import Foundation
import GMMKProtocol
import GloriousVisualizer

// The r2 metrics: M8 beat alignment, M9 accumulation and memory, M10 spatial
// diversity.
//
// Each is the numerical statement of one of the three live-hardware complaints,
// and each was chosen so that the *shipped* build fails it. A metric that the
// build already passes cannot be the reason the build is wrong.

/// **M8 — beat alignment.** The numerical statement of *"the keyboard updates
/// feel off beat."*
///
/// Computed on the click cases, where the true beat times are exact, and with
/// the `/latency` arm on so the simulated pipeline latency is included.
struct BeatAlignment {
    var mae: Double = 0
    var bias: Double = 0
    var deviation: Double = 0
    var missRate: Double = 1
    /// Fraction of beats that produced a visible gesture at all.
    var gesturesPerBeat: Double = 0
    var beats = 0
    var measured = false

    /// A beat counts as shown when its crest clears its trough by this much.
    static let visible: Double = 0.04

    /// - Parameters:
    ///   - board: board-mean linear lightness per displayed frame.
    ///   - times: when those frames were **visible** (`t_scheduled + L_out`).
    ///   - beats: exact beat times from the generator.
    /// - Parameter warmUp: how long the grid is given to exist before its
    ///   alignment is a fair question. §2.3's tracker autocorrelates over an 8 s
    ///   window and requires three agreeing estimates before it will move the
    ///   tempo at all, and §2.3.4 requires a confirmation before it will predict
    ///   anything; measuring alignment before any of that has happened is
    ///   measuring the lock-in transient, which showed up as ±50 ms outliers on
    ///   beats 6–8 and dominated `sd` on every case.
    static func measure(board: [Double], times: [Double], beats: [Double],
                        warmUp: Double = 8.0) -> BeatAlignment {
        var result = BeatAlignment()
        guard board.count == times.count, board.count > 4, beats.count > 2 else {
            return result
        }
        // The period is the generator's own spacing, so nothing about the metric
        // depends on our estimate of the tempo.
        var periods: [Double] = []
        for index in 1..<beats.count { periods.append(beats[index] - beats[index - 1]) }
        let period = percentile(periods, 0.5)
        guard period > 0 else { return result }

        var errors: [Double] = []
        var shown = 0
        var considered = 0
        let last = times.last ?? 0
        for beat in beats where beat >= warmUp && beat + 0.45 * period <= last {
            considered += 1
            let troughStart = beat - 0.45 * period
            let crestStart = beat - 0.25 * period
            let crestEnd = beat + 0.35 * period
            var trough = Double.infinity
            var crest = -Double.infinity
            for (index, time) in times.enumerated() {
                if time >= troughStart, time <= beat { trough = min(trough, board[index]) }
                if time >= crestStart, time <= crestEnd { crest = max(crest, board[index]) }
            }
            guard trough.isFinite, crest.isFinite, crest - trough >= Self.visible else { continue }
            shown += 1
            let half = trough + 0.5 * (crest - trough)
            // **Linear interpolation between the bracketing displayed frames is
            // mandatory**: quantising the crossing to `dt_f` would put a 33 ms
            // floor under a metric whose threshold is 30 ms.
            var crossing: Double?
            for index in 1..<times.count {
                guard times[index] >= crestStart, times[index] <= crestEnd else { continue }
                guard board[index] >= half, board[index - 1] < half else { continue }
                let span = board[index] - board[index - 1]
                let fraction = span > 0 ? (half - board[index - 1]) / span : 0
                crossing = times[index - 1] + (times[index] - times[index - 1]) * fraction
                break
            }
            if let crossing {
                errors.append(crossing - beat)
                if ProcessInfo.processInfo.environment["VIZ_M8"] != nil {
                    print(String(format: "beat %7.3f  e %+7.1f ms  trough %.3f crest %.3f",
                                 beat, (crossing - beat) * 1000, trough, crest))
                }
            }
        }
        result.beats = considered
        guard considered > 0 else { return result }
        result.gesturesPerBeat = Double(shown) / Double(considered)
        result.missRate = 1 - result.gesturesPerBeat
        guard !errors.isEmpty else { return result }
        result.measured = true
        result.mae = errors.reduce(0) { $0 + abs($1) } / Double(errors.count)
        result.bias = errors.reduce(0, +) / Double(errors.count)
        let mean = result.bias
        result.deviation = (errors.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                            / Double(errors.count)).squareRoot()
        return result
    }

