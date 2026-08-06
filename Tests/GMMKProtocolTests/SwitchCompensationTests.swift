import XCTest
@testable import GMMKProtocol

/// The inverse-filter correction, which set of keys it lands on, and the paint
/// it feeds.
final class SwitchCompensationTests: XCTestCase {

    private let orange = RGB(red: 0xFF, green: 0x88, blue: 0x00)

    // MARK: - The correction

    /// Strength 0 is the identity, and it is where the slider starts: opening
    /// the tuner must not change how the board looks.
    func testStrengthZeroLeavesTheColorAlone() {
        for color in [orange, .black, RGB(red: 0x12, green: 0x34, blue: 0x56),
                      RGB(red: 0xFF, green: 0xFF, blue: 0xFF)] {
            XCTAssertEqual(SwitchCompensation.compensate(color, strength: 0), color)
        }
    }

    func testDefaultStrengthIsNoCorrection() {
        XCTAssertEqual(SwitchCompensation.defaultStrength, 0)
        XCTAssertEqual(SwitchCompensation.strengthRange, 0...1)
        XCTAssertTrue(SwitchCompensation.strengthRange.contains(SwitchCompensation.defaultStrength))
    }

    /// r' = r + (255 - r)·s, g' = g·(1 - s), b' = b·(1 - s/2), rounded.
    /// For 80/40/20 at s = 0.5: 80 + 87.5 = 167.5 → 168; 20; 20 × 0.75 = 15.
    func testHalfStrength() {
        XCTAssertEqual(
            SwitchCompensation.compensate(RGB(red: 80, green: 40, blue: 20), strength: 0.5),
            RGB(red: 168, green: 20, blue: 15))
    }

    /// **The case that motivates the model.** With red already at 0xFF there is
    /// no headroom to boost, so the cyan tint can only be cancelled by pulling
    /// green and blue down — and the correction must still do something.
    func testRedAlreadyAtFullStillCorrects() {
        let corrected = SwitchCompensation.compensate(orange, strength: 0.5)
        XCTAssertEqual(corrected.red, 0xFF, "red has nowhere to go and must stay put")
        XCTAssertEqual(corrected.green, 68, "136 × 0.5")
        XCTAssertNotEqual(corrected, orange, "the correction must not be a no-op here")

        // Same with blue in play: b = 200 at s = 0.5 → 200 × 0.75 = 150.
        let warm = RGB(red: 0xFF, green: 0x40, blue: 200)
        let correctedWarm = SwitchCompensation.compensate(warm, strength: 0.5)
        XCTAssertEqual(correctedWarm, RGB(red: 0xFF, green: 32, blue: 150))
    }

    /// Full strength: red to 255, green to nothing, blue halved.
    func testFullStrength() {
        XCTAssertEqual(SwitchCompensation.compensate(orange, strength: 1),
                       RGB(red: 0xFF, green: 0x00, blue: 0x00))
        XCTAssertEqual(SwitchCompensation.compensate(RGB(red: 0, green: 200, blue: 200),
                                                     strength: 1),
                       RGB(red: 255, green: 0, blue: 100))
    }

    /// Blue is pulled down half as hard as green — the one asymmetry.
    func testBlueIsCutAtHalfRate() {
        XCTAssertEqual(SwitchCompensation.blueStrengthFactor, 0.5)
        let cyan = RGB(red: 0x00, green: 0xC8, blue: 0xC8)
        let corrected = SwitchCompensation.compensate(cyan, strength: 0.5)
        XCTAssertEqual(corrected.green, 100)     // 200 × 0.5
        XCTAssertEqual(corrected.blue, 150)      // 200 × 0.75
    }

    /// Rounding is to nearest, not truncation.
    func testRoundingIsToNearest() {
        // red 0 + 255 × 0.5 = 127.5 → 128; green 1 × 0.5 = 0.5 → 1;
        // blue 3 × 0.75 = 2.25 → 2.
        XCTAssertEqual(SwitchCompensation.compensate(RGB(red: 0, green: 1, blue: 3),
                                                     strength: 0.5),
                       RGB(red: 128, green: 1, blue: 2))
    }

