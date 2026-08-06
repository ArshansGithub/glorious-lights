import Foundation

/// What one frame of music looks like, in terms a light show can use.
///
/// The first visualizer painted the instantaneous spectrum straight onto the
/// keys, and the verdict was that it "feels random". It was not random — it was
/// *literal*. A 17-column spectrum on a 6-row grid, redrawn fifteen times a
/// second, has no memory and no phrasing, so nothing on the board corresponds to
/// anything a listener is tracking. Music's shape is rhythmic and dynamic over
/// time, so this describes it that way: what just *happened* (onsets), where the
/// music *is* (tempo and phase), and how it *feels* (loudness, brightness,
/// weight). Modes then choose a gesture, rather than transcribing bins.
public struct MusicalFrame: Equatable, Sendable {

    /// Seconds since the session started.
    public var time: Double = 0

    /// Per-column levels, `0…1`, already smoothed. Only ``VisualizerMode/spectrum``
    /// uses these; every other mode works from the features below.
    public var bandLevels: [Float] = []

    /// Overall loudness, `0…1`, compressed so a quiet passage still shows life
    /// and a drop still lands.
    public var loudness: Float = 0
    /// Spectral centroid mapped to `0…1`: 0 is bass-heavy and dark, 1 is
    /// treble-rich and bright. Drives hue in most modes.
    public var brightness: Float = 0

    /// Smoothed band-group envelopes, `0…1`.
    public var bass: Float = 0
    public var mid: Float = 0
    public var treble: Float = 0

    /// Onset strengths for this frame, `0` when nothing fired.
    public var onsets: [OnsetKind: Float] = [:]

    /// The current tempo estimate and where we are within the beat.
    public var tempo: TempoEstimate = TempoEstimate()

    public init() {}

    /// Strength of an onset this frame, `0` if none.
    public func onset(_ kind: OnsetKind) -> Float { onsets[kind] ?? 0 }

    /// Whether any percussive onset fired this frame.
    public var hasOnset: Bool { onsets.values.contains { $0 > 0 } }
}

/// The three percussive events worth telling apart on a keyboard.
///
/// Not a full drum transcription — just enough for a light show to hit
/// differently on a kick than on a hat. Each is a frequency region plus the
/// character of its transient.
public enum OnsetKind: String, CaseIterable, Sendable {
    /// ~40–120 Hz. The thing you feel.
    case kick
    /// ~150–400 Hz plus a broadband transient. The backbeat.
    case snare
    /// ~6–12 kHz. The subdivision.
    case hat

    /// Frequency range, in Hz.
    public var range: ClosedRange<Float> {
        switch self {
        case .kick:  return 40...120
        case .snare: return 150...400
        case .hat:   return 6_000...12_000
        }
    }

    /// Minimum gap between two onsets of this kind.
    ///
    /// Tuned per kind because the parts play at different rates: a kick that
    /// fires more than about six times a second is the detector re-triggering
    /// on one hit's ragged edge, while hats genuinely subdivide fast. Measured
    /// against real tracks — before this, the detector reported eight kicks a
    /// second on a 120 BPM song, which should be two.
    public var refractorySeconds: Double {
        switch self {
        case .kick:  return 0.18
        case .snare: return 0.13
        case .hat:   return 0.06
        }
    }

    /// How far past the running median the flux must go. Higher for the
    /// low-frequency parts, where a sustained bass note otherwise reads as a
    /// stream of hits.
    public var thresholdRatio: Float {
        switch self {
        case .kick:  return 5.0
        case .snare: return 4.4
        case .hat:   return 3.6
        }
    }
}

/// A tempo estimate and the current position within the beat.
public struct TempoEstimate: Equatable, Sendable {
    /// Beats per minute, or `0` when nothing has been established.
    public var bpm: Double = 0
    /// `0…1`, how much to trust ``bpm``. Modes fall back to loudness-driven
    /// behaviour when this is low rather than locking to a wrong grid.
    public var confidence: Double = 0
    /// Position within the current beat, `0` at the beat and approaching `1`
    /// just before the next.
    public var phase: Double = 0

