import Foundation

/// The multi-timescale energy model (§11): the answer to *"it's like a cliff —
/// the moment a certain sound plays a certain colour happens, it's instantaneous
/// triggered and then goes back to zero. There's no sort of short term
/// accumulation."*
///
/// ## Why the previous design could not accumulate
///
/// Everything r1 displayed was built from quantities that are, by explicit
/// design, memoryless beyond four seconds. `AVERAGE_RELATIVE` is
/// `short / long` with `long τ = 4 s` and §3.2 states outright that it "revolves
/// around 1.0 for any material at any volume" — which is precisely the property
/// that destroys structure. `x_norm` is percentile-normalised over ten seconds,
/// so a sixteen-second build is normalised *while it is happening*. A quantity
/// normalised over τ is high-pass filtered at ≈ 1/τ: it **cannot** express
/// variation slower than τ, by construction.
///
/// P9 is the amendment: normalise against a window *longer* than the structure
/// you want to show, and make every displayed quantity name its timescale.
///
/// | timescale | window | what it may express |
/// |---|---|---|
/// | TRANSIENT | 10–300 ms | individual hits (the §4 accents) |
/// | PHRASE | 0.5–2 s | this bar is louder than the last one (``phrase``) |
/// | SECTION | 10–30 s | we are in the drop, not the intro (``section``) |
///
/// M6's `[0.85, 1.20]` bound continues to apply to the *fast* relative values
/// and explicitly does **not** apply to these envelopes; asserting it on them
/// would re-impose the defect.
public struct EnergyModel: Sendable {

    // MARK: - Constants (§11, Appendix A)

    /// The reference window for `E`. Sixty seconds, not ten: to show a twenty
    /// second build you must normalise over something longer than twenty
    /// seconds. Sixty is roughly two sections of popular music and comfortably
    /// longer than any phrase.
    public static let referenceWindow: Double = 60.0
    /// The minimum divisor, in decibels: the programme dynamic range below which
    /// there is genuinely nothing to show, and stretching noise to full range
    /// would be inventing structure. The one place a decibel appears as a
    /// constant, and a statement about *perception* rather than about a track
    /// (P1b).
    ///
    /// **18 dB, not §11.1's 6 dB.** The floor is not only a guard against
    /// degenerate material: on any run shorter than the 60 s reference window it
    /// is what actually sets the mapping, because the percentile trackers have
    /// not yet seen a full window and `R_hi − R_lo` is still small. At 6 dB the
    /// energy saturated six decibels above the noise floor — measured, `E` had a
    /// mean of 0.997 across the whole 39 dB `crescendo` — which is the r1 defect
    /// this section exists to remove, wearing a different hat. 18 dB is the
    /// crest factor §10.1 specifies for `ballad-72`, i.e. the programme range of
    /// sparse acoustic material; below it a master reads flat, which is what
    /// §11.1 asks for.
    ///
    /// **What this actually measures at HEAD**, replacing a comment that quoted
    /// figures the build does not produce: `build-drop/pulse` scores ρ_slow
    /// **0.725** and ρ_build **0.652** against bounds of 0.80 and 0.60, and
    /// `crescendo/pulse` scores ρ_slow **0.218**. The earlier "ρ_slow 0.85 at
    /// 18 dB" was not reproducible — every one of the battery's seventy ρ_slow
    /// checks fails at HEAD — and a normative-looking justification that states
    /// a measurement the build does not produce is worse than no justification.
    ///
    /// The residual on `crescendo` is **structural, not a tuning error**, and it
    /// is worth writing down so nobody sweeps this constant again looking for
    /// it. `E` is `(Λ − R_lo) / max(R_hi − R_lo, floor)` with `R_lo` a slow p05,
    /// so on a *monotone* ramp the numerator grows with the material while the
    /// divisor is pinned at the floor: `E` therefore saturates exactly `floor`
    /// decibels above where the ramp started. `crescendo`'s RMS envelope spans
    /// 66 dB, so at 18 dB the board reaches full three quarters of the way
    /// through the rise and is flat for the rest. Widening the floor fixes
    /// `crescendo` and costs `build-drop` its `dropContrast` (a 20 dB build
    /// would then use a fifth of the range); narrowing it does the reverse. And
    /// letting `R_hi` chase the ramp — the other lever — makes `E ≡ 1` for the
    /// whole rise, which is §11.0's "normalised while it is happening" defect
    /// arriving by a different route. No single value of this constant satisfies
    /// both cases; see §10.5.
    public static let dynamicRangeFloor: Double = 18.0