    /// The phantom-beat test for `click-120-gap` (§2.3.4).
    ///
    /// The document states this as "frames with a rise of ≥ 0.04 above the
    /// pre-gap baseline". Measured against a **running** trough rather than the
    /// pre-gap level, which is strictly stronger: once the bed has decayed into
    /// the gap a phantom pulse can be plainly visible on the board while still
    /// sitting below where the music left off, and the literal clause would miss
    /// exactly the failure it exists to catch.
    static func phantomRises(board: [Double], times: [Double],
                             from start: Double, to end: Double,
                             lookback: Double = 0.4) -> Int {
        var count = 0
        for (index, time) in times.enumerated() where time >= start && time <= end {
            var trough = board[index]
            var scan = index
            while scan > 0, times[index] - times[scan] <= lookback {
                trough = min(trough, board[scan])
                scan -= 1
            }
            if board[index] - trough >= Self.visible { count += 1 }
        }
        return count
    }
}

/// **M9 — accumulation and memory.** The numerical statement of *"there's no
/// short-term accumulation — it's like a cliff."*
struct Accumulation {
    /// M9a: the fraction of the board's AC power that lives below 0.5 Hz.
    var slowBandFraction: Double = 0
    /// M9b.
    var buildCorrelation: Double = 0
    var slowCorrelation: Double = 0
    var dropContrast: Double = 0
    var hasBuild = false
    /// M9c.
    var deadFraction: Double = 0
    var hasDead = false
    /// The complement, so a constant glow cannot satisfy both halves.
    var silenceMean: Double = 0
    var hasSilence = false
    /// M9d: the autocorrelation 1/e lag, reported and not gated.
    var memoryHorizon: Double = 0