    public init(bpm: Double = 0, confidence: Double = 0, phase: Double = 0) {
        self.bpm = bpm
        self.confidence = confidence
        self.phase = phase
    }

    /// Whether a mode should lock to the grid rather than react moment to
    /// moment.
    public var isReliable: Bool { confidence >= 0.35 && bpm > 0 }

    /// Beat period in seconds, or `nil` if there is no usable tempo.
    public var beatPeriod: Double? { bpm > 0 ? 60 / bpm : nil }
}

// MARK: - Onset detection

/// Detects percussive onsets from spectral flux with an adaptive threshold.
///
/// Spectral flux — the sum of *positive* changes in magnitude — is the standard
/// onset function: it rises when energy appears and ignores energy dying away,
/// which is what makes a drum hit look different from a note ending. The
/// threshold is a running **median** of recent flux rather than a fixed number,
/// because the useful threshold on a sparse intro and a dense chorus differ by
/// an order of magnitude, and a median is what shrugs off the outliers the
/// onsets themselves create.
public struct OnsetDetector: Sendable {

    /// How much of the recent flux history the threshold is drawn from.
    public static let historySeconds: Double = 1.5
    /// The threshold is this multiple of the running median, plus a small
    /// absolute floor. Above 1 so ordinary variation does not trigger.
    public var thresholdRatio: Float
    /// Minimum gap between onsets of one kind, which stops a single hit's
    /// ragged edge from firing several times.
    public var refractorySeconds: Double

    private var history: [Float] = []
    private var historyLimit: Int
    private var previousMagnitudes: [Float] = []
    private var lastOnsetTime: Double = -.infinity
    /// The last three flux values, so the middle one can be peak-tested.
    private var recent: [(flux: Float, time: Double)] = []

    public init(analysisRate: Double,
                thresholdRatio: Float = 2.4,
                refractorySeconds: Double = 0.12) {
        self.thresholdRatio = thresholdRatio
        self.refractorySeconds = refractorySeconds
        self.historyLimit = max(8, Int(analysisRate * Self.historySeconds))
    }

    /// Feeds one analysis frame's magnitudes for this detector's bin range.
    ///
    /// - Returns: onset strength in `0…1` — how far past the threshold the flux
    ///   went — or `0` for no onset.
    public mutating func process(magnitudes: [Float], time: Double) -> Float {
        defer { previousMagnitudes = magnitudes }
        guard previousMagnitudes.count == magnitudes.count, !magnitudes.isEmpty else {
            return 0
        }

        // Half-wave rectified flux: only energy *appearing* counts.
        var flux: Float = 0
        for index in magnitudes.indices {
            let rise = magnitudes[index] - previousMagnitudes[index]
            if rise > 0 { flux += rise }
        }

        history.append(flux)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }

        // Hold the last three values so the middle one can be tested for being
        // a **local maximum**. Without this, a single drum hit whose flux stays
        // above threshold for several analysis frames fires on every one of
        // them — which is most of why the detector reported 4.4 kicks a second
        // on a track with 1.9 beats a second. An onset is a peak, not a period
        // spent above a line.
        recent.append((flux: flux, time: time))
        if recent.count > 3 { recent.removeFirst(recent.count - 3) }
        guard recent.count == 3, history.count >= 8 else { return 0 }

        let candidate = recent[1]
        guard candidate.flux > recent[0].flux, candidate.flux >= recent[2].flux else { return 0 }

        let sorted = history.sorted()
        let median = sorted[sorted.count / 2]
        // The absolute term keeps near-silence from producing onsets when the
        // median is essentially zero.
        let threshold = median * thresholdRatio + 1e-5

