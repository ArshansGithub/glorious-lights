import Foundation

/// One detected percussive event, timestamped on the host clock.
///
/// Events are values with times, not flags on a frame. That is the whole
/// difference between "responds to the little details" and not: the old pipeline
/// coalesced every onset that landed between two display frames into one
/// strength per kind, so three hits inside 67 ms became one. These are queued
/// individually and the model schedules each at its own true time.
public struct OnsetEvent: Equatable, Sendable {
    public var time: Double
    public var kind: OnsetKind
    /// How far past its threshold the flux went, saturating — `0…1`.
    public var strength: Double
    /// `clamp((flux/thresh − 1)/2, 0, 1)`. Low-confidence events drive dimmer
    /// gestures rather than being dropped, so the transition from "hit" to
    /// "no hit" is continuous and the board cannot chatter at the boundary.
    public var confidence: Double

    public init(time: Double, kind: OnsetKind, strength: Double, confidence: Double) {
        self.time = time
        self.kind = kind
        self.strength = strength
        self.confidence = confidence
    }
}

/// Adaptive-median spectral-flux onset detection for one band group.
///
/// Three structural faults in the old detector made it emit 12.1 onsets per
/// second on a pure sine wave — a signal containing exactly zero onsets — and
/// four of five modes are onset-driven, so the board was free-running on a
/// detector artefact. All three are fixed here:
///
/// 1. **No absolute floor.** The threshold was `median · ratio + 1e-5`, and that
///    `1e-5` dominates in any band holding only spectral leakage. The floor is
///    now the band's own median plus a multiple of its own median absolute
///    deviation, which is zero for a stationary signal by construction.
/// 2. **Whitened input.** Flux is computed on whitened bins, so a band's
///    absolute level cannot decide whether it produces onsets.
/// 3. **A relative SNR test.** `CURRENT_RELATIVE > 1.25` — a steady tone's
///    current-to-long-average ratio sits at exactly 1.0 forever, so it can never
///    fire. This one test alone would have caught the sine-wave bug.
public struct FluxOnsetDetector: Sendable {

    /// Median/MAD span, in **seconds**.
    ///
    /// The design says eleven hops (~117 ms). 224 ms is used instead: with
    /// eleven samples the MAD is itself so noisy that the threshold it produces
    /// varies more than the signal it is judging, and the local-maximum
    /// pre-selection makes that bias one-sided. Doubling the window halves the
    /// estimator's variance and costs nothing — the window is causal and the
    /// detection instant is still a peak among its neighbours. Expressed in
    /// seconds so it does not silently change meaning with the hop size.
    public static let medianSeconds: Double = 0.224
    /// Threshold is `median + δ·MAD`.
    public static let deltaMAD: Double = 3.0
    /// …and must also be this multiple of the median, which is the test that
    /// survives when MAD collapses.
    public static let medianRatio: Double = 1.6
    /// The band must actually be louder than its own long-term average — by the
    /// same margin ``BandGate/openAt`` calls "this band is doing something",
    /// rather than by a number of its own. The two tests ask the same question
    /// about the same quantity and disagreeing about the answer is how a voiced
    /// syllable, whose region creeps over its average across a 60 ms attack,
    /// used to clear a bar the gate would not have opened for.
    public static let snrRatio: Double = 1.30
    /// …and no band inside the region may be sitting at its own average, which
    /// is what a tone entering one edge of the region looks like. Per kind,
    /// because the regions are not alike: the two bands of the kick region are
    /// 20–120 Hz and a real kick fills both, so "not below its own average" is
    /// the whole test, while the snare region is 250 Hz–1 kHz, which is where
    /// the human voice lives — the one material §10.1 asks it to reject — and a
    /// formant sweeping through one of its two bands must not read as a hit.
    public static func weakestBandRatio(for kind: OnsetKind) -> Double {
        switch kind {
        case .kick, .hat: return 1.00
        case .snare:      return 1.15
        }
    }

    public let kind: OnsetKind
    /// Median/MAD span in hops, derived from the analysis rate.
    public let medianSpan: Int

