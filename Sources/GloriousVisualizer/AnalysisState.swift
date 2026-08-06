import Foundation

/// One published snapshot of the analysis thread's view of the music.
///
/// Everything continuous lives in a flat `channels` array rather than in named
/// stored properties. That is not a micro-optimisation: the renderer has to
/// **interpolate between states** (§6.1) and interpolating a flat vector is one
/// loop that cannot forget a field, where a hand-written per-field interpolator
/// silently drops whatever was added last. The named accessors below are the
/// readable face of it.
///
/// Every value here is dimensionless. Nothing in this struct has a unit of dBFS,
/// and nothing was chosen by listening to a track.
public struct AnalysisState: Equatable, Sendable {

    /// Number of analysis bands (§2.1).
    public static let bandCount = 8
    /// Number of display registers, formed by pairing bands (0+1, 2, 3, 4, 5+6, 7)
    /// so the register set is a *view* of the band set rather than a second
    /// analysis.
    public static let registerCount = 6

    /// Where each band's four values start in `channels`.
    public enum Channel {
        public static func bandCurrent(_ band: Int) -> Int { band * 4 }
        public static func bandAverage(_ band: Int) -> Int { band * 4 + 1 }
        public static func bandNorm(_ band: Int) -> Int { band * 4 + 2 }
        public static func bandGate(_ band: Int) -> Int { band * 4 + 3 }
        /// The band's share of the spectrum's own level — how much of what is
        /// playing lives here. Distinguishes "quiet" from "empty", which no
        /// percentile-normalised or relative value can.
        public static func bandShare(_ band: Int) -> Int {
            AnalysisState.bandCount * 4 + band
        }

        static let registersStart = AnalysisState.bandCount * 5
        static let registerPeaksStart = registersStart + AnalysisState.registerCount
        static let accentsStart = registerPeaksStart + AnalysisState.registerCount

        public static func register(_ index: Int) -> Int { registersStart + index }
        public static func registerPeak(_ index: Int) -> Int { registerPeaksStart + index }
        public static func accent(_ kind: OnsetKind) -> Int {
            switch kind {
            case .kick:  return accentsStart
            case .snare: return accentsStart + 1
            case .hat:   return accentsStart + 2
            }
        }

        public static let vu = accentsStart + 3
        public static let body = vu + 1
        public static let master = body + 1
        public static let overallCurrent = master + 1
        public static let overallAverage = overallCurrent + 1
        public static let brightness = overallAverage + 1
        public static let count = brightness + 1
    }

    /// Host time this state describes — the timestamp of the last sample in its
    /// analysis window.
    public var time: Double = 0
    public var channels = [Double](repeating: 0, count: Channel.count)
    public var tempo = TempoEstimate()

    public init() {}

    public subscript(channel: Int) -> Double {
        get { channels[channel] }
        set { channels[channel] = newValue }
    }

    /// Instantaneous level over the band's own long-term average. **Triggers
    /// only** — driving motion from this is a flicker source in itself.
    public func currentRelative(_ band: Int) -> Double { channels[Channel.bandCurrent(band)] }
    /// Short-average over long-average. **Everything that moves continuously
    /// uses this** (MilkDrop's `bass_att`).
    public func averageRelative(_ band: Int) -> Double { channels[Channel.bandAverage(band)] }
    /// Percentile-normalised band level, `0…1`.
    public func norm(_ band: Int) -> Double { channels[Channel.bandNorm(band)] }
    /// Gate contribution, `0…1` — a ramp, never a step.
    public func gate(_ band: Int) -> Double { channels[Channel.bandGate(band)] }
    public func share(_ band: Int) -> Double { channels[Channel.bandShare(band)] }

    public func register(_ index: Int) -> Double { channels[Channel.register(index)] }
    public func registerPeak(_ index: Int) -> Double { channels[Channel.registerPeak(index)] }
    public func accent(_ kind: OnsetKind) -> Double { channels[Channel.accent(kind)] }

    /// VU ballistic on overall loudness, `0…1`.
    public var vu: Double { channels[Channel.vu] }
    /// Mid-band body envelope, `0…1`.
    public var body: Double { channels[Channel.body] }
    /// Master brightness after the percentile AGC and its gain clamp, `0…1`.
    public var master: Double { channels[Channel.master] }
    public var overallCurrentRelative: Double { channels[Channel.overallCurrent] }
    public var overallAverageRelative: Double { channels[Channel.overallAverage] }
    /// Spectral centroid mapped to `0…1` by its own percentiles: 0 dark, 1 bright.
    public var brightness: Double { channels[Channel.brightness] }

    /// The average of the bands a kick lives in — the trigger amplitude source
    /// for pulse and wave.
    public var bassCurrentRelative: Double {
        (currentRelative(0) + currentRelative(1)) / 2
    }
    public var midAverageRelative: Double {
        (averageRelative(3) + averageRelative(4)) / 2
    }