        guard candidate.flux > threshold,
              candidate.time - lastOnsetTime >= refractorySeconds else { return 0 }
        lastOnsetTime = candidate.time
        // Strength saturates: a hit twice past the threshold is already "hard".
        return min(1, (candidate.flux - threshold) / max(threshold, 1e-6))
    }
}

// MARK: - Tempo

/// Estimates tempo by autocorrelating the onset envelope.
///
/// The envelope is sampled at the *analysis* rate rather than the display rate,
/// which matters more than it looks: at 15 fps a beat period is 7–8 frames and
/// the nearest candidates are 112 and 128 BPM, so tempo could never be better
/// than ±8 BPM. The pipeline analyses on a small hop for exactly this reason,
/// and the peak is parabolically interpolated on top.
public struct TempoTracker: Sendable {

    /// The range of lags searched, in BPM. Wide, because the *reported* tempo
    /// is folded into a canonical octave afterwards rather than constrained
    /// here — searching narrowly just moves the octave error into the search.
    public static let minimumBPM: Double = 60
    public static let maximumBPM: Double = 200

    /// Reported tempos are folded by doubling or halving into this range.
    ///
    /// Autocorrelation cannot tell 90 BPM from 180: both are real periodicities
    /// of the same music, and which peak wins flips with the arrangement. Left
    /// alone, that shows up as a tempo that "jumps an octave" mid-track — the
    /// Night Vision estimate sat at 181.5 while Blackmail wandered. Folding
    /// makes half- and double-time observations agree, which is what lets the
    /// median below mean anything.
    public static let canonicalRange: ClosedRange<Double> = 85...170
    /// How much history the autocorrelation runs over. Long enough for several
    /// bars, short enough to follow a tempo change.
    public static let windowSeconds: Double = 8

    private let analysisRate: Double
    private var envelope: [Float] = []
    private let capacity: Int
    private var estimate = TempoEstimate()
    /// Recent octave-folded observations, for the median.
    private var observations: [Double] = []
    /// Whether the published tempo has stopped following the median.
    private var isLocked = false
    /// Advances with time so phase keeps running between updates.
    private var phaseAccumulator: Double = 0
    private var framesSinceEstimate = 0

    public init(analysisRate: Double) {
        self.analysisRate = analysisRate
        self.capacity = max(32, Int(analysisRate * Self.windowSeconds))
    }

    /// Adds one onset-envelope sample and advances the beat phase.
    public mutating func process(fluxSum: Float, elapsed: Double) -> TempoEstimate {
        envelope.append(fluxSum)
        if envelope.count > capacity { envelope.removeFirst(envelope.count - capacity) }

        framesSinceEstimate += 1
        // Re-estimating every frame is wasted work — tempo does not change that
        // fast, and the autocorrelation is the expensive part of the analysis.
        if framesSinceEstimate >= Int(analysisRate / 2), envelope.count >= capacity / 2 {
            framesSinceEstimate = 0
            reestimate()
        }

        if let period = estimate.beatPeriod, estimate.confidence > 0 {
            phaseAccumulator += elapsed / period
            phaseAccumulator -= phaseAccumulator.rounded(.down)
            estimate.phase = phaseAccumulator
        }
        return estimate
    }