    /// PHRASE ballistics. **The hold is the anti-cliff term at this timescale**:
    /// side-chain ducking at 128 BPM has a 469 ms period and a beat gap in a
    /// ballad is about 800 ms, so a 250 ms hold plus a 1.6 s release means
    /// neither of those starts a meaningful fall — while a genuine four-bar
    /// decrescendo (≈ 7.5 s at 128 BPM) is tracked almost exactly.
    public static let phraseAttack: Double = 0.350
    public static let phraseHold: Double = 0.250
    public static let phraseRelease: Double = 1.600

    /// SECTION time constants. Asymmetric on purpose: a section arrives faster
    /// than it leaves, so a two-bar breakdown inside a drop does not discard the
    /// drop.
    public static let sectionRise: Double = 8.0
    public static let sectionFall: Double = 20.0
    /// The accelerated constant used by the novelty escape hatch.
    public static let sectionEscape: Double = 3.0
    /// Novelty is `|Φ − Σ|` sustained for ``noveltyHold`` seconds.
    public static let noveltyOpen: Double = 0.35
    public static let noveltyClose: Double = 0.15
    public static let noveltyHold: Double = 1.5
    /// The escape may accelerate `Σ`'s *fall* only on sustained genuine quiet.
    public static let quietLevel: Double = 0.15
    public static let quietHold: Double = 3.0
    /// **The anti-cliff guarantee at the SECTION timescale**, and it is
    /// normative: even the accelerated path takes at least four seconds from
    /// full to zero.
    public static let sectionFallRateLimit: Double = 0.25

    /// True silence still darkens the board — but only after the music has
    /// genuinely stopped, and never sooner.
    public static let silenceLevel: Double = 0.05
    public static let silenceRampStart: Double = 4.0
    public static let silenceRampEnd: Double = 8.0

    /// Where the soft knee starts.
    public static let knee: Double = 0.5

    /// The widest the reference range may be, in decibels.
    ///
    /// A p05 tracker falls nineteen times faster than it rises — that asymmetry
    /// is what makes it a 5th percentile — so a single stretch of digital
    /// silence drops the floor to the numerical guard and it then climbs back at
    /// 0.03 dB/s, which is seventeen minutes to recover thirty decibels. Every
    /// level above it is then 200 dB above the floor and `E` reads exactly 1.000
    /// at every hop: measured on two real tracks, `E` min = max = 1.000 across a
    /// sixty-second excerpt, so `Φ` and `Σ` carried no dynamics at all and the
    /// bed the whole of §11 exists to produce was a constant. This is the same
    /// defect §3.3 names in the old `NoiseFloorTracker` — "drops *instantly* to
    /// any new minimum and takes 12 s to recover" — arriving in a new place.
    ///
    /// Forty decibels is wider than the programme range of any master and
    /// narrower than the distance to digital silence, and it is a *ratio*
    /// between two observed quantities, so nothing here becomes absolute (P1).
    public static let maximumRange: Double = 40.0

    /// Maps the normalised log level onto `0…1` with a **soft knee** instead of
    /// a hard clamp at the top.
    ///
    /// §11.1 writes `clamp(…, 0, 1)`. A hard clamp means every level above the
    /// reference's p95 looks identical, which is the same "loud passages all
    /// read the same" failure the section exists to remove — and on any run
    /// shorter than the 60 s reference window it bites early, because the span
    /// is still the floor. Measured on `crescendo`, whose whole content is a
    /// monotone 39 dB ramp, a hard clamp put `E` at 1.000 for three quarters of
    /// the run and M9b's correlation at 0.27; the knee is a limiter rather than
    /// a clipper and it keeps the ramp monotone all the way up. The bottom stays
    /// a hard clamp at zero: below the reference floor there really is nothing.
    static func compress(_ x: Double) -> Double {
        guard x > Self.knee else { return max(0, x) }
        let head = 1 - Self.knee
        return Self.knee + head * (1 - exp(-(x - Self.knee) / head))
    }

    // MARK: - State

    private var low = QuantileTracker(percentile: 0.05, window: EnergyModel.referenceWindow)
    private var high = QuantileTracker(percentile: 0.95, window: EnergyModel.referenceWindow)
    private var phraseEnvelope = AHR(attack: EnergyModel.phraseAttack,
                                     hold: EnergyModel.phraseHold,
                                     release: EnergyModel.phraseRelease)
    private var sectionValue: Double = 0
    private var noveltyFor: Double = 0
    private var quietFor: Double = 0
    private var escaping = false
    private var silentFor: Double = 0
    private var hasOpened = false