    /// No channel can overflow or underflow, at any strength.
    func testChannelsStayInRange() {
        let extremes = [RGB(red: 255, green: 255, blue: 255), .black,
                        RGB(red: 254, green: 1, blue: 1)]
        for step in 0...20 {
            let s = Double(step) / 20.0
            for color in extremes {
                let c = SwitchCompensation.compensate(color, strength: s)
                XCTAssertTrue((0...255).contains(Int(c.red)))
                XCTAssertTrue((0...255).contains(Int(c.green)))
                XCTAssertTrue((0...255).contains(Int(c.blue)))
            }
        }
        XCTAssertEqual(SwitchCompensation.compensate(RGB(red: 255, green: 255, blue: 255),
                                                     strength: 1),
                       RGB(red: 255, green: 0, blue: 128))
    }

    /// Out-of-range strengths clamp rather than producing nonsense. Negative
    /// values are a leftover from the bidirectional experiment and must read as
    /// "no correction", not as an inverted one.
    func testStrengthIsClamped() {
        XCTAssertEqual(SwitchCompensation.compensate(orange, strength: 42),
                       SwitchCompensation.compensate(orange, strength: 1))
        XCTAssertEqual(SwitchCompensation.compensate(orange, strength: -0.5), orange)
    }

    // MARK: - Which keys get corrected

    /// The default case: the user marked their few clear switches, so the
    /// *unmarked* majority is tinted and is what gets corrected. The marked keys
    /// show the target colour untouched.
    func testMarkedTrueColorKeysAreLeftAloneAndTheRestCorrected() {
        let marked: Set<UInt16> = [1, 89]
        let corrected = SwitchCompensation.compensate(orange, strength: 0.5)

        for index: UInt16 in [1, 89] {
            XCTAssertEqual(SwitchCompensation.color(forLEDIndex: index, target: orange,
                                                    markedLEDIndices: marked,
                                                    markedSwitches: .trueColor,
                                                    strength: 0.5),
                           orange, "marked true-colour key \(index)")
        }
        for index: UInt16 in [2, 52, 126] {
            XCTAssertEqual(SwitchCompensation.color(forLEDIndex: index, target: orange,
                                                    markedLEDIndices: marked,
                                                    markedSwitches: .trueColor,
                                                    strength: 0.5),
                           corrected, "unmarked tinted key \(index)")
        }
    }

    /// The other way round, for a board whose minority is the tinted switches.
    func testMarkedTintedKeysAreTheOnesCorrected() {
        let marked: Set<UInt16> = [1, 89]
        let corrected = SwitchCompensation.compensate(orange, strength: 0.5)

        for index: UInt16 in [1, 89] {
            XCTAssertEqual(SwitchCompensation.color(forLEDIndex: index, target: orange,
                                                    markedLEDIndices: marked,
                                                    markedSwitches: .tinted,
                                                    strength: 0.5),
                           corrected, "marked tinted key \(index)")
        }
        XCTAssertEqual(SwitchCompensation.color(forLEDIndex: 2, target: orange,
                                                markedLEDIndices: marked,
                                                markedSwitches: .tinted,
                                                strength: 0.5),
                       orange)
    }

    /// The two settings are exact complements of each other.
    func testTheTwoSettingsAreComplements() {
        let marked: Set<UInt16> = [1, 52, 89]
        for index in GMMKKeyMap.paintableLEDIndices {
            XCTAssertNotEqual(
                SwitchCompensation.needsCorrection(ledIndex: index,
                                                   markedLEDIndices: marked,
                                                   markedSwitches: .trueColor),
                SwitchCompensation.needsCorrection(ledIndex: index,
                                                   markedLEDIndices: marked,
                                                   markedSwitches: .tinted),
                "index \(index)")
        }
    }

    // MARK: - Whole-board colours

    /// Nothing marked, marked-are-true-colour: the whole board is tinted, so the
    /// whole board is corrected.
    func testNothingMarkedCorrectsEverything() {
        let colors = SwitchCompensation.uniformColors(target: orange,
                                                      markedLEDIndices: [],
                                                      markedSwitches: .trueColor,
                                                      strength: 0.5)
        XCTAssertEqual(colors.count, GMMKKeyMap.paintableLEDIndices.count)
        XCTAssertTrue(colors.allSatisfy { $0 == SwitchCompensation.compensate(orange,
                                                                              strength: 0.5) })
    }

    /// Nothing marked, marked-are-tinted: nothing is tinted, so nothing changes.
    func testNothingMarkedAsTintedCorrectsNothing() {
        let colors = SwitchCompensation.uniformColors(target: orange,
                                                      markedLEDIndices: [],
                                                      markedSwitches: .tinted,
                                                      strength: 0.5)
        XCTAssertTrue(colors.allSatisfy { $0 == orange })
    }

