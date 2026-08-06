import Foundation
import GMMKProtocol

/// The whole visualizer behind one object: audio in on one clock, frames out on
/// another, and nothing shared between them but a lock-free-in-spirit handoff.
///
/// The app and the offline simulator both drive *this*, so a number measured in
/// `viz-sim` is a claim about the app rather than about a copy of it. The two
/// entry points are deliberately the only ones:
///
/// * ``ingest(_:hostTime:)`` — called from the audio callback (which does
///   nothing else), runs the analysis stage at ~94 Hz.
/// * ``renderFrame(at:)`` — called from the fixed-rate render clock, composes
///   the frame for its **scheduled** timestamp.
///
/// Neither waits for the other (P3), and the renderer never touches the
/// transport (P6).
public final class VisualizerEngine {

    public let analyzer: MusicAnalyzer
    public let bus = AnalysisBus()
    public let renderer: ModeRenderer

    /// Display frame interval. Every ballistic clamp in the system is expressed
    /// in terms of this, never in terms of 30 or 15.
    public let frameInterval: Double

    /// User gain on the composed picture, `>0`. Applied to the model's own
    /// output, so the interlock still sees what the modes asked for.
    public var sensitivity: Double = 1.0
    /// User brightness, applied after the interlock and before the gamma encode.
    public var brightness: Double = 1.0

    private var interlock = KeyInterlock()
    private var history: [AnalysisState] = []
    private var lastFrameTime: Double?
    private var latency: LatencyEstimate

    /// The §8.3 user offset, ±100 ms, signed. Fixed capture latency differs per
    /// machine and per output device; it should be dialled out, not designed
    /// around.
    public var userOffset: Double {
        get { latency.userOffset }
        set { latency.userOffset = clamp(newValue, -0.100, 0.100) }
    }

    /// One delivered frame's measured `t_END_echoed − t_scheduled` (§8.2-R).
    ///
    /// Called from the transport thread on hardware and from the harness in
    /// `viz-sim`. Nothing else feeds `L̂`: P10 requires the compensating latency
    /// to be measured live, and a design that compensates a mean it never
    /// measured is indistinguishable from one that got lucky.
    public func reportDelivery(lag: Double) {
        latency.record(deliveryLag: lag, dt: frameInterval)
    }

    /// What the scheduler is currently compensating, in seconds.
    public var measuredLatency: Double { latency.value }

    /// How far past the newest analysis state the renderer may extrapolate
    /// before the frame is counted as stale (§6.1).
    public static let extrapolationLimit: Double = 0.020

    public private(set) var telemetry = Telemetry()

    public init(sampleRate: Double,
                frameRate: Double,
                mode: VisualizerMode = .pulse,
                themeColor: RGB = RGB(red: 0x00, green: 0xCC, blue: 0xAA),
                useThemeColor: Bool = false) {
        let interval = 1 / max(frameRate, 1)
        self.frameInterval = interval
        self.latency = LatencyEstimate(frameInterval: interval)
        self.analyzer = MusicAnalyzer(sampleRate: sampleRate, frameInterval: interval)
        self.renderer = ModeRenderer(mode: mode, themeColor: themeColor,
                                     useThemeColor: useThemeColor, frameInterval: interval)
    }

    public var mode: VisualizerMode {
        get { renderer.mode }
        set { renderer.mode = newValue }
    }

    public var themeColor: RGB {
        get { renderer.themeColor }
        set { renderer.themeColor = newValue }
    }

    /// Whether the percentile AGC may move the gain (§3.3).
    public var autoGain: Bool {
        get { analyzer.autoGain.value }
        set { analyzer.autoGain.value = newValue }
    }

    // MARK: - Analysis side

    /// Runs analysis over whatever whole hops these samples complete.
    ///
    /// - Parameter hostTime: when the last sample was captured.
    public func ingest(_ samples: [Float], hostTime: Double) {
        analyzer.ingest(samples, hostTime: hostTime, into: bus)
    }

    // MARK: - Render side

