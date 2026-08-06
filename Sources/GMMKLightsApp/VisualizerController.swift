import Foundation
import GMMKHID
import GMMKProtocol
import GloriousAudioCapture
import GloriousVisualizer

/// Runs the audio visualizer: audio in, frames onto the keyboard.
///
/// ## Four clocks, and the boundaries between them are the design
///
/// * **The capture thread** copies samples into ``VisualizerEngine`` and does
///   nothing else. It never touches the transport and never blocks.
/// * **The analysis stage** runs inside the engine at ~94 Hz, on the capture
///   thread's back, independent of the display rate.
/// * **The render thread**, created here, runs a **fixed-rate clock**: it waits
///   for a deadline, composes the frame *for that deadline's timestamp*, hands
///   it to a single-slot buffer and returns. It never waits on the transport.
/// * **The transport thread** owns the keyboard, takes whatever frame is in the
///   slot, diffs it against the last one sent and writes only the keys that
///   changed.
///
/// The old loop did all of this on one thread and slept "the remainder of the
/// frame" after the USB write, which meant the frame rate was whatever the
/// transport sustained and a stalled packet froze the display for seconds. Now
/// a slow transport shows up as *dropped frames* and nothing else: the model's
/// timing is untouched, and because gestures are continuous functions of time
/// the next delivered frame shows them where they genuinely are (P6).
final class VisualizerController {

    /// Display frames per second. Reachable because the transport writes only
    /// changed keys; the design is correct at 15 too, and every ballistic clamp
    /// in the engine is expressed in terms of the frame interval rather than in
    /// terms of any particular rate.
    static let targetFrameRate: Double = 30

    /// What the visualizer asks of the transport: a short reply timeout and few
    /// attempts. A frame is worth at most a frame's time; a packet that has not
    /// been echoed in 60 ms will not be echoed.
    static let visualizerReplyTimeout: TimeInterval = 0.060
    static let visualizerSendAttempts = 2

    private let lease: TransportLease
    private var capture: AudioSourceCapturing?

    /// Which source the next start will use.
    var source: AudioSource

    private let keyboard = GMMKKeyboard()
    private var engine: VisualizerEngine?
    private let frameSlot = FrameSlot()
    private let budgetLock = NSLock()
    private var budget = PacketBudget()
    private var renderThread: Thread?
    private var transportThread: Thread?

    private let settingsLock = NSLock()
    private var mode: VisualizerMode
    private var themeColor: RGB
    private var sensitivity: Double
    private var autoGainEnabled: Bool

    /// Written on the main thread, read in both background loop conditions.
    private let isStopping = AtomicFlag(false)

    private(set) var isRunning = false
    private(set) var lastError: String?
    var onStatusChange: (() -> Void)?

    init(lease: TransportLease,
         source: AudioSource,
         mode: VisualizerMode,
         themeColor: RGB,
         sensitivity: Double,
         autoGain: Bool) {
        self.lease = lease
        self.source = source
        self.mode = mode
        self.themeColor = themeColor
        self.sensitivity = sensitivity
        self.autoGainEnabled = autoGain
    }

    // MARK: - Settings

    func update(mode: VisualizerMode? = nil,
                themeColor: RGB? = nil,
                sensitivity: Double? = nil,
                autoGain: Bool? = nil) {
        settingsLock.lock()
        if let mode { self.mode = mode }
        if let themeColor { self.themeColor = themeColor }
        if let sensitivity { self.sensitivity = sensitivity }
        if let autoGain { self.autoGainEnabled = autoGain }
        settingsLock.unlock()
    }

