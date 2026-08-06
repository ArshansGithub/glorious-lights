import XCTest
@testable import GloriousVisualizer
import GMMKProtocol

/// The musical layer, against synthesised signals whose answers are known.
///
/// This is the part the redesign rests on: if the tempo is wrong or the onsets
/// fire on everything, every mode built on top inherits it and the board goes
/// back to looking random.
final class MusicalAnalysisTests: XCTestCase {

    private let sampleRate: Double = 48_000

    // MARK: - Fixtures

    /// A kick-like pattern: a short 60 Hz burst with a fast decay, every beat.
    private func kickPattern(bpm: Double, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        let period = 60 / bpm
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            let phase = t.truncatingRemainder(dividingBy: period)
            let envelope = exp(-phase * 22)
            return Float(0.9 * envelope * sin(2 * .pi * 60 * t))
        }
    }

    /// Feeds a signal through a pipeline the way the app does, and returns the
    /// last musical frame plus everything that fired along the way.
    private func run(_ samples: [Float],
                     fps: Double = 15,
                     profile: VisualizerPipeline.SourceProfile = .music)
        -> (frames: [MusicalFrame], onsets: [OnsetKind: Int]) {
        let pipeline = VisualizerPipeline(
            sampleRate: Float(sampleRate),
            bandCount: VisualizerLayout.columns.count,
            tuning: .init(sourceProfile: profile))
        let interval = 1 / fps
        let perFrame = Int(sampleRate * interval)
        var frames: [MusicalFrame] = []
        var counts: [OnsetKind: Int] = [:]

        var offset = 0
        while offset + perFrame <= samples.count {
            pipeline.analyze(Array(samples[offset..<(offset + perFrame)]))
            let frame = pipeline.musicalFrame(elapsed: interval)
            frames.append(frame)
            for (kind, strength) in frame.onsets where strength > 0 {
                counts[kind, default: 0] += 1
            }
            offset += perFrame
        }
        return (frames, counts)
    }

    // MARK: - Tempo

    /// **A 120 BPM kick pattern must read as 120 BPM.** The whole rhythmic half
    /// of the redesign is downstream of this.
    func testTempoOfA120BPMKickPattern() {
        let (frames, _) = run(kickPattern(bpm: 120, seconds: 20))
        let estimates = frames.map(\.tempo.bpm).filter { $0 > 0 }
        XCTAssertFalse(estimates.isEmpty, "no tempo was ever established")

        let settled = Array(estimates.suffix(estimates.count / 3))
        let sorted = settled.sorted()
        let median = sorted[sorted.count / 2]
        XCTAssertEqual(median, 120, accuracy: 4, "settled at \(median) BPM")
    }

    /// And a different tempo must give a different answer — a detector that
    /// always says 120 would pass the test above.
    func testTempoOfA150BPMKickPattern() {
        let (frames, _) = run(kickPattern(bpm: 150, seconds: 20))
        let estimates = frames.map(\.tempo.bpm).filter { $0 > 0 }
        let settled = Array(estimates.suffix(max(1, estimates.count / 3))).sorted()
        let median = settled[settled.count / 2]
        XCTAssertEqual(median, 150, accuracy: 5, "settled at \(median) BPM")
    }

    /// Half- and double-time observations of the same music must agree, which
    /// is what the octave folding is for.
    func testTemposAreFoldedIntoOneOctave() {
        XCTAssertEqual(TempoTracker.canonical(bpm: 180), 90, accuracy: 0.001)
        XCTAssertEqual(TempoTracker.canonical(bpm: 45), 90, accuracy: 0.001)
        XCTAssertEqual(TempoTracker.canonical(bpm: 120), 120, accuracy: 0.001)
        for bpm in stride(from: 40.0, through: 400.0, by: 7) {
            let folded = TempoTracker.canonical(bpm: bpm)
            XCTAssertTrue(TempoTracker.canonicalRange.contains(folded),
                          "\(bpm) folded to \(folded)")
        }
    }

    /// Noise has no tempo, and the tracker must say so rather than inventing
    /// one a mode would then lock to.
    func testNoiseProducesLowTempoConfidence() {
        var state: UInt64 = 99
        let noise = (0..<Int(sampleRate * 12)).map { _ -> Float in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Double(state >> 11) / Double(1 << 53) - 0.5) * 0.4
        }
        let (frames, _) = run(noise)
        let confidence = frames.map(\.tempo.confidence).suffix(30)
        let mean = confidence.reduce(0, +) / Double(max(confidence.count, 1))
        XCTAssertLessThan(mean, 0.6, "noise should not read as strongly periodic")
    }

    // MARK: - Onsets

    /// A 120 BPM kick pattern fires roughly two kicks a second — not eight,
    /// which is what the detector did before the refractory periods were tuned.
    func testKickOnsetsMatchTheBeatRate() {
        let seconds = 16.0
        let (_, counts) = run(kickPattern(bpm: 120, seconds: seconds))
        let kicks = counts[.kick] ?? 0
        let perSecond = Double(kicks) / seconds
        XCTAssertGreaterThan(perSecond, 1.2, "only \(kicks) kicks in \(seconds)s")
        XCTAssertLessThan(perSecond, 3.2, "\(kicks) kicks in \(seconds)s is re-triggering")
    }

    /// Onsets land on the beat, not scattered between them.
    func testKickOnsetsLandOnTheBeat() {
        let bpm = 120.0
        let (frames, _) = run(kickPattern(bpm: bpm, seconds: 16))
        let period = 60 / bpm

        let onsetTimes = frames.filter { $0.onset(.kick) > 0 }.map(\.time)
        XCTAssertFalse(onsetTimes.isEmpty)
        // Each onset should sit near a multiple of the beat period. One display
        // frame is 67 ms, so a fifth of a beat is the tightest honest bound.
        var near = 0
        for time in onsetTimes {
            let offset = time.truncatingRemainder(dividingBy: period)
            let distance = min(offset, period - offset)
            if distance < period * 0.2 { near += 1 }
        }
        XCTAssertGreaterThan(Double(near) / Double(onsetTimes.count), 0.7,
                             "only \(near) of \(onsetTimes.count) onsets landed near a beat")
    }

    /// Silence produces no onsets at all.
    func testSilenceProducesNoOnsets() {
        let (_, counts) = run([Float](repeating: 0, count: Int(sampleRate * 5)))
        XCTAssertEqual(counts.values.reduce(0, +), 0)
    }

    /// The room profile asks for more evidence, so the same material fires
    /// fewer onsets than the music profile — the point of having two.
    func testTheRoomProfileIsLessTriggerHappy() {
        let signal = kickPattern(bpm: 128, seconds: 14)
        let music = run(signal, profile: .music).onsets.values.reduce(0, +)
        let room = run(signal, profile: .room).onsets.values.reduce(0, +)
        XCTAssertLessThanOrEqual(room, music,
                                 "room fired \(room) onsets, music \(music)")
    }

    // MARK: - Features

    /// **A rising sweep must raise the brightness monotonically** — that is the
    /// whole contract of the centroid feature, and hue depends on it.
    func testBrightnessRisesWithASweep() {
        let seconds = 12.0
        let count = Int(sampleRate * seconds)
        let low = 120.0, high = 9_000.0
        let sweep = (0..<count).map { index -> Float in
            let t = Double(index) / sampleRate
            let progress = t / seconds
            let k = log(high / low)
            let phase = 2 * .pi * low * seconds / k * (exp(progress * k) - 1)
            return Float(0.5 * sin(phase))
        }
        let (frames, _) = run(sweep)
        let brightness = frames.map(\.brightness)
        XCTAssertFalse(brightness.isEmpty)

        // Compare thirds rather than adjacent frames: the feature is smoothed,
        // so what matters is the trend, not that every step rises.
        let third = brightness.count / 3
        let first = brightness[0..<third].reduce(0, +) / Float(third)
        let last = brightness[(third * 2)...].reduce(0, +) / Float(brightness.count - third * 2)
        XCTAssertGreaterThan(last, first + 0.15,
                             "brightness went \(first) → \(last) across a rising sweep")
    }

    /// A bass-only signal reads dark and a treble-only signal reads bright.
    func testBrightnessSeparatesBassFromTreble() {
        func tone(_ hz: Double) -> [Float] {
            (0..<Int(sampleRate * 8)).map { index in
                Float(0.5 * sin(2 * .pi * hz * Double(index) / sampleRate))
            }
        }
        let bass = run(tone(80)).frames.map(\.brightness).suffix(20)
        let treble = run(tone(5_000)).frames.map(\.brightness).suffix(20)
        let bassMean = bass.reduce(0, +) / Float(bass.count)
        let trebleMean = treble.reduce(0, +) / Float(treble.count)
        XCTAssertLessThan(bassMean, trebleMean - 0.2,
                          "80 Hz read \(bassMean), 5 kHz read \(trebleMean)")
    }

    /// Loudness is compressed, so a quiet passage still shows life rather than
    /// mapping to nearly nothing.
    func testLoudnessIsCompressed() {
        let loud = run(kickPattern(bpm: 120, seconds: 8)).frames.map(\.loudness).suffix(20)
        let loudMean = loud.reduce(0, +) / Float(loud.count)
        XCTAssertGreaterThan(loudMean, 0.15, "a kick pattern should read as clearly audible")
        XCTAssertLessThanOrEqual(loudMean, 1.0)
    }

    // MARK: - Modes

    /// **No mode may ever light an isolated key.** This is the property the
    /// whole redesign was asked for, so it is checked for every mode against
    /// real-ish material rather than argued for in a comment.
    func testNoModeProducesIsolatedKeys() {
        let signal = kickPattern(bpm: 128, seconds: 10)
        for mode in VisualizerMode.allCases {
            let pipeline = VisualizerPipeline(sampleRate: Float(sampleRate),
                                              bandCount: VisualizerLayout.columns.count)
            let renderer = ModeRenderer(mode: mode)
            let interval = 1.0 / 15
            let perFrame = Int(sampleRate * interval)
            var offset = 0
            var worstRun = Int.max

            while offset + perFrame <= signal.count {
                pipeline.analyze(Array(signal[offset..<(offset + perFrame)]))
                let colors = renderer.render(pipeline.musicalFrame(elapsed: interval),
                                             elapsed: interval)
                offset += perFrame

                // Which columns are meaningfully lit, relative to this frame's
                // own brightest key.
                let luminance = { (color: RGB) -> Double in
                    (0.2126 * Double(color.red) + 0.7152 * Double(color.green)
                     + 0.0722 * Double(color.blue)) / 255
                }
                let peak = colors.map(luminance).max() ?? 0
                guard peak > 0.02 else { continue }
                var lit: [Bool] = []
                for column in VisualizerLayout.columns {
                    let isLit = column.levelRows.flatMap { $0 }.contains { led in
                        let offset = Int(led) - Int(GMMKKeyMap.minLEDIndex)
                        guard colors.indices.contains(offset) else { return false }
                        return luminance(colors[offset]) >= peak * 0.45
                    }
                    lit.append(isLit)
                }
                guard lit.contains(true) else { continue }

                // The shortest run of lit columns in this frame.
                var run = 0
                var shortest = Int.max
                for isLit in lit {
                    if isLit {
                        run += 1
                    } else if run > 0 {
                        shortest = min(shortest, run)
                        run = 0
                    }
                }
                if run > 0 { shortest = min(shortest, run) }
                if shortest != Int.max { worstRun = min(worstRun, shortest) }
            }

            XCTAssertGreaterThanOrEqual(worstRun, 2,
                                        "\(mode.rawValue) produced a run of \(worstRun) column(s)")
        }
    }

    func testEveryModeIsNamedAndDistinct() {
        let names = VisualizerMode.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(VisualizerMode.allCases.count, 5)
        XCTAssertFalse(VisualizerMode.allCases.map(\.summary).contains(""))
    }
}
