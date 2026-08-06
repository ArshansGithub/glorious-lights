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
