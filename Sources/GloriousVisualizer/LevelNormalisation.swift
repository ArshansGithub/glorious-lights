import Foundation

/// Tracks the quietest level each band settles at — the input's own noise floor.
///
/// The first tuning pass gated on **absolute** dBFS, which was measured against
/// full-scale file audio. A room microphone runs roughly 40 dB quieter than
/// that, so the same threshold swallowed everything and the user had to shout
/// into the mic to move a bar. Nothing absolute can serve both a microphone and
/// a line-level system tap; the floor has to be *observed*.
///
/// A minimum-follower does that: it drops instantly to any new quiet level and
/// creeps back up slowly. Instant down means a source that starts loud converges
/// on its first quiet frame; slow up means a sustained note is not mistaken for
/// the noise floor and gated away.
///
/// Note what this implies: a **perfectly constant** input has zero excess over
/// its own floor and therefore lights nothing, gate or no gate. That is correct
/// — a steady tone with no variation carries no information a level meter can
/// show — and it is why the tests here drive varying signals.
public struct NoiseFloorTracker: Equatable, Sendable {

    /// Time constant for the floor drifting back up. Deliberately long: the
    /// floor should describe the room, not the music.
    public static let defaultRiseTime: Double = 12

    public var riseTime: Double
    private(set) var floors: [Float]
    private var hasSeenInput = false

    public init(bandCount: Int, riseTime: Double = NoiseFloorTracker.defaultRiseTime) {
        self.riseTime = riseTime
        self.floors = [Float](repeating: 0, count: bandCount)
    }

    public var current: [Float] { floors }

    /// A textbook minimum-follower: **drop instantly** to any new minimum, creep
    /// back up slowly.
    ///
    /// The instant drop is what makes the invariant hold — the floor is never
    /// above the signal, so the excess over it is never negative and a band can
    /// never be gated by a floor that has drifted above the audio. An earlier
    /// version eased downward as well as up, which let an alternating
    /// loud/quiet signal walk the floor up past its own quiet passages; the
    /// test that caught it is `testTheFloorNeverExceedsTheSignal`.
    ///
    /// Nothing is lost by dropping instantly: a single quiet frame pinning the
    /// floor low is exactly right for a *minimum*, and the slow rise is what
    /// brings it back to the room's real level.
    public mutating func update(with levels: [Float], elapsed: Double) -> [Float] {
        let rise = Float(exp(-max(elapsed, 0) / max(riseTime, 1e-6)))

        // The first frame seeds the floor rather than easing towards it from
        // zero, so a session does not spend its first seconds treating
        // everything as signal.
        if !hasSeenInput {
            hasSeenInput = true
            for index in floors.indices where index < levels.count {
                floors[index] = levels[index]
            }
            return floors
        }

        for index in floors.indices {
            let level = index < levels.count ? levels[index] : 0
            if level <= floors[index] {
                floors[index] = level
            } else {
                floors[index] = min(level, level + (floors[index] - level) * rise)
            }
        }
        return floors
    }
}

/// Tracks how loud the input has been recently, so the display can normalise to
/// it rather than to full scale.
///
/// The reference is a **high percentile across bands**, not the single peak: one
/// band spiking should not decide the scale for the whole board, which is what
/// made the old peak-driven auto-gain pump. Attack is quick so a track starting
/// fills the board within a second or two; release is slow so a gap between
/// phrases does not ramp everything up and then slam it back down.
public struct LoudnessReference: Equatable, Sendable {

    /// How quickly the reference rises to a louder passage.
    public static let defaultAttackTime: Double = 0.4
    /// How slowly it falls afterwards.
    public static let defaultReleaseTime: Double = 3.0
    /// Which percentile across bands counts as "how loud this is".
    public static let percentile: Double = 0.9
    /// The reference can never fall below this.
    ///
    /// This is the one deliberately **absolute** number in an otherwise
    /// source-relative design, and it is what stops a purely relative system
    /// from amplifying a silent room until its hiss fills the board — the
    /// failure a fully relative AGC cannot avoid, because "quiet room" and
    /// "music played very quietly" look identical to it.
    ///
    /// Measured with `viz-sim`: a -60 dBFS noise bed settles at a reference
    /// around 0.00003, ordinary programme material between 0.004 and 0.012. A
    /// minimum of 0.002 therefore sits below anything real and well above
    /// nothing, capping the amplification of near-silence at roughly 500x
    /// instead of the 10000x an unbounded minimum allowed.
    public static let minimumReference: Float = 0.002

    public var attackTime: Double
    public var releaseTime: Double
    private(set) var reference: Float

    public init(attackTime: Double = LoudnessReference.defaultAttackTime,
                releaseTime: Double = LoudnessReference.defaultReleaseTime) {
        self.attackTime = attackTime
        self.releaseTime = releaseTime
        self.reference = LoudnessReference.minimumReference
    }

    public var current: Float { reference }

    /// The percentile of `values`, which is the loudness this frame contributes.
    public static func percentileValue(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = percentile * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = Float(position - Double(lower))
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    public mutating func update(with values: [Float], elapsed: Double) -> Float {
        let observed = Self.percentileValue(of: values)
        let time = observed > reference ? attackTime : releaseTime
        let decay = Float(exp(-max(elapsed, 0) / max(time, 1e-6)))
        reference = observed + (reference - observed) * decay
        reference = max(reference, Self.minimumReference)
        return reference
    }
}
