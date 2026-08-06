import Foundation

/// A shape moving on the board, described once and then evaluated as a pure
/// function of time.
///
/// This is the single largest change in the redesign. Nothing here is advanced
/// once per frame; the display is `f(gestures, t_frame)`. Three properties come
/// out of that for free:
///
/// * frame jitter does not become motion jitter,
/// * a dropped frame skips nothing — the gesture is still where it should be,
/// * sub-frame positions are exact.
public struct Gesture: Equatable, Sendable {

    public enum Kind: Sendable {
        /// Board-wide brightness.
        case pulse
        /// A band of light travelling across the columns.
        case wave
        /// A shell expanding from an origin column.
        case ring
    }

    public enum Phase: Equatable, Sendable { case attack, hold, release }

    public var kind: Kind
    /// Host time the gesture began — often slightly in the past, because onsets
    /// are timestamped back by the analysis group delay.
    public var startTime: Double
    /// `0…1`, raised by absorption, never lowered.
    public var amplitude: Double
    /// Column the shape starts from.
    public var origin: Double
    /// `+1` or `-1`.
    public var direction: Double
    /// Columns per second. Already velocity-clamped when the gesture is made.
    public var speed: Double
    /// Spatial extent in columns before motion blur.
    public var width: Double
    /// Which drum made it, for colour. `nil` for beat-driven gestures.
    public var onsetKind: OnsetKind?
    /// The level this gesture **inherited** from the one it replaced.
    ///
    /// A mode whose gesture capacity is one (pulse: "the board *is* the
    /// gesture") evicts the outgoing gesture the instant a new one starts. With
    /// the outgoing level simply discarded, the board falls off its own decay
    /// curve to zero and then climbs again — a dip, one to two frames wide, on
    /// every beat. That is a cliff of exactly the kind §11 exists to remove, and
    /// it also made M8's pre-beat trough depend on **sub-frame phase**: whether
    /// the first post-launch frame landed above or below the discarded tail
    /// moved the half-rise crossing by up to 30 ms, which is most of the
    /// measured `sd`. Carrying the tail forward makes the transition continuous
    /// and the measurement deterministic.
    public var carry: Double = 0

    var attack: Double
    var hold: Double
    var release: Double

    public init(kind: Kind, startTime: Double, amplitude: Double,
                origin: Double = 0, direction: Double = 1, speed: Double = 0,
                width: Double = 2.8, onsetKind: OnsetKind? = nil,
                carry: Double = 0, envelope: AHR) {
        self.kind = kind
        self.startTime = startTime
        self.amplitude = amplitude
        self.origin = origin
        self.direction = direction
        self.speed = speed
        self.width = width
        self.onsetKind = onsetKind
        self.carry = max(0, carry)
        self.attack = envelope.attack
        self.hold = envelope.hold
        self.release = envelope.release
    }

    /// How long after `startTime` this gesture's envelope reaches **half** its
    /// amplitude — the instant §2.3.3 schedules against and M8 measures.
    ///
    /// The document writes it as `τ_a · ln 2`, which is the half-rise of a bare
    /// exponential. The envelope below is normalised so that its peak is exactly
    /// `amplitude` after three time constants, so its true half-rise is a little
    /// earlier; the difference is under two milliseconds, and computing it
    /// exactly is free. The metric and the mechanism have to agree on what "the
    /// gesture happened" means, or M8 measures the disagreement.
    public static func halfRise(attack: Double) -> Double {
        riseDelay(attack: attack, fraction: 0.5)
    }

    /// How long after `startTime` the envelope reaches `fraction` of its own
    /// amplitude.
    public static func riseDelay(attack: Double, fraction: Double) -> Double {
        let f = clamp(fraction, 0, 0.99)
        return -max(attack, 1e-6) * log(1 - f * (1 - exp(-3.0)))
    }

    public var halfRise: Double { Self.halfRise(attack: attack) }