    private var previous: [Double] = []
    private var history: [Double] = []
    /// Three hops of flux, so the middle one can be peak-tested against its
    /// neighbours. An onset is a *peak*, not a period spent above a line —
    /// without this one hit fires on every hop it stays above the threshold.
    private var recent: [(flux: Double, time: Double, relative: Double,
                          weakest: Double, gate: Double)] = []
    private var lastFire: Double = -.infinity
    /// A candidate whose flux was convincing but whose level had not caught up.
    private var deferred: Candidate?

    public init(kind: OnsetKind, analysisRate: Double) {
        self.kind = kind
        self.medianSpan = max(11, Int((Self.medianSeconds * analysisRate).rounded()))
    }

    /// Feeds one hop of whitened bins for this detector's region.
    ///
    /// - Returns: a candidate event, before arbitration (§2.2 fault 3).
    public mutating func process(whitened: ArraySlice<Double>,
                                 time: Double,
                                 currentRelative: Double,
                                 weakestBand: Double,
                                 gate: Double) -> Candidate? {
        let bins = Array(whitened)
        defer { previous = bins }
        guard previous.count == bins.count, !bins.isEmpty else { return nil }

        var flux: Double = 0
        for index in bins.indices {
            let rise = bins[index] - previous[index]
            if rise > 0 { flux += rise }
        }
        // Per-bin, so a wide band is not simply more likely to fire than a
        // narrow one — the threshold vocabulary has to mean the same thing for
        // the five-bin kick region and the four-hundred-bin hat region.
        flux /= Double(bins.count)

        history.append(flux)
        if history.count > medianSpan { history.removeFirst(history.count - medianSpan) }

        recent.append((flux, time, currentRelative, weakestBand, gate))
        if recent.count > 3 { recent.removeFirst(recent.count - 3) }
        guard recent.count == 3, history.count >= medianSpan else { return nil }

        // A deferred candidate from the previous hop gets one more chance now
        // that the level has had a hop to catch up. Its time is unchanged, so
        // deferring costs the *event* nothing — only its delivery.
        var released: Candidate?
        if var waiting = deferred {
            deferred = nil
            if currentRelative > Self.snrRatio,
               weakestBand > Self.weakestBandRatio(for: kind), gate > 0.5,
               waiting.time - lastFire > kind.refractorySeconds {
                waiting.deferredByAHop = true
                released = waiting
            }
        }

        let candidate = recent[1]
        // A plateau counts as a peak: a kick's flux often holds for two hops,
        // and a strict inequality on both sides drops it.
        guard candidate.flux >= recent[0].flux, candidate.flux >= recent[2].flux,
              candidate.flux > 0 else { return released }

        let sorted = history.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = history.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        let threshold = median + Self.deltaMAD * mad

        // The gate test is allowed the hop of grace the level test below is
        // allowed, and for the same reason — but not the hop *before* the
        // candidate, which describes the region before the transient.
        let gateLevel = max(recent[1].gate, recent[2].gate)
        // No `threshold > 0` guard. After a genuine silence — a two-second gap
        // in a ballad, the half second between cuts — the flux history is all
        // zeros, so the median and the MAD are both zero and a positivity guard
        // would reject the *first hit back*, which is the most important onset
        // in the passage. Zero variability means any flux at all is infinitely
        // above the band's own noise; the relative, gate and liveliness tests
        // are what decide whether it is real.
        guard candidate.flux > threshold,
              candidate.flux > Self.medianRatio * median,
              gateLevel > 0.5,
              candidate.time - lastFire > kind.refractorySeconds else { return released }

        let excess = candidate.flux / max(threshold, QuantileTracker.floor)
        let found = Candidate(time: candidate.time,
                              kind: kind,
                              flux: candidate.flux,
                              threshold: threshold,
                              strength: min(1, (excess - 1) / 1.5),
                              confidence: clamp((excess - 1) / 2, 0, 1))

        // **Flux leads level, structurally.** The flux peaks when energy is
        // entering the analysis window fastest; the band's level peaks half a
        // window later, when the window is full of it. At the flux peak of a
        // measured kick the band's CURRENT_RELATIVE was 1.12 and two hops later
        // 1.39 — so asking "is this band above its own long average *now*" is
        // asking a hop or two too early, and simply waiting for the answer costs
        // 21 ms of a 67 ms budget on **every** onset.
        //
        // So the level test runs twice. A hit whose level has already caught up
        // fires immediately, which is most of them; one whose level is still
        // rising is held for exactly one hop and re-tested. The slow path costs
        // 11 ms and only the events that need it.
        // The weakest band of the region gets its own, gentler floor: the region
        // has to have risen as a whole, not just at one edge. A voice's
        // fundamental sits at 85–180 Hz, on the upper band of the kick region
        // and nowhere near its lower one, so on the region's mean alone every
        // voiced syllable reads as a kick.
        // Over the candidate hop and the one *after* it, never the one before.
        // The level lags the flux, so looking forward is the whole point of the
        // deferral below; looking backward is looking at the state the region
        // was in before the transient, which is evidence of nothing and quietly
        // turned the region test into "did any of the last three hops look
        // right".
        let relative = max(recent[1].relative, recent[2].relative)
        let weakest = max(recent[1].weakest, recent[2].weakest)
        if relative > Self.snrRatio, weakest > Self.weakestBandRatio(for: kind) { return found }
        deferred = found
        return released
    }

