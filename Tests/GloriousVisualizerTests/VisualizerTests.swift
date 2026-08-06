import XCTest
@testable import GloriousVisualizer
import GMMKProtocol

/// The visualizer's pure half: which keys form which column, which FFT bins feed
/// which band, and how the source picker chooses.
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
        let column = VisualizerLayout.columns[1]
        let labels = column.levelRows.map { row in
            row.compactMap { GMMKKeyMap.key(forLEDIndex: $0)?.label }
        }
        XCTAssertEqual(labels, [["Left Cmd"], ["Z"], ["A"], ["Q"], ["1"]])
    }

    func testWideKeysSpanTheColumnsTheyCover() {
        let space = GMMKKeyMap.ansiTKL.first { $0.label == "Space" }!.ledIndex
        let columnsWithSpace = VisualizerLayout.columns.enumerated().filter {
            $0.element.levelRows[0].contains(space)
        }
        XCTAssertEqual(columnsWithSpace.count, 7)
        let indices = columnsWithSpace.map(\.offset)
        XCTAssertEqual(indices, Array(indices.first!...indices.last!))
    }

    func testEveryColumnHasAPeakKeyFromTheFunctionRow() {
        let functionRowLEDs = Set((1...13).map(UInt16.init) + [106, 107, 108])
        for (index, column) in VisualizerLayout.columns.enumerated() {
            XCTAssertEqual(column.peakKeys.count, 1, "column \(index)")
            XCTAssertTrue(functionRowLEDs.contains(column.peakKeys[0]),
                          "column \(index) peaks on LED \(column.peakKeys[0])")
        }
        XCTAssertEqual(VisualizerLayout.columns.first?.peakKeys, [1])
        XCTAssertEqual(VisualizerLayout.columns.last?.peakKeys, [108])
    }

    func testNoKeyRepeatsWithinAColumn() {
        for (index, column) in VisualizerLayout.columns.enumerated() {
            let all = column.levelRows.flatMap { $0 }
            XCTAssertEqual(Set(all).count, all.count, "column \(index) repeats a key")
        }
    }

    // MARK: - Bands

    /// The eight bands are log-spaced and named for what they carry, and each is
    /// wider in bins than the one below — the property that keeps bass from
    /// collapsing into one column.
    func testBandsWidenTowardsHigherFrequencies() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        XCTAssertEqual(analyzer.bandBins.count, AnalysisState.bandCount)
        let widths = analyzer.bandBins.map { $0.upper - $0.lower + 1 }
        XCTAssertEqual(widths, widths.sorted(), "band widths should be non-decreasing")
        XCTAssertLessThan(widths.first!, widths.last!)
    }

    /// No band includes bin 0 (DC), none is empty, and they ascend — at every
    /// capture rate the app can be handed.
    func testBandRangesAreWellFormed() {
        for rate: Float in [44_100, 48_000] {
            let analyzer = SpectrumAnalyzer(sampleRate: rate)
            var previousLower = 0
            for (index, range) in analyzer.bandBins.enumerated() {
                XCTAssertGreaterThanOrEqual(range.lower, 1, "band \(index) at \(rate) includes DC")
                XCTAssertLessThanOrEqual(range.lower, range.upper, "band \(index) at \(rate)")
                XCTAssertLessThan(range.upper, SpectrumAnalyzer.windowSize / 2,
                                  "band \(index) at \(rate) runs past Nyquist")
                XCTAssertGreaterThanOrEqual(range.lower, previousLower, "band \(index) at \(rate)")
                previousLower = range.lower
            }
        }
    }

    /// Registers are a *view* of the band set, not a second analysis: every band
    /// appears exactly once across the six display registers.
    func testRegistersCoverEveryBandExactlyOnce() {
        let covered = SpectrumAnalyzer.registerBands.flatMap { Array($0) }
        XCTAssertEqual(covered.sorted(), Array(0..<AnalysisState.bandCount))
        XCTAssertEqual(SpectrumAnalyzer.registerBands.count, AnalysisState.registerCount)
    }

    /// A sine lands in the band whose range contains it, and nowhere else.
    func testASineWaveLandsInTheExpectedBand() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let samples = (0..<SpectrumAnalyzer.windowSize).map { index in
            Float(sin(2 * .pi * 440 * Double(index) / 48_000))
        }
        let magnitudes = analyzer.magnitudes(from: samples)
        let energy = analyzer.bandBins.map { range in
            magnitudes[range.lower...range.upper].reduce(0, +)
        }
        // 440 Hz is in band 3 (250–500 Hz).
        XCTAssertEqual(energy.firstIndex(of: energy.max()!), 3)
    }

    // MARK: - Source selection

    func testSystemAudioIsPreferredWhenGranted() {
        XCTAssertEqual(preferredAudioSource(systemAudio: .granted, microphone: .granted),
                       .systemAudio)
        XCTAssertEqual(preferredAudioSource(systemAudio: .granted, microphone: .denied),
                       .systemAudio)
        XCTAssertEqual(preferredAudioSource(systemAudio: .granted, microphone: .undetermined),
                       .systemAudio)
    }

    /// **Anything short of granted falls back rather than prompting.**
    func testAnUngrantedSystemAudioDoesNotWin() {
        for state: AudioSourceAuthorization in [.denied, .undetermined, .unavailable] {
            XCTAssertEqual(preferredAudioSource(systemAudio: state, microphone: .granted),
                           .microphone, "system audio \(state)")
        }
    }

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

    func testEveryModeIsNamedAndDistinct() {
        XCTAssertEqual(VisualizerMode.allCases.count, 5)
        XCTAssertEqual(Set(VisualizerMode.allCases.map(\.displayName)).count, 5)
        XCTAssertEqual(Set(VisualizerMode.allCases.map(\.summary)).count, 5)
        for mode in VisualizerMode.allCases {
            XCTAssertEqual(VisualizerMode(rawValue: mode.rawValue), mode)
        }
    }
}
