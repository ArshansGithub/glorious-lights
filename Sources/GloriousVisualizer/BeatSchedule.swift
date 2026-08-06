import Foundation

/// Schedule-to-land (§2.3.3) and prediction credit (§2.3.4) — the answer to
/// *"the keyboard updates feel off beat."*
///
/// ## Why a constant lead was the wrong shape
///
/// r1 already scheduled beat-locked gestures early, by a *fixed*
/// `predictionLead = 0.040` that nobody measured, applied only when a beat
/// happened to fall inside the current frame's window. A constant lead cancels a
/// constant lag; the complaint is about the part that is *not* constant, and
/// nothing measured that part. P10 restates the goal: schedule so that the
/// gesture's **visible onset**, plus the measured pipeline latency, coincides
/// with the beat.
///
/// ```
/// t_vis     = startTime + τ_a · ln 2                  // half-rise
/// require     t_vis + L̂ = T_b
/// therefore   startTime = T_b − leadWeight · (L̂ + τ_a · ln 2)
/// ```
///
/// The half-rise is used because that is what an eye — and M8 — calls "the
/// gesture happened", so the metric and the mechanism agree on what is being
/// measured. `leadWeight` (§2.3.2) scales the whole lead by how stable the phase
/// actually is, so a shaky grid degrades *continuously* to reactive behaviour
/// rather than switching.
///
/// ## What bounds a prediction that turns out to be wrong
///
/// A predicted gesture is launched before its evidence exists, so three rules
/// bound what that can cost: a provisional amplitude (`γ = 0.6` of the recent
/// confirmed amplitude, so a phantom is always a modest accent and never a full
/// flash), **absorption** of the confirming onset (P5, unchanged — but the
/// consumption must be explicit or prediction and detection double-fire on every
/// beat, which reads as a flam), and a credit counter that stops prediction after
/// two consecutive misses.
public struct BeatSchedule: Sendable {

    /// A confirming onset must land inside `±W` of the predicted beat.
    public static let confirmWindow: Double = 0.090
    /// Provisional amplitude at the *lowest* credit prediction is allowed at.
    public static let provisional: Double = 0.6

    /// How much of the expected amplitude a predicted gesture launches at, given
    /// how much credit the grid has earned.
    ///
    /// **Deviation from §2.3.4, and its reasoning.** The document fixes
    /// `γ = 0.6` so that "a phantom is always a modest accent, never a full
    /// flash". Held at 0.6 unconditionally, the confirming onset then raises the
    /// gesture 40–70 ms after the beat, and the board's excursion has a *step*
    /// in it: the level sits at `0.6·A` for two frames and then jumps to `A`.
    /// Measured on `click-120`, half of the eventual excursion lands within a
    /// few thousandths of that plateau, so which side of it the crossing falls
    /// on is decided by noise — M8's `sd` was 12 ms on the click track and 32 ms
    /// on `edm-128` purely from that knife edge, and the bias was +37 ms
    /// wherever the plateau sat just under the half level.
    ///
    /// The credit counter is already the system's measure of how likely a
    /// prediction is to be right, so it is what γ should be a function of. At
    /// `credit = 1` — the minimum at which prediction is permitted at all — γ is
    /// the document's 0.6. At `credit = 4`, four consecutive beats have been
    /// confirmed and the prediction is not meaningfully speculative, so the
    /// gesture launches whole and there is no step to fall either side of. The
    /// phantom bound is unaffected: two misses still take credit below the
    /// launch threshold, which is what `click-120-gap` measures.
    public static func provisionalFraction(credit: Double) -> Double {
        Self.provisional + (1 - Self.provisional)
            * smoothstep(Self.creditToLaunch, Self.creditLimit, credit)
    }

