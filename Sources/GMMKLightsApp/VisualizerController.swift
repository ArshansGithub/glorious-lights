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
    private var renderThread: Thread?
    private var transportThread: Thread?

    private let settingsLock = NSLock()
    private var mode: VisualizerMode
    private var themeColor: RGB
    private var sensitivity: Double
    private var autoGainEnabled: Bool

    private var isStopping = false

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

        isStopping = false
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
    func stop() {
        guard isRunning else { return }
        capture?.stop()
        capture?.onSamples = nil
        capture = nil

        isStopping = true
        while renderThread?.isFinished == false || transportThread?.isFinished == false {
            Thread.sleep(forTimeInterval: 0.005)
        }
        renderThread = nil
        transportThread = nil
        engine = nil

        lease.release(.visualizer)
        isRunning = false
        onStatusChange?()
    }

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

        while !isStopping {
            let now = ProcessInfo.processInfo.systemUptime
            if next > now { Thread.sleep(forTimeInterval: next - now) }
            if isStopping { break }

            let settings = currentSettings
            engine.mode = settings.mode
            engine.themeColor = settings.color
            engine.sensitivity = settings.sensitivity

            // Compose for the SCHEDULED time, not for `now`.
            frameSlot.put(engine.renderFrame(at: next))

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
        keyboard.replyTimeout = Self.visualizerReplyTimeout
        keyboard.maxSendAttempts = Self.visualizerSendAttempts
        do {
            try keyboard.open()
            try keyboard.beginStreaming()
        } catch {
            let message = String(describing: error)
            DispatchQueue.main.async { [weak self] in self?.fail(message) }
            keyboard.stop()
            return
        }

        var lastSent: [RGB]?
        while !isStopping {
            guard let frame = frameSlot.take() else {
                // Nothing new to send. Sleep a fraction of a frame rather than
                // spinning; the render clock is what decides timing.
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }

            let packets = Self.packets(for: frame, lastSent: lastSent)
            lastSent = frame
            guard !packets.isEmpty else { continue }

            do {
                try keyboard.sendFrame(packets: GMMKTransaction.bracket(packets))
            } catch {
                let message = String(describing: error)
                DispatchQueue.main.async { [weak self] in self?.fail(message) }
                break
            }
        }

        keyboard.endStreaming()
        keyboard.stop()
    }

    /// Dirty-region diffing (§7.2).
    ///
    /// The old path sent a full 126-LED repaint every frame — `START`, seven
    /// colour packets, `END`, all echo-paced — whatever was on screen. On
    /// typical material most keys do not change between frames, and the colour
    /// command takes an arbitrary start index and length, so a frame costs one
    /// packet per contiguous run of changed keys. That is what makes 30 fps
    /// reachable at all.
    static func packets(for frame: [RGB], lastSent: [RGB]?) -> [[UInt8]] {
        guard let lastSent, lastSent.count == frame.count else {
            return GMMKPacket.customColorPackets(startKeyIndex: GMMKKeyMap.minLEDIndex,
                                                 colors: frame)
        }
        var packets: [[UInt8]] = []
        var index = 0
        while index < frame.count {
            guard frame[index] != lastSent[index] else {
                index += 1
                continue
            }
            var end = index
            // A run ends after a few unchanged keys rather than at the first
            // one: two packets with a one-key gap cost more than one packet
            // that repaints the gap.
            var gap = 0
            var scan = index
            while scan < frame.count {
                if frame[scan] != lastSent[scan] {
                    end = scan
                    gap = 0
                } else {
                    gap += 1
                    if gap > 4 { break }
                }
                scan += 1
            }
            packets += GMMKPacket.customColorPackets(
                startKeyIndex: GMMKKeyMap.minLEDIndex + UInt16(index),
                colors: Array(frame[index...end]))
            index = end + 1
        }
        return packets
    }
}
