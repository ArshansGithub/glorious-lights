import XCTest
@testable import GloriousVisualizer
import GMMKProtocol

/// The visualizer's pure half: which keys form which column, which FFT bins
/// feed which column, how a level becomes lit rows, and how bars fall.
final class VisualizerTests: XCTestCase {

    // MARK: - Layout

    func testColumnCount() {
        XCTAssertEqual(VisualizerLayout.columns.count, 17)
        XCTAssertEqual(VisualizerLayout.mainBlockColumnCount, 14)
    }

    /// The main block's columns are all five rows tall; the navigation cluster
    /// is two, which is the honest height of that block rather than a padded
    /// five that would show phantom lit rows.
    func testColumnHeights() {
        for index in 0..<VisualizerLayout.mainBlockColumnCount {
            XCTAssertEqual(VisualizerLayout.columns[index].rowCount,
                           VisualizerLayout.levelRowCount, "column \(index)")
        }
        for index in VisualizerLayout.mainBlockColumnCount..<VisualizerLayout.columns.count {
            XCTAssertEqual(VisualizerLayout.columns[index].rowCount, 2, "column \(index)")
        }
    }

    /// Every LED the display can light is a real key on the board.
    func testEveryLitLEDIsARealKey() {
        for led in VisualizerLayout.litLEDIndices {
            XCTAssertNotNil(GMMKKeyMap.key(forLEDIndex: led),
                            "LED \(led) is not a key in the ANSI TKL map")
            XCTAssertTrue(GMMKKeyMap.paintableLEDIndices.contains(led), "LED \(led)")
        }
    }

    /// Rows run bottom to top: the bottom row of a main column is a modifier or
    /// the space bar, the top is the number row.
    func testRowsRunBottomToTop() {
        let column = VisualizerLayout.columns[1]   // "1" / Q / A / Z / Left Cmd
        let labels = column.levelRows.map { row in
            row.compactMap { GMMKKeyMap.key(forLEDIndex: $0)?.label }
        }
        XCTAssertEqual(labels, [["Left Cmd"], ["Z"], ["A"], ["Q"], ["1"]])
    }

    /// The space bar is wide, so it belongs to every column it physically
    /// covers rather than to one arbitrary column.
    func testWideKeysSpanTheColumnsTheyCover() {
        let space = GMMKKeyMap.ansiTKL.first { $0.label == "Space" }!.ledIndex
        let columnsWithSpace = VisualizerLayout.columns.enumerated().filter {
            $0.element.levelRows[0].contains(space)
        }
        XCTAssertEqual(columnsWithSpace.count, 7)
        // And they are contiguous.
        let indices = columnsWithSpace.map(\.offset)
        XCTAssertEqual(indices, Array(indices.first!...indices.last!))
    }

    /// Every column has a peak key, and they come from the function row.
    func testEveryColumnHasAPeakKeyFromTheFunctionRow() {
        let functionRowLEDs = Set((1...13).map(UInt16.init) + [106, 107, 108])
        for (index, column) in VisualizerLayout.columns.enumerated() {
            XCTAssertEqual(column.peakKeys.count, 1, "column \(index)")
            XCTAssertTrue(functionRowLEDs.contains(column.peakKeys[0]),
                          "column \(index) peaks on LED \(column.peakKeys[0])")
        }
        // Leftmost peaks on Esc, rightmost on the last function-row key.
        XCTAssertEqual(VisualizerLayout.columns.first?.peakKeys, [1])
        XCTAssertEqual(VisualizerLayout.columns.last?.peakKeys, [108])
    }

    /// A key must not appear twice in the same column, or a bar would paint it
    /// twice and the top write would win.
    func testNoKeyRepeatsWithinAColumn() {
        for (index, column) in VisualizerLayout.columns.enumerated() {
            let all = column.levelRows.flatMap { $0 }
            XCTAssertEqual(Set(all).count, all.count, "column \(index) repeats a key")
        }
    }

    // MARK: - Band mapping

    /// Bands are geometric, so each is wider in bins than the one below — the
    /// property that keeps bass from collapsing into one column.
    func testBandsWidenTowardsHigherFrequencies() {
        let ranges = SpectrumAnalyzer.bandBinRanges(sampleRate: 48_000, bandCount: 17)
        XCTAssertEqual(ranges.count, 17)
        let widths = ranges.map { $0.upper - $0.lower + 1 }
        XCTAssertEqual(widths, widths.sorted(), "band widths should be non-decreasing")
        XCTAssertLessThan(widths.first!, widths.last!)
    }

