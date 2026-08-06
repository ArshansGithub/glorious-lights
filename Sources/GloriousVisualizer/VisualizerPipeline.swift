import Foundation

/// Everything between "band levels" and "bar heights", in one place.
///
/// This exists so the app and the offline simulator cannot drift apart. The gain
/// stage, the noise gate and the smoothing used to live in the app's render
/// loop, which meant tuning against a simulator would have been tuning against a
/// copy. Both now call this; there is no second implementation to keep in step.
///
/// The split into ``analyze(_:)`` and ``advance(elapsed:)`` is deliberate rather
/// than cosmetic: in the app the FFT runs on the audio thread and the display
/// advances on the render thread, so the two halves genuinely happen in
/// different places. The simulator calls them one after the other.
public final class VisualizerPipeline {

    /// Everything a user can turn.
    public struct Tuning: Equatable, Sendable {
        /// Input gain multiplier applied after the gate.
        public var sensitivity: Double
        /// Whether to normalise to recent peaks.
        public var autoGain: Bool
        /// How far above the *observed* noise floor a band must sit before it
        /// counts as signal, in dB. `-.infinity` disables the gate.
        ///
        /// Relative, not absolute: an absolute threshold cannot serve both a
        /// room microphone and a line-level system tap, which differ by roughly
        /// 40 dB. See ``NoiseFloorTracker``.
        public var gateMarginDB: Double
        /// Whether the analyzer flattens pink noise. Off is the pre-tuning
        /// behaviour, for measuring against.
        public var equalization: Bool

        public init(sensitivity: Double = 1.0,
                    autoGain: Bool = true,
                    gateMarginDB: Double = VisualizerPipeline.defaultGateMarginDB,
                    equalization: Bool = true) {
            self.sensitivity = sensitivity
            self.autoGain = autoGain
            self.gateMarginDB = gateMarginDB
            self.equalization = equalization
        }

        /// What the visualizer did before any live-test tuning: no gate, no
        /// equalisation, and a flat multiplier. Kept so before/after can be
        /// measured with one binary.
        public static let preTuning = Tuning(sensitivity: 2.0,
                                             gateMarginDB: -.infinity,
                                             equalization: false)
    }

    /// How far above its own noise floor a band must climb to open the gate.
    ///
    /// 9 dB is comfortably above the frame-to-frame wobble of a settled floor
    /// without needing the signal to be loud — which is the whole point, since a
    /// quiet room mic never gets loud in absolute terms.
    public static let defaultGateMarginDB: Double = 9

    /// How much of the margin a band must give back before the gate closes
    /// again, in dB.
    ///
    /// Without this, a band sitting exactly at the floor chatters — open, shut,
    /// open — once per frame, which is precisely the flicker the gate is meant
    /// to remove. 6 dB is the usual starting point for a gate's hysteresis and
    /// is about the smallest step that reads as deliberate rather than noisy.
    public static let gateHysteresisDB: Double = 6

    /// Below this fraction of full height, a bar is snapped to exactly zero.
    ///
    /// Two jobs. A gated band feeds 0 into the smoother, so its bar *decays* to
    /// nothing rather than snapping — which looks far better — but an
    /// exponential never quite reaches zero, and
    /// ``BarRenderer/rowsLit(level:rowCount:)`` rounds up, so any positive
    /// height lights a key.
    ///
    /// It is also the last line against a nearly-silent room. The levelling is
    /// source-relative by design, so it will always find *something* in noise;
    /// what it cannot do is make that something large. Measured with `viz-sim`,
    /// a -60 dBFS bed produces bars around 1% of full height while real material
    /// sits between 15% and 50%. Five percent is comfortably between the two,
    /// and on a five-row column it is a quarter of the bottom row — nothing a
    /// bar could usefully show anyway.
    public static let displayEpsilon: Float = 0.05

    public var tuning: Tuning {
        didSet {
            guard tuning.equalization != oldValue.equalization else { return }
            analyzer = SpectrumAnalyzer(sampleRate: sampleRate,
                                        bandCount: bandCount,
                                        equalized: tuning.equalization)
        }
    }

    public let sampleRate: Float
    public let bandCount: Int