    /// How long after `startTime` the board crosses **half of the excursion it
    /// is going to make** — the instant §2.3.3 wants to land on the beat.
    ///
    /// §2.3.3 writes this as `τ_a · ln 2`, the half-rise of a bare exponential
    /// launched at its final amplitude from zero. Three things make the real
    /// figure larger, and each one left out lands the gesture late by its own
    /// size:
    ///
    /// * the gesture launches at `γ · A` and is raised to `A` by its confirming
    ///   onset 40–70 ms later (§2.3.4),
    /// * it starts from the tail of the gesture it replaced, not from zero, so
    ///   half of the *excursion* is above half of the amplitude,
    /// * the displayed level is integrated over half a frame's exposure (§5.5).
    ///
    /// All three are known at scheduling time, which is what makes them
    /// *compensated* rather than unavoidable latency (§8.1-R).
    static func visibleOnsetDelay(expected: Double, launched: Double, carry: Double,
                                  envelope: AHR, frameInterval: Double) -> Double {
        let peak = max(expected, launched)
        let half = carry + 0.5 * max(peak - carry, 1e-6)
        return Gesture.visibleDelay(level: half, amplitude: launched, carry: carry,
                                    attack: envelope.attack, hold: envelope.hold,
                                    release: envelope.release,
                                    frameInterval: frameInterval)
    }
    /// The EWMA over which "the recent confirmed amplitude" is measured, in
    /// beats.
    public static let amplitudeBeats: Double = 4
    /// `+1` on confirmation, `−2` on a miss, clamped, launching only at `≥ +1`.
    /// Two consecutive misses therefore stop prediction and two consecutive
    /// confirmations restart it.
    public static let creditOnConfirm: Double = 1
    public static let creditOnMiss: Double = -2
    public static let creditLimit: Double = 4
    public static let creditToLaunch: Double = 1

    /// One predicted beat, from the moment it is published until the moment its
    /// confirmation window closes.
    private struct Slot {
        var time: Double
        var launched = false
        var confirmed = false
    }

    private var slots: [Slot] = []
    private var credit: Double = 0
    private var expected: Double = 0.7

    public init() {}

    /// `0…1`, for telemetry and tests.
    public var predictionCredit: Double { credit }
    /// How many gestures were launched ahead of their evidence, and how many
    /// beats were confirmed and missed. Telemetry, so that "is it predicting?"
    /// is a number rather than an inference from the picture.
    public private(set) var launches = 0
    public private(set) var confirmations = 0
    public private(set) var misses = 0
    /// Whether prediction is currently permitted.
    public var isPredicting: Bool { credit >= Self.creditToLaunch }
    /// The EWMA of confirmed on-grid amplitudes, `A_exp`.
    public var expectedAmplitude: Double { expected }

