import XCTest
@testable import GMMKProtocol

/// The compensation curve, and the paint it feeds.
final class SwitchCompensationTests: XCTestCase {

    private let orange = RGB(red: 0xFF, green: 0x88, blue: 0x00)

    // MARK: - The curve

    /// Strength 0 is the identity: nothing is compensated.
    func testStrengthZeroLeavesTheColorAlone() {
        for color in [orange, .black, RGB(red: 0x12, green: 0x34, blue: 0x56)] {
            XCTAssertEqual(SwitchCompensation.compensate(color, strength: 0), color)
        }
    }

    /// Strength 1 pushes red to full and green and blue to nothing.
    func testStrengthOneIsPureRed() {
        XCTAssertEqual(SwitchCompensation.compensate(orange, strength: 1),
                       RGB(red: 0xFF, green: 0x00, blue: 0x00))
        XCTAssertEqual(SwitchCompensation.compensate(.black, strength: 1),
                       RGB(red: 0xFF, green: 0x00, blue: 0x00))
    }

    /// r' = r + (255 - r)·s, g' = g·(1 - s), b' = b·(1 - s), rounded.
    /// For 80/40/20 at s = 0.5: 80 + 87.5 = 167.5 → 168; 20; 10.
    func testHalfStrength() {
        XCTAssertEqual(
            SwitchCompensation.compensate(RGB(red: 80, green: 40, blue: 20), strength: 0.5),
            RGB(red: 168, green: 20, blue: 10))
    }

    /// ff8800 at s = 0.25: red is already full, green 136 × 0.75 = 102.
    func testQuarterStrengthOnOrange() {
        XCTAssertEqual(SwitchCompensation.compensate(orange, strength: 0.25),
                       RGB(red: 0xFF, green: 102, blue: 0))
    }

    /// Rounding is to nearest, not truncation: 1 × 0.5 = 0.5 → 1.
    func testRoundingIsToNearest() {
        XCTAssertEqual(SwitchCompensation.compensate(RGB(red: 0, green: 1, blue: 3),
                                                     strength: 0.5),
                       RGB(red: 128, green: 1, blue: 2))   // 127.5 → 128, 1.5 → 2
    }

    /// Red can only approach 255, never overflow it, and no channel underflows.
    func testChannelsStayInRange() {
        for step in 0...20 {
            let s = Double(step) / 20.0
            let c = SwitchCompensation.compensate(RGB(red: 254, green: 1, blue: 1), strength: s)
            XCTAssertGreaterThanOrEqual(c.red, 254)
        }
        XCTAssertEqual(SwitchCompensation.compensate(RGB(red: 255, green: 255, blue: 255),
                                                     strength: 1),
                       RGB(red: 255, green: 0, blue: 0))
    }

    /// Out-of-range strengths clamp rather than producing nonsense.
    func testStrengthIsClamped() {
        XCTAssertEqual(SwitchCompensation.compensate(orange, strength: -3),
                       SwitchCompensation.compensate(orange, strength: 0))
        XCTAssertEqual(SwitchCompensation.compensate(orange, strength: 42),
                       SwitchCompensation.compensate(orange, strength: 1))
    }

    func testDefaultStrengthIsInRange() {
        XCTAssertEqual(SwitchCompensation.defaultStrength, 0.5)
        XCTAssertTrue(SwitchCompensation.strengthRange.contains(SwitchCompensation.defaultStrength))
    }

    // MARK: - Per-LED selection

    func testOnlyMarkedIndicesAreCompensated() {
        let lynx: Set<UInt16> = [1, 89]
        for index: UInt16 in [1, 89] {
            XCTAssertEqual(SwitchCompensation.color(forLEDIndex: index, target: orange,
                                                    lynxLEDIndices: lynx, strength: 0.5),
                           SwitchCompensation.compensate(orange, strength: 0.5))
        }
        XCTAssertEqual(SwitchCompensation.color(forLEDIndex: 2, target: orange,
                                                lynxLEDIndices: lynx, strength: 0.5),
                       orange)
    }

    // MARK: - Whole-board colours

    func testUniformColorsCoverThePaintableRange() {
        let colors = SwitchCompensation.uniformColors(target: orange,
                                                      lynxLEDIndices: [],
                                                      strength: 0.5)
        XCTAssertEqual(colors.count, GMMKKeyMap.paintableLEDIndices.count)
        XCTAssertTrue(colors.allSatisfy { $0 == orange })
    }

    /// The array is index-ordered from ``GMMKKeyMap/minLEDIndex``, so LED `n`
    /// sits at offset `n - 1`.
    func testUniformColorsAreIndexOrdered() {
        let esc = GMMKKeyMap.ansiTKL.first { $0.label == "Esc" }!
        let space = GMMKKeyMap.ansiTKL.first { $0.label == "Space" }!
        let colors = SwitchCompensation.uniformColors(target: orange,
                                                      lynxLEDIndices: [space.ledIndex],
                                                      strength: 0.5)
        let compensated = SwitchCompensation.compensate(orange, strength: 0.5)
        XCTAssertEqual(colors[Int(space.ledIndex - GMMKKeyMap.minLEDIndex)], compensated)
        XCTAssertEqual(colors[Int(esc.ledIndex - GMMKKeyMap.minLEDIndex)], orange)
        XCTAssertEqual(colors.filter { $0 == compensated }.count, 1)
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

    func testPaintCompensatedMatchesUniformWhenNothingIsMarked() {
        XCTAssertEqual(GMMKTransaction.paintCompensated(target: orange,
                                                        lynxLEDIndices: [],
                                                        strength: 0.75),
                       GMMKTransaction.paintUniform(orange))
    }

    /// Marking one key changes exactly the three bytes of that LED's triplet.
    func testPaintCompensatedChangesOnlyMarkedKeys() {
        let plain = GMMKTransaction.paintUniform(orange)
        let marked = GMMKTransaction.paintCompensated(target: orange,
                                                      lynxLEDIndices: [1],
                                                      strength: 1)
        XCTAssertEqual(plain.count, marked.count)
        let differing = zip(plain, marked).filter { $0 != $1 }
        XCTAssertEqual(differing.count, 1)
        // LED 1 is the first triplet of the first colour packet: data starts at
        // payload offset 7.
        XCTAssertEqual(Array(marked[4][7..<10]), [0xFF, 0x00, 0x00])
        XCTAssertEqual(Array(plain[4][7..<10]), [0xFF, 0x88, 0x00])
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