    /// Records that arbitration accepted this detector's candidate. Only an
    /// accepted event starts the refractory window — a suppressed candidate must
    /// not blind the detector to the next real hit.
    public mutating func accept(at time: Double) { lastFire = time }

    public mutating func reset() {
        previous.removeAll()
        history.removeAll()
        recent.removeAll()
        deferred = nil
        lastFire = -.infinity
    }

    /// A candidate onset, before the cross-band arbiter has had its say.
    public struct Candidate: Equatable, Sendable {
        public var time: Double
        public var kind: OnsetKind
        public var flux: Double
        public var threshold: Double
        public var strength: Double
        public var confidence: Double
        /// Whether this event took the slow path, for telemetry.
        public var deferredByAHop = false

        /// Arbitration score: how convincing this candidate is, weighted by how
        /// much its kind should win a tie.
        public var score: Double { (flux / max(threshold, 1e-12)) * kind.arbiterWeight }
    }
}

/// Winner-take-all across kinds over a short window (§2.2, fault 3).
///
/// A kick legitimately spans 40–400 Hz and used to fire the kick *and* the snare
/// detector, doubling the trigger rate on every real hit and inventing two
/// phantom snares a second on a kick-only signal. Bass wins ties deliberately: a
/// genuine simultaneous kick and snare reads fine as a kick accent, whereas a
/// phantom snare on every kick is the measured failure.
public struct OnsetArbiter: Sendable {

    /// Candidates whose times fall within this window compete.
    public static let window: Double = 0.025
    /// How long a lower-precedence candidate waits before it is decided.
    ///
    /// Longer than the 25 ms competition window, because the peaks of one hit's
    /// energy in different regions do not coincide: a kick's mid-band click can
    /// peak 40 ms before its low-band body does, and a snare decided at 25 ms
    /// would be emitted before the kick that caused it ever arrived. Costs the
    /// snare and hat about one display frame; costs the kick nothing, since the
    /// top precedence is emitted immediately.
    public static let decisionDelay: Double = 0.060

    private var pending: [FluxOnsetDetector.Candidate] = []
    /// Times a top-precedence event has already taken.
    private var claimed: [(time: Double, weight: Double)] = []

    public init() {}

    /// Adds this hop's candidates and returns those that can now be decided.
    ///
    /// A candidate of the **top** precedence needs no arbitration at all: under
    /// the strict ordering below nothing arriving later can beat it, so it is
    /// emitted the moment it appears and the arbiter costs the kick — the event
    /// every mode reacts to — exactly zero latency. Lower-precedence candidates
    /// wait out the window to see whether a kick turns up.
    public mutating func arbitrate(_ candidates: [FluxOnsetDetector.Candidate],
                                   now: Double) -> [FluxOnsetDetector.Candidate] {
        var winners: [FluxOnsetDetector.Candidate] = []
        for candidate in candidates where candidate.kind.arbiterWeight >= Self.topWeight {
            guard !isBlocked(candidate) else { continue }
            winners.append(candidate)
            claimed.append((candidate.time, candidate.kind.arbiterWeight))
        }
        pending += candidates.filter { $0.kind.arbiterWeight < Self.topWeight }
        claimed.removeAll { now - $0.time > Self.samePrecedenceBlock * 2 }

        var remaining: [FluxOnsetDetector.Candidate] = []
        var decided: [FluxOnsetDetector.Candidate] = []
        for candidate in pending {
            if now - candidate.time >= Self.decisionDelay {
                decided.append(candidate)
            } else {
                remaining.append(candidate)
            }
        }
        pending = remaining

        // Anything an equal-or-higher-precedence event already claimed is
        // suppressed, over the two windows below: a hit's energy smears across
        // the spectrum over the length of its transient, so a snare detector
        // firing inside a kick is describing the same physical event — the
        // phantom-snare failure the audit measured at 2 per second — while two
        // events of the same kind are paced by how long a gesture takes to be
        // seen.
        decided.removeAll { isBlocked($0) }
        decided.sort { $0.time < $1.time }
        var group: [FluxOnsetDetector.Candidate] = []
        for candidate in decided {
            if let first = group.first, candidate.time - first.time >= Self.window {
                if let best = Self.winner(of: group), !isBlocked(best) {
                    winners.append(best)
                    claimed.append((best.time, best.kind.arbiterWeight))
                }
                group = []
            }
            group.append(candidate)
        }
        if let best = Self.winner(of: group), !isBlocked(best) {
            winners.append(best)
            claimed.append((best.time, best.kind.arbiterWeight))
        }
        return winners
    }