    private mutating func reestimate() {
        // A light 3-tap smooth before correlating: the envelope is spiky by
        // construction and the autocorrelation of spikes is itself spiky, which
        // is half of why the estimate used to jump between neighbouring lags.
        var smoothed = envelope
        if envelope.count >= 3 {
            for index in 1..<(envelope.count - 1) {
                smoothed[index] = (envelope[index - 1] + 2 * envelope[index]
                                   + envelope[index + 1]) / 4
            }
        }

        // Mean-remove so the autocorrelation measures periodicity rather than
        // the envelope's DC level, which would swamp it.
        let mean = smoothed.reduce(0, +) / Float(smoothed.count)
        let centred = smoothed.map { $0 - mean }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else {
            estimate = TempoEstimate()
            return
        }

        let minimumLag = max(1, Int((60 / Self.maximumBPM) * analysisRate))
        let maximumLag = min(centred.count - 1, Int((60 / Self.minimumBPM) * analysisRate))
        guard maximumLag > minimumLag else { return }

        // Correlate across the whole plausible span, plus the multiples the
        // harmonic sum below needs.
        let correlationLimit = min(centred.count - 1, maximumLag * Self.harmonics)
        var correlations = [Float](repeating: 0, count: correlationLimit + 1)
        for lag in minimumLag...correlationLimit {
            var sum: Float = 0
            for index in lag..<centred.count {
                sum += centred[index] * centred[index - lag]
            }
            // Normalising by overlap length stops long lags being penalised
            // simply for having fewer terms.
            correlations[lag] = sum / Float(centred.count - lag)
        }

        // **Harmonic sum.** A beat period is supported by its own multiples —
        // energy recurs at one beat, two beats, four — while a metrical
        // relative is not. Scoring each candidate by its correlation *plus* a
        // falling share of its multiples is what separates the beat from the
        // 3:2 and 4:3 lags that a plain peak search picks arbitrarily between:
        // one track drifted among 100, 113 and 150 BPM, all of which are real
        // periodicities of the same music.
        var best = (lag: 0, value: Float(0))
        for lag in minimumLag...maximumLag {
            var score = correlations[lag]
            for harmonic in 2...Self.harmonics {
                let multiple = lag * harmonic
                guard multiple <= correlationLimit else { break }
                score += correlations[multiple] / Float(harmonic)
            }
            if score > best.value { best = (lag, score) }
        }
        guard best.lag > 0, best.value > 0 else { return }

        let chosenLag = best.lag

        // Parabolic interpolation around the peak, which is what buys sub-frame
        // — and therefore sub-BPM — resolution.
        var refinedLag = Double(chosenLag)
        if chosenLag > minimumLag, chosenLag < maximumLag {
            let left = Double(correlations[chosenLag - 1])
            let centre = Double(correlations[chosenLag])
            let right = Double(correlations[chosenLag + 1])
            let denominator = left - 2 * centre + right
            if abs(denominator) > 1e-12 {
                let offset = 0.5 * (left - right) / denominator
                if abs(offset) <= 1 { refinedLag += offset }
            }
        }

        let bpm = 60 / (refinedLag / analysisRate)
        // Confidence is the peak against the envelope's own energy: a strongly
        // periodic signal correlates with itself far better than a wash does.
        let normaliser = energy / Float(centred.count)
        let confidence = normaliser > 0
            ? min(1, Double(correlations[min(chosenLag, correlations.count - 1)] / normaliser))
            : 0

        recordObservation(bpm: bpm, confidence: confidence)
    }

    /// Folds a tempo into ``canonicalRange`` by repeated doubling or halving.
    static func canonical(bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        var folded = bpm
        while folded < canonicalRange.lowerBound { folded *= 2 }
        while folded > canonicalRange.upperBound { folded /= 2 }
        return folded
    }