    private var analyzer: SpectrumAnalyzer
    private var smoother: LevelSmoother
    private var noiseFloor: NoiseFloorTracker
    private var loudness: LoudnessReference
    /// A short-term average of each band, used **only** to decide the floor and
    /// the gate — never to drive a bar.
    ///
    /// The floor and the gate have to be judged on something stable. Feeding
    /// them the instantaneous level meant a band of steady noise was compared
    /// against its own running *minimum*, so the noise's crest factor alone
    /// cleared a 9 dB margin and hiss lit the board. Averaging first makes
    /// "is anything happening here" a question about the band's level rather
    /// than about how spiky its noise is. Bars still use the instantaneous
    /// value, so attack stays instant.
    private var decisionAverage: [Float]
    /// Whether ``decisionAverage`` holds real data yet.
    ///
    /// It has to be *seeded* from the first frame rather than eased up from
    /// zero. Easing meant the noise floor — which is seeded from this — was
    /// itself seeded near zero on frame one, leaving every band reading as
    /// enormously above its floor and the gate wide open for the first seconds
    /// of every session. Three tests caught it at once.
    private var hasSeededDecisionAverage = false
    /// Per band: whether the gate is currently open. Carried between frames,
    /// which is what makes the hysteresis mean anything.
    private var gateIsOpen: [Bool]

    /// What the last ``advance(levels:elapsed:)`` computed, for diagnostics.
    public private(set) var lastNoiseFloor: [Float] = []
    public private(set) var lastReference: Float = 0

    /// The most recent analysis, written by whoever calls ``analyze(_:)``.
    private let levelsLock = NSLock()
    private var latestLevels: [Float]?

    public init(sampleRate: Float, bandCount: Int, tuning: Tuning = Tuning()) {
        self.sampleRate = sampleRate
        self.bandCount = bandCount
        self.tuning = tuning
        self.analyzer = SpectrumAnalyzer(sampleRate: sampleRate,
                                         bandCount: bandCount,
                                         equalized: tuning.equalization)
        self.smoother = LevelSmoother(bandCount: bandCount)
        self.noiseFloor = NoiseFloorTracker(bandCount: bandCount)
        self.loudness = LoudnessReference()
        self.decisionAverage = [Float](repeating: 0, count: bandCount)
        self.gateIsOpen = [Bool](repeating: false, count: bandCount)
    }

    /// Time constant of ``decisionAverage``. Long enough to average out the
    /// frame-to-frame wobble of noise, short enough that a passage starting is
    /// not held back for a noticeable moment.
    public static let decisionAverageTime: Double = 0.25

    // MARK: - Analysis half

    /// Runs the FFT and stores the result, replacing anything not yet displayed.
    ///
    /// Overwriting rather than queueing is the whole coalescing story: if the
    /// display falls behind, the frames it missed are gone rather than piling up
    /// into a backlog that drifts ever further behind the music.
    @discardableResult
    public func analyze(_ samples: [Float]) -> [Float] {
        let levels = analyzer.levels(from: samples)
        levelsLock.lock()
        latestLevels = levels
        levelsLock.unlock()
        return levels
    }

    // MARK: - Display half

    /// Turns the newest analysis into bar heights, `0…1` per column.
    ///
    /// The gain staging is **entirely source-relative**, which is what lets one
    /// set of defaults serve a quiet room microphone and a full-scale system tap
    /// without the user touching anything:
    ///
    /// 1. **Observe the floor.** ``NoiseFloorTracker`` learns what each band
    ///    sits at when nothing is happening.
    /// 2. **Subtract it.** What is left — the excess over the floor — is the
    ///    only thing that can light a bar, so a hissy input starts from zero
    ///    rather than from its own hiss.
    /// 3. **Gate on the ratio,** not on an absolute level: a band must stand
    ///    ``Tuning/gateMarginDB`` above its own floor, with hysteresis.
    /// 4. **Normalise to recent loudness,** so the excess is measured against
    ///    how loud this source actually gets rather than against full scale.
    /// 5. **Then** apply the user's sensitivity, and smooth.
    public func advance(elapsed: Double) -> [Float] {
        levelsLock.lock()
        let raw = latestLevels
        levelsLock.unlock()
        return advance(levels: raw ?? [Float](repeating: 0, count: bandCount),
                       elapsed: elapsed)
    }

