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
        /// Band level below which a bar is silenced, in dBFS. `-.infinity`
        /// disables the gate.
        public var noiseFloorDB: Double
        /// Whether the analyzer flattens pink noise. Off is the pre-tuning
        /// behaviour, for measuring against.
        public var equalization: Bool

        public init(sensitivity: Double = 2.0,
                    autoGain: Bool = true,
                    noiseFloorDB: Double = VisualizerPipeline.defaultNoiseFloorDB,
                    equalization: Bool = true) {
            self.sensitivity = sensitivity
            self.autoGain = autoGain
            self.noiseFloorDB = noiseFloorDB
            self.equalization = equalization
        }

        /// What the visualizer did before the first round of live-test tuning:
        /// no gate, no equalisation. Kept so before/after can be measured with
        /// one binary.
        public static let preTuning = Tuning(noiseFloorDB: -.infinity, equalization: false)
    }

    /// Default gate, in dBFS of equalised band magnitude. Low enough to pass
    /// quiet music, high enough to reject a room's noise floor.
    public static let defaultNoiseFloorDB: Double = -50

    /// How far above the gate a band must climb to re-open once it has closed,
    /// in dB.
    ///
    /// Without this, a band sitting exactly at the floor chatters — open, shut,
    /// open — once per frame, which is precisely the flicker the gate is meant
    /// to remove. 6 dB is the usual starting point for a gate's hysteresis and
    /// is about the smallest step that reads as deliberate rather than noisy.
    public static let gateHysteresisDB: Double = 6

    /// Below this, a smoothed bar is snapped to exactly zero.
    ///
    /// A gated band feeds 0 into the smoother, so its bar *decays* to nothing
    /// rather than snapping — which looks far better — but an exponential never
    /// quite reaches zero, and a bar stuck at 0.4% still lights its bottom row
    /// because ``BarRenderer/rowsLit(level:rowCount:)`` rounds up. This is where
    /// "fully zero below the floor" is actually made true.
    public static let displayEpsilon: Float = 0.004

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
    private var autoGain = AutoGain()
    /// Per band: whether the gate is currently open. Carried between frames,
    /// which is what makes the hysteresis mean anything.
    private var gateIsOpen: [Bool]

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
        self.gateIsOpen = [Bool](repeating: false, count: bandCount)
    }

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
    /// Order matters and is the same every time: **gate, then gain, then
    /// smooth**. Gating before the gain is what stops a high sensitivity — or an
    /// auto-gain multiplier that has wound itself up during a quiet passage —
    /// from amplifying the room's noise floor into a full-height bar. The floor
    /// describes the input, not how hard it is being amplified.
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
        var levels = input
        if levels.count < bandCount {
            levels += [Float](repeating: 0, count: bandCount - levels.count)
        }

        applyGate(&levels)

        var gain = Float(tuning.sensitivity)
        if tuning.autoGain {
            // The peak feeding the auto-gain is the *gated* one, so silence
            // cannot wind the multiplier up on noise and then slam everything
            // to full the moment real audio arrives.
            gain *= autoGain.update(observedPeak: levels.prefix(bandCount).max() ?? 0,
                                    elapsed: elapsed)
        }
        for index in 0..<bandCount {
            levels[index] = min(max(levels[index] * gain, 0), 1)
        }

        var heights = smoother.update(with: Array(levels.prefix(bandCount)), elapsed: elapsed)
        for index in heights.indices where heights[index] < Self.displayEpsilon {
            heights[index] = 0
        }
        return heights
    }

    /// Silences bands below the floor, with hysteresis so one sitting on the
    /// threshold does not chatter.
    private func applyGate(_ levels: inout [Float]) {
        guard tuning.noiseFloorDB > -.infinity else {
            for index in gateIsOpen.indices { gateIsOpen[index] = true }
            return
        }
        let close = Float(pow(10, tuning.noiseFloorDB / 20))
        let open = Float(pow(10, (tuning.noiseFloorDB + Self.gateHysteresisDB) / 20))

        for index in 0..<min(levels.count, bandCount) {
            if gateIsOpen[index] {
                if levels[index] < close { gateIsOpen[index] = false }
            } else if levels[index] >= open {
                gateIsOpen[index] = true
            }
            if !gateIsOpen[index] { levels[index] = 0 }
        }
    }

    /// Forgets all display state, so a new session does not inherit the last
    /// one's bar heights or wound-up auto-gain.
    public func reset() {
        smoother = LevelSmoother(bandCount: bandCount)
        autoGain = AutoGain()
        gateIsOpen = [Bool](repeating: false, count: bandCount)
        levelsLock.lock()
        latestLevels = nil
        levelsLock.unlock()
    }
}
