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

    var attack: Double
    var hold: Double
    var release: Double

    public init(kind: Kind, startTime: Double, amplitude: Double,
                origin: Double = 0, direction: Double = 1, speed: Double = 0,
                width: Double = 2.8, onsetKind: OnsetKind? = nil,
                envelope: AHR) {
        self.kind = kind
        self.startTime = startTime
        self.amplitude = amplitude
        self.origin = origin
        self.direction = direction
        self.speed = speed
        self.width = width
        self.onsetKind = onsetKind
        self.attack = envelope.attack
        self.hold = envelope.hold
        self.release = envelope.release
    }

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
        if u < holdEnd {
            let rise = (1 - exp(-u / max(attack, 1e-6))) / (1 - exp(-3.0))
            return amplitude * min(1, rise)
        }
        return amplitude * exp(-(u - holdEnd) / max(release, 1e-6))
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