    /// The peak is reached after three attack time constants; the hold runs from
    /// there.
    var attackEnd: Double { 3 * attack }
    var holdEnd: Double { attackEnd + hold }
    /// After five release time constants the gesture contributes less than 1 %
    /// and is evicted.
    public var lifetime: Double { holdEnd + 5 * release }

    public func phase(at time: Double) -> Phase {
        let u = time - startTime
        if u < attackEnd { return .attack }
        if u < holdEnd { return .hold }
        return .release
    }

    /// The gesture's amplitude envelope at `time` — a real point on a continuous
    /// function (P7), normalised so the peak is exactly `amplitude`.
    public func level(at time: Double) -> Double {
        let u = time - startTime
        guard u >= 0 else { return 0 }
        return max(Self.envelopeLevel(u: u, amplitude: amplitude, attack: attack,
                                      holdEnd: holdEnd, release: release),
                   carry * exp(-u / max(release, 1e-6)))
    }

    static func envelopeLevel(u: Double, amplitude: Double, attack: Double,
                              holdEnd: Double, release: Double) -> Double {
        if u < holdEnd {
            let rise = (1 - exp(-u / max(attack, 1e-6))) / (1 - exp(-3.0))
            return amplitude * min(1, rise)
        }
        return amplitude * exp(-(u - holdEnd) / max(release, 1e-6))
    }