    public init() {}

    /// `E(t)` — the dimensionless long-referenced energy all three envelopes are
    /// driven from. `0` until the master gate has opened at least once, so a
    /// session that begins in silence does not light the board.
    public private(set) var energy: Double = 0
    /// `Φ(t)` — the PHRASE layer.
    public var phrase: Double { phraseEnvelope.value }
    /// `Σ(t)` — the SECTION layer.
    public var section: Double { sectionValue }
    /// `0 → 1` over the four seconds after the music has been silent for four
    /// seconds, so the board reaches black about eight seconds after the music
    /// genuinely stops.
    public private(set) var silenceRamp: Double = 0

    /// Folds one analysis hop in.
    ///
    /// - Parameters:
    ///   - rms: time-domain RMS of the hop. The one quantity in the pipeline
    ///     that carries an absolute level, and it is used here only through its
    ///     own 60 s percentiles — the comparison stays relative (P1).
    ///   - gateOpen: whether the master gate is open. The percentile history is
    ///     frozen while it is closed, exactly as §3.3 requires, so silence
    ///     cannot wind the reference down.
    public mutating func update(rms: Double, gateOpen: Bool, now: Double, dt: Double) {
        if gateOpen { hasOpened = true }

        // Log domain: music is multiplicative. `QuantileTracker` takes
        // multiplicative steps, so tracking the percentiles of `rms` *is*
        // tracking the percentiles of `Λ` — one Double per tracker instead of a
        // 64-bucket histogram, converging to the same estimand.
        // Digital silence is not an observation of the material's level, and it
        // must not seed the reference. `QuantileTracker` seeds on its first
        // sample, and a file or a stream that begins with a few silent hops
        // seeded **both** percentiles at the numerical guard — from which p05
        // climbs at 0.003 nats per second and p95 at 0.06, so after twenty
        // seconds of a real track the reference was still 120 dB below the
        // music and `E` read exactly 1.000 at every hop. Measured on two real
        // masters; the synthetic battery never saw it because its generators
        // start on the first sample. `1e-6` is a numerical guard far below any
        // converter's own noise floor and is never used as a decision threshold
        // (P1c) — the *decision* about whether anything is playing is the master
        // gate, which is the other half of this condition.
        if gateOpen, rms > 1e-6 { low.update(rms, dt: dt); high.update(rms, dt: dt) }
        let lambda = 20 * log10(max(rms, 1e-7))
        let lowDB = 20 * log10(max(low.value, 1e-7))
        let highDB = 20 * log10(max(high.value, 1e-7))
        let lowBounded = max(lowDB, highDB - Self.maximumRange)
        let span = max(highDB - lowBounded, Self.dynamicRangeFloor)
        energy = hasOpened ? Self.compress((lambda - lowBounded) / span) : 0

        phraseEnvelope.update(target: energy, now: now, dt: dt)
        updateSection(dt: dt)

        // **The ramp-out is driven by the master gate, not by `E`.**
        //
        // §11.3 writes the condition as `E < 0.05` for four seconds. `E` is a
        // *percentile* of the last sixty seconds, so its bottom is wherever the
        // quietest 5 % of the material sits — and a passage that is genuinely
        // playing but quiet lives exactly there by construction. Measured on
        // `cut-transitions`, the five seconds of −34 dBFS piano in each half sat
        // at `E ≈ 0` and the board ramped itself to black while the music was
        // audible: 26 % of the playing frames dark against a 5 % bound. That is
        // the user's complaint about quiet material, arriving through the very
        // mechanism §11 added to fix it. The master gate is the pipeline's
        // "is anything playing at all" test and is the one place an absolute
        // level legitimately enters (§3.3's clamped AGC), so it is what the
        // ramp-out belongs on. Any open-gate hop resets the timer instantly:
        // rise is unrestricted, only the fall is held back.
        // **…and by `E` *and* `Σ` together, which is what a room floor trips.**
        //
        // Gating on the master gate alone leaves a hole the size of a quiet
        // room. The gate is `smoothstep(0.018, 0.030, rmsPeak · gain)` with the
        // AGC gain clamped at 16×, so it decides "is anything playing" inside a
        // 4.4 dB window centred on −57 dBFS: a −45 dBFS noise floor — where a
        // microphone in a quiet room actually sits — reads 0.09 through it and
        // is therefore "music". Measured on 20 s of 128 BPM material followed by
        // a noise tail, the board went dark, *relit*, and then held a board mean
        // of 0.10 indefinitely on nothing but room tone.
        //
        // `E < 0.05` alone is §11.3's literal condition and cannot be used
        // alone either: `E` is a percentile of the last sixty seconds, so a
        // passage that is genuinely playing but quiet sits at `E ≈ 0` by
        // construction, and `cut-transitions`' five seconds of −34 dBFS piano
        // ramped itself to black while the music was audible.
        //
        // `Σ` is what separates the two, and it is separated by the mechanism
        // §11.3 already specifies rather than by a new threshold: SECTION falls
        // with τ = 20 s and is rate-limited to 0.25 per second, so five seconds
        // of quiet piano *cannot* pull it under ``quietLevel`` while a minute of
        // room tone certainly does. Quiet music keeps its section; a room does
        // not have one.
        if !hasOpened {
            silentFor = 0
            silenceRamp = 0
        } else if !gateOpen || (energy < Self.silenceLevel && sectionValue < Self.quietLevel) {
            silentFor += dt
            silenceRamp = smoothstep(Self.silenceRampStart, Self.silenceRampEnd, silentFor)
        } else {
            silentFor = 0
            silenceRamp = 0
        }
    }

