import Foundation
import GloriousVisualizer

/// The temporal metrics (§10.2).
///
/// The audit's finding about the old tooling is the important one: **every
/// metric in `viz-sim` was spatial or aggregate, and none was temporal.** There
/// was not one frame-to-frame difference metric in the tool, and
/// `gestureCoherence` reported a perfect 1.000 in all five modes on the very
/// signal the user called unusable. The tool literally could not see the defect
/// it was used to tune away. Everything below is a number that moves when the
/// board flickers, goes inert, lags, or stops holding.
struct Metrics {

    /// A key is **on** when its gamma-decoded lightness is at least this. The
    /// same value in every metric, so the metrics are mutually consistent.
    ///
    /// Mapped through the user sensitivity curve: sensitivity is an output gain
    /// applied *after* the per-key interlock, so it changes how bright the board
    /// is without changing which keys the model is holding lit.
    static let onLevel: Double = 0.10

    // M1
    var flickerMean: Double = 0
    var flickerP95: Double = 0
    // M2
    var deltaMean: Double = 0
    var deltaP95: Double = 0
    // M3
    var latencyMedian: Double = 0
    var latencyP90: Double = 0
    var missRate: Double = 0
    var hasLatency = false
    // M4
    var onDurationMedian: Double = 0
    var onDurationP10: Double = 0
    var hasOnDuration = false
    // M5
    var onsetRate: Double = 0
    var onsetCount = 0
    var kickRecall: Double = 0
    var kickPrecision: Double = 0
    var snareFalseRate: Double = 0
    var tempoConfidenceLowFraction: Double = 0
    // M6
    var averageRelativeMin: Double = 0
    var averageRelativeMax: Double = 0
    var boardMeanBrightness: Double = 0
    // M7
    var tickP95: Double = 0
    var tickMax: Double = 0
    var staleFraction: Double = 0
    var droppedFrames = 0
    var deliveredFraction: Double = 1

    /// LED offsets grouped by display register, the same six groups the
    /// spectrum mode paints into.
    static let regions: [[Int]] = {
        let columns = VisualizerLayout.columns
        let perRegister = Double(columns.count) / Double(AnalysisState.registerCount)
        return (0..<AnalysisState.registerCount).map { register in
            let start = Int((Double(register) * perRegister).rounded())
            let end = register == AnalysisState.registerCount - 1
                ? columns.count
                : Int((Double(register + 1) * perRegister).rounded())
            var leds: [Int] = []
            for index in start..<end {
                for row in columns[index].levelRows { leds += row.map { Int($0) - 1 } }
                leds += columns[index].peakKeys.map { Int($0) - 1 }
            }
            return leds
        }
    }()