    /// How long after `startTime` the **displayed** level — the frame-integrated
    /// one, inheriting `carry` — first reaches `level`.
    ///
    /// Solved numerically rather than from `τ · ln 2`, because the quantity the
    /// eye and M8 see is not the bare exponential: it is averaged over half a
    /// frame's exposure (§5.5), it starts from the tail of the gesture it
    /// replaced, and the level it has to reach is half of the *excursion* rather
    /// than half of the amplitude. Each of those is a known, compensable delay
    /// in §8.1-R's sense, and each one that is left out lands the gesture late by
    /// its own size.
    public static func visibleDelay(level: Double, amplitude: Double, carry: Double,
                                    attack: Double, hold: Double, release: Double,
                                    frameInterval: Double) -> Double {
        let holdEnd = 3 * attack + hold
        func displayed(_ u: Double) -> Double {
            func at(_ x: Double) -> Double {
                guard x >= 0 else { return 0 }
                return max(envelopeLevel(u: x, amplitude: amplitude, attack: attack,
                                         holdEnd: holdEnd, release: release),
                           carry * exp(-x / max(release, 1e-6)))
            }
            return (at(u) + at(u - frameInterval / 2)) / 2
        }
        guard displayed(holdEnd) > level else { return holdEnd }
        var low = 0.0, high = holdEnd
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if displayed(mid) < level { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// The level averaged over the frame's exposure window (§5.5's sub-step
    /// alternative).
    ///
    /// A display that samples once per frame and holds is an integrator, not a
    /// sampler; evaluating a 15 ms attack at a single instant makes the first
    /// frame of every gesture a full-amplitude step, which is what pushes the
    /// frame-to-frame difference metric past its ceiling. Averaging three
    /// sub-steps costs nothing and adds no latency — the newest sub-step is
    /// still the frame's own timestamp.
    public func integratedLevel(at time: Double, frameInterval: Double) -> Double {
        // Two sub-steps over the half-frame nearest the timestamp, not three
        // over the whole frame: averaging over the full exposure is a half-frame
        // of extra latency on every attack, and latency is the other half of the
        // user's verdict.
        (level(at: time) + level(at: time - frameInterval / 2)) / 2
    }

    /// Where the shape's centre is, in columns.
    public func position(at time: Double) -> Double {
        origin + direction * speed * max(0, time - startTime)
    }

    /// Spatial kernel widened by the distance travelled during one frame's
    /// exposure (§5.5). A 15/30 fps sample-and-hold display point-sampling a
    /// moving gesture aliases; widening the kernel converts strobing into
    /// streaking, which is what the eye expects from something moving fast.
    public func effectiveWidth(frameInterval: Double) -> Double {
        let smear = speed * frameInterval * 0.5
        return (width * width + smear * smear).squareRoot()
    }

    public func isAlive(at time: Double) -> Bool { time - startTime < lifetime }
}

/// The population of live gestures, with the absorption rule that is the whole
/// answer to "the lights don't properly stay on".
///
/// **A trigger arriving during ATTACK or HOLD is absorbed** — it raises the
/// amplitude and touches nothing else. It does not create a second gesture and
/// it does not reset the phase. Re-launching is exactly what stops a gesture
/// from ever displaying its body: the animation is perpetually restarted from
/// zero and the board reads as strobing rather than as moving.
public struct GestureList: Sendable {

    /// Hard cap; the oldest is evicted first. Even with correct detection a cap
    /// is required, because overlapping gestures average out to a uniform glow —
    /// the opposite of responding to detail.
    public var capacity: Int
    public private(set) var gestures: [Gesture] = []

    public init(capacity: Int) { self.capacity = capacity }

    /// Adds a gesture, or absorbs it into a compatible one already in flight.
    ///
    /// - Parameter minimumAge: a gesture younger than this cannot be replaced;
    ///   it absorbs instead. For waves this is half a beat (§9.2).
    @discardableResult
    public mutating func trigger(_ gesture: Gesture, at time: Double,
                                 minimumAge: Double = 0) -> Bool {
        prune(at: time)
        // Absorption: anything still building or holding takes the new energy —
        // but only if it is the *same* event. P5 is "a trigger arriving while a
        // gesture is in ATTACK or HOLD raises that gesture's amplitude", and a
        // snare is not a louder kick: it has its own origin, speed and hue
        // (§9.3), and VU filters its accents by kind (§9.5). Matching on
        // `Kind` alone made every ripple ring a `.ring` and every VU accent a
        // `.pulse`, so a drum landing inside another drum's attack+hold was
        // silently merged into it — with the wrong origin, colour and speed,
        // and on any backbeat that is the common case rather than the corner
        // one.
        if let index = gestures.firstIndex(where: { candidate in
            candidate.kind == gesture.kind
                && candidate.onsetKind == gesture.onsetKind
                && (candidate.phase(at: time) != .release
                    || time - candidate.startTime < minimumAge)
        }) {
            gestures[index].amplitude = max(gestures[index].amplitude, gesture.amplitude)
            return false
        }
        gestures.append(gesture)
        if gestures.count > capacity { gestures.removeFirst(gestures.count - capacity) }
        return true
    }

    /// Raises the newest gesture of a kind, creating nothing.
    ///
    /// This is §2.3.4's confirmation step: an onset that lands inside a
    /// predicted beat's window is **consumed** by the gesture already in flight
    /// for that beat rather than firing a second one. Without the explicit
    /// consumption, prediction and detection double-fire on every beat, which
    /// reads as a flam — the failure mode that would make schedule-to-land feel
    /// worse than the constant lead it replaces.
    public mutating func absorb(kind: Gesture.Kind, amplitude: Double) {
        guard let index = gestures.lastIndex(where: { $0.kind == kind }) else { return }
        gestures[index].amplitude = max(gestures[index].amplitude, amplitude)
    }

    public mutating func prune(at time: Double) {
        gestures.removeAll { !$0.isAlive(at: time) }
    }

    public mutating func removeAll() { gestures.removeAll() }

    /// The youngest gesture of a kind, if any.
    public func newest(_ kind: Gesture.Kind) -> Gesture? {
        gestures.last { $0.kind == kind }
    }
}

/// Velocity clamp of §5.4: with seventeen columns, motion faster than about two
/// cells per frame is unreadable — it reads as a shape reappearing elsewhere
/// rather than as motion.
@inlinable
public func clampedSpeed(_ cellsPerSecond: Double, frameInterval: Double) -> Double {
    min(cellsPerSecond, 2.0 / max(frameInterval, 1e-6))
}

/// Musical duration (§5.1): gestures are sized in beats, so they stretch when
/// the tempo halves instead of overlapping.
@inlinable
public func musicalDuration(beats: Double, beatPeriod: Double) -> Double {
    clamp(beats * beatPeriod, 0.20, 2.0)
}