    /// `Σ`'s one-pole, its novelty escape and its fall-rate limit.
    ///
    /// A pure twenty-second time constant makes a real section change take
    /// twenty seconds to show, which is its own failure — hence the escape. The
    /// **downward asymmetry is normative**: `Σ` may accelerate its rise on any
    /// novelty, but may accelerate its fall only on sustained genuine quiet. A
    /// filter sweep to nothing, a one-bar stop, a badly gain-staged verse —
    /// none of them may collapse the bed.
    private mutating func updateSection(dt: Double) {
        let novelty = abs(phraseEnvelope.value - sectionValue)
        if novelty > Self.noveltyOpen {
            noveltyFor += dt
            if noveltyFor >= Self.noveltyHold { escaping = true }
        } else {
            noveltyFor = 0
            if novelty < Self.noveltyClose { escaping = false }
        }
        if energy < Self.quietLevel { quietFor += dt } else { quietFor = 0 }
        noveltyFired = escaping && !wasEscaping
        wasEscaping = escaping

        let rising = phraseEnvelope.value > sectionValue
        var tau: Double
        if rising {
            tau = escaping ? Self.sectionEscape : Self.sectionRise
        } else {
            let mayAccelerate = escaping && quietFor >= Self.quietHold
            tau = mayAccelerate ? Self.sectionEscape : Self.sectionFall
        }
        let a = exp(-max(dt, 0) / max(tau, 1e-6))
        var next = phraseEnvelope.value + (sectionValue - phraseEnvelope.value) * a
        // The hard limit, applied at all times and not only on the escape path.
        let floor = sectionValue - Self.sectionFallRateLimit * max(dt, 0)
        if next < floor { next = floor }
        sectionValue = clamp(next, 0, 1)
    }

    /// Whether a §11.3 novelty event *began* on this hop. §12.1's structure kick
    /// consumes it: a new section visibly changes the palette.
    public private(set) var noveltyFired = false
    private var wasEscaping = false

    public mutating func reset() {
        low.reset()
        high.reset()
        phraseEnvelope.reset()
        sectionValue = 0
        noveltyFor = 0
        quietFor = 0
        escaping = false
        wasEscaping = false
        noveltyFired = false
        silentFor = 0
        silenceRamp = 0
        hasOpened = false
        energy = 0
    }
}

/// The §11.4 composition, in one place so that no mode can invent a bed of its
/// own again.
///
/// ```
/// bed(t)      = B0 + B1 · Σ(t)
/// swell(t)    = S1 · max(0, Φ(t) − k · Σ(t))
/// headroom(t) = 1 − bed(t) − swell(t)
/// L(x,t)      = clamp( (bed + swell) · shape(x,t)
///                      + A1 · accent(x,t) · headroom(t), 0, 1 ) · (1 − outAmount)
/// ```
///
/// The accent term is **added into the headroom**, and nothing in the accent
/// path may write back to `Φ`, `Σ`, `E` or the trail buffers. That one-way
/// dependency is the whole anti-cliff mechanism: a hit can only add light, never
/// remove it, and can never be followed by a return to zero because zero is not
/// where the bed is.
public struct Composition: Equatable, Sendable {

