import Foundation

/// A running percentile of a positive quantity, in constant memory.
///
/// This is the workhorse of "nothing absolute" (P1). Every level decision in the
/// pipeline — the whitening floor, the normalisation range, the master gain — is
/// a comparison against a percentile of *that same quantity's own recent
/// history*, so none of them carries a number that came from listening to
/// anything.
///
/// It is a stochastic-approximation quantile estimator (Robbins–Monro) run in
/// the log domain: the estimate is nudged up by `p` of a step when the sample is
/// above it and down by `1 - p` when below, so it settles where a fraction `p`
/// of samples lie beneath. Multiplicative steps make the tracking rate
/// scale-free — the same code follows a -60 dBFS bed and a full-scale mix at the
/// same *relative* speed, which a linear step cannot do.
///
/// Why not the design's 64-bucket decaying histogram: this converges to the same
/// estimand with one Double per tracker instead of 64, which matters because
/// there is one tracker per FFT bin. The properties the design asks for hold
/// either way — a single click cannot move `p90` (one sample moves the estimate
/// by at most one step), and a momentary dip cannot pin `p10` the way the old
/// minimum-follower did.
public struct QuantileTracker: Equatable, Sendable {

    /// Which percentile, `0…1`.
    public let percentile: Double
    /// Window time constant. The estimate reflects roughly the last `window`
    /// seconds of history.
    public var window: Double
    /// Dimensionless rate: how many nats the estimate can travel in one window.
    /// Four means a factor of ~50 per window, which is fast enough to follow a
    /// hard cut and slow enough that a bar of music cannot move it.
    public static let rate: Double = 4.0

    private var estimate: Double = 0
    private var seeded = false

    public init(percentile: Double, window: Double) {
        self.percentile = percentile
        self.window = window
    }

    public var value: Double { estimate }

    @discardableResult
    public mutating func update(_ sample: Double, dt: Double) -> Double {
        let x = max(sample, 0)
        guard seeded else {
            seeded = true
            estimate = max(x, Self.floor)
            return estimate
        }
        let step = min(max(dt, 0) / max(window, 1e-6), 0.5) * Self.rate
        let direction = x > estimate ? percentile : -(1 - percentile)
        estimate = max(Self.floor, estimate * exp(step * direction))
        return estimate
    }

    public mutating func reset() {
        estimate = 0
        seeded = false
    }

    /// A numerical guard far below any converter's own noise floor, used only to
    /// keep divisions finite — never as a decision threshold (P1c).
    public static let floor: Double = 1e-12
}

/// Per-bin adaptive whitening (Stowell & Plumbley, ICMC'07).
///
/// Divides every bin by a slowly-decaying record of its own recent peak, so the
/// spectrum handed downstream is flat for *any* material with no per-song EQ and
/// no training. This replaces the old fixed pink-noise tilt, which is a
/// correction for one assumed spectrum and wrong for everything else.
///
/// The floor matters as much as the peak: without it a silent bin is divided by
/// its own dying peak and amplified to full scale, and hiss becomes a light
/// show. The floor is `2 × p10` of that bin — relative, per bin, observed.
public struct AdaptiveWhitening: Sendable {

    /// Peak decay time constant.
    public static let peakTime: Double = 3.7
    /// The floor is this multiple of the bin's own 10th percentile.
    public static let floorMultiple: Double = 2.0
    /// How much history the per-bin floor is drawn from.
    public static let floorWindow: Double = 10.0

    private var peaks: [Double]
    private var floors: [QuantileTracker]

    public init(binCount: Int) {
        peaks = [Double](repeating: 0, count: binCount)
        floors = [QuantileTracker](repeating: QuantileTracker(percentile: 0.10,
                                                              window: Self.floorWindow),
                                   count: binCount)
    }

    /// Whitens one magnitude spectrum in place, returning values in `0…1`.
    public mutating func process(_ magnitudes: [Float], dt: Double) -> [Double] {
        let decay = exp(-dt / Self.peakTime)
        var out = [Double](repeating: 0, count: magnitudes.count)
        for index in magnitudes.indices where index < peaks.count {
            let x = Double(magnitudes[index])
            let floor = Self.floorMultiple * floors[index].update(x, dt: dt)
            let peak = max(max(x, floor), peaks[index] * decay)
            peaks[index] = peak
            out[index] = peak > 0 ? min(1, x / peak) : 0
        }
        return out
    }

    public mutating func reset() {
        for index in peaks.indices { peaks[index] = 0 }
        for index in floors.indices { floors[index].reset() }
    }
}

/// The three followers every band carries, and the two dimensionless ratios they
/// publish (§3.2, projectM's `bass` / `bass_att` trick).
///
/// Both ratios revolve around **1.0 for any material at any volume**, which is
/// what makes one threshold vocabulary — `< 0.7` quiet, `≈ 1.0` normal,
/// `> 1.3` a hit — work across every genre without a per-song constant.
public struct RelativeFollower: Equatable, Sendable {

    public static let shortRise: Double = 0.020
    public static let shortFall: Double = 0.050
    public static let longTime: Double = 4.0
    /// A deliberately fast long-average for the first fifty hops, so the board
    /// is not visibly wrong for the first five seconds after pressing play.
    public static let warmUpTime: Double = 0.32
    public static let warmUpHops = 50

    private var shortValue: Double = 0
    private var longValue: Double = 0
    private var hops = 0

    public init() {}