    static func measure(board: [Double], frameInterval dt: Double,
                        rms: [(time: Double, rms: Double)],
                        frameTimes: [Double],
                        silence: [ClosedRange<Double>],
                        drop: (intro: ClosedRange<Double>, drop: ClosedRange<Double>)?)
        -> Accumulation {
        var result = Accumulation()
        guard board.count > 8 else { return result }
        let mean = board.reduce(0, +) / Double(board.count)
        let centred = board.map { $0 - mean }

        result.slowBandFraction = Self.slowBand(centred, dt: dt)
        result.memoryHorizon = Self.memoryHorizon(centred, dt: dt)

        guard !rms.isEmpty, frameTimes.count == board.count else { return result }
        // The generator's own envelope, low-passed and resampled onto the frame
        // grid. Never our analyser's idea of the level: that would be measuring
        // the analyser against itself.
        let reference = Self.resample(Self.onePole(rms.map(\.rms),
                                                   dt: Self.step(of: rms), tau: 1.0),
                                      at: rms.map(\.time), onto: frameTimes)
        result.hasBuild = true
        if ProcessInfo.processInfo.environment["VIZ_M9"] != nil {
            for index in stride(from: 0, to: board.count, by: 1) {
                print(String(format: "t %6.2f  r %.5f  b %.4f", frameTimes[index],
                             reference[index], board[index]))
            }
        }
        result.buildCorrelation = Self.pearson(reference, board)
        result.slowCorrelation = Self.pearson(Self.onePole(reference, dt: dt, tau: 1 / (2 * .pi * 0.25)),
                                              Self.onePole(board, dt: dt, tau: 1 / (2 * .pi * 0.25)))
        if let drop {
            let intro = Self.window(board, times: frameTimes, in: drop.intro)
            let peak = Self.window(board, times: frameTimes, in: drop.drop)
            if !intro.isEmpty, !peak.isEmpty {
                result.dropContrast = peak.reduce(0, +) / Double(peak.count)
                    - intro.reduce(0, +) / Double(intro.count)
            }
        }

        // M9c — dead only where the *input* says music is genuinely playing,
        // defined from the ground-truth track and not from our own analyser.
        let levels = rms.map(\.rms).sorted()
        let playing = levels[min(levels.count - 1, Int(Double(levels.count - 1) * 0.20))]
        var considered = 0
        var dead = 0
        for (index, time) in frameTimes.enumerated() {
            guard let level = Self.sample(rms, at: time, span: dt), level >= playing,
                  time >= 2 else { continue }
            considered += 1
            if board[index] < 0.06 { dead += 1 }
        }
        if considered > 0 {
            result.hasDead = true
            result.deadFraction = Double(dead) / Double(considered)
        }

        // …and the complement, asserted at the same time: ten seconds into a
        // genuine silence the board must be dark.
        //
        // Measured against the **generator's own silence windows**, not against
        // a percentile of the run's RMS. A percentile cannot say "this is a
        // room, not quiet music": a stationary noise floor's own p05 sits
        // inside the floor, so a run that is two thirds room tone reads as
        // continuously playing and the clause is never emitted. Measured at
        // HEAD before this change, it was emitted **zero** times in 13 138
        // checks — which is why a board that relights on room tone and holds a
        // bright floor for ever passed the whole table.
        var silentSamples: [Double] = []
        for (index, time) in frameTimes.enumerated() {
            for window in silence where time >= window.lowerBound + 10
                && time <= window.upperBound {
                silentSamples.append(board[index])
                break
            }
        }
        if !silentSamples.isEmpty {
            result.hasSilence = true
            result.silenceMean = silentSamples.reduce(0, +) / Double(silentSamples.count)
        }
        return result
    }