    private func isBlocked(_ candidate: FluxOnsetDetector.Candidate) -> Bool {
        claimed.contains { claim in
            guard claim.weight >= candidate.kind.arbiterWeight else { return false }
            let window = claim.weight > candidate.kind.arbiterWeight
                ? candidate.kind.shadowSeconds
                : Self.samePrecedenceBlock
            return abs(claim.time - candidate.time) < window
        }
    }

    /// How long an accepted event suppresses candidates of its **own**
    /// precedence: two events of the same kind have to read as two on a
    /// keyboard, and a gesture needs its attack, its hold and some of its
    /// release to be seen at all.
    ///
    /// This and ``OnsetKind/shadowSeconds`` used to be one constant at 330 ms,
    /// which made the arbiter a global rate limiter rather than a cross-band
    /// exclusion: on `edm-128`, against a ground truth of ~2.1 kicks, ~4.3 hats
    /// and ~1.1 snares per second, the accepted rate was 2.03 Hz and almost
    /// every hat was discarded outright — the opposite of §1.2's reason for
    /// having an onset ring at all, and invisible to M5 because 3 Hz sits
    /// inside its 0.5–5 Hz band.

    /// …and how long it suppresses candidates of its **own** precedence: two
    /// events of the same kind have to read as two on a keyboard, and a gesture
    /// needs its attack, its hold and some of its release to be seen at all.
    ///
    /// These were one constant at 330 ms, and that made the arbiter a global
    /// rate limiter rather than a cross-band exclusion: on `edm-128`, against a
    /// ground truth of ~2.1 kicks, ~4.3 hats and ~1.1 snares per second, the
    /// accepted rate was 2.03 Hz and almost every hat and snare was discarded
    /// outright — the opposite of §1.2's reason for having an onset ring at
    /// all, and invisible to M5 because 3 Hz sits inside its 0.5–5 Hz band. A
    /// kick no longer deletes the hats around it; it only outranks anything
    /// describing the same transient.
    public static let samePrecedenceBlock: Double = 0.330

    /// The highest precedence any kind carries.
    private static var topWeight: Double {
        OnsetKind.allCases.map(\.arbiterWeight).max() ?? 1
    }

    /// Precedence, then score.
    ///
    /// The ordering is strict rather than a weighted score, because the two
    /// cases the arbiter has to separate are asymmetric. A kick leaking into the
    /// snare band must never produce a snare; a genuine kick landing *with* a
    /// snare — every backbeat of every four-to-the-floor track — must still be
    /// reported, and the design's own answer is that it "reads fine as a kick
    /// accent". Scoring the two against each other lost half the kicks on
    /// edm-128, because a snare's noise burst always outscores a sine kick.
    private static func winner(of group: [FluxOnsetDetector.Candidate])
        -> FluxOnsetDetector.Candidate? {
        group.max { left, right in
            left.kind.arbiterWeight != right.kind.arbiterWeight
                ? left.kind.arbiterWeight < right.kind.arbiterWeight
                : left.score < right.score
        }
    }

    public mutating func reset() {
        pending.removeAll()
        claimed.removeAll()
    }
}