    /// Folds this frame's published beat in and resolves anything whose window
    /// has closed.
    ///
    /// - Returns: the beat to launch on this frame, if any, with the provisional
    ///   amplitude it should launch at.
    /// - Returns: the beat to launch on this frame, the timestamp to start its
    ///   envelope at, and the amplitude to launch it with.
    /// - Parameter carry: the level the board is currently falling from, which
    ///   the new gesture will inherit (``Gesture/carry``).
    public mutating func advance(state: AnalysisState, latency: Double,
                                 envelope: AHR, frameInterval: Double, carry: Double,
                                 previousFrame: Double, now: Double,
                                 grace: Double = 0)
        -> (beatTime: Double, startTime: Double, amplitude: Double)? {
        let period = state.tempo.beatPeriod

        // Resolve: a beat that has passed its confirmation window unconfirmed is
        // a miss. This is time-based rather than tied to the phase rolling over,
        // because a confirmation may legitimately arrive after the beat.
        var index = 0
        while index < slots.count {
            if now > slots[index].time + Self.confirmWindow + max(grace, 0) {
                if !slots[index].confirmed {
                    misses += 1
                    credit = clamp(credit + Self.creditOnMiss, -Self.creditLimit,
                                   Self.creditLimit)
                }
                slots.remove(at: index)
            } else {
                index += 1
            }
        }

        // The grid has stopped being believable: the analyser abandons it four
        // seconds after the last onset, and the board must not go on beating at
        // a tempo the music has stopped playing.
        guard state.tempo.bpm > 0, state.tempo.gridWeight > 0 else {
            // **A prediction that is abandoned is still a prediction that was
            // not confirmed.** Clearing the slots silently meant the credit
            // counter never saw the failure, so on `click-120-gap` — the case
            // that exists to test §2.3.4 — the whole four-second gap produced
            // *one* miss against eight muted beats, and what actually stopped
            // the board was the grid-grounding timeout rather than the credit
            // rule. The check passed while the mechanism it names went
            // untested. A slot whose beat time has already passed was a
            // published prediction that nothing confirmed, whether or not a
            // gesture was launched on it; one still in the future was never
            // asserted and is simply dropped.
            for slot in slots where slot.time <= now && !slot.confirmed {
                misses += 1
                credit = clamp(credit + Self.creditOnMiss, -Self.creditLimit,
                               Self.creditLimit)
            }
            slots.removeAll()
            credit = min(credit, 0)
            return nil
        }

        let beat = state.tempo.nextBeatTime
        if beat > 0, !slots.contains(where: { abs($0.time - beat) < period * 0.5 }) {
            slots.append(Slot(time: beat))
            if slots.count > 4 { slots.removeFirst(slots.count - 4) }
        }

        guard credit >= Self.creditToLaunch else { return nil }
        let fraction = Self.provisionalFraction(credit: credit)
        let amplitude = clamp(fraction * expected, 0, 1)
        let lead = state.tempo.leadWeight
            * (latency + Self.visibleOnsetDelay(expected: expected, launched: amplitude,
                                                carry: min(carry, amplitude * 0.9),
                                                envelope: envelope,
                                                frameInterval: frameInterval))
        for index in slots.indices where !slots[index].launched {
            let start = slots[index].time - lead
            // The frame whose scheduled time first reaches or passes `startTime`
            // (§2.3.3). A gesture launched one frame late is still rendered at
            // the right point of its own envelope, because it is evaluated as
            // `f(t_frame − startTime)`; a gesture launched arbitrarily late is
            // not, so a stale slot is simply skipped.
            guard start <= now, start > previousFrame - period * 0.5 else { continue }
            slots[index].launched = true
            launches += 1
            return (slots[index].time, start, amplitude)
        }
        return nil
    }

    /// Offers an arbitrated onset to the schedule.
    ///
    /// - Parameter amplitude: what this onset would have driven, or `nil` if the
    ///   mode does not display this kind. **Every arbitrated onset confirms** —
    ///   §2.3.4 says "an arbitrated onset", not "an onset this mode happens to
    ///   paint". A hat on a beat is evidence that the beat happened, and on the
    ///   174 BPM breakbeat it is the *only* evidence on half of the beats of the
    ///   half-time grid the tracker folds to: with hats excluded the credit
    ///   counter alternated `+1, −2` forever and the board never predicted a
    ///   single beat on that case.
    ///
    /// - Returns: `.absorbed` when a predicted gesture is already in flight for
    ///   this beat — the caller must raise that gesture's amplitude and create
    ///   nothing, which is exactly §5.2's absorption rule. `.reactive` when the
    ///   onset is not on a predicted beat, or is on one the credit rule did not
    ///   let us launch, in which case it fires normally.
    public mutating func offer(onset: OnsetEvent, amplitude: Double?) -> Consumption {
        guard let index = slots.firstIndex(where: {
            abs(onset.time - $0.time) <= Self.confirmWindow && !$0.confirmed
        }) else { return .reactive }
        slots[index].confirmed = true
        confirmations += 1
        credit = clamp(credit + Self.creditOnConfirm, -Self.creditLimit, Self.creditLimit)
        // A four-beat EWMA of what a confirmed on-grid hit actually looks like,
        // so the provisional amplitude is drawn from the music rather than from
        // a constant. Only onsets the mode actually paints contribute: a hat
        // confirms the grid but says nothing about how bright a beat is.
        if let amplitude {
            let a = exp(-1 / Self.amplitudeBeats)
            expected = amplitude + (expected - amplitude) * a
        }
        guard amplitude != nil else { return .reactive }
        return slots[index].launched ? .absorbed : .reactive
    }

    public enum Consumption: Sendable { case absorbed, reactive }

    public mutating func reset() {
        slots.removeAll()
        credit = 0
        expected = 0.7
    }
}
