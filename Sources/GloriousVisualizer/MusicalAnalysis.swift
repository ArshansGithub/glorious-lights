import Foundation

/// The three percussive events worth telling apart on a keyboard.
///
/// Not a drum transcription — just enough for a light show to hit differently on
/// a kick than on a hat. Each is a region of the eight-band set (§2.1), not an
/// ad-hoc frequency range, so a detector cannot be fed something the rest of the
/// pipeline never adapted.
public enum OnsetKind: String, CaseIterable, Sendable {
    /// Bands 0–1: 20–120 Hz. The thing you feel.
    case kick
    /// Bands 3–4: 250 Hz–1 kHz. The backbeat.
    case snare
    /// Band 7: 6–16 kHz. The subdivision.
    case hat

    /// Which of the eight analysis bands this detector watches.
    public var bands: ClosedRange<Int> {
        switch self {
        case .kick:  return 0...1
        case .snare: return 3...4
        case .hat:   return 7...7
        }
    }

    /// Minimum gap between two *accepted* onsets of this kind (§4.4).
    ///
    /// 120 ms is WLED's peak-detector number and LedFx's `beat_min_time_since`;
    /// hats get 160 ms because they subdivide fastest and are the least worth
    /// showing individually.
    public var refractorySeconds: Double {
        switch self {
        case .kick:  return 0.120
        case .snare: return 0.120
        case .hat:   return 0.160
        }
    }

    /// How long a *higher*-precedence accepted event keeps this kind's region
    /// contaminated, and so how long one physical hit can go on producing
    /// candidates here (§2.2).
    ///
    /// Per kind because the smear is not symmetric. A kick's body is a
    /// low-frequency swing that goes on exciting the 250 Hz–1 kHz snare region
    /// for the length of its decay, so a snare detected a third of a second
    /// into a kick is very often the same drum. Its energy at 6–16 kHz is a
    /// click that is over in a few tens of milliseconds, so a hat is a
    /// different event much sooner — and a single shared window long enough for
    /// the snare case deleted almost every offbeat hat on the battery's own
    /// four-on-the-floor case, which is the detail the whole redesign exists to
    /// show.
    public var shadowSeconds: Double {
        switch self {
        case .kick:  return 0.330
        case .snare: return 0.330
        case .hat:   return 0.200
        }
    }

    /// Tie-break weight in the cross-band arbiter (§2.2).
    public var arbiterWeight: Double {
        switch self {
        case .kick:  return 1.0
        case .snare: return 0.9
        case .hat:   return 0.8
        }
    }

    /// The clamped AHR this kind's accents run (§4.1). `frameInterval` is
    /// required because the release floor is defined in display frames.
    public func accentEnvelope(frameInterval: Double) -> AHR {
        switch self {
        case .kick:
            return .clamped(attack: 0.015, hold: 0.100, release: 0.320, frameInterval: frameInterval)
        case .snare:
            return .clamped(attack: 0.008, hold: 0.080, release: 0.240, frameInterval: frameInterval)
        case .hat:
            return .clamped(attack: 0.005, hold: 0.060, release: 0.200, frameInterval: frameInterval)
        }
    }
}

/// Tempo, and — the part that changed — a **continuously advancing phase**
/// rather than a stream of beat triggers.
///
/// A phase can be predicted forward, which is what lets beat-locked gestures be
/// scheduled *ahead* of the beat by the measured pipeline latency and land with
/// zero visible lag (§8.2). A trigger stream cannot: by the time it exists the
/// beat has already happened.
public struct TempoEstimate: Equatable, Sendable {
    /// Beats per minute, or `0` when nothing has been established.
    public var bpm: Double = 0
    /// `0…1`. Below 0.35 modes cross-fade away from the grid rather than
    /// locking to one that is visibly wrong.
    public var confidence: Double = 0
    /// Position within the current beat, `0` at the beat.
    public var phase: Double = 0
    /// **Absolute host time of the next beat** (§2.3.1), computed where the
    /// phase actually lives.
    ///
    /// The renderer must never recompute a beat time from `φ` and its own `now`:
    /// `φ` in an interpolated state has already been advanced by the
    /// interpolator, and doing the arithmetic twice is how a 10–20 ms error
    /// enters for free. One absolute timestamp, published once.
    public var nextBeatTime: Double = 0
    /// `σ_φ` — the standard deviation of the last eight phase errors, in beats
    /// (§2.3.2).
    ///
    /// **The user's complaint is phase, not BPM.** The tracker's BPM sd is 0.04,
    /// an order of magnitude better than it needs to be; what was never measured
    /// is how much the *phase* wanders, and that is what "off beat" feels like.
    /// This is the one number r1 never had, and it is what decides whether the
    /// board is allowed to anticipate at all.
    public var phaseSigma: Double = 1