    /// ``advance(elapsed:)`` with the levels supplied directly, for callers that
    /// already have them — and for tests.
    public func advance(levels input: [Float], elapsed: Double) -> [Float] {
        var levels = Array(input.prefix(bandCount))
        if levels.count < bandCount {
            levels += [Float](repeating: 0, count: bandCount - levels.count)
        }

        // Average first: the floor and the gate are decided on this, the bars
        // on the instantaneous level.
        if hasSeededDecisionAverage {
            let smoothing = Float(exp(-max(elapsed, 0) / Self.decisionAverageTime))
            for index in 0..<bandCount {
                decisionAverage[index] = levels[index]
                    + (decisionAverage[index] - levels[index]) * smoothing
            }
        } else {
            hasSeededDecisionAverage = true
            decisionAverage = levels
        }

        let floors = noiseFloor.update(with: decisionAverage, elapsed: elapsed)
        lastNoiseFloor = floors

        // Excess over the floor. Everything downstream works in this space, so
        // a source's own hiss contributes nothing no matter how loud it is in
        // absolute terms.
        var excess = [Float](repeating: 0, count: bandCount)
        for index in 0..<bandCount {
            excess[index] = max(0, levels[index] - floors[index])
        }

        applyGate(&excess, levels: decisionAverage, floors: floors)

        // The reference is measured on the gated excess, so silence cannot wind
        // it down to nothing and then let the first sound slam the board.
        let reference: Float
        if tuning.autoGain {
            reference = loudness.update(with: excess, elapsed: elapsed)
        } else {
            // Fixed reference: a manual mode that still works in excess space,
            // roughly "-26 dBFS above the floor is a full bar".
            reference = Self.fixedReference
            _ = loudness.update(with: excess, elapsed: elapsed)
        }
        lastReference = reference

        let scale = Float(tuning.sensitivity) / max(reference, LoudnessReference.minimumReference)
        for index in 0..<bandCount {
            excess[index] = min(max(excess[index] * scale, 0), 1)
        }

        var heights = smoother.update(with: excess, elapsed: elapsed)
        for index in heights.indices where heights[index] < Self.displayEpsilon {
            heights[index] = 0
        }
        return heights
    }

    /// The reference used when auto-gain is off — the point where a band
    /// standing this far above its floor fills its column.
    public static let fixedReference: Float = 0.05

    /// Silences bands that are not meaningfully above their own noise floor,
    /// with hysteresis so one sitting on the threshold does not chatter.
    ///
    /// The comparison is a **ratio against the observed floor**, so it means the
    /// same thing whether the source peaks at -6 dBFS or -46 dBFS. A hard
    /// absolute minimum guards the degenerate case: digital silence gives a
    /// floor of zero, and every ratio against zero is infinite.
    private func applyGate(_ excess: inout [Float], levels: [Float], floors: [Float]) {
        guard tuning.gateMarginDB > -.infinity else {
            for index in gateIsOpen.indices { gateIsOpen[index] = true }
            return
        }
        let openRatio = Float(pow(10, tuning.gateMarginDB / 20))
        let closeRatio = Float(pow(10, (tuning.gateMarginDB - Self.gateHysteresisDB) / 20))

        for index in 0..<bandCount {
            // True digital silence: nothing to measure a ratio against.
            if levels[index] <= Self.absoluteSilence {
                gateIsOpen[index] = false
                excess[index] = 0
                continue
            }
            let floor = max(floors[index], Self.absoluteSilence)
            let ratio = levels[index] / floor
            if gateIsOpen[index] {
                if ratio < closeRatio { gateIsOpen[index] = false }
            } else if ratio >= openRatio {
                gateIsOpen[index] = true
            }
            if !gateIsOpen[index] { excess[index] = 0 }
        }
    }

    /// Below this a band is treated as digitally silent rather than quiet, so a
    /// ratio against a zero floor is never computed.
    public static let absoluteSilence: Float = 1e-7

    /// Forgets all display state, so a new session does not inherit the last
    /// one's bar heights or wound-up auto-gain.
    public func reset() {
        smoother = LevelSmoother(bandCount: bandCount)
        noiseFloor = NoiseFloorTracker(bandCount: bandCount)
        loudness = LoudnessReference()
        decisionAverage = [Float](repeating: 0, count: bandCount)
        hasSeededDecisionAverage = false
        gateIsOpen = [Bool](repeating: false, count: bandCount)
        levelsLock.lock()
        latestLevels = nil
        levelsLock.unlock()
    }
}