    /// Linear blend of two states, used for the ordinary bracketed case.
    public static func mix(_ a: AnalysisState, _ b: AnalysisState, _ t: Double) -> AnalysisState {
        var out = a
        out.time = a.time + (b.time - a.time) * t
        for index in out.channels.indices {
            out.channels[index] = a.channels[index] + (b.channels[index] - a.channels[index]) * t
        }
        out.tempo = TempoEstimate(bpm: b.tempo.bpm,
                                  confidence: a.tempo.confidence
                                      + (b.tempo.confidence - a.tempo.confidence) * t,
                                  phase: b.tempo.phase)
        return out
    }

    /// Catmull-Rom through three states, evaluated between `b` and `c`.
    ///
    /// C¹ continuous, so there is no velocity discontinuity when the renderer
    /// crosses a state boundary — a linear blend has one, and at 30 fps it is
    /// visible as a tick in any slow fade.
    public static func catmullRom(_ a: AnalysisState, _ b: AnalysisState, _ c: AnalysisState,
                                  _ t: Double) -> AnalysisState {
        var out = b
        out.time = b.time + (c.time - b.time) * t
        let t2 = t * t
        let t3 = t2 * t
        for index in out.channels.indices {
            let p0 = a.channels[index], p1 = b.channels[index], p2 = c.channels[index]
            // One-sided tangents: p0…p2 is all the history there is, so the
            // outgoing tangent is the centred difference and the incoming one
            // the backward difference.
            let m1 = (p2 - p0) / 2
            let m2 = p2 - p1
            let value = (2 * t3 - 3 * t2 + 1) * p1 + (t3 - 2 * t2 + t) * m1
                + (-2 * t3 + 3 * t2) * p2 + (t3 - t2) * m2
            out.channels[index] = value
        }
        out.tempo = TempoEstimate(bpm: c.tempo.bpm,
                                  confidence: b.tempo.confidence
                                      + (c.tempo.confidence - b.tempo.confidence) * t,
                                  phase: c.tempo.phase)
        return out
    }
}

/// The renderer's window onto the analysis thread: the last three states, the
/// per-channel peak since the renderer last looked, and the onsets that have not
/// been consumed yet.
///
/// This replaces an unsynchronised `latestLevels` array — a real data race — and
/// a `[OnsetKind: Float]` dictionary that took the `max` per kind between display
/// frames, which is precisely why the board "doesn't respond to the little
/// details": three hits inside one frame became one.
public final class AnalysisBus: @unchecked Sendable {

    private let lock = NSLock()
    private var states: [AnalysisState] = []
    private var peaks = [Double](repeating: 0, count: AnalysisState.Channel.count)
    private var onsets: [OnsetEvent] = []
    private var dropped = 0

    /// Onsets are never merged, but the queue cannot grow without bound if the
    /// renderer stops. 256 events is several seconds of the fastest legal
    /// trigger rate.
    public static let onsetCapacity = 256

    /// Observation hook for offline measurement: sees every state and every
    /// event at the full analysis rate, before the renderer's sampling has a
    /// chance to alias them. `viz-sim` computes the onset ground-truth and
    /// universality metrics from this.
    public var onPublish: ((AnalysisState, [OnsetEvent]) -> Void)?

    public init() {}

    public func publish(_ state: AnalysisState, onsets newOnsets: [OnsetEvent]) {
        onPublish?(state, newOnsets)
        lock.lock()
        states.append(state)
        if states.count > 3 { states.removeFirst(states.count - 3) }
        for index in peaks.indices { peaks[index] = max(peaks[index], state.channels[index]) }
        onsets += newOnsets
        if onsets.count > Self.onsetCapacity {
            dropped += onsets.count - Self.onsetCapacity
            onsets.removeFirst(onsets.count - Self.onsetCapacity)
        }
        lock.unlock()
    }

    /// Takes everything the renderer needs for one frame, clearing the peak
    /// holds and the onset queue.
    ///
    /// The peak hold is the levels' equivalent of not coalescing onsets: a
    /// transient that peaked between two display frames is otherwise lost
    /// entirely, and whether it is lost depends on sampling phase — which is the
    /// aliasing that poisoned the old auto-gain.
    public func take() -> (states: [AnalysisState], peaks: [Double], onsets: [OnsetEvent]) {
        lock.lock()
        defer {
            peaks = [Double](repeating: 0, count: AnalysisState.Channel.count)
            onsets.removeAll(keepingCapacity: true)
            lock.unlock()
        }
        return (states, peaks, onsets)
    }

    public var droppedOnsets: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public func reset() {
        lock.lock()
        states.removeAll()
        peaks = [Double](repeating: 0, count: AnalysisState.Channel.count)
        onsets.removeAll()
        dropped = 0
        lock.unlock()
    }
}