    /// Adds one observation and republishes the **median** of recent ones.
    ///
    /// A median rather than a running average, and rather than the inertia rule
    /// this replaced: inertia keeps whatever it locked onto first, which turned
    /// one early bad estimate into a tempo that never moved. A median over a
    /// rolling window is not sticky, ignores outliers, and settles quickly.
    private mutating func recordObservation(bpm: Double, confidence: Double) {
        let folded = Self.canonical(bpm: bpm)
        observations.append(folded)
        if observations.count > Self.observationWindow {
            observations.removeFirst(observations.count - Self.observationWindow)
        }
        guard observations.count >= 3 else { return }

        let sorted = observations.sorted()
        let median = sorted[sorted.count / 2]

        // Confidence is how much the recent observations agree with each other,
        // scaled by how periodic the envelope was. Agreement is the part that
        // matters to a mode deciding whether to trust the grid.
        let agreeing = observations.filter { abs($0 - median) / median < 0.04 }.count
        let agreement = Double(agreeing) / Double(observations.count)

        if estimate.bpm <= 0 { phaseAccumulator = 0 }

        if isLocked {
            // Release only when the recent observations genuinely stop agreeing
            // with the locked value — a real tempo change, not one odd reading.
            let agreeingWithLock = observations.filter {
                abs($0 - estimate.bpm) / max(estimate.bpm, 1) < 0.04
            }.count
            if Double(agreeingWithLock) / Double(observations.count) < Self.unlockAgreement {
                isLocked = false
            }
        } else if agreement >= Self.lockAgreement && observations.count >= 6 {
            estimate.bpm = median
            isLocked = true
        } else if abs(median - estimate.bpm) > 0.05 {
            estimate.bpm = median
        }

        estimate.confidence = estimate.confidence * 0.5
            + (agreement * min(1, confidence * 2)) * 0.5
    }

    /// How many recent observations the median is taken over — about eight
    /// seconds at one observation every half second.
    private static let observationWindow = 16

    /// Agreement at which the tempo is considered **locked**.
    ///
    /// Once this many recent observations agree, the published BPM stops
    /// following the median at all. Modes tie animation speed to it — the wave
    /// crosses the board in one beat — so a tempo that keeps drifting by a few
    /// BPM makes the motion visibly breathe even though the track has not
    /// changed. Locking costs nothing: a genuine tempo change breaks the
    /// agreement and releases the lock.
    private static let lockAgreement = 0.75
    /// Agreement below which a lock is released.
    private static let unlockAgreement = 0.45

    /// How many multiples of a candidate lag contribute to its harmonic score.
    private static let harmonics = 4

    /// Nudges the beat phase toward an onset that arrived, so the grid stays
    /// aligned with the music rather than free-running from whenever it locked.
    public mutating func align(toOnsetAt time: Double) {
        guard estimate.bpm > 0 else { return }
        // Pull toward zero phase, gently: a hard reset on every kick would make
        // the phase as jittery as the onsets themselves.
        let wrapped = phaseAccumulator > 0.5 ? phaseAccumulator - 1 : phaseAccumulator
        phaseAccumulator -= wrapped * 0.25
        phaseAccumulator -= phaseAccumulator.rounded(.down)
    }

    public var current: TempoEstimate { estimate }

    /// Whether the tempo is locked and no longer tracking the median.
    public var isTempoLocked: Bool { isLocked }
}

// MARK: - Features

/// Loudness, brightness and the band-group envelopes, all smoothed.
public struct FeatureExtractor: Sendable {

    /// Attack and release for the band envelopes.
    public static let envelopeAttack: Double = 0.05
    public static let envelopeRelease: Double = 0.25
    /// Loudness follows more slowly still, so it reads as dynamics rather than
    /// as a level meter.
    public static let loudnessAttack: Double = 0.08
    public static let loudnessRelease: Double = 0.45
    /// Brightness drifts: hue should wander with the music, not flicker.
    public static let brightnessTime: Double = 0.9

    private var bass: Float = 0
    private var mid: Float = 0
    private var treble: Float = 0
    private var loudness: Float = 0
    private var brightness: Float = 0
    /// Running bounds of the observed centroid, so the hue ramp is stretched
    /// across the range this material actually uses.
    private var centroidLow: Float = 0
    private var centroidHigh: Float = 0
    private var hasSeenCentroid = false

    /// How quickly the observed centroid bounds adapt. Slow: they should
    /// describe the track, not the bar.
    public static let centroidAdaptTime: Double = 8
    /// Minimum span of the observed centroid range, in Hz. Without a floor, a
    /// steady tone collapses the range to nothing and the hue jumps wildly on
    /// noise.
    public static let minimumCentroidSpan: Float = 400