    /// - Returns: `(current, average)` relative values.
    @discardableResult
    /// - Parameter floor: a lower bound on the long average, expressed in the
    ///   same units as `current`. A band holding nothing at all has a long
    ///   average of nearly nothing, and every ratio against nearly nothing is
    ///   enormous — an empty band would otherwise report `CURRENT_RELATIVE` of
    ///   16 on its own leakage and fire a detector. The floor is supplied by the
    ///   caller as a fraction of the whole spectrum's level, which keeps it a
    ///   dimensionless cross-band comparison rather than an absolute.
    public mutating func update(_ current: Double, dt: Double,
                                floor: Double = 0) -> (current: Double, average: Double) {
        let riseTime = current > shortValue ? Self.shortRise : Self.shortFall
        shortValue = current + (shortValue - current) * exp(-dt / riseTime)

        hops += 1
        let longTime = hops <= Self.warmUpHops ? Self.warmUpTime : Self.longTime
        // The long average follows the **short envelope**, not the raw value.
        // Both ratios then compare a quantity to its own history at a longer
        // timescale, so their time-average is 1.0 for any material — which is
        // the property the universality gate (§10, M6) actually tests. Averaging
        // the raw value instead leaves AVERAGE_RELATIVE biased upward by the
        // band's crest factor, so a percussive band would sit near 2.0 and a pad
        // near 1.0, and one threshold vocabulary could not serve both.
        longValue = shortValue + (longValue - shortValue) * exp(-dt / longTime)

        let reference = max(longValue, max(floor, QuantileTracker.floor))
        return (min(current / reference, 16), min(shortValue / reference, 16))
    }

    public var long: Double { longValue }
    public var short: Double { shortValue }

    public mutating func reset() {
        shortValue = 0
        longValue = 0
        hops = 0
    }
}

/// A per-band noise gate stated entirely in relative units, and — the part that
/// matters for flicker — one that **decays rather than snaps**.
///
/// The old pipeline had four hard cutoffs to black. Each was a cliff a value
/// could oscillate across once per frame. This has hysteresis (open and close
/// are different thresholds), a hold-open minimum (the anti-chatter term every
/// noise-gate designer adds), and a ramp rather than a switch, so silence always
/// fades out.
public struct BandGate: Equatable, Sendable {

    public static let openAt: Double = 1.30
    public static let closeAt: Double = 1.10
    /// The band is above its own observed floor: the percentile test the design
    /// pairs with the relative one.
    public static let openNorm: Double = 0.25
    public static let closeNorm: Double = 0.10
    public static let holdOpen: Double = 0.120
    public static let rampTime: Double = 0.400

    private var isOpen = false
    private var openedAt: Double = -.infinity
    private var ramp: Double = 0

    public init() {}

    /// - Returns: the gate's contribution, `0…1`, which is a ramp and never a
    ///   step.
    @discardableResult
    /// - Parameter norm: the band's percentile-normalised level, `0…1`.
    ///
    /// Both tests matter, and the percentile one is what makes the gate musical.
    /// Closing on `AVERAGE_RELATIVE < 1.10` alone means closing after *every*
    /// hit, because with a correctly formed long average that ratio sits at 1.0
    /// in all material — the gate then chops continuous music into per-note
    /// bursts. A gate exists to remove silence and hiss, not to re-articulate
    /// the performance, so it stays open while the band is above its own
    /// observed floor.
    public mutating func update(currentRelative: Double, averageRelative: Double,
                                norm: Double, now: Double, dt: Double) -> Double {
        if isOpen {
            if norm < Self.closeNorm, averageRelative < Self.closeAt,
               now - openedAt > Self.holdOpen {
                isOpen = false
            }
        } else if currentRelative > Self.openAt || norm > Self.openNorm {
            isOpen = true
            openedAt = now
        }
        let target = isOpen ? 1.0 : 0.0
        // Opening is immediate — an attack must never be smoothed — while
        // closing is a 400 ms ramp so a band's contribution fades out.
        ramp = isOpen ? 1 : target + (ramp - target) * exp(-dt / Self.rampTime)
        return ramp
    }

    public var open: Bool { isOpen }
    public var level: Double { ramp }

    public mutating func reset() {
        isOpen = false
        openedAt = -.infinity
        ramp = 0
    }
}

/// Percentile normalisation of one quantity onto `0…1` (§3.3).
///
/// `p10` is the floor, `p90` the "loud but not a click" reference. Both are
/// observed, so this needs no gain constant at all. The dual-speed escape hatch
/// is the one concession to reality: if the output pins at either end for more
/// than half a second the windows shorten, so a sudden drop or a quiet intro is
/// followed quickly without the estimator breathing on ordinary material.
public struct PercentileNormaliser: Sendable {

    public static let window: Double = 10.0
    public static let escapeWindow: Double = 0.5
    public static let escapeAfter: Double = 0.5

    private var low = QuantileTracker(percentile: 0.10, window: PercentileNormaliser.window)
    private var high = QuantileTracker(percentile: 0.90, window: PercentileNormaliser.window)
    private var outOfRangeFor: Double = 0

    public init() {}

    @discardableResult
    public mutating func update(_ sample: Double, dt: Double, frozen: Bool = false) -> Double {
        if !frozen {
            let window = outOfRangeFor > Self.escapeAfter ? Self.escapeWindow : Self.window
            low.window = window
            high.window = window
            low.update(sample, dt: dt)
            high.update(sample, dt: dt)
        }
        let span = max(high.value - low.value, QuantileTracker.floor)
        let normalised = clamp((sample - low.value) / span, 0, 1)
        if normalised > 0.98 || normalised < 0.02 {
            outOfRangeFor += dt
        } else {
            outOfRangeFor = 0
        }
        return normalised
    }

    public var floor: Double { low.value }
    public var reference: Double { high.value }

    public mutating func reset() {
        low.reset()
        high.reset()
        outOfRangeFor = 0
    }
}