    static func measure(_ result: SimRun.Result, signal: Signal) -> Metrics {
        var metrics = Metrics()
        let frames = result.levels
        guard frames.count > 1, let ledCount = frames.first?.count else { return metrics }
        let dt = result.frameInterval
        let duration = Double(frames.count) * dt
        // The on-threshold follows the user gain through the same curve the
        // display does, so a uniformly dimmed board is not reported as a dark
        // one and a brightened one is not reported as permanently lit.
        let onLevel = KeyInterlock.gain(Self.onLevel, result.sensitivity)

        // ---- M1 flicker: complete on→off→on cycles per key-second.
        var flicker = [Double](repeating: 0, count: ledCount)
        var onRuns: [Double] = []
        for led in 0..<ledCount {
            var wasOn = frames[0][led] >= onLevel
            var sawOff = false
            var cycles = 0.0
            var runStart = wasOn ? 0 : -1
            for index in 1..<frames.count {
                let isOn = frames[index][led] >= onLevel
                if isOn != wasOn {
                    if isOn {
                        if sawOff { cycles += 1 }
                        runStart = index
                    } else {
                        sawOff = true
                        if runStart >= 0 { onRuns.append(Double(index - runStart) * dt) }
                    }
                    wasOn = isOn
                }
            }
            if wasOn, runStart >= 0 { onRuns.append(Double(frames.count - runStart) * dt) }
            flicker[led] = cycles / duration
        }
        metrics.flickerMean = mean(flicker)
        metrics.flickerP95 = percentile(flicker, 0.95)

        // ---- M2 smoothness: frame-to-frame change, bounded on both sides.
        var deltas: [Double] = []
        for index in 1..<frames.count {
            var sum = 0.0
            for led in 0..<ledCount { sum += abs(frames[index][led] - frames[index - 1][led]) }
            deltas.append(sum / Double(ledCount))
        }
        metrics.deltaMean = mean(deltas)
        metrics.deltaP95 = percentile(deltas, 0.95)

        // ---- M4 hold: how long a key stays on once it lights.
        if !onRuns.isEmpty {
            metrics.hasOnDuration = true
            metrics.onDurationMedian = percentile(onRuns, 0.5)
            metrics.onDurationP10 = percentile(onRuns, 0.10)
        }

        // ---- board-mean brightness per frame, for M6.
        let boardMean = frames.map { frame in frame.reduce(0, +) / Double(ledCount) }
        metrics.boardMeanBrightness = mean(boardMean)

        // ---- M3 responsiveness, in frames.
        if !result.events.isEmpty {
            var latencies: [Double] = []
            var misses = 0
            let baselineFrames = max(1, Int(0.100 / dt))
            // Scoped to kicks: the kick is the one event every mode is
            // specified to react to (pulse and wave do not chase hats by
            // design), so it is the only event whose absence from the display
            // is unambiguously a latency failure.
            for event in result.events where event.kind == .kick && event.time >= 1.0 {
                // The first frame **at or after** the event, per §10.2.
                // `Int(t/dt)` is the frame at or *before* it, which granted the
                // pipeline up to a free frame and admitted negative latencies —
                // which is the whole explanation for a reported median of
                // −0.41, not §8.2's predictive scheduling.
                let eventFrame = Int((event.time / dt).rounded(.up))
                guard eventFrame > 2 * baselineFrames,
                      eventFrame + 6 < frames.count else { continue }
                // The rise is measured per LED and only its **positive** part is
                // averaged. A plain board mean lets one region's decay cancel
                // another's rise: on a spectrum display a kick lights the bass
                // registers while the registers a snare lit 100 ms earlier are
                // still falling, and the mean can stay flat while the board
                // visibly responds. Summing only the increases measures "did
                // new light appear", which is what the metric is for.
                var baseline = [Double](repeating: 0, count: ledCount)
                for index in (eventFrame - baselineFrames)..<eventFrame {
                    for led in 0..<ledCount { baseline[led] += frames[index][led] }
                }
                for led in 0..<ledCount { baseline[led] /= Double(baselineFrames) }
                // …and over the whole board, as §10.2 specifies. Taking the
                // maximum over six register groups instead meant a response in
                // one register of six satisfied the metric, which is a weaker
                // claim than the one the document makes and than the one the
                // user's complaint is about.
                func rise(_ frame: Int) -> Double {
                    var total = 0.0
                    for led in 0..<ledCount { total += max(0, frames[frame][led] - baseline[led]) }
                    return total / Double(ledCount)
                }
                var found = false
                for offset in 0...6 {
                    if rise(eventFrame + offset) >= 0.05 {
                        latencies.append((Double(eventFrame + offset) * dt - event.time) / dt)
                        found = true
                        break
                    }
                }
                if !found { misses += 1 }
            }
            let considered = latencies.count + misses
            if considered > 0 {
                metrics.hasLatency = true
                metrics.missRate = Double(misses) / Double(considered)
                if !latencies.isEmpty {
                    metrics.latencyMedian = percentile(latencies, 0.5)
                    metrics.latencyP90 = percentile(latencies, 0.90)
                }
            }
        }

        // ---- M5 onset ground truth.
        metrics.onsetCount = result.detectedOnsets.count
        metrics.onsetRate = Double(result.detectedOnsets.count) / duration
        let window = 0.050
        // The first second is the analyser's own warm-up: the long averages are
        // converging and the liveliness gate has not yet filled its window, so
        // detection there is neither expected nor meaningful. Everything after
        // it counts.
        let warmUp = 1.0
        let trueKicks = result.events.filter { $0.kind == .kick && $0.time >= warmUp }
        let detectedKicks = result.detectedOnsets.filter { $0.kind == .kick && $0.time >= warmUp }
        if !trueKicks.isEmpty {
            let matched = trueKicks.filter { truth in
                detectedKicks.contains { abs($0.time - truth.time) <= window }
            }.count
            metrics.kickRecall = Double(matched) / Double(trueKicks.count)
            if !detectedKicks.isEmpty {
                let correct = detectedKicks.filter { detection in
                    trueKicks.contains { abs($0.time - detection.time) <= window }
                }.count
                metrics.kickPrecision = Double(correct) / Double(detectedKicks.count)
            }
        }
        let trueSnares = result.events.filter { $0.kind == .snare }
        let detectedSnares = result.detectedOnsets.filter { $0.kind == .snare }
        let phantomSnares = detectedSnares.filter { detection in
            !trueSnares.contains { abs($0.time - detection.time) <= window }
        }.count
        metrics.snareFalseRate = Double(phantomSnares) / duration

        if !result.tempoConfidence.isEmpty {
            metrics.tempoConfidenceLowFraction =
                Double(result.tempoConfidence.filter { $0 < 0.4 }.count)
                    / Double(result.tempoConfidence.count)
        }

        // ---- M6 universality.
        let present = (0..<AnalysisState.bandCount).filter { result.bandPresent[$0] }
        if !present.isEmpty {
            let values = present.map { result.bandAverageRelative[$0] }
            metrics.averageRelativeMin = values.min() ?? 0
            metrics.averageRelativeMax = values.max() ?? 0
        }

        // ---- M7 timing integrity.
        let ticks = result.tickIntervals.dropFirst()
        if !ticks.isEmpty {
            metrics.tickP95 = percentile(Array(ticks), 0.95)
            metrics.tickMax = ticks.max() ?? 0
        }
        metrics.droppedFrames = result.droppedFrames
        metrics.deliveredFraction = 1 - Double(result.droppedFrames) / Double(frames.count)
        metrics.staleFraction = Double(result.staleFrames) / Double(max(frames.count, 1))
        return metrics
    }

