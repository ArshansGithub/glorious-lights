import Foundation

/// Attack–Hold–Release: the one ballistic primitive the whole visualizer uses.
///
/// Everything that moves in this codebase moves through an `AHR`. Having one
/// primitive is not tidiness — it is what makes the flicker guarantee provable.
/// A release time constant is the *only* way brightness can fall, so bounding it
/// (see ``clamped(attack:hold:release:frameInterval:)``) bounds how fast the
/// board can go dark, everywhere, at once.
///
/// Three properties, each answering one half of the user's verdict:
///
/// * **Wall-clock coefficients.** `a = exp(-dt/τ)` with `dt` measured, never a
///   per-frame constant, so the shape of a decay is identical at 15 fps, at
///   30 fps and across a dropped frame (principle P2).
/// * **A real hold.** After a rise the value is *pinned* at its peak for `hold`
///   seconds. Without it a 15 ms attack followed immediately by a release means
///   the peak exists for one analysis hop and may fall between two display
///   frames — literally "the lights don't properly stay on".
/// * **Asymmetry.** Attack:release of 1:5 to 1:20. A 15 ms attack with a 320 ms
///   release reads as instant *and* stays lit; 100/100 reads as late and
///   twitchy.
public struct AHR: Equatable, Sendable {

    /// Rise time constant, seconds.
    public var attack: Double
    /// Absolute hold at the peak after a rise, seconds.
    public var hold: Double
    /// Fall time constant, seconds.
    public var release: Double

    public private(set) var value: Double = 0
    private var holdUntil: Double = -.infinity

    public init(attack: Double, hold: Double, release: Double) {
        self.attack = attack
        self.hold = hold
        self.release = release
    }

    /// The clamps of §4.2, applied in code rather than trusted to presets.
    ///
    /// * `release ≥ max(3·dt_f, 200 ms)` — an envelope that falls faster than
    ///   three display frames cannot be rendered and aliases into flicker (P4).
    /// * `hold ≥ 2·dt_f` — a peak must survive into at least two frames to be
    ///   seen at all.
    /// * `attack ≤ release/4` — the asymmetry is the point; a preset cannot
    ///   accidentally give itself a slow attack.
    public static func clamped(attack: Double, hold: Double, release: Double,
                               frameInterval dt: Double) -> AHR {
        let boundedRelease = max(release, max(3 * dt, 0.200))
        return AHR(attack: min(attack, boundedRelease / 4),
                   hold: max(hold, 2 * dt),
                   release: boundedRelease)
    }

    /// Folds one observation in. `now` is host time; `dt` is time since the last
    /// call to this envelope, measured, never assumed.
    @discardableResult
    public mutating func update(target: Double, now: Double, dt: Double) -> Double {
        let step = max(dt, 0)
        if target > value {
            let a = exp(-step / max(attack, 1e-6))
            value = target + (value - target) * a
            holdUntil = now + hold
        } else if now < holdUntil {
            // Hold: the peak is pinned, which is what makes it visible.
        } else {
            let a = exp(-step / max(release, 1e-6))
            value = target + (value - target) * a
        }
        return value
    }

    /// Where this envelope will be `ahead` seconds from now if nothing new
    /// arrives — used by the renderer to extrapolate past the newest analysis
    /// state with the envelope's *own* time constant (§6.1), which is safe
    /// precisely because the envelope is an exponential.
    public func projected(by ahead: Double, now: Double) -> Double {
        guard ahead > 0 else { return value }
        if now + ahead < holdUntil { return value }
        let releaseFrom = max(0, now + ahead - max(now, holdUntil))
        return value * exp(-releaseFrom / max(release, 1e-6))
    }

    public mutating func reset() {
        value = 0
        holdUntil = -.infinity
    }
}

/// Peak-marker ballistics: **snap up, fall at a constant rate.**
///
/// Deliberately not an exponential. A marker that eases down reads as noisy;
/// one that falls at a fixed speed reads as a physical object under gravity,
/// which is why every meter that has ever looked good does this.
public struct GravityPeak: Equatable, Sendable {
    /// Seconds for the marker to fall the full 0…1 range.
    public var fallSeconds: Double
    /// How long the peak is held before gravity takes over. "Instant rise,
    /// **peak-hold**, gravity fall" — without the hold the fall begins on the
    /// very next hop and a bar never gets to be seen at its peak.
    public var hold: Double
    public private(set) var value: Double = 0
    private var holdRemaining: Double = 0

    public init(fallSeconds: Double, hold: Double = 0) {
        self.fallSeconds = fallSeconds
        self.hold = hold
    }

    @discardableResult
    public mutating func update(target: Double, dt: Double) -> Double {
        if target > value {
            value = target
            holdRemaining = hold
        } else if holdRemaining > 0 {
            holdRemaining -= max(dt, 0)
        } else {
            value = max(target, value - max(dt, 0) / max(fallSeconds, 1e-6))
        }
        return value
    }

    public mutating func reset() {
        value = 0
        holdRemaining = 0
    }
}

/// Hermite smoothstep, the one shape used wherever this codebase used to have a
/// hard threshold.
///
/// Every `if x > k` in a render path is a cliff a noisy value oscillates across
/// once per frame; §3.4 and §6.4 replace all of them with this.
/// `edge0 > edge1` is legal and means a **descending** ramp — which is how every
/// soft edge in the render is written (`smoothstep(reach + 1, reach - 1,
/// distance)` fades out with distance). Rejecting that ordering silently turns
/// the ramp into a hard, inverted step.
@inlinable
public func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge0 != edge1 else { return x >= edge1 ? 1 : 0 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

@inlinable
public func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double {
    min(max(x, low), high)
}