    /// The array is index-ordered from ``GMMKKeyMap/minLEDIndex``, so LED `n`
    /// sits at offset `n - 1`.
    func testUniformColorsAreIndexOrdered() {
        let esc = GMMKKeyMap.ansiTKL.first { $0.label == "Esc" }!
        let space = GMMKKeyMap.ansiTKL.first { $0.label == "Space" }!
        let colors = SwitchCompensation.uniformColors(target: orange,
                                                      markedLEDIndices: [space.ledIndex],
                                                      markedSwitches: .trueColor,
                                                      strength: 0.5)
        XCTAssertEqual(colors[Int(space.ledIndex - GMMKKeyMap.minLEDIndex)], orange)
        XCTAssertEqual(colors[Int(esc.ledIndex - GMMKKeyMap.minLEDIndex)],
                       SwitchCompensation.compensate(orange, strength: 0.5))
        XCTAssertEqual(colors.filter { $0 == orange }.count, 1)
    }

    // MARK: - Red-heaviness score

    /// redFraction = r / (r + g + b).
    func testRedFraction() {
        XCTAssertEqual(SwitchCompensation.redFraction(RGB(red: 255, green: 0, blue: 0)), 1.0)
        XCTAssertEqual(SwitchCompensation.redFraction(RGB(red: 0, green: 255, blue: 0)), 0.0)
        XCTAssertEqual(SwitchCompensation.redFraction(RGB(red: 100, green: 100, blue: 100)),
                       1.0 / 3.0, accuracy: 1e-12)
        // ff8800: 255 / (255 + 136) = 0.652…
        XCTAssertEqual(SwitchCompensation.redFraction(orange), 255.0 / 391.0, accuracy: 1e-12)
    }

    /// Black has no drive at all; the score must not divide by zero.
    func testRedFractionOfBlackIsZero() {
        XCTAssertEqual(SwitchCompensation.redFraction(.black), 0)
        XCTAssertFalse(SwitchCompensation.isRedHeavy(.black))
    }

    func testRedHeavyThreshold() {
        XCTAssertEqual(SwitchCompensation.redHeavyThreshold, 0.45)
        // Warm colours trip it.
        XCTAssertTrue(SwitchCompensation.isRedHeavy(orange))
        XCTAssertTrue(SwitchCompensation.isRedHeavy(RGB(red: 255, green: 0, blue: 0)))
        XCTAssertTrue(SwitchCompensation.isRedHeavy(RGB(red: 200, green: 100, blue: 100)))
        // Neutral and cool ones do not.
        XCTAssertFalse(SwitchCompensation.isRedHeavy(RGB(red: 255, green: 255, blue: 255)))
        XCTAssertFalse(SwitchCompensation.isRedHeavy(RGB(red: 0, green: 200, blue: 255)))
    }

    /// The comparison is strictly greater-than, so a colour sitting exactly on
    /// the threshold is not flagged.
    func testExactlyAtTheThresholdIsNotRedHeavy() {
        // 45 / (45 + 30 + 25) = 0.45 exactly.
        let onTheLine = RGB(red: 45, green: 30, blue: 25)
        XCTAssertEqual(SwitchCompensation.redFraction(onTheLine), 0.45, accuracy: 1e-12)
        XCTAssertFalse(SwitchCompensation.isRedHeavy(onTheLine))
    }

    // MARK: - Switch-friendly palette

    /// The point of the palette: every swatch is green/blue-dominant enough
    /// that both housings render it about the same.
    func testEverySwatchIsSwitchFriendly() {
        XCTAssertFalse(SwitchFriendlyPalette.swatches.isEmpty)
        for swatch in SwitchFriendlyPalette.swatches {
            let fraction = SwitchCompensation.redFraction(swatch.color)
            XCTAssertLessThanOrEqual(fraction, SwitchFriendlyPalette.maxRedFraction,
                                     "\(swatch.name) (#\(swatch.color.hexString)) is too red")
            XCTAssertFalse(SwitchCompensation.isRedHeavy(swatch.color), swatch.name)
        }
    }

    /// The ceiling has to sit below the point where a colour is called out as
    /// red-heavy, or the palette could recommend a colour the UI warns about.
    func testPaletteCeilingIsBelowTheRedHeavyThreshold() {
        XCTAssertLessThan(SwitchFriendlyPalette.maxRedFraction,
                          SwitchCompensation.redHeavyThreshold)
    }