    private var currentSettings: (mode: VisualizerMode, color: RGB,
                                  sensitivity: Double, autoGain: Bool) {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return (mode, themeColor, sensitivity, autoGainEnabled)
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard lease.acquire(.visualizer) else {
            return fail("Something else is driving the keyboard right now.")
        }

        guard let capture = makeCapture() else {
            lease.release(.visualizer)
            return fail("Capturing system audio needs macOS 14.2 or later.")
        }
        self.capture = capture

        let settings = currentSettings
        let engine = VisualizerEngine(sampleRate: capture.sampleRate,
                                      frameRate: Self.targetFrameRate,
                                      mode: settings.mode,
                                      themeColor: settings.color)
        engine.sensitivity = settings.sensitivity
        self.engine = engine

        // The capture callback does one thing: hand the samples over. The FFT
        // runs inside, on this thread, but nothing else does — no locks held
        // across it, no transport, no allocation of frames.
        capture.onSamples = { [weak engine] samples in
            engine?.ingest(samples, hostTime: ProcessInfo.processInfo.systemUptime)
        }

        do {
            try capture.start()
        } catch {
            self.capture = nil
            self.engine = nil
            lease.release(.visualizer)
            return fail(String(describing: error))
        }

        // The tap reports its own rate, which need not be the one assumed before
        // it started, and every band edge derives from it.
        if abs(capture.sampleRate - engine.analyzer.sampleRate) > 1 {
            let corrected = VisualizerEngine(sampleRate: capture.sampleRate,
                                             frameRate: Self.targetFrameRate,
                                             mode: settings.mode,
                                             themeColor: settings.color)
            corrected.sensitivity = settings.sensitivity
            self.engine = corrected
            capture.onSamples = { [weak corrected] samples in
                corrected?.ingest(samples, hostTime: ProcessInfo.processInfo.systemUptime)
            }
        }

        isStopping.value = false
        let transport = Thread { [weak self] in self?.transportLoop() }
        transport.name = "com.glorious-lights.visualizer.transport"
        transport.qualityOfService = .userInitiated
        transportThread = transport
        transport.start()

        let render = Thread { [weak self] in self?.renderLoop() }
        render.name = "com.glorious-lights.visualizer.render"
        // Above default so a busy main thread does not stutter the display, but
        // below the audio thread, which must never wait on us.
        render.qualityOfService = .userInitiated
        renderThread = render
        render.start()

        isRunning = true
        lastError = nil
        onStatusChange?()
        return true
    }

    /// Stops rendering and hands the transport back. Main thread.
    func stop() { stop(because: nil) }

    /// The single teardown path, whether the user asked or the transport failed.
    ///
    /// A transport-thread failure used to call `fail(...)` and return, which set
    /// a message and nothing else: the lease stayed held by `.visualizer` — so
    /// every menu action was refused for the rest of the session — the render
    /// thread went on composing at 30 fps into a slot nobody drained, and
    /// `start()` returned early on `guard !isRunning`. There was no way back
    /// except finding and toggling stop.
    private func stop(because failure: String?) {
        guard isRunning else {
            if let failure { fail(failure) }
            return
        }
        capture?.stop()
        capture?.onSamples = nil
        capture = nil

        isStopping.value = true
        while renderThread?.isFinished == false || transportThread?.isFinished == false {
            Thread.sleep(forTimeInterval: 0.005)
        }
        lastTiming = timingSummary
        renderThread = nil
        transportThread = nil
        engine = nil

        lease.release(.visualizer)
        isRunning = false
        lastError = failure
        onStatusChange?()
    }

    /// What the render clock and the frame handoff actually did, for §10.5's
    /// first open measurement gap: nothing on the hardware side recorded the
    /// tick distribution, the stale-frame rate or the dropped-frame count, so
    /// "does the board actually run at 30 fps?" had no answer off the simulator.
    private var timingSummary: String? {
        guard let engine, engine.telemetry.frames > 0 else { return lastTiming }
        let telemetry = engine.telemetry
        let delivered = frameSlot.deliveredFrames + frameSlot.droppedFrames
        return String(format: "%d frames, tick p95 %.1f ms / max %.1f ms, "
                      + "%.1f %% late, %.1f %% stale, %.1f %% delivered",
                      telemetry.frames,
                      telemetry.intervalP95 * 1000, telemetry.intervalMax * 1000,
                      100 * Double(telemetry.lateFrames) / Double(telemetry.frames),
                      100 * telemetry.staleFraction,
                      delivered > 0
                          ? 100 * Double(frameSlot.deliveredFrames) / Double(delivered) : 0)
            + (packetSummary.map { ", " + $0 } ?? "")
    }

    private var packetSummary: String? {
        budgetLock.lock()
        defer { budgetLock.unlock() }
        return budget.summary
    }

    /// The last run's timing summary, for the menu to show.
    private(set) var lastTiming: String?

    private func makeCapture() -> AudioSourceCapturing? {
        switch source {
        case .microphone:  return AudioCapture()
        case .systemAudio: return SystemAudio.makeCapture()
        }
    }

    @discardableResult
    private func fail(_ message: String) -> Bool {
        lastError = message
        onStatusChange?()
        return false
    }

    // MARK: - Render loop