    /// Composes one frame for the time it was **scheduled** for, not for the
    /// instant the thread happened to wake.
    ///
    /// That single choice removes the render-side contribution to motion jitter
    /// entirely: even if the thread wakes eight milliseconds late, the gesture
    /// positions it computes are the ones belonging to that frame's slot in time.
    public func renderFrame(at time: Double) -> [RGB] {
        let dt = lastFrameTime.map { max(time - $0, 0) } ?? frameInterval
        lastFrameTime = time
        telemetry.record(interval: dt, expected: frameInterval)
        renderer.latency = latency.advance(dt: dt)

        let taken = bus.take()
        for state in taken.states {
            if let last = history.last, state.time <= last.time { continue }
            history.append(state)
        }
        if history.count > 3 { history.removeFirst(history.count - 3) }

        guard var state = interpolate(to: time) else {
            // Nothing has been analysed yet: a dark board is the honest answer.
            telemetry.stale += 1
            return [RGB](repeating: .black, count: GMMKKeyMap.paintableLEDIndices.count)
        }
        applyPeakHold(&state, peaks: taken.peaks)

        let canvas = renderer.render(state: state, onsets: taken.onsets, time: time)
        // Master brightness is applied **once**, here, at the end of the
        // composition (§6.2) — never inside a mode. Modes compose in relative
        // units, so a quiet passage dims the whole picture instead of quietly
        // shrinking every gesture's amplitude, and there is exactly one place
        // where "how loud is this material, really" enters the render.
        return encode(canvas, brightness: clamp(brightness, 0, 1) * state.master,
                      now: time, dt: dt)
    }

    private func encode(_ canvas: LinearCanvas, brightness: Double,
                        now: Double, dt: Double) -> [RGB] {
        var levels = [(r: Double, g: Double, b: Double)](
            repeating: (0, 0, 0), count: GMMKKeyMap.paintableLEDIndices.count)
        // Master and user brightness are applied *before* the interlock, not
        // after it as §6.2's ordering implies. The interlock's promise — "once
        // lit, a key stays lit for at least 150 ms" — is a promise about what
        // the board shows, and any multiplier applied downstream can void it by
        // dragging a held key back under the visible threshold. Measured: with
        // the multiply last, the p10 on-duration collapsed to 30–70 ms on every
        // case whose loudness moves, which is the metric the interlock exists to
        // guarantee.
        //
        // The *user's* sensitivity is the exception, and goes after. It is a
        // taste control on how bright the board is, not a statement about the
        // material, and putting it upstream made the interlock's own decisions
        // depend on it: at the shipped minimum the whole composed picture
        // landed under the 0.14 rise threshold, so the board went dark between
        // gestures and every gesture became an on→off→on cycle for every key it
        // touched — measured flicker p95 went from 0.000 to 1.000 purely by
        // moving the slider. Downstream of the interlock the hold decisions are
        // made on what the modes asked for, which is what this type's own
        // documentation has always claimed.
        let scale = brightness
        func write(_ led: UInt16, _ colour: (r: Double, g: Double, b: Double)) {
            let offset = Int(led) - Int(GMMKKeyMap.minLEDIndex)
            guard levels.indices.contains(offset) else { return }
            levels[offset] = (max(levels[offset].r, colour.r * scale),
                              max(levels[offset].g, colour.g * scale),
                              max(levels[offset].b, colour.b * scale))
        }
        for (index, column) in VisualizerLayout.columns.enumerated() {
            for (rowIndex, row) in column.levelRows.enumerated() {
                let colour = canvas.sample(column: index, physicalRow: rowIndex,
                                           of: column.rowCount)
                for led in row { write(led, colour) }
            }
            let peak = canvas.peak(column: index)
            for led in column.peakKeys { write(led, peak) }
        }
        return interlock.encode(levels, sensitivity: max(sensitivity, 0), now: now, dt: dt)
    }

    /// Finds the analysis states bracketing `time` and evaluates them there.
    ///
    /// The old renderer latched whichever levels it happened to see, at an
    /// arbitrary phase: five of every six analysis frames were discarded, and a
    /// transient peaking between display frames was caught at full or missed
    /// entirely depending on phase. That aliasing then poisoned the noise floor
    /// and the auto-gain, so the whole board's brightness inherited the sampling
    /// jitter.
    private func interpolate(to time: Double) -> AnalysisState? {
        guard let newest = history.last else { return nil }
        if time >= newest.time {
            let ahead = time - newest.time
            if ahead > Self.extrapolationLimit { telemetry.stale += 1 }
            return extrapolate(newest, by: min(ahead, Self.extrapolationLimit))
        }
        guard history.count >= 2 else { return newest }
        // Bracket, then Catmull-Rom across three states when a third exists so
        // there is no velocity discontinuity at a state boundary.
        for index in stride(from: history.count - 1, through: 1, by: -1) {
            let a = history[index - 1], b = history[index]
            guard time >= a.time, time < b.time else { continue }
            let span = max(b.time - a.time, 1e-9)
            let t = (time - a.time) / span
            if index >= 2 {
                return AnalysisState.catmullRom(history[index - 2], a, b, t)
            }
            return AnalysisState.mix(a, b, t)
        }
        return history.first
    }