    public init(bpm: Double = 0, confidence: Double = 0, phase: Double = 0,
                nextBeatTime: Double = 0, phaseSigma: Double = 1) {
        self.bpm = bpm
        self.confidence = confidence
        self.phase = phase
        self.nextBeatTime = nextBeatTime
        self.phaseSigma = phaseSigma
    }

    /// Confidence at which gestures may be scheduled on the grid at all.
    public static let usableConfidence: Double = 0.35
    /// Confidence at which beat prediction is trusted enough to schedule
    /// gestures *before* the beat arrives.
    public static let predictiveConfidence: Double = 0.6

    public var isReliable: Bool { confidence >= Self.usableConfidence && bpm > 0 }

    /// Beat period in seconds. Falls back to a 0.5 s nominal when there is no
    /// usable tempo, so musical durations still have something to scale by.
    public var beatPeriod: Double { bpm > 0 ? 60 / bpm : 0.5 }

    /// How much beat-locked behaviour to mix in, `0…1`. A ramp, never a switch:
    /// a hard cut between grid-locked and free-running motion is more visible
    /// than either.
    public var gridWeight: Double {
        guard bpm > 0 else { return 0 }
        return smoothstep(Self.usableConfidence, Self.usableConfidence + 0.2, confidence)
    }

    /// Phase spread at which the full prediction lead is applied, and at which
    /// none of it is (§2.3.2).
    public static let phaseSigmaFull: Double = 0.06
    public static let phaseSigmaNone: Double = 0.12

    /// How much of the §2.3.3 lead to apply: full when the grid holds within
    /// ±6 % of a beat (≈ 32 ms at 112 BPM), none when it is worse than ±12 %,
    /// continuous in between, multiplied by the existing confidence ramp.
    ///
    /// With a shaky grid the lead collapses to zero and the board is reactive —
    /// which is correct, because anticipating a beat you cannot locate is worse
    /// than being late.
    public var leadWeight: Double {
        smoothstep(Self.phaseSigmaNone, Self.phaseSigmaFull, phaseSigma) * gridWeight
    }
}

/// Estimates tempo by autocorrelating the onset envelope, and tracks beat phase.
///
/// The measurement chain — autocorrelation, harmonic sum, octave folding, median
/// over recent observations — measured well and is kept. What changed is
/// everything about how the result is *published*:
///
/// * phase advances every hop, always, even when detection fails,
/// * phase is corrected 20 % toward the beat rather than snapped,
/// * tempo moves at most ±2 % per beat and only after three agreeing estimates.
///
/// That is BTrack's prior-weighted design: new evidence never overrides an
/// established hypothesis in one step.
public struct TempoTracker: Sendable {

    public static let minimumBPM: Double = 60
    public static let maximumBPM: Double = 200
    /// Reported tempos are folded by doubling or halving into this range, so
    /// half- and double-time observations of the same music agree.
    public static let canonicalRange: ClosedRange<Double> = 85...170
    public static let windowSeconds: Double = 8

    /// Fraction of the way to zero that a detected beat pulls the phase.
    public static let phaseCorrection: Double = 0.20
    /// …and the fraction of the same error that is fed back into the **period**.
    ///
    /// A phase corrector with a proportional term only is a first-order servo,
    /// and a wrong tempo is a *ramp* disturbance to its input: it settles with a
    /// standing error of `phaseError / phaseCorrection` — five times the
    /// per-beat drift. Measured on `click-90-ramp`, the board sat a flat +42 ms
    /// late for the whole eight seconds it took the autocorrelation window to
    /// forget the ramp, with `σ_φ` reporting the grid as perfectly stable
    /// throughout, because a *constant* error has no spread. That is precisely
    /// the failure mode §2.3.2 says to look for and precisely the one `σ_φ`
    /// cannot see, so the fix has to be in the loop rather than in the gate.
    ///
    /// A frequency term makes it second order: a persistent late phase means the
    /// period is too long, so shorten it. Small, and still bounded by the ±2 %
    /// per beat limit §2.3 already states.
    public static let periodCorrection: Double = 0.10
    /// Maximum tempo change per beat.
    public static let tempoRateLimit: Double = 0.02
    /// Agreeing estimates required before the tempo is allowed to move at all.
    public static let agreementsRequired = 3

    private let analysisRate: Double
    private var envelope: [Float] = []
    private let capacity: Int
    private var estimate = TempoEstimate()
    private var observations: [Double] = []
    private var phaseAccumulator: Double = 0
    private var phaseErrors: [Double] = []
    private var hopsSinceEstimate = 0
    /// Consecutive observations agreeing with a *proposed* new tempo.
    private var pendingTempo: Double = 0
    private var pendingAgreements = 0