    /// The fixed-rate clock of §1.1.
    ///
    /// Two properties matter and both were wrong before:
    ///
    /// * frames are composed **for their scheduled timestamp**, not for the
    ///   instant the thread happened to wake, so a late wake-up does not become
    ///   motion jitter;
    /// * the deadline advances by a whole frame interval, so the loop cannot
    ///   free-run — the old "sleep whatever is left of the frame" pattern let
    ///   USB latency set the frame rate.
    private func renderLoop() {
        guard let engine else { return }
        let interval = engine.frameInterval
        var next = ProcessInfo.processInfo.systemUptime + interval

        while !isStopping.value {
            let now = ProcessInfo.processInfo.systemUptime
            if next > now { Thread.sleep(forTimeInterval: next - now) }
            if isStopping.value { break }

            let settings = currentSettings
            engine.mode = settings.mode
            engine.themeColor = settings.color
            engine.sensitivity = settings.sensitivity
            engine.autoGain = settings.autoGain

            // Compose for the SCHEDULED time, not for `now`.
            frameSlot.put(engine.renderFrame(at: next), scheduledFor: next)

            next += interval
            // Catch up by whole intervals if we overran, so the phase of the
            // clock is preserved rather than drifting with each late frame.
            let after = ProcessInfo.processInfo.systemUptime
            if next < after { next = after + interval }
        }
    }

    // MARK: - Transport loop

    /// Owns the keyboard and the echo pacer. Takes whatever frame is in the slot
    /// and writes only the keys whose bytes changed.
    private func transportLoop() {
        // Captured once: `engine` is written on the main thread at teardown, and
        // reading it per frame from here would be a data race on the one path
        // that runs at 30 Hz.
        let engine = self.engine
        keyboard.replyTimeout = Self.visualizerReplyTimeout
        keyboard.maxSendAttempts = Self.visualizerSendAttempts
        do {
            try keyboard.open()
            try keyboard.beginStreaming()
        } catch {
            keyboard.stop()
            reportFailure(String(describing: error))
            return
        }

        var lastSent: [RGB]?
        while !isStopping.value {
            guard let frame = frameSlot.take() else {
                // Nothing new to send. Sleep a fraction of a frame rather than
                // spinning; the render clock is what decides timing.
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }

            let plan = FramePackets.plan(for: frame.colors, lastSent: lastSent)
            lastSent = frame.colors
            budgetLock.lock()
            budget.record(plan)
            budgetLock.unlock()
            guard !plan.packets.isEmpty else { continue }

            do {
                try keyboard.sendFrame(packets: GMMKTransaction.bracket(plan.packets))
            } catch {
                reportFailure(String(describing: error))
                break
            }
            // `END` has been echoed by the time `sendFrame` returns, so this is
            // exactly §8.2-R's `t_END_echoed − t_scheduled` — the one term of
            // `L̂` that has to come from the wire. P10: the compensating latency
            // is measured live, never assumed.
            engine?.reportDelivery(
                lag: ProcessInfo.processInfo.systemUptime - frame.scheduledFor)

        }

        keyboard.endStreaming()
        keyboard.stop()
    }

    /// Called from the transport thread. Asks every loop to wind down now, then
    /// hands the teardown — which owns the lease and joins the threads — to the
    /// main thread.
    private func reportFailure(_ message: String) {
        isStopping.value = true
        DispatchQueue.main.async { [weak self] in self?.stop(because: message) }
    }

    /// §7.2-R's packet budget, measured rather than hoped for.
    ///
    /// The audit's single biggest measurement gap was that nothing counted
    /// anything, so "does the board actually run at 30 fps?" had no answer off
    /// the simulator. The packet count per frame is the other half of that: it
    /// is what decides whether the transport can deliver a frame inside its
    /// slot, and it is the input to `L̂`.
    private struct PacketBudget {
        var counts: [Int] = []
        var fallbacks = 0
        var frames = 0

        mutating func record(_ plan: FramePackets.Plan) {
            frames += 1
            counts.append(plan.colourPackets)
            if counts.count > 4096 { counts.removeFirst(counts.count - 4096) }
            if plan.fullRepaint { fallbacks += 1 }
        }

        var summary: String? {
            guard !counts.isEmpty else { return nil }
            let sorted = counts.sorted()
            func at(_ fraction: Double) -> Int {
                sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
            }
            return String(format: "packets/frame p50 %d / p95 %d / max %d, %.1f %% repaint",
                          at(0.5), at(0.95), sorted.last ?? 0,
                          100 * Double(fallbacks) / Double(max(frames, 1)))
        }
    }
}