    // MARK: - Pass criteria (§10.3)

    struct Check {
        var name: String
        var value: String
        var bound: String
        var passed: Bool
    }

    /// The full pass table for one case, in the order of §10.3.
    ///
    /// - Parameter perOnsetMode: whether this mode is *specified* to show a
    ///   discrete response to every arbitrated onset. Only pulse and ripple are:
    ///   §9.2 says a wave cannot be launched while one is younger than half a
    ///   beat, §9.4 makes spectrum a level display whose registers hold under
    ///   gravity, and §9.5 gives VU a 150 ms / 1 s ballistic and calls the
    ///   contrast between that and its peak marker the point. Holding those
    ///   three to a two-frame response *per kick* would contradict the same
    ///   document that defines them, so M3 is measured where it means something
    ///   and the other three are bounded by M1, M2 and M4.
    /// - Parameters:
    ///   - assertLatency: whether M3 means anything on this arm. A deliberately
    ///     injected transport stall *is* latency — the design's own worst-case
    ///     end-to-end stall is 250 ms and M3's window is 200 ms — so holding a
    ///     stalled arm to a two-frame response would be asserting that the stall
    ///     did not happen.
    ///   - assertLiveliness: whether M2's *lower* bound means anything on this
    ///     arm. The user's sensitivity is a monotone output gain, so it scales
    ///     the frame-to-frame difference by construction; "is the board inert"
    ///     is a question about the model and is asked at unity gain.
    func checks(for signal: Signal, frameInterval dt: Double,
                perOnsetMode: Bool = true,
                assertLatency: Bool = true,
                assertLiveliness: Bool = true) -> [Check] {
        var checks: [Check] = []
        func add(_ name: String, _ value: Double, _ bound: String, _ passed: Bool,
                 format: String = "%.3f") {
            checks.append(Check(name: name, value: String(format: format, value),
                                bound: bound, passed: passed))
        }

        // M1 — stricter on stationary material: a stationary signal must produce
        // a stationary board.
        let stationary = signal.mustBeSilentOfOnsets
        let flickerCeiling = stationary ? 0.1 : 1.5
        add("M1 flicker p95", flickerP95,
            "≤ \(String(format: "%.1f", flickerCeiling))", flickerP95 <= flickerCeiling + 1e-9)
        add("M1 flicker mean", flickerMean, "≤ 0.8", flickerMean <= 0.8 + 1e-9)

        // M2 — bounded both ways. Too high is strobing; too low means the board
        // is inert, which is the other way to fail the user's complaint.
        //
        // The bounds are per *frame*, and §10.3 states them for the 30 fps
        // target, so they scale with the frame interval: the same motion seen
        // at 15 fps is twice the change from one frame to the next, and a fixed
        // number would be a claim about the frame rate rather than about the
        // picture. §1.1 requires every clamp to be expressed in terms of `dt_f`
        // and this is one of them.
        // Only the *upper* bounds scale: they are about how much the picture may
        // step in one frame, and the same motion at half the frame rate is twice
        // the step. The lower bound is about the board not being dead, which is
        // a statement about the display rather than about a frame, so it stays
        // where §10.3 puts it at every rate.
        let rate = dt * 30
        func scaled(_ bound: Double) -> Double { bound * rate }
        func format(_ low: Double, _ high: Double) -> String {
            String(format: "%.3f … %.3f", low, high)
        }
        if signal.carriesLivelinessBound, assertLiveliness {
            add("M2 Δframe mean", deltaMean, format(0.010, scaled(0.075)),
                deltaMean >= 0.010 && deltaMean <= scaled(0.075))
        } else {
            add("M2 Δframe mean", deltaMean, String(format: "≤ %.3f", scaled(0.075)),
                deltaMean <= scaled(0.075))
        }
        add("M2 Δframe p95", deltaP95, String(format: "≤ %.3f", scaled(0.22)),
            deltaP95 <= scaled(0.22))

        if signal.isRhythmic, hasLatency, perOnsetMode, assertLatency {
            add("M3 latency median", latencyMedian, "≤ 2.0 fr", latencyMedian <= 2.0, format: "%.2f")
            add("M3 latency p90", latencyP90, "≤ 3.5 fr", latencyP90 <= 3.5, format: "%.2f")
            add("M3 miss rate", missRate, "≤ 5 %", missRate <= 0.05)
        }

        if signal.isMusical, hasOnDuration {
            add("M4 onDuration median", onDurationMedian, "≥ 0.25 s", onDurationMedian >= 0.25)
        }
        if hasOnDuration {
            add("M4 onDuration p10", onDurationP10, "≥ 0.15 s", onDurationP10 >= 0.15 - 1e-9)
        }

        if signal.mustBeSilentOfOnsets {
            add("M5 false onsets", Double(onsetCount), "= 0", onsetCount == 0, format: "%.0f")
        } else if signal.isMusical {
            add("M5 trigger rate", onsetRate, "0.5 … 5.0 Hz", onsetRate >= 0.5 && onsetRate <= 5.0)
        }
        if case .edm128 = signal {
            add("M5 kick recall", kickRecall, "≥ 0.95", kickRecall >= 0.95)
            add("M5 kick precision", kickPrecision, "≥ 0.90", kickPrecision >= 0.90)
        }
        if case .edm128KickOnly = signal {
            add("M5 phantom snares", snareFalseRate, "≤ 0.05/s", snareFalseRate <= 0.05)
        }
        if case .speech = signal {
            add("M5 speech rate", onsetRate, "≤ 2.0 Hz", onsetRate <= 2.0)
            add("M5 tempo unlocked", tempoConfidenceLowFraction, "≥ 90 %",
                tempoConfidenceLowFraction >= 0.90)
        }

        if case .nearSilence = signal {
            add("M6 board brightness", boardMeanBrightness, "≤ 0.03", boardMeanBrightness <= 0.03)
        } else if signal.hasSteadyState {
            // Reported even when no band registered as present. Skipping
            // silently meant the universality gate could disappear from a run
            // without anything saying so.
            checks.append(Check(name: "M6 AVERAGE_REL range",
                                value: averageRelativeMin > 0
                                    ? String(format: "%.2f–%.2f", averageRelativeMin,
                                             averageRelativeMax)
                                    : "no band",
                                bound: "0.85 … 1.20",
                                passed: averageRelativeMin >= 0.85
                                    && averageRelativeMax <= 1.20))
        }

        add("M7 tick p95", tickP95, "≤ \(String(format: "%.3f", dt * 1.15))",
            tickP95 <= dt * 1.15 + 1e-6)
        add("M7 tick max", tickMax, "≤ \(String(format: "%.3f", dt * 2))",
            tickMax <= dt * 2 + 1e-6)
        add("M7 delivered", deliveredFraction, "≥ 80 %", deliveredFraction >= 0.80)
        add("M7 stale frames", staleFraction, "≤ 1 %", staleFraction <= 0.01)
        return checks
    }
}

func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[index]
}