    public init(analysisRate: Double) {
        self.analysisRate = analysisRate
        self.capacity = max(32, Int(analysisRate * Self.windowSeconds))
    }

    /// Adds one onset-envelope sample and advances the beat phase.
    @discardableResult
    public mutating func process(fluxSum: Float, elapsed: Double) -> TempoEstimate {
        envelope.append(fluxSum)
        if envelope.count > capacity { envelope.removeFirst(envelope.count - capacity) }

        hopsSinceEstimate += 1
        if hopsSinceEstimate >= Int(analysisRate / 2), envelope.count >= capacity / 2 {
            hopsSinceEstimate = 0
            reestimate()
        }

        // Phase advances unconditionally: a beat grid that stops whenever
        // detection has a bad second is worse than one that coasts.
        if estimate.bpm > 0 {
            phaseAccumulator += elapsed / estimate.beatPeriod
            phaseAccumulator -= phaseAccumulator.rounded(.down)
            estimate.phase = phaseAccumulator
        }
        return estimate
    }

    /// Pulls the phase gently toward a detected beat. Never snaps: a hard reset
    /// on every kick makes the grid as jittery as the detector.
    ///
    /// - Parameters:
    ///   - time: when the beat actually happened.
    ///   - now: the timestamp of the hop this is being called from. The two are
    ///     not the same — peak-picking sees the transient one or two hops after
    ///     it happened, and the event is timestamped back by the group delay on
    ///     top of that. Correcting as though the beat were *now* biased the grid
    ///     36–47 ms late on every alignment, which the render-side prediction
    ///     lead then happened to cancel. Two errors that agree numerically is
    ///     not the same as either being right.
    public mutating func align(toBeatAt time: Double, now: Double) {
        guard estimate.bpm > 0 else { return }
        // Where the grid says the phase was at the beat's own instant.
        var atBeat = phaseAccumulator - (now - time) / estimate.beatPeriod
        atBeat -= atBeat.rounded(.down)
        let wrapped = atBeat > 0.5 ? atBeat - 1 : atBeat
        // §2.3.2: the *pre-correction* error is the observation, recorded before
        // the correction that is about to hide it.
        phaseErrors.append(wrapped)
        if phaseErrors.count > Self.phaseErrorWindow {
            phaseErrors.removeFirst(phaseErrors.count - Self.phaseErrorWindow)
        }
        estimate.phaseSigma = Self.sigma(of: phaseErrors)
        // The frequency half of the loop: a beat that keeps arriving late means
        // the period is too long. Bounded by the same ±2 % per beat the tempo
        // median is bounded by, so a single mis-detected beat cannot move it.
        let nudge = clamp(-wrapped * Self.periodCorrection,
                          -Self.tempoRateLimit, Self.tempoRateLimit)
        estimate.bpm = clamp(estimate.bpm * (1 + nudge), Self.minimumBPM, Self.maximumBPM)
        phaseAccumulator -= wrapped * Self.phaseCorrection
        phaseAccumulator -= phaseAccumulator.rounded(.down)
        estimate.phase = phaseAccumulator
    }

    /// How many phase corrections `σ_φ` is measured over.
    public static let phaseErrorWindow = 8

    /// `σ_φ` in beats, or a deliberately pessimistic 1.0 until enough
    /// corrections exist to say anything. An unmeasured grid must not be
    /// anticipated: ``TempoEstimate/leadWeight`` reads 1.0 as "no lead".
    static func sigma(of errors: [Double]) -> Double {
        guard errors.count >= 3 else { return 1 }
        let mean = errors.reduce(0, +) / Double(errors.count)
        let variance = errors.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(errors.count)
        return variance.squareRoot()
    }

    public var current: TempoEstimate { estimate }

    static func canonical(bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        var folded = bpm
        while folded < canonicalRange.lowerBound { folded *= 2 }
        while folded > canonicalRange.upperBound { folded /= 2 }
        return folded
    }

