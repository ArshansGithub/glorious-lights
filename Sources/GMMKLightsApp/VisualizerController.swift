import Foundation
import GMMKHID
import GMMKProtocol
import GloriousAudioCapture
import GloriousVisualizer

/// Runs the audio visualizer: microphone in, spectrum out, frames onto the
/// keyboard.
///
/// ## Threads
///
/// Three, and the boundaries between them are the whole design.
///
/// * **AVAudioEngine's render thread** delivers sample buffers. It does the FFT
///   and stores the result in ``latestLevels``. It never touches the transport
///   and never blocks — a render thread that waits on USB drops audio.
/// * **The render thread**, created here, owns its own ``GMMKKeyboard`` and its
///   own run loop, because that class is one-thread-at-a-time by design. It
///   loops: take the newest levels, smooth, paint, send, sleep the remainder of
///   the frame.
/// * **The main thread** starts and stops all of it and owns the UI.
///
/// The two hand-offs are a lock around ``latestLevels`` and a ``TransportLease``
/// that stops the menu's own keyboard instance from sending while this one is
/// running.
///
/// ## Coalescing rather than queueing
///
/// The audio thread *overwrites* the pending levels instead of appending to a
/// queue. If the transport falls behind, the frames it missed are simply gone —
/// which is what a live display wants. A queue would build a backlog and the
/// bars would drift steadily further behind the music.
///
/// > TODO: the mouse's six LEDs could pulse to the beat alongside this. Not
/// > built — the mouse's write path is a whole-blob read-modify-write, so it
/// > cannot sustain a frame rate and would need its own much slower beat-driven
/// > path rather than a share of this one.
final class VisualizerController {

    /// Frames per second to aim for. Fast enough to read as live, slow enough
    /// that the echo-paced transport can keep up without the render loop
    /// spending all its time waiting.
    static let targetFrameRate: Double = 15

    private let lease: TransportLease
    /// Built per session from ``source``, because the two sources are different
    /// objects with different lifetimes — everything downstream is identical.
    private var capture: AudioSourceCapturing?

    /// Which source the next start will use. Changing it while running has no
    /// effect until the session is restarted; the delegate does that.
    var source: AudioSource

    /// The visualizer's own transport, touched only from ``renderThread``.
    private let keyboard = GMMKKeyboard()

    /// The shared analysis-and-display pipeline. The audio thread feeds it and
    /// the render thread advances it; it owns the coalescing, so there is no
    /// second copy of the gate, gain or smoothing here for the simulator to
    /// drift away from.
    private var pipeline: VisualizerPipeline?
    private var renderThread: Thread?

    /// Set on the main thread, read by the render thread; guarded by its own
    /// lock so a style change mid-frame cannot tear.
    private let settingsLock = NSLock()
    private var mode: VisualizerMode
    private var themeColor: RGB
    private var sensitivity: Double
    private var autoGainEnabled: Bool

    private var isStopping = false

    /// Whether the visualizer is running. Main thread only.
    private(set) var isRunning = false

    /// Last error, for the menu to show. Main thread only.
    private(set) var lastError: String?

    /// Fires when ``isRunning`` or ``lastError`` changes.
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

    /// Starts capture and rendering. Main thread.
    ///
    /// - Returns: `false` if it could not start, with ``lastError`` set.
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
        let pipeline = VisualizerPipeline(
            sampleRate: Float(capture.sampleRate),
            bandCount: VisualizerLayout.columns.count,
            tuning: .init(sensitivity: settings.sensitivity,
                          autoGain: settings.autoGain,
                          sourceProfile: source == .microphone ? .room : .music))
        self.pipeline = pipeline
        // The FFT happens on the audio thread, so the render thread only ever
        // does arithmetic on 17 floats before sending.
        capture.onSamples = { [weak pipeline] samples in pipeline?.analyze(samples) }

        do {
            try capture.start()
        } catch {
            self.capture = nil
            lease.release(.visualizer)
            return fail(String(describing: error))
        }

        // The tap reports its own rate, which need not be the 48 kHz assumed
        // before it started, and the band edges are derived from it — so the
        // pipeline is rebuilt once the real rate is known.
        if abs(capture.sampleRate - Double(pipeline.sampleRate)) > 1 {
            let corrected = VisualizerPipeline(
                sampleRate: Float(capture.sampleRate),
                bandCount: VisualizerLayout.columns.count,
                tuning: .init(sensitivity: settings.sensitivity,
                              autoGain: settings.autoGain,
                              sourceProfile: source == .microphone ? .room : .music))
            self.pipeline = corrected
            capture.onSamples = { [weak corrected] samples in corrected?.analyze(samples) }
        }

        isStopping = false
        let thread = Thread { [weak self] in self?.renderLoop() }
        thread.name = "com.glorious-lights.visualizer"
        // Above default so a busy main thread does not stutter the display, but
        // below the audio thread, which must never wait on us.
        thread.qualityOfService = .userInitiated
        renderThread = thread
        thread.start()

        isRunning = true
        lastError = nil
        onStatusChange?()
        return true
    }

    /// Stops rendering and hands the transport back. Main thread.
    ///
    /// Returns once the render thread has finished, so a caller can immediately
    /// re-apply the user's own look without racing a final frame.
    func stop() {
        guard isRunning else { return }
        capture?.stop()
        capture?.onSamples = nil
        capture = nil

        isStopping = true
        // The render loop checks the flag once per frame, so this is bounded by
        // one frame plus one transaction.
        while renderThread?.isFinished == false {
            Thread.sleep(forTimeInterval: 0.005)
        }
        renderThread = nil
        pipeline = nil

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

    private func renderLoop() {
        let frameInterval = 1 / Self.targetFrameRate
        var lastFrame = ProcessInfo.processInfo.systemUptime
        let renderer = ModeRenderer(mode: currentSettings.mode,
                                    themeColor: currentSettings.color)

        do {
            try keyboard.open()
            try keyboard.beginStreaming()
        } catch {
            let message = String(describing: error)
            DispatchQueue.main.async { [weak self] in self?.fail(message) }
            keyboard.stop()
            return
        }

        while !isStopping {
            let frameStart = ProcessInfo.processInfo.systemUptime
            let elapsed = frameStart - lastFrame
            lastFrame = frameStart

            // The pipeline holds the newest analysis and drops anything older,
            // so a slow frame loses intermediate audio rather than accumulating
            // a backlog.
            let settings = currentSettings
            guard let pipeline else { break }
            pipeline.tuning.sensitivity = settings.sensitivity
            pipeline.tuning.autoGain = settings.autoGain

            renderer.mode = settings.mode
            renderer.themeColor = settings.color
            let musical = pipeline.musicalFrame(elapsed: elapsed)
            let colors = renderer.render(musical, elapsed: elapsed)

            do {
                try keyboard.sendFrame(
                    packets: GMMKTransaction.bracket(
                        GMMKPacket.customColorPackets(startKeyIndex: GMMKKeyMap.minLEDIndex,
                                                      colors: colors)))
            } catch {
                let message = String(describing: error)
                DispatchQueue.main.async { [weak self] in self?.fail(message) }
                break
            }

            // Sleep only what is left of the frame. If the transaction took
            // longer than the interval, go straight round again — the display
            // simply runs at whatever rate the transport sustains.
            let spent = ProcessInfo.processInfo.systemUptime - frameStart
            if spent < frameInterval {
                Thread.sleep(forTimeInterval: frameInterval - spent)
            }
        }

        keyboard.endStreaming()
        keyboard.stop()
    }
}