    /// Extrapolation is safe only with the envelope's own time constant, because
    /// the envelope *is* an exponential. Ratios and gates are held: decaying a
    /// dimensionless ratio toward zero would be meaningless.
    private func extrapolate(_ state: AnalysisState, by ahead: Double) -> AnalysisState {
        guard ahead > 0 else { return state }
        var out = state
        out.time = state.time + ahead
        for (channel, tau) in Self.decayingChannels {
            out.channels[channel] = state.channels[channel] * exp(-ahead / tau)
        }
        if state.tempo.bpm > 0 {
            var phase = state.tempo.phase + ahead / state.tempo.beatPeriod
            phase -= phase.rounded(.down)
            out.tempo.phase = phase
        }
        return out
    }

    /// Which channels decay to zero on their own, and with what time constant.
    private static let decayingChannels: [(Int, Double)] = {
        var table: [(Int, Double)] = []
        for kind in OnsetKind.allCases {
            let envelope = kind.accentEnvelope(frameInterval: 1.0 / 30)
            table.append((AnalysisState.Channel.accent(kind), envelope.release))
        }
        return table
    }()

    /// Bar heights take the maximum of the interpolated value and the peak the
    /// analyser saw since the renderer last looked, so a transient between
    /// display frames is never lost. This is the treatment onsets already got
    /// and levels never did.
    private func applyPeakHold(_ state: inout AnalysisState, peaks: [Double]) {
        guard peaks.count == state.channels.count else { return }
        for register in 0..<AnalysisState.registerCount {
            let channel = AnalysisState.Channel.register(register)
            state.channels[channel] = max(state.channels[channel], peaks[channel])
            let peakChannel = AnalysisState.Channel.registerPeak(register)
            state.channels[peakChannel] = max(state.channels[peakChannel], peaks[peakChannel])
        }
        for kind in OnsetKind.allCases {
            let channel = AnalysisState.Channel.accent(kind)
            state.channels[channel] = max(state.channels[channel], peaks[channel])
        }
    }

    public func reset() {
        analyzer.reset()
        bus.reset()
        renderer.reset()
        interlock.reset()
        latency.reset()
        history.removeAll()
        lastFrameTime = nil
        telemetry = Telemetry()
    }

    /// What the render clock and the analysis handoff actually did.
    ///
    /// The audit's biggest measurement gap was that nothing counted anything, so
    /// "does the board actually run at 15 fps?" had no answer. It has one now.
    public struct Telemetry: Sendable {
        public var frames = 0
        public var stale = 0
        public private(set) var intervals: [Double] = []
        public var lateFrames = 0

        mutating func record(interval: Double, expected: Double) {
            frames += 1
            intervals.append(interval)
            if intervals.count > 2048 { intervals.removeFirst(intervals.count - 2048) }
            if interval > expected * 1.15 { lateFrames += 1 }
        }

        public var intervalP95: Double {
            guard !intervals.isEmpty else { return 0 }
            let sorted = intervals.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        }
        public var intervalMax: Double { intervals.max() ?? 0 }
        public var staleFraction: Double {
            frames > 0 ? Double(stale) / Double(frames) : 0
        }
    }
}

/// A single-slot handoff to the transport, with replace semantics.
///
/// Backpressure shows up as a lower *delivered* frame rate and never as a
/// distorted render clock (P6). Because gestures are continuous functions of
/// time, a skipped frame loses nothing structurally — the next delivered frame
/// shows the gesture where it genuinely is.
public final class FrameSlot: @unchecked Sendable {

    /// A composed frame and the timestamp it was composed **for**.
    ///
    /// The scheduled time travels with the frame because the transport is the
    /// only place that can measure `t_END_echoed − t_scheduled`, and that
    /// difference is the one term of `L̂` nothing else can supply (§8.2-R).
    public struct Frame: Sendable {
        public var colors: [RGB]
        public var scheduledFor: Double
    }

    private let lock = NSLock()
    private var frame: Frame?
    private var dropped = 0
    private var delivered = 0

    public init() {}

    public func put(_ colors: [RGB], scheduledFor time: Double) {
        lock.lock()
        if frame != nil { dropped += 1 }
        frame = Frame(colors: colors, scheduledFor: time)
        lock.unlock()
    }

    public func take() -> Frame? {
        lock.lock()
        defer {
            if frame != nil { delivered += 1 }
            frame = nil
            lock.unlock()
        }
        return frame
    }

    public var droppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    public var deliveredFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return delivered
    }
}