    /// **B0 = 0.16, not §11.4's 0.09**, and the reason is an inconsistency
    /// between two sections rather than a preference.
    ///
    /// §11.4 promises "board-mean lightness ≥ 0.09 · mean_x shape ≥ 0.06,
    /// which is M9c's floor", and deliberately makes it a board-mean rather than
    /// a per-key floor so that M1 and M4 keep measuring the model. But §6.3's
    /// interlock will not *light* a key until the composed level exceeds 0.14.
    ///
    /// **It is 0.09, the document's own number, and the 0.16 it replaces was a
    /// defect rather than a deviation.** A bed of 0.16 sits *above* §6.3's 0.14
    /// rise threshold, which makes it a **per-key floor** — the one thing
    /// §11.4 property 1 forbids in as many words: "a per-key floor above the
    /// interlock's 0.14 rise threshold would make M1 and M4 vacuous — the exact
    /// circularity `ModeRenderer` was already corrected for once." It did. On
    /// `edm-128/pulse`, 83 mapped LEDs produced 83 on/off transitions in a 30 s
    /// run — one each, every key lighting once and never going out — so M1 read
    /// 0.000 in 665 runs out of 665 and M4's on-duration median read the length
    /// of the run. Two whole metric families, 2 275 checks, asserted nothing.
    ///
    /// The same number was also what kept the board glowing on room tone: with
    /// the bed alone above the rise threshold, a −45 dBFS noise floor lit every
    /// key to a board mean of 0.10 and held it there indefinitely.
    ///
    /// What 0.16 was really compensating for was a *second* defect, in the
    /// interlock: a held key's output was snapped up to the rise threshold, so
    /// the bed had to clear 0.14 to be seen at all. §6.3 says the interlock "is
    /// a filter, not a source: it cannot create light that the model did not ask
    /// for", and snapping is precisely creating it. With the snap gone the bed
    /// is displayed at the level the model composed, and 0.09 works as written.
    public static let bedFloor: Double = 0.09          // B0
    public static let bedScale: Double = 0.15          // B1
    public static let swellScale: Double = 0.55        // S1
    public static let swellReference: Double = 0.85    // k
    public static let accentScale: Double = 0.90       // A1
    /// How much a transient's brightness depends on how loud the music is.
    ///
    /// **Added in r2, and it is the other half of the anti-cliff mechanism.**
    /// §11.4 scales the accent by `headroom`, which *shrinks* as the section
    /// gets loud — so a soft kick in an eight-second intro painted the same
    /// board as a full-energy kick in the drop, and `dropContrast` measured
    /// 0.05 against a 0.18 bound. Every gesture amplitude upstream is a
    /// `CURRENT_RELATIVE` ratio, which by construction says "this hit is loud
    /// *for this passage*" and cannot say "this passage is loud". P9 is exactly
    /// that point: a TRANSIENT rides on a SECTION, and if the transient is the
    /// only thing that moves then the display has no memory. Scaling by `Φ`
    /// makes a hit's brightness a statement about its context as well as about
    /// itself, and nothing in the accent path writes back to `Φ`, so the one-way
    /// dependency §11.4 requires is unchanged.
    public static let accentFloor: Double = 0.70
    public static let accentSpan: Double = 0.30

    public let bed: Double
    public let swell: Double
    public let silenceRamp: Double
    /// How bright this passage lets a transient be.
    public let accentGain: Double

    public init(phrase: Double, section: Double, silenceRamp: Double) {
        bed = Self.bedFloor + Self.bedScale * clamp(section, 0, 1)
        swell = Self.swellScale * max(0, clamp(phrase, 0, 1)
                                      - Self.swellReference * clamp(section, 0, 1))
        self.silenceRamp = clamp(silenceRamp, 0, 1)
        accentGain = Self.accentFloor + Self.accentSpan * clamp(phrase, 0, 1)
    }

    /// What a gesture has left to work with.
    public var headroom: Double { max(0, 1 - bed - swell) }

    /// The resting level, before the mode's own geometry.
    public var resting: Double { bed + swell }

    /// One column's composed lightness.
    ///
    /// - Parameters:
    ///   - shape: where the bed sits on the board — the only part of the resting
    ///     level a mode still owns.
    ///   - accent: the mode's fast field at this column, `0…1`.
    public func level(shape: Double, accent: Double) -> Double {
        let value = resting * clamp(shape, 0, 1)
            + Self.accentScale * accentGain * clamp(accent, 0, 1) * headroom
        return clamp(value, 0, 1) * (1 - silenceRamp)
    }
}