    /// No band includes bin 0 (DC), no band is empty, and they ascend.
    func testBandRangesAreWellFormed() {
        for rate: Float in [44_100, 48_000] {
            let ranges = SpectrumAnalyzer.bandBinRanges(sampleRate: rate, bandCount: 17)
            var previousLower = 0
            for (index, range) in ranges.enumerated() {
                XCTAssertGreaterThanOrEqual(range.lower, 1, "band \(index) at \(rate) includes DC")
                XCTAssertLessThanOrEqual(range.lower, range.upper, "band \(index) at \(rate)")
                XCTAssertLessThan(range.upper, SpectrumAnalyzer.windowSize / 2,
                                  "band \(index) at \(rate) runs past Nyquist")
                XCTAssertGreaterThanOrEqual(range.lower, previousLower, "band \(index) at \(rate)")
                previousLower = range.lower
            }
        }
    }

    /// A pure tone lands in the column whose band contains it, and not in the
    /// columns either side. This is the end-to-end check that the FFT, the
    /// window and the band edges agree.
    func testASineWaveLandsInTheExpectedColumn() {
        let sampleRate: Float = 48_000
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, bandCount: 17)
        let ranges = SpectrumAnalyzer.bandBinRanges(sampleRate: sampleRate, bandCount: 17)
        let binWidth = sampleRate / Float(SpectrumAnalyzer.windowSize)

        // Pick a band in the middle and generate a tone at its centre bin.
        let target = 8
        let centreBin = (ranges[target].lower + ranges[target].upper) / 2
        let frequency = Float(centreBin) * binWidth

        let samples = (0..<SpectrumAnalyzer.windowSize).map { index -> Float in
            sin(2 * .pi * frequency * Float(index) / sampleRate)
        }
        let levels = analyzer.levels(from: samples)