    private mutating func reestimate() {
        var smoothed = envelope
        if envelope.count >= 3 {
            for index in 1..<(envelope.count - 1) {
                smoothed[index] = (envelope[index - 1] + 2 * envelope[index]
                                   + envelope[index + 1]) / 4
            }
        }
        let mean = smoothed.reduce(0, +) / Float(smoothed.count)
        let centred = smoothed.map { $0 - mean }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else {
            decayConfidence()
            return
        }

        let minimumLag = max(1, Int((60 / Self.maximumBPM) * analysisRate))
        let maximumLag = min(centred.count - 1, Int((60 / Self.minimumBPM) * analysisRate))
        guard maximumLag > minimumLag else { return }

        let correlationLimit = min(centred.count - 1, maximumLag * Self.harmonics)
        var correlations = [Float](repeating: 0, count: correlationLimit + 1)
        for lag in minimumLag...correlationLimit {
            var sum: Float = 0
            for index in lag..<centred.count { sum += centred[index] * centred[index - lag] }
            correlations[lag] = sum / Float(centred.count - lag)
        }

        // Harmonic sum: a beat period is supported by its own multiples, while a
        // metrical relative is not. This is what separates the beat from the 3:2
        // and 4:3 lags a plain peak search picks arbitrarily between.
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
        guard best.lag > 0, best.value > 0 else {
            decayConfidence()
            return
        }

        var refinedLag = Double(best.lag)
        if best.lag > minimumLag, best.lag < maximumLag {
            let left = Double(correlations[best.lag - 1])
            let centre = Double(correlations[best.lag])
            let right = Double(correlations[best.lag + 1])
            let denominator = left - 2 * centre + right
            if abs(denominator) > 1e-12 {
                let offset = 0.5 * (left - right) / denominator
                if abs(offset) <= 1 { refinedLag += offset }
            }
        }

        let bpm = 60 / (refinedLag / analysisRate)
        // How *peaked* the autocorrelation is, not how large it is: the peak
        // measured against the mean correlation across the whole search range.
        // A rhythm gives a sharp peak several times the mean absolute
        // correlation; speech and
        // rubato give a broad hump barely above it, and measuring the peak
        // against the envelope's energy instead cannot tell those apart — it
        // reported a usable tempo for a third of a spoken-word run.
        var correlationSum: Float = 0
        var correlationCount = 0
        for lag in minimumLag...maximumLag {
            correlationSum += abs(correlations[lag])
            correlationCount += 1
        }
        let average = correlationCount > 0 ? correlationSum / Float(correlationCount) : 0
        let peak = correlations[min(best.lag, correlations.count - 1)]
        let periodicity = average > 0
            ? clamp((Double(peak / average) - 1) / 3, 0, 1)
            : 0
        record(bpm: bpm, periodicity: periodicity)
    }

    private mutating func decayConfidence() {
        estimate.confidence *= 0.5
        observations.removeAll()
        pendingAgreements = 0
    }

    private mutating func record(bpm: Double, periodicity: Double) {
        let folded = Self.canonical(bpm: bpm)
        observations.append(folded)
        if observations.count > Self.observationWindow {
            observations.removeFirst(observations.count - Self.observationWindow)
        }
        guard observations.count >= 3 else { return }

        let sorted = observations.sorted()
        let median = sorted[sorted.count / 2]
        let agreeing = observations.filter { abs($0 - median) / median < 0.04 }.count
        let agreement = Double(agreeing) / Double(observations.count)

        if estimate.bpm <= 0 {
            // Nothing established yet: accept the median once it has been
            // agreed on three times running, and start the phase from here.
            if abs(median - pendingTempo) / max(pendingTempo, 1) < 0.04 {
                pendingAgreements += 1
            } else {
                pendingTempo = median
                pendingAgreements = 1
            }
            if pendingAgreements >= Self.agreementsRequired {
                estimate.bpm = median
                phaseAccumulator = 0
            }
        } else if abs(median - estimate.bpm) / estimate.bpm > 0.005 {
            // Established: move at most ±2 % per beat toward the new median, and
            // only once three consecutive estimates have agreed on it.
            if abs(median - pendingTempo) / max(pendingTempo, 1) < 0.04 {
                pendingAgreements += 1
            } else {
                pendingTempo = median
                pendingAgreements = 1
            }
            if pendingAgreements >= Self.agreementsRequired {
                let limit = estimate.bpm * Self.tempoRateLimit
                estimate.bpm += clamp(median - estimate.bpm, -limit, limit)
            }
        }

        estimate.confidence = estimate.confidence * 0.6
            + (agreement * min(1, periodicity * 2)) * 0.4
    }

    /// How many tempo observations the median is taken over. Re-estimation runs
    /// twice a second, so this is the window in seconds ×2.
    ///
    /// Eight, not sixteen. The median of sixteen observations spans eight
    /// seconds, so after a tempo change half of what it is averaging is the old
    /// tempo for a further eight seconds — measured on `click-90-ramp`, the
    /// reported BPM was still 90.3 four seconds after the music had settled at
    /// 100, and M8's alignment error stayed at 43 ms because `nextBeatTime` was
    /// being projected with a period 11 % too long. Eight observations is four
    /// seconds, which is §10.3's own bound for a settled grid, and the three
    /// consecutive agreements plus the ±2 %/beat rate limit are what still stop
    /// a single bad estimate from moving anything.
    private static let observationWindow = 8
    private static let harmonics = 4
}