    public init() {}

    private static func follow(_ current: Float, _ target: Float,
                               attack: Double, release: Double, elapsed: Double) -> Float {
        let time = target > current ? attack : release
        let decay = Float(exp(-max(elapsed, 0) / max(time, 1e-6)))
        return target + (current - target) * decay
    }

    /// - Parameters:
    ///   - bandLevels: normalised per-column levels.
    ///   - centroid: spectral centroid in Hz.
    public mutating func update(bandLevels: [Float],
                                centroid: Float,
                                elapsed: Double) -> (bass: Float, mid: Float, treble: Float,
                                                     loudness: Float, brightness: Float) {
        guard !bandLevels.isEmpty else { return (bass, mid, treble, loudness, brightness) }

        // Thirds of the column range: the display is the point, so the groups
        // are the ones a viewer would name looking at the board.
        let third = max(1, bandLevels.count / 3)
        func mean(_ slice: ArraySlice<Float>) -> Float {
            slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
        }
        let bassTarget = mean(bandLevels[0..<third])
        let midTarget = mean(bandLevels[third..<min(third * 2, bandLevels.count)])
        let trebleTarget = mean(bandLevels[min(third * 2, bandLevels.count)...])

        bass = Self.follow(bass, bassTarget, attack: Self.envelopeAttack,
                           release: Self.envelopeRelease, elapsed: elapsed)
        mid = Self.follow(mid, midTarget, attack: Self.envelopeAttack,
                          release: Self.envelopeRelease, elapsed: elapsed)
        treble = Self.follow(treble, trebleTarget, attack: Self.envelopeAttack,
                             release: Self.envelopeRelease, elapsed: elapsed)

        // Compressed loudness: the square root pulls quiet passages up so the
        // board still lives during them, which a linear mapping does not.
        let rawLoudness = mean(bandLevels[...])
        loudness = Self.follow(loudness, sqrt(min(max(rawLoudness, 0), 1)),
                               attack: Self.loudnessAttack,
                               release: Self.loudnessRelease, elapsed: elapsed)

        // Centroid on a log scale, since pitch perception is logarithmic —
        // then stretched across the range *this material* actually occupies.
        //
        // A fixed 200 Hz - 6 kHz window was the reason every frame came out
        // blue or purple: real music keeps its centroid in a far narrower band
        // than that, so only the middle of the hue ramp was ever reached.
        // Tracking the observed bounds the same way the level stage tracks its
        // noise floor makes the full ramp available to any source.
        let logCentroid = log(Double(min(max(centroid, 60), 12_000)))
        if !hasSeenCentroid {
            hasSeenCentroid = true
            centroidLow = Float(logCentroid)
            centroidHigh = Float(logCentroid)
        } else {
            let adapt = Float(exp(-max(elapsed, 0) / Self.centroidAdaptTime))
            // Bounds snap outward to any new extreme and relax inward slowly,
            // so a track's full range stays represented between its extremes.
            centroidLow = min(Float(logCentroid), centroidLow * adapt
                              + Float(logCentroid) * (1 - adapt))
            centroidHigh = max(Float(logCentroid), centroidHigh * adapt
                               + Float(logCentroid) * (1 - adapt))
        }

        let minimumSpan = Float(log(Double(Self.minimumCentroidSpan)) - log(200.0))
        var low = centroidLow
        var high = centroidHigh
        if high - low < minimumSpan {
            let middle = (high + low) / 2
            low = middle - minimumSpan / 2
            high = middle + minimumSpan / 2
        }
        let target = min(max((Float(logCentroid) - low) / (high - low), 0), 1)
        let decay = Float(exp(-max(elapsed, 0) / Self.brightnessTime))
        brightness = target + (brightness - target) * decay

        return (bass, mid, treble, loudness, brightness)
    }
}
