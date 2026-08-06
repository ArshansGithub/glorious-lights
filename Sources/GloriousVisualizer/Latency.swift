import Foundation

/// The live end-to-end latency estimate `L̂` (§8.2-R).
///
/// r1 compensated latency with one literal — `predictionLead = 0.040`, a guess
/// nobody measured, applied only inside `beatIsDue` and only when a beat
/// happened to fall inside the current frame's window. P10 replaces it: *the
/// pipeline latency used for scheduling must be a measured, live quantity, never
/// a constant.* A design that compensates a mean it never measured is
/// indistinguishable from one that got lucky.
///
/// ## What is in `L̂` and what deliberately is not
///
/// ```
/// L̂ = D                 // transport and latch, measured per delivered frame
///   + userOffset        // §8.3, signed
/// ```
///
/// Everything already compensated by *timestamping* is excluded, because
/// including it would double-count. The analysis group delay, the peak-pick lag
/// and the analysis→render handoff are all subtracted from event timestamps
/// upstream (`MusicAnalyzer.groupDelay`, §6.1's interpolation); adding them here
/// would push gestures ~30 ms early — which is the failure mode
/// `TempoTracker.align` already had to be fixed for once. Two errors that agree
/// numerically is not the same as either being right.
///
/// **Two deviations from §8.2-R's formula, both deliberate, both measured.**
///
/// 1. `0.5·hopSeconds` and `captureBufferSeconds` are excluded. Those terms
///    belong to the *reactive* path — the delay between a sound existing and the
///    analyser knowing about it. A **predicted** gesture does not traverse them:
///    the beat time it is scheduled against is published in the same host-time
///    frame the capture callback stamped, so the capture buffer and the hop have
///    already been paid before `nextBeatTime` exists. Including them would be
///    exactly the double-count the paragraph above forbids.
///
/// 2. `0.5·dt_f`, the mean display quantisation, is excluded too — and this one
///    is a statement about the *measurement convention*, not about the pipeline.
///    That term models the extra delay an observer of a sample-and-hold
///    staircase perceives: the light changes at a frame boundary, so the
///    perceived crossing is uniformly late by up to one frame. M8 deliberately
///    removes frame quantisation from its measurement by interpolating linearly
///    between displayed frames — it has to, because a 33 ms grid would otherwise
///    put a floor under a 30 ms threshold. Compensating for a delay the metric
///    has defined away biases the board *early* by exactly `dt_f/2`, and it is
///    measurable: on `click-120` the M8 bias moves from −27 ms to −10 ms with
///    nothing else changed. The mechanism and the metric have to share one
///    convention; the residual half-frame is the frame-quantisation line item of
///    §8.1-R's unavoidable budget, and §8.3's user offset is what dials out
///    whatever of it is visible on a given machine.
public struct LatencyEstimate: Sendable {

    /// Transport lag is smoothed over this, so one hiccup cannot yank the grid.
    public static let smoothing: Double = 5.0
    /// `L̂` is clamped to this range and rate-limited below.
    public static let lowerBound: Double = 0
    public static let upperBound: Double = 0.150
    /// …and may change by at most this per second.
    public static let rateLimit: Double = 0.005

    /// Display frame interval; the mean quantisation term is half of it.
    public var frameInterval: Double
    /// The §8.3 user offset, signed, ±100 ms. Fixed capture latency differs per
    /// machine and per output device; it should be dialled out, not designed
    /// around.
    public var userOffset: Double = 0

    private var transport: Double = 0
    private var seeded = false
    private var smoothed: Double = 0

    public init(frameInterval: Double) {
        self.frameInterval = frameInterval
        smoothed = 0
    }

    /// One delivered frame's measured `t_END_echoed − t_scheduled`.
    public mutating func record(deliveryLag lag: Double, dt: Double) {
        let clamped = clamp(lag, 0, Self.upperBound)
        guard seeded else {
            seeded = true
            transport = clamped
            return
        }
        let a = exp(-max(dt, 0) / Self.smoothing)
        transport = clamped + (transport - clamped) * a
    }

    /// Advances the rate limiter toward the raw estimate and returns `L̂`.
    @discardableResult
    public mutating func advance(dt: Double) -> Double {
        let target = clamp(transport + userOffset, Self.lowerBound, Self.upperBound)
        let step = Self.rateLimit * max(dt, 0)
        smoothed = clamp(smoothed + clamp(target - smoothed, -step, step),
                         Self.lowerBound, Self.upperBound)
        return smoothed
    }

    public var value: Double { smoothed }
    /// What the transport alone is contributing, for telemetry.
    public var transportLag: Double { transport }

    public mutating func reset() {
        transport = 0
        seeded = false
        smoothed = 0
    }
}