    /// Welch power spectrum, 8 s Hann segments at 50 % overlap, DC excluded.
    ///
    /// DC is the bed and is measured by M9c; 8 Hz is the ceiling because it is
    /// the display's own Nyquist at 15 fps. Defined as **0** when the total
    /// power is negligible — a frozen board must not score infinity.
    static func slowBand(_ centred: [Double], dt: Double) -> Double {
        let segment = min(centred.count, max(16, Int((8.0 / dt).rounded())))
        let hop = max(1, segment / 2)
        guard centred.count >= segment else { return 0 }
        let nyquist = 0.5 / dt
        let resolution = 1 / (Double(segment) * dt)
        let topBin = min(segment / 2, Int(min(8.0, nyquist) / resolution))
        let slowBin = max(1, Int((0.5 / resolution).rounded()))
        guard topBin > slowBin else { return 0 }

        var window = [Double](repeating: 0, count: segment)
        for index in 0..<segment {
            window[index] = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(segment - 1))
        }
        var slow = 0.0
        var total = 0.0
        var start = 0
        var segments = 0
        while start + segment <= centred.count {
            var windowed = [Double](repeating: 0, count: segment)
            var offset = 0.0
            for index in 0..<segment { offset += centred[start + index] }
            offset /= Double(segment)
            for index in 0..<segment { windowed[index] = (centred[start + index] - offset) * window[index] }
            for bin in 1...topBin {
                var real = 0.0, imaginary = 0.0
                let step = 2 * Double.pi * Double(bin) / Double(segment)
                for index in 0..<segment {
                    real += windowed[index] * cos(step * Double(index))
                    imaginary -= windowed[index] * sin(step * Double(index))
                }
                let power = real * real + imaginary * imaginary
                total += power
                if bin <= slowBin { slow += power }
            }
            start += hop
            segments += 1
        }
        guard segments > 0, total >= 1e-8 else { return 0 }
        return slow / total
    }

    /// M9d: the lag at which the autocorrelation first falls below `1/e`.
    static func memoryHorizon(_ centred: [Double], dt: Double) -> Double {
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-12 else { return 0 }
        let limit = min(centred.count - 1, Int(8.0 / dt))
        guard limit > 1 else { return 0 }
        for lag in 1...limit {
            var sum = 0.0
            for index in lag..<centred.count { sum += centred[index] * centred[index - lag] }
            if sum / energy < 1 / M_E { return Double(lag) * dt }
        }
        return Double(limit) * dt
    }

    // MARK: - Small helpers

    static func step(of series: [(time: Double, rms: Double)]) -> Double {
        guard series.count > 1 else { return 1 }
        return max(series[1].time - series[0].time, 1e-6)
    }

    static func onePole(_ values: [Double], dt: Double, tau: Double) -> [Double] {
        let a = exp(-dt / max(tau, 1e-6))
        var y = values.first ?? 0
        return values.map { x in
            y = x + (y - x) * a
            return y
        }
    }

    static func resample(_ values: [Double], at times: [Double], onto grid: [Double]) -> [Double] {
        guard !values.isEmpty else { return [Double](repeating: 0, count: grid.count) }
        var index = 0
        return grid.map { time in
            while index + 1 < times.count, times[index + 1] <= time { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }

    /// The input level over the frame that *starts* at `time` — the **maximum**
    /// over the analysis hops it spans, not a point sample.
    ///
    /// The envelope is at the 10.7 ms analysis hop and frames are 33 ms apart,
    /// so a point sample sees roughly one hop in three. On a click track, whose
    /// content is a 12 ms burst every half second, that meant the sampled input
    /// was digital silence on almost every frame and the silence complement
    /// declared the whole run silent — a board correctly showing a click track
    /// was scored as a board glowing through a silence.
    static func sample(_ series: [(time: Double, rms: Double)], at time: Double,
                       span: Double = 0) -> Double? {
        guard let first = series.first, time >= first.time - 0.05 else { return nil }
        let step = Self.step(of: series)
        let start = min(series.count - 1, max(0, Int((time - first.time) / step)))
        let end = min(series.count - 1, max(start, Int((time + span - first.time) / step)))
        var peak = 0.0
        for index in start...end { peak = max(peak, series[index].rms) }
        return peak
    }

    static func window(_ values: [Double], times: [Double], in range: ClosedRange<Double>) -> [Double] {
        var out: [Double] = []
        for (index, time) in times.enumerated() where range.contains(time) { out.append(values[index]) }
        return out
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let count = min(a.count, b.count)
        guard count > 2 else { return 0 }
        let meanA = a.prefix(count).reduce(0, +) / Double(count)
        let meanB = b.prefix(count).reduce(0, +) / Double(count)
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in 0..<count {
            let x = a[index] - meanA, y = b[index] - meanB
            covariance += x * y
            varianceA += x * x
            varianceB += y * y
        }
        guard varianceA > 1e-12, varianceB > 1e-12 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }
}

/// **M10 — spatial diversity.** The numerical statement of *"the colour is
/// concentrated in the centre and isn't diverse."*
///
/// r1 scores ≈ 0 on M10a by construction: one hue for the whole board.
struct SpatialDiversity {
    /// M10a, in **turns**.
    var hueSpreadMedian: Double = 0
    var hueSpreadP05: Double = 0
    /// M10b.
    var hueDrift: Double = 0
    /// M10a's anti-vacuity companion: how much the *shape* of the hue field
    /// across the board moves, once the frame's own mean hue is removed.
    ///
    /// M10a and M10b can both be satisfied with no audio input at all. A static
    /// `±0.30`-turn gradient plus §12.1's constant `1/180` turn-per-second
    /// clock — literally the design's own `H0` and `A·G` with the music taken
    /// out — scores σ_h 0.091 and drift 0.048 through the shipped measurement,
    /// i.e. it passes both. What that board cannot do is *change the shape* of
    /// the gradient: §12.1 makes the boundary position `x_c` follow the
    /// centroid and the fan width `A` follow the spectral spread, and neither
    /// moves on a timer. This is the residual after the frame's circular mean
    /// is removed, so a rotating palette contributes nothing to it.
    var hueShapeMotion: Double = 0
    /// M10c, in columns.
    var centreMean: Double = 8
    var centreDeviation: Double = 0
    var centreRange: Double = 0
    /// M10d, as a fraction of the column mean.
    var columnMinRatio: Double = 1
    var columnMaxRatio: Double = 1
    var measured = false

    /// A frame counts only when the board is showing something.
    static let visibleMean: Double = 0.06

    /// LED offsets per display column, level rows and peak key together.
    static let columnLEDs: [[Int]] = VisualizerLayout.columns.map { column in
        var leds: [Int] = []
        for row in column.levelRows {
            leds += row.map { Int($0) - Int(GMMKKeyMap.minLEDIndex) }
        }
        leds += column.peakKeys.map { Int($0) - Int(GMMKKeyMap.minLEDIndex) }
        return leds
    }

    static func measure(colors: [[RGB]]) -> SpatialDiversity {
        var result = SpatialDiversity()
        guard let first = colors.first, !first.isEmpty else { return result }
        let columns = columnLEDs.count

        var spreads: [Double] = []
        var meanHues: [Double] = []
        var centres: [Double] = []
        var columnTotals = [Double](repeating: 0, count: columns)
        var columnFrames = 0
        // Per-frame hue profiles, relative to the frame's own mean hue.
        var profiles: [[Double]] = []

        for frame in colors {
            var weight = 0.0
            var cosine = 0.0, sine = 0.0
            var columnValues = [Double](repeating: 0, count: columns)
            var columnHues = [Double](repeating: .nan, count: columns)
            for (index, leds) in columnLEDs.enumerated() {
                var sum = 0.0
                var columnWeight = 0.0
                var columnCosine = 0.0, columnSine = 0.0
                for led in leds where led >= 0 && led < frame.count {
                    let colour = frame[led]
                    let r = KeyInterlock.decode(colour.red)
                    let g = KeyInterlock.decode(colour.green)
                    let b = KeyInterlock.decode(colour.blue)
                    let value = max(r, max(g, b))
                    sum += value
                    guard value > 1e-6 else { continue }
                    // Hue is circular, and a hue on a dark key is not visible,
                    // so the spread is brightness-weighted and circular.
                    let hue = hueOfRGB(r, g, b)
                    weight += value
                    cosine += value * cos(2 * .pi * hue)
                    sine += value * sin(2 * .pi * hue)
                    columnWeight += value
                    columnCosine += value * cos(2 * .pi * hue)
                    columnSine += value * sin(2 * .pi * hue)
                }
                columnValues[index] = leds.isEmpty ? 0 : sum / Double(leds.count)
                if columnWeight > 1e-9 {
                    columnHues[index] = atan2(columnSine, columnCosine) / (2 * .pi)
                }
            }
            let ledCount = Double(frame.count)
            let boardMean = weight / max(ledCount, 1)
            columnFrames += 1
            for index in 0..<columns { columnTotals[index] += columnValues[index] }

            guard boardMean >= visibleMean, weight > 1e-9 else { continue }
            let c = cosine / weight, s = sine / weight
            let r = min(1, (c * c + s * s).squareRoot())
            spreads.append(r > 1e-9 ? (-2 * log(r)).squareRoot() / (2 * .pi) : 0.5)
            var meanHue = atan2(s, c) / (2 * .pi)
            meanHue -= meanHue.rounded(.down)
            meanHues.append(meanHue)

            // The hue profile: every column's hue minus this frame's own mean
            // hue, wrapped to ±0.5 turns. Columns that are dark this frame
            // carry no hue and are left out of the comparison.
            if columnHues.contains(where: { !$0.isNaN }) {
                profiles.append(columnHues.map { hue in
                    hue.isNaN ? Double.nan : Self.wrapTurns(hue - meanHue)
                })
            }

            let columnSum = columnValues.reduce(0, +)
            if columnSum >= visibleMean * Double(columns) {
                var moment = 0.0
                for index in 0..<columns { moment += columnValues[index] * Double(index) }
                centres.append(moment / columnSum)
            }
        }

        guard !spreads.isEmpty, !centres.isEmpty, columnFrames > 0 else { return result }
        result.measured = true
        result.hueSpreadMedian = percentile(spreads, 0.5)
        result.hueSpreadP05 = percentile(spreads, 0.05)
        result.hueDrift = Self.circularDeviation(meanHues)
        result.hueShapeMotion = Self.profileMotion(profiles, columns: columns)
        result.centreMean = centres.reduce(0, +) / Double(centres.count)
        let centreMean = result.centreMean
        result.centreDeviation = (centres.reduce(0) { $0 + ($1 - centreMean) * ($1 - centreMean) }
                                  / Double(centres.count)).squareRoot()
        result.centreRange = percentile(centres, 0.95) - percentile(centres, 0.05)

        let averages = columnTotals.map { $0 / Double(columnFrames) }
        let overall = averages.reduce(0, +) / Double(columns)
        if overall > 1e-9 {
            result.columnMinRatio = (averages.min() ?? 0) / overall
            result.columnMaxRatio = (averages.max() ?? 0) / overall
        }
        return result
    }

    /// Wraps a hue difference into `±0.5` turns.
    static func wrapTurns(_ turns: Double) -> Double {
        var value = turns - turns.rounded(.down)
        if value > 0.5 { value -= 1 }
        return value
    }

    /// How far a frame's hue profile departs from the run's average profile,
    /// in turns — the median over frames of the RMS over columns.
    ///
    /// Zero for any board whose hue field is a fixed function of column, no
    /// matter how fast the whole palette rotates.
    static func profileMotion(_ profiles: [[Double]], columns: Int) -> Double {
        guard profiles.count > 8 else { return 0 }
        var average = [Double](repeating: 0, count: columns)
        for column in 0..<columns {
            var cosine = 0.0, sine = 0.0, count = 0.0
            for profile in profiles where !profile[column].isNaN {
                cosine += cos(2 * .pi * profile[column])
                sine += sin(2 * .pi * profile[column])
                count += 1
            }
            average[column] = count > 0 ? atan2(sine, cosine) / (2 * .pi) : 0
        }
        var residuals: [Double] = []
        for profile in profiles {
            var sum = 0.0
            var count = 0.0
            for column in 0..<columns where !profile[column].isNaN {
                let difference = Self.wrapTurns(profile[column] - average[column])
                sum += difference * difference
                count += 1
            }
            if count > 0 { residuals.append((sum / count).squareRoot()) }
        }
        return residuals.isEmpty ? 0 : percentile(residuals, 0.5)
    }

    /// Standard deviation of a circular quantity, in turns — the mean hue
    /// wanders across the wrap point and a linear sd would report a rainbow.
    static func circularDeviation(_ turns: [Double]) -> Double {
        guard turns.count > 1 else { return 0 }
        var cosine = 0.0, sine = 0.0
        for turn in turns {
            cosine += cos(2 * .pi * turn)
            sine += sin(2 * .pi * turn)
        }
        cosine /= Double(turns.count)
        sine /= Double(turns.count)
        let r = min(1, (cosine * cosine + sine * sine).squareRoot())
        guard r > 1e-9 else { return 0.5 }
        return (-2 * log(r)).squareRoot() / (2 * .pi)
    }
}