    func testSwatchesAreDistinctAndNamed() {
        let names = SwitchFriendlyPalette.swatches.map(\.name)
        let colors = SwitchFriendlyPalette.swatches.map(\.color)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(colors).count, colors.count)
        XCTAssertFalse(names.contains(""))
        XCTAssertEqual(SwitchFriendlyPalette.swatches.count, 8)
    }

    /// Spot-check that the hex literals parsed into the bytes they name.
    func testSwatchHexParsing() {
        let mint = SwitchFriendlyPalette.swatches.first { $0.name == "Mint" }
        XCTAssertEqual(mint?.color, RGB(red: 0x66, green: 0xFF, blue: 0xAA))
        let indigo = SwitchFriendlyPalette.swatches.first { $0.name == "Indigo" }
        XCTAssertEqual(indigo?.color, RGB(red: 0x55, green: 0x33, blue: 0xFF))
    }

    // MARK: - Transactions

    /// 126 LEDs → 7 full packets of 18, plus mode-custom at three profiles,
    /// plus START and END.
    func testPaintUniformPacketShape() {
        let packets = GMMKTransaction.paintUniform(orange)
        XCTAssertEqual(packets.count, 1 + 3 + 7 + 1)
        XCTAssertEqual(packets.first, GMMKPacket.start())
        XCTAssertEqual(packets.last, GMMKPacket.end())
        XCTAssertEqual(Array(packets[1...3]),
                       GMMKPacket.atEveryProfile { GMMKPacket.setMode(.custom, profileBase: $0) })
        for packet in packets[4...10] {
            XCTAssertEqual(packet[2], GMMKPacket.Command.writeCustomColors)
            XCTAssertEqual(packet[3], 0x36)     // 18 keys × 3 bytes
        }
        XCTAssertEqual(packets[4][4], 0x03)     // first address = index 1 × 3
    }

    /// At strength 0 the paint is uniform whatever is marked and whichever way
    /// the toggle is set.
    func testZeroStrengthPaintsTheTargetEverywhere() {
        for markedSwitches in SwitchCompensation.MarkedSwitches.allCases {
            XCTAssertEqual(GMMKTransaction.paintCompensated(target: orange,
                                                            markedLEDIndices: [1, 52, 89],
                                                            markedSwitches: markedSwitches,
                                                            strength: 0),
                           GMMKTransaction.paintUniform(orange),
                           "\(markedSwitches)")
        }
    }

    /// Marking one true-colour key leaves exactly that LED's triplet at the
    /// target while every other LED is corrected.
    func testPaintCompensatedCorrectsTheComplementOfTheMarkedSet() {
        let corrected = SwitchCompensation.compensate(orange, strength: 1)
        let packets = GMMKTransaction.paintCompensated(target: orange,
                                                       markedLEDIndices: [1],
                                                       markedSwitches: .trueColor,
                                                       strength: 1)
        // LED 1 is the first triplet of the first colour packet; LED 2 the
        // second. Data starts at payload offset 7.
        XCTAssertEqual(Array(packets[4][7..<10]), [orange.red, orange.green, orange.blue])
        XCTAssertEqual(Array(packets[4][10..<13]),
                       [corrected.red, corrected.green, corrected.blue])
    }

    /// The same marked set with the toggle flipped swaps which LEDs move.
    func testFlippingTheToggleSwapsTheCorrectedSet() {
        let corrected = SwitchCompensation.compensate(orange, strength: 1)
        let asTinted = GMMKTransaction.paintCompensated(target: orange,
                                                        markedLEDIndices: [1],
                                                        markedSwitches: .tinted,
                                                        strength: 1)
        XCTAssertEqual(Array(asTinted[4][7..<10]),
                       [corrected.red, corrected.green, corrected.blue])
        XCTAssertEqual(Array(asTinted[4][10..<13]), [orange.red, orange.green, orange.blue])
    }

    /// A single-key paint is one bracketed `0x11` write and nothing else — no
    /// mode packets, so it cannot disturb a board already in custom mode.
    func testPaintKeyIsOneWrite() {
        let packets = GMMKTransaction.paintKey(ledIndex: 106, color: .black)
        XCTAssertEqual(packets, [
            GMMKPacket.start(),
            GMMKPacket.setCustomColors(startKeyIndex: 106, colors: [.black]),
            GMMKPacket.end(),
        ])
        XCTAssertEqual(packets[1][4], 0x3E)     // address 106 × 3 = 0x013E
        XCTAssertEqual(packets[1][5], 0x01)
    }
}