        XCTAssertEqual(levels.count, 17)
        let loudest = levels.enumerated().max { $0.element < $1.element }!.offset
        XCTAssertEqual(loudest, target,
                       "a \(Int(frequency)) Hz tone should light column \(target)")
        XCTAssertGreaterThan(levels[target], 0.01)
    }

    /// Silence is silent everywhere — no window artefact lights a column.
    func testSilenceProducesNoLevels() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000, bandCount: 17)
        let levels = analyzer.levels(from: [Float](repeating: 0,
                                                   count: SpectrumAnalyzer.windowSize))
        XCTAssertTrue(levels.allSatisfy { $0 < 1e-6 }, "\(levels)")
    }

    /// A short buffer is zero-padded rather than crashing or reading garbage.
    func testShortBuffersArePadded() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000, bandCount: 17)
        XCTAssertEqual(analyzer.levels(from: [0.1, -0.1, 0.2]).count, 17)
        XCTAssertEqual(analyzer.levels(from: []).count, 17)
    }

    // MARK: - Bar quantisation

    /// Any audible signal lights the bottom row: rounding to nearest would
    /// leave quiet passages looking like a dead display.
    func testRowsLitRoundsUpSoQuietSignalsShow() {
        XCTAssertEqual(BarRenderer.rowsLit(level: 0, rowCount: 5), 0)
        XCTAssertEqual(BarRenderer.rowsLit(level: 0.001, rowCount: 5), 1)
        XCTAssertEqual(BarRenderer.rowsLit(level: 0.2, rowCount: 5), 1)
        XCTAssertEqual(BarRenderer.rowsLit(level: 0.21, rowCount: 5), 2)
        XCTAssertEqual(BarRenderer.rowsLit(level: 0.6, rowCount: 5), 3)
        XCTAssertEqual(BarRenderer.rowsLit(level: 1.0, rowCount: 5), 5)
    }

    func testRowsLitClampsAndHandlesShortColumns() {
        XCTAssertEqual(BarRenderer.rowsLit(level: 5, rowCount: 5), 5)
        XCTAssertEqual(BarRenderer.rowsLit(level: -1, rowCount: 5), 0)
        XCTAssertEqual(BarRenderer.rowsLit(level: 0.5, rowCount: 2), 1)
        XCTAssertEqual(BarRenderer.rowsLit(level: 0.6, rowCount: 2), 2)
        XCTAssertEqual(BarRenderer.rowsLit(level: 0.5, rowCount: 0), 0)
    }

    /// Every level is monotonic in height: louder never lights fewer rows.
    func testRowsLitIsMonotonic() {
        var last = 0
        for step in 0...100 {
            let lit = BarRenderer.rowsLit(level: Float(step) / 100, rowCount: 5)
            XCTAssertGreaterThanOrEqual(lit, last)
            last = lit
        }
        XCTAssertEqual(last, 5)
    }

    // MARK: - Colour

    func testHeatRampRunsGreenToRed() {
        let renderer = BarRenderer(style: .heat, themeColor: .black)
        let bottom = renderer.color(forRow: 0, of: 5)
        let top = renderer.color(forRow: 4, of: 5)
        XCTAssertEqual(bottom, RGB(red: 0, green: 255, blue: 0))
        XCTAssertEqual(top, RGB(red: 255, green: 0, blue: 0))
        // The middle is yellow-ish: both red and green well up, no blue.
        let middle = renderer.color(forRow: 2, of: 5)
        XCTAssertGreaterThan(middle.red, 200)
        XCTAssertGreaterThan(middle.green, 200)
        XCTAssertEqual(middle.blue, 0)
    }

    /// The theme style keeps the hue and varies only the intensity, so a desk
    /// look's colour survives being turned into a bar graph.
    func testThemeRampKeepsTheHueAndBrightensUpwards() {
        let teal = RGB(red: 0x00, green: 0xCC, blue: 0xAA)
        let renderer = BarRenderer(style: .theme, themeColor: teal)
        let bottom = renderer.color(forRow: 0, of: 5)
        let top = renderer.color(forRow: 4, of: 5)

        XCTAssertEqual(top, teal)
        XCTAssertLessThan(bottom.green, top.green)
        XCTAssertGreaterThan(bottom.green, 0, "the bottom row must still be visible")
        // Hue preserved: the green:blue ratio is the same at both ends.
        let bottomRatio = Double(bottom.green) / Double(bottom.blue)
        let topRatio = Double(top.green) / Double(top.blue)
        XCTAssertEqual(bottomRatio, topRatio, accuracy: 0.05)
        XCTAssertEqual(bottom.red, 0)
    }

    // MARK: - Frames

    /// A silent frame paints the whole board the background colour.
    func testSilentFrameIsAllBackground() {
        let renderer = BarRenderer(style: .heat, themeColor: .black)
        let frame = renderer.frame(levels: [Float](repeating: 0, count: 17))
        XCTAssertEqual(frame.count, GMMKKeyMap.paintableLEDIndices.count)
        XCTAssertTrue(frame.allSatisfy { $0 == .black })
    }

    /// A full-scale frame lights every level row of every column, and every
    /// peak key too.
    func testFullScaleFrameLightsEverything() {
        let renderer = BarRenderer(style: .heat, themeColor: .black)
        let frame = renderer.frame(levels: [Float](repeating: 1, count: 17))
        for led in VisualizerLayout.litLEDIndices {
            let offset = Int(led) - Int(GMMKKeyMap.minLEDIndex)
            XCTAssertNotEqual(frame[offset], .black, "LED \(led) should be lit")
        }
    }

    /// One loud column lights that column and leaves its neighbours dark — the
    /// property that makes the display readable as a spectrum at all.
    func testOneLoudColumnDoesNotBleed() {
        let renderer = BarRenderer(style: .heat, themeColor: .black)
        var levels = [Float](repeating: 0, count: 17)
        levels[5] = 1
        let frame = renderer.frame(levels: levels)

        func isLit(_ led: UInt16) -> Bool {
            frame[Int(led) - Int(GMMKKeyMap.minLEDIndex)] != .black
        }
        for led in VisualizerLayout.columns[5].levelRows.flatMap({ $0 }) {
            XCTAssertTrue(isLit(led), "LED \(led) in the loud column should be lit")
        }
        // Column 5's own peak key may be shared with a neighbour, so check the
        // neighbours' *level* rows only.
        for neighbour in [4, 6] {
            for led in VisualizerLayout.columns[neighbour].levelRows.flatMap({ $0 })
            where !VisualizerLayout.columns[5].levelRows.flatMap({ $0 }).contains(led) {
                XCTAssertFalse(isLit(led), "LED \(led) in column \(neighbour) should be dark")
            }
        }
    }

    /// The peak key only lights above the threshold.
    func testPeakKeyLightsOnlyOnPeaks() {
        let renderer = BarRenderer(style: .heat, themeColor: .black)
        let peak = VisualizerLayout.columns[0].peakKeys[0]
        let offset = Int(peak) - Int(GMMKKeyMap.minLEDIndex)

        var quiet = [Float](repeating: 0, count: 17)
        quiet[0] = BarRenderer.peakThreshold - 0.05
        XCTAssertEqual(renderer.frame(levels: quiet)[offset], .black)

        var loud = [Float](repeating: 0, count: 17)
        loud[0] = BarRenderer.peakThreshold + 0.05
        XCTAssertNotEqual(renderer.frame(levels: loud)[offset], .black)
    }

    /// Missing levels read as silence rather than crashing — the analyzer and
    /// the layout could disagree about the column count after an edit.
    func testShortLevelArraysAreTreatedAsSilent() {
        let renderer = BarRenderer(style: .heat, themeColor: .black)
        XCTAssertEqual(renderer.frame(levels: []).count,
                       GMMKKeyMap.paintableLEDIndices.count)
        XCTAssertTrue(renderer.frame(levels: []).allSatisfy { $0 == .black })
        XCTAssertEqual(renderer.frame(levels: [1, 1, 1]).count,
                       GMMKKeyMap.paintableLEDIndices.count)
    }

    // MARK: - Smoothing

    /// Attack is instant: a bar reaches a new peak in the frame it arrives.
    func testAttackIsInstant() {
        var smoother = LevelSmoother(bandCount: 3)
        let levels = smoother.update(with: [1, 0.5, 0], elapsed: 1.0 / 15)
        XCTAssertEqual(levels, [1, 0.5, 0])
    }

    /// Release is exponential and time-based: after one release time the bar is
    /// at about 1/e of where it was.
    func testReleaseFallsExponentially() {
        var smoother = LevelSmoother(bandCount: 1, releaseTime: 0.2)
        _ = smoother.update(with: [1], elapsed: 0)
        let after = smoother.update(with: [0], elapsed: 0.2)
        XCTAssertEqual(Double(after[0]), 1 / M_E, accuracy: 0.01)

        let further = smoother.update(with: [0], elapsed: 0.2)
        XCTAssertEqual(Double(further[0]), 1 / (M_E * M_E), accuracy: 0.01)
    }

    /// **The property a dropped frame depends on**: the fall is computed from
    /// elapsed time, so one long gap decays the same as several short ones.
    /// Without this a stuttering transport would leave bars hanging.
    func testDecayDependsOnElapsedTimeNotFrameCount() {
        var oneStep = LevelSmoother(bandCount: 1, releaseTime: 0.2)
        _ = oneStep.update(with: [1], elapsed: 0)
        let afterOneLongGap = oneStep.update(with: [0], elapsed: 0.3)

        var manySteps = LevelSmoother(bandCount: 1, releaseTime: 0.2)
        _ = manySteps.update(with: [1], elapsed: 0)
        var last: Float = 0
        for _ in 0..<3 { last = manySteps.update(with: [0], elapsed: 0.1)[0] }

        XCTAssertEqual(Double(afterOneLongGap[0]), Double(last), accuracy: 0.001)
    }

    func testSmootherNeverGoesNegativeOrExceedsItsInput() {
        var smoother = LevelSmoother(bandCount: 2)
        for _ in 0..<50 {
            let levels = smoother.update(with: [0.4, 0], elapsed: 1.0 / 15)
            XCTAssertTrue(levels.allSatisfy { $0 >= 0 && $0 <= 0.4 }, "\(levels)")
        }
    }

    // MARK: - Pink-noise equalisation

    /// **Spectrally exact** pink noise: one sinusoid per FFT bin with amplitude
    /// proportional to `f^-1/2` and a random phase.
    ///
    /// Deliberately not the Voss-McCartney generator the simulator uses. Voss is
    /// cheap and looks pink, but it deviates from a true `1/f` slope at both
    /// ends of the range — so a flatness test fed by it measures the
    /// *generator's* error as much as the equaliser's. Synthesising bin by bin
    /// makes the input pink by construction, which is the only way this test is
    /// a statement about the equalisation.
    ///
    /// Being exactly periodic in the analysis window also means no spectral
    /// leakage, so no averaging over many windows is needed.
    private func exactPinkNoise(seed: UInt64) -> [Float] {
        let count = SpectrumAnalyzer.windowSize
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func nextPhase() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53) * 2 * .pi
        }

        var output = [Double](repeating: 0, count: count)
        for bin in 1..<(count / 2) {
            // Power ∝ 1/f means amplitude ∝ f^-1/2; bin index is proportional
            // to frequency, so the bin number serves directly.
            let amplitude = 1 / sqrt(Double(bin))
            let phase = nextPhase()
            let step = 2 * Double.pi * Double(bin) / Double(count)
            for sample in 0..<count {
                output[sample] += amplitude * sin(step * Double(sample) + phase)
            }
        }
        // Normalise to a sane peak so the numbers resemble real audio.
        let peak = output.map(abs).max() ?? 1
        let scale = peak > 0 ? 0.5 / peak : 1
        return output.map { Float($0 * scale) }
    }

    /// Average band levels over a few phase seeds.
    private func averagePinkLevels(equalized: Bool, windows: Int = 8) -> [Double] {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000, bandCount: 17, equalized: equalized)
        var totals = [Double](repeating: 0, count: 17)
        for window in 0..<windows {
            let levels = analyzer.levels(from: exactPinkNoise(seed: UInt64(window + 1)))
            for band in 0..<17 { totals[band] += Double(levels[band]) }
        }
        return totals.map { $0 / Double(windows) }
    }

    /// **The property the equalisation exists for: pink noise makes a flat
    /// board.** Music is roughly pink, so without this the bottom columns pin
    /// and the top of the board stays dark whatever the gain — which is exactly
    /// what the first live test reported.
    func testPinkNoiseProducesAFlatBarProfile() {
        let levels = averagePinkLevels(equalized: true)
        let mean = levels.reduce(0, +) / Double(levels.count)
        XCTAssertGreaterThan(mean, 0)

        // Measured: spread 0.27, tallest band 1.30x the shortest. The residual
        // is not an error in the weights — it is the Hann window spreading each
        // synthesised bin across its neighbours, which the narrow low bands feel
        // most because they span the fewest bins. On a five-row column a 1.3x
        // difference is well under one row, so the board reads as flat.
        let spread = (levels.max()! - levels.min()!) / mean
        XCTAssertLessThan(spread, 0.4,
                          "pink noise should light the board evenly; got \(levels)")
        XCTAssertLessThan(levels.max()! / levels.min()!, 1.45)
    }

    /// The same measurement without equalisation, to show the fix is doing the
    /// work rather than the signal being flat to begin with.
    func testUnequalizedPinkNoiseIsStronglyBassHeavy() {
        let levels = averagePinkLevels(equalized: false)
        let mean = levels.reduce(0, +) / Double(levels.count)
        // Measured: the lowest band sits 21x the highest — the "energy clusters
        // in the corners, board stays dark" the first live test reported.
        let spread = (levels.max()! - levels.min()!) / mean
        XCTAssertGreaterThan(spread, 2.5,
                             "unequalised pink noise should be visibly bass-heavy")
        XCTAssertGreaterThan(levels.max()! / levels.min()!, 10)
        // And it is the low bands that dominate, not some arbitrary band.
        XCTAssertEqual(levels.firstIndex(of: levels.max()!), 0)
    }

    /// The weights are normalised so equalisation changes the shape of the
    /// display without moving its overall level — a sensitivity that worked
    /// before still works.
    func testEqualizationPreservesOverallLevel() {
        let ranges = SpectrumAnalyzer.bandBinRanges(sampleRate: 48_000, bandCount: 17)
        let weights = SpectrumAnalyzer.pinkEqualization(for: ranges, sampleRate: 48_000)
        XCTAssertEqual(weights.count, 17)
        let logSum = weights.reduce(Float(0)) { $0 + log($1) }
        XCTAssertEqual(Double(exp(logSum / Float(weights.count))), 1.0, accuracy: 0.001)
        // Higher bands are boosted, lower ones cut — the shape of a pink tilt.
        XCTAssertLessThan(weights.first!, 1)
        XCTAssertGreaterThan(weights.last!, 1)
        XCTAssertEqual(weights, weights.sorted())
    }

    // MARK: - Source-relative levelling

    private func pipeline(gateMarginDB: Double = VisualizerPipeline.defaultGateMarginDB,
                          sensitivity: Double = 1,
                          autoGain: Bool = true,
                          bandCount: Int = 3) -> VisualizerPipeline {
        VisualizerPipeline(sampleRate: 48_000, bandCount: bandCount,
                           tuning: .init(sensitivity: sensitivity,
                                         autoGain: autoGain,
                                         gateMarginDB: gateMarginDB,
                                         equalization: true))
    }

    /// Runs a constant input for `seconds` and returns the final bar heights.
    private func settle(_ pipeline: VisualizerPipeline,
                        levels: [Float],
                        seconds: Double,
                        fps: Double = 15) -> [Float] {
        var heights = [Float]()
        for _ in 0..<Int(seconds * fps) {
            heights = pipeline.advance(levels: levels, elapsed: 1 / fps)
        }
        return heights
    }

    /// **The defect that made the microphone useless.** Live mic input runs
    /// roughly 40 dB below file audio, and the first tuning pass gated on
    /// absolute dBFS measured against files — so everything was swallowed. The
    /// levelling is now relative to the source's own floor, and the same quiet
    /// input has to fill the board.
    func testAVeryQuietSourceStillFillsTheBoard() {
        let pipeline = self.pipeline()
        // A mic-like signal: a noise floor around -60 dBFS with content ~20 dB
        // above it — nowhere near full scale.
        let floor: Float = 0.001
        let content: Float = 0.01

        _ = settle(pipeline, levels: [floor, floor, floor], seconds: 2)
        let heights = settle(pipeline, levels: [content, content, content], seconds: 2)

        XCTAssertTrue(heights.allSatisfy { $0 > 0.5 },
                      "a quiet source should still reach useful bar heights; got \(heights)")
    }

    /// And the same defaults must not blow up on a loud one.
    func testAFullScaleSourceIsNotPermanentlyPinned() {
        let pipeline = self.pipeline()
        _ = settle(pipeline, levels: [0.5, 0.5, 0.5], seconds: 2)
        // A quieter passage after loud material must visibly drop rather than
        // staying at full.
        let quieter = settle(pipeline, levels: [0.05, 0.05, 0.05], seconds: 1)
        XCTAssertTrue(quieter.allSatisfy { $0 < 0.9 }, "\(quieter)")
    }

    /// Two sources ~34 dB apart should end up looking the same, which is the
    /// whole point of normalising to the source rather than to full scale.
    func testQuietAndLoudSourcesConvergeToSimilarHeights() {
        let quiet = self.pipeline()
        let loud = self.pipeline()

        _ = settle(quiet, levels: [0.001, 0.001, 0.001], seconds: 2)
        _ = settle(loud, levels: [0.05, 0.05, 0.05], seconds: 2)

        let quietHeights = settle(quiet, levels: [0.02, 0.02, 0.02], seconds: 3)
        let loudHeights = settle(loud, levels: [1.0, 1.0, 1.0], seconds: 3)

        XCTAssertEqual(Double(quietHeights[0]), Double(loudHeights[0]), accuracy: 0.1,
                       "a 34 dB level difference should not change the display")
    }

    /// **Where scale-independence deliberately stops.** A purely relative system
    /// cannot tell a silent room from music played very quietly, so it would
    /// happily amplify hiss to full height. ``LoudnessReference/minimumReference``
    /// is the absolute floor that prevents it — and the price is that sources
    /// below it are *not* normalised up to match louder ones.
    func testSourcesBelowTheReferenceFloorAreNotAmplifiedToMatch() {
        let veryQuiet = self.pipeline()
        _ = settle(veryQuiet, levels: [0.00001, 0.00001, 0.00001], seconds: 2)
        // Excess far below the minimum reference.
        let heights = settle(veryQuiet, levels: [0.0002, 0.0002, 0.0002], seconds: 3)
        XCTAssertTrue(heights.allSatisfy { $0 < 0.3 },
                      "near-silence must not be normalised up to fill the board; got \(heights)")
    }

    /// A source that is only its own noise floor stays dark, whatever that
    /// floor's absolute level is.
    func testSteadyNoiseIsGatedOnceTheFloorConverges() {
        for floor: Float in [0.00001, 0.001, 0.05] {
            let pipeline = self.pipeline()
            let heights = settle(pipeline, levels: [floor, floor, floor], seconds: 4)
            XCTAssertEqual(heights, [0, 0, 0],
                           "a steady floor of \(floor) should be gated away")
        }
    }

    /// Digital silence never divides by a zero floor.
    func testDigitalSilenceIsDarkAndFinite() {
        let pipeline = self.pipeline()
        let heights = settle(pipeline, levels: [0, 0, 0], seconds: 3)
        XCTAssertEqual(heights, [0, 0, 0])
        XCTAssertTrue(heights.allSatisfy { $0.isFinite })
    }

    /// Content well above the floor opens the gate.
    func testContentAboveTheMarginOpensTheGate() {
        let pipeline = self.pipeline(gateMarginDB: 9)
        _ = settle(pipeline, levels: [0.001, 0.001, 0.001], seconds: 2)
        // +20 dB over the floor is comfortably past a 9 dB margin.
        let heights = pipeline.advance(levels: [0.01, 0.01, 0.01], elapsed: 1.0 / 15)
        XCTAssertTrue(heights.allSatisfy { $0 > 0 }, "\(heights)")
    }

    /// **Hysteresis**: a band hovering at the margin must not chatter open and
    /// shut once per frame, which is the flicker the gate exists to remove.
    func testTheGateDoesNotChatterAtTheMargin() {
        let pipeline = self.pipeline(gateMarginDB: 9, bandCount: 1)
        let floor: Float = 0.001
        _ = settle(pipeline, levels: [floor], seconds: 3)

        // Sit just under the opening ratio: it must never open.
        let justUnder = floor * Float(pow(10.0, 8.0 / 20.0))
        var opened = 0
        for _ in 0..<40 {
            let heights = pipeline.advance(levels: [justUnder], elapsed: 1.0 / 15)
            if heights[0] > 0 { opened += 1 }
        }
        XCTAssertEqual(opened, 0, "the gate opened below its margin")
    }

    /// The gate can be disabled, which is what ``Tuning/preTuning`` does.
    ///
    /// Driven with a *varying* signal on purpose: the floor tracks a constant
    /// input exactly, so a constant leaves no excess and lights nothing whether
    /// the gate is on or off.
    func testTheGateCanBeDisabled() {
        let gated = self.pipeline(gateMarginDB: 40)
        let ungated = VisualizerPipeline(sampleRate: 48_000, bandCount: 3,
                                         tuning: .preTuning)
        var gatedLit = false
        var ungatedLit = false
        for step in 0..<60 {
            // Quiet floor with small bumps: under a 40 dB margin the gate keeps
            // these out, and with no gate at all they get through.
            let level: Float = step.isMultiple(of: 3) ? 0.0015 : 0.001
            gatedLit = gatedLit || gated.advance(levels: [level, level, level],
                                                 elapsed: 1.0 / 15).contains { $0 > 0 }
            ungatedLit = ungatedLit || ungated.advance(levels: [level, level, level],
                                                       elapsed: 1.0 / 15).contains { $0 > 0 }
        }
        XCTAssertFalse(gatedLit, "a 40 dB margin should reject a 3.5 dB bump")
        XCTAssertTrue(ungatedLit, "with the gate disabled the same bump should show")
    }

    /// A gated band decays rather than snapping, and still reaches exactly zero.
    func testAGatedBarDecaysToExactlyZero() {
        let pipeline = self.pipeline()
        _ = settle(pipeline, levels: [0.0001, 0.0001, 0.0001], seconds: 2)
        _ = settle(pipeline, levels: [0.05, 0.05, 0.05], seconds: 1)

        let firstAfter = pipeline.advance(levels: [0.0001, 0.0001, 0.0001], elapsed: 1.0 / 15)
        XCTAssertGreaterThan(firstAfter[0], 0, "the bar should fall, not snap")

        let heights = settle(pipeline, levels: [0.0001, 0.0001, 0.0001], seconds: 4)
        XCTAssertEqual(heights, [0, 0, 0], "an exponential tail must still reach zero")
    }

    func testResetClearsDisplayState() {
        let pipeline = self.pipeline()
        _ = settle(pipeline, levels: [0.5, 0.5, 0.5], seconds: 1)
        pipeline.reset()
        let heights = pipeline.advance(levels: [0, 0, 0], elapsed: 1.0 / 15)
        XCTAssertEqual(heights, [0, 0, 0])
    }

    // MARK: - Noise floor tracker

    /// A minimum-follower drops to a new minimum immediately, so a session
    /// converges on the first quiet frame instead of gating everything while it
    /// eases down.
    func testTheFloorDropsImmediatelyToANewMinimum() {
        var tracker = NoiseFloorTracker(bandCount: 1)
        _ = tracker.update(with: [1.0], elapsed: 0)
        let floor = tracker.update(with: [0.01], elapsed: 1.0 / 15)[0]
        XCTAssertEqual(floor, 0.01)
    }

    /// And rises slowly, so a sustained note is not mistaken for the floor and
    /// gated away mid-phrase.
    func testTheFloorRisesSlowly() {
        var tracker = NoiseFloorTracker(bandCount: 1)
        _ = tracker.update(with: [0.001], elapsed: 0)
        var floor: Float = 0
        for _ in 0..<30 { floor = tracker.update(with: [0.5], elapsed: 1.0 / 15)[0] }
        XCTAssertLessThan(floor, 0.25, "two seconds of loud audio should not become the floor")
    }

    /// **The invariant**: the floor is a minimum, so it is never above the
    /// signal — otherwise the excess over it goes negative and real audio gets
    /// gated by a floor that walked up past it. An alternating loud/quiet signal
    /// is what breaks a follower that eases downward instead of snapping.
    func testTheFloorNeverExceedsTheSignal() {
        var tracker = NoiseFloorTracker(bandCount: 1)
        for step in 0..<200 {
            let value: Float = step.isMultiple(of: 2) ? 0.02 : 0.9
            let floor = tracker.update(with: [value], elapsed: 1.0 / 15)[0]
            XCTAssertLessThanOrEqual(floor, value, "step \(step)")
        }
    }

    // MARK: - Loudness reference

    /// The reference is a high percentile across bands, not the single peak —
    /// so one band spiking does not rescale the whole board.
    func testTheReferenceIsAPercentileNotThePeak() {
        var loud = [Float](repeating: 0.01, count: 17)
        loud[3] = 1.0
        let percentile = LoudnessReference.percentileValue(of: loud)
        XCTAssertLessThan(percentile, 0.5, "one spike should not define the scale")
        XCTAssertGreaterThan(percentile, 0)
    }

    /// It rises quickly, so a track starting fills the board within a second or
    /// two, and falls slowly, so gaps between phrases do not pump.
    func testTheReferenceRisesFasterThanItFalls() {
        var rising = LoudnessReference()
        let afterRise = rising.update(with: [Float](repeating: 1, count: 3), elapsed: 0.5)
        XCTAssertGreaterThan(afterRise, 0.5, "should reach most of the way up in half a second")

        // Settle a second one at full, then let it fall for the same half second.
        var falling = LoudnessReference()
        for _ in 0..<30 { _ = falling.update(with: [Float](repeating: 1, count: 3),
                                             elapsed: 1.0 / 15) }
        XCTAssertGreaterThan(falling.current, 0.9)
        let afterFall = falling.update(with: [Float](repeating: 0, count: 3), elapsed: 0.5)
        XCTAssertGreaterThan(afterFall, 0.5,
                             "half a second of quiet should barely move the reference")
        XCTAssertLessThan(afterFall, falling.current + 0.001)
    }

    /// Silence cannot drive the reference to zero and the gain to infinity.
    func testTheReferenceHasAFloor() {
        var reference = LoudnessReference()
        var value: Float = 0
        for _ in 0..<200 { value = reference.update(with: [0, 0, 0], elapsed: 1) }
        XCTAssertEqual(value, LoudnessReference.minimumReference)
        XCTAssertTrue(value > 0)
    }

    // MARK: - Source selection    // MARK: - Source selection

    /// System audio is what someone playing music actually wants — it hears the
    /// mix rather than the room — so it wins when it is already granted.
    func testSystemAudioIsPreferredWhenGranted() {
        XCTAssertEqual(preferredAudioSource(systemAudio: .granted, microphone: .granted),
                       .systemAudio)
        XCTAssertEqual(preferredAudioSource(systemAudio: .granted, microphone: .denied),
                       .systemAudio)
        XCTAssertEqual(preferredAudioSource(systemAudio: .granted, microphone: .undetermined),
                       .systemAudio)
    }

    /// **Anything short of granted falls back rather than prompting.** The
    /// permission dialog should follow a deliberate choice in the picker, not
    /// appear because the app launched.
    func testAnUngrantedSystemAudioDoesNotWin() {
        for state: AudioSourceAuthorization in [.denied, .undetermined, .unavailable] {
            XCTAssertEqual(preferredAudioSource(systemAudio: state, microphone: .granted),
                           .microphone, "system audio \(state)")
        }
    }

    /// With neither granted, the microphone is offered because its prompt is
    /// the one users recognise — but only if it can still be asked for.
    func testFallbackWhenNeitherIsGranted() {
        XCTAssertEqual(preferredAudioSource(systemAudio: .undetermined,
                                            microphone: .undetermined), .microphone)
        XCTAssertEqual(preferredAudioSource(systemAudio: .undetermined, microphone: .denied),
                       .systemAudio)
        XCTAssertEqual(preferredAudioSource(systemAudio: .unavailable, microphone: .denied),
                       .microphone)
        XCTAssertEqual(preferredAudioSource(systemAudio: .denied, microphone: .denied),
                       .microphone)
    }

    /// The picker's copy has to name the permission macOS will actually ask
    /// for, or the instruction sends people to the wrong Settings pane.
    func testSourcesNameTheirOwnPermission() {
        XCTAssertEqual(AudioSource.microphone.permissionName, "Microphone")
        XCTAssertEqual(AudioSource.systemAudio.permissionName, "Audio Recording")
        XCTAssertEqual(Set(AudioSource.allCases.map(\.displayName)).count,
                       AudioSource.allCases.count)
        XCTAssertEqual(AudioSource.allCases.count, 2)
    }

    /// Raw values are persisted, so they are API and must not drift.
    func testSourceRawValuesArePersistable() {
        XCTAssertEqual(AudioSource.microphone.rawValue, "microphone")
        XCTAssertEqual(AudioSource.systemAudio.rawValue, "systemAudio")
        for source in AudioSource.allCases {
            XCTAssertEqual(AudioSource(rawValue: source.rawValue), source)
        }
    }

    // MARK: - Auto-gain

    /// A loud peak takes effect at once; the reference then decays slowly, so
    /// the display does not pump between a quiet passage and the next hit.
    func testAutoGainRisesFastAndFallsSlowly() {
        var gain = AutoGain(decayTime: 4)
        let loud = gain.update(observedPeak: 0.5, elapsed: 0)
        XCTAssertEqual(Double(loud), 2, accuracy: 0.001)

        // A moment of quiet barely moves it.
        let soonAfter = gain.update(observedPeak: 0.01, elapsed: 0.1)
        XCTAssertEqual(Double(soonAfter), 2, accuracy: 0.1)

        // Many seconds of quiet do.
        let muchLater = gain.update(observedPeak: 0.01, elapsed: 8)
        XCTAssertGreaterThan(muchLater, soonAfter)
    }

    /// Silence must not drive the gain to infinity, or the first faint sound
    /// blinds the display.
    func testAutoGainHasAFloor() {
        var gain = AutoGain(decayTime: 0.01)
        var multiplier: Float = 0
        for _ in 0..<100 { multiplier = gain.update(observedPeak: 0, elapsed: 1) }
        XCTAssertEqual(Double(multiplier), Double(1 / AutoGain.minimumPeak), accuracy: 0.001)
        XCTAssertTrue(multiplier.isFinite)
    }
}
