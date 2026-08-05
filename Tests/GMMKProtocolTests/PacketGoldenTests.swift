import XCTest
@testable import GMMKProtocol

/// Golden-byte tests. Every expectation is the byte-exact packet from
/// `docs/protocol.md`, with the leading `0x04` report-ID byte stripped (see
/// `GMMKPacket`'s payload convention) and zero-padded to 63 bytes.
///
/// Checksums are re-derived by hand in the comment above each case:
/// `sum(wire bytes 3…63) mod 2^16`, stored little-endian at payload bytes 0–1.
final class PacketGoldenTests: XCTestCase {

    /// Zero-pads a prefix to the full 63-byte payload length.
    private func payload(_ prefix: [UInt8]) -> [UInt8] {
        XCTAssertLessThanOrEqual(prefix.count, GMMKPacket.payloadLength)
        return prefix + [UInt8](repeating: 0, count: GMMKPacket.payloadLength - prefix.count)
    }

    // MARK: - Framing invariants

    func testPayloadLengthIsAlways63() {
        XCTAssertEqual(GMMKPacket.start().count, 63)
        XCTAssertEqual(GMMKPacket.end().count, 63)
        XCTAssertEqual(GMMKPacket.setMode(.fixed).count, 63)
        XCTAssertEqual(GMMKPacket.setColor(red: 1, green: 2, blue: 3).count, 63)
        XCTAssertEqual(
            GMMKPacket.setCustomColors(
                startKeyIndex: 1,
                colors: Array(repeating: RGB(red: 1, green: 2, blue: 3), count: 18)).count,
            63)
    }

    func testReportIDIsFour() {
        XCTAssertEqual(GMMKPacket.reportID, 0x04)
    }

    // MARK: - Checksum

    /// The checksum covers wire bytes 3…63 == payload bytes 2…62, i.e. every
    /// byte after the checksum field including the zero padding.
    func testChecksumCoversEverythingAfterTheChecksumField() {
        var body = [UInt8](repeating: 0, count: 61)
        body[0] = 0x06   // command
        body[1] = 0x01   // count
        body[5] = 0x7F   // a data byte
        // 0x06 + 0x01 + 0x7F = 0x86
        XCTAssertEqual(GMMKPacket.checksum(payloadBody: body[...]), 0x0086)
    }

    /// Plain 16-bit sum: no carry folding and no complement. The maximum a
    /// 61-byte body can reach is 61 × 0xFF = 15555 = 0x3CC3, so a real
    /// wraparound is unreachable on the wire — but the sum must still be a
    /// straight total, which the all-0xFF case pins down.
    func testChecksumIsAPlainSum() {
        let body = [UInt8](repeating: 0xFF, count: 61)
        XCTAssertEqual(GMMKPacket.checksum(payloadBody: body[...]), 0x3CC3)
    }

    // MARK: - Transaction bracketing

    /// Wire: `04 01 00 01 00 …` — checksum = 0x01 (only the command byte).
    func testStart() {
        XCTAssertEqual(GMMKPacket.start(), payload([0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]))
    }

    /// Wire: `04 02 00 02 00 …` — checksum = 0x02.
    func testEnd() {
        XCTAssertEqual(GMMKPacket.end(), payload([0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]))
    }

    // MARK: - Mode

    /// Wire: `04 0d 00 06 01 00 00 00 06` — 0x06+0x01+0x06 = 0x0D.
    /// (Golden packet captured from the official Windows software.)
    func testSetModeFixed() {
        XCTAssertEqual(GMMKPacket.setMode(.fixed),
                       payload([0x0D, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x06]))
    }

    /// Wire: `04 1b 00 06 01 00 00 00 14` — 0x06+0x01+0x14 = 0x1B.
    func testSetModeCustom() {
        XCTAssertEqual(GMMKPacket.setMode(.custom),
                       payload([0x1B, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x14]))
    }

    /// Wire: `04 1a 00 06 01 00 00 00 13` — 0x06+0x01+0x13 = 0x1A.
    func testSetModeOff() {
        XCTAssertEqual(GMMKPacket.setMode(.off),
                       payload([0x1A, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x13]))
    }

    /// Wire: `04 08 00 06 01 00 00 00 01` — 0x06+0x01+0x01 = 0x08.
    func testSetModeRawID() {
        XCTAssertEqual(GMMKPacket.setModeID(0x01),
                       payload([0x08, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x01]))
        XCTAssertEqual(GMMKPacket.setModeID(0x01), GMMKPacket.setMode(.horizontalWave))
    }

    /// Every mode packet differs only in the data byte, and the checksum tracks it.
    func testEveryModeIDRoundTrips() {
        for mode in LightingMode.allCases {
            let p = GMMKPacket.setMode(mode)
            XCTAssertEqual(p[2], 0x06)                    // write config RAM
            XCTAssertEqual(p[3], 0x01)                    // count
            XCTAssertEqual(p[4], 0x00)                    // address lo = mode
            XCTAssertEqual(p[5], 0x00)                    // address hi
            XCTAssertEqual(p[7], mode.rawValue)
            let expected = UInt16(0x06) + 0x01 + UInt16(mode.rawValue)
            XCTAssertEqual(UInt16(p[0]) | (UInt16(p[1]) << 8), expected,
                           "checksum mismatch for \(mode.displayName)")
        }
        XCTAssertEqual(LightingMode.allCases.count, 20)
        XCTAssertEqual(LightingMode.allCases.first?.rawValue, 0x01)
        XCTAssertEqual(LightingMode.allCases.last?.rawValue, 0x14)
    }

    // MARK: - Brightness

    /// Wire levels 0…4: `04 08 00 …00`, `04 09 00 …01`, `04 0a 00 …02`,
    /// `04 0b 00 …03`, `04 0c 00 …04`.
    /// 0x06+0x01+0x01 = 0x08, plus the level byte.
    func testSetBrightnessAllLevels() {
        let expectedChecksums: [UInt8] = [0x08, 0x09, 0x0A, 0x0B, 0x0C]
        for level in UInt8(0)...4 {
            XCTAssertEqual(
                GMMKPacket.setBrightness(level: level),
                payload([expectedChecksums[Int(level)], 0x00, 0x06, 0x01, 0x01, 0x00, 0x00, level]),
                "brightness \(level)")
        }
    }

    /// Values above 4 are untested on this board, so they clamp to 4.
    func testSetBrightnessClampsAboveFour() {
        XCTAssertEqual(GMMKPacket.setBrightness(level: 9), GMMKPacket.setBrightness(level: 4))
    }

    func testBrightnessPercentMapping() {
        XCTAssertEqual(Brightness.level(fromPercent: 0), 0)     // 0% is off
        XCTAssertEqual(Brightness.level(fromPercent: 1), 1)     // never silently off
        XCTAssertEqual(Brightness.level(fromPercent: 25), 1)
        XCTAssertEqual(Brightness.level(fromPercent: 50), 2)
        XCTAssertEqual(Brightness.level(fromPercent: 80), 3)
        XCTAssertEqual(Brightness.level(fromPercent: 100), 4)
        XCTAssertEqual(Brightness.level(fromPercent: 500), 4)   // clamped
        XCTAssertEqual(Brightness.level(fromPercent: -5), 0)    // clamped
    }

    // MARK: - Speed / delay

    /// Wire: `04 0c 00 06 01 02 00 00 03` — 0x06+0x01+0x02+0x03 = 0x0C.
    func testSetDelayThree() {
        XCTAssertEqual(GMMKPacket.setDelay(3),
                       payload([0x0C, 0x00, 0x06, 0x01, 0x02, 0x00, 0x00, 0x03]))
    }

    /// delay 0 (fastest): 0x06+0x01+0x02+0x00 = 0x09.
    func testSetDelayZero() {
        XCTAssertEqual(GMMKPacket.setDelay(0),
                       payload([0x09, 0x00, 0x06, 0x01, 0x02, 0x00, 0x00, 0x00]))
    }

    /// Only 0…3 are corroborated as meaningful.
    func testSetDelayClampsAboveThree() {
        XCTAssertEqual(GMMKPacket.setDelay(200), GMMKPacket.setDelay(3))
    }

    /// Speed 1 (slowest) → delay 3; speed 5 (fastest) → delay 0.
    func testSpeedToDelayMapping() {
        XCTAssertEqual(Delay.delay(fromSpeed: 1), 3)
        XCTAssertEqual(Delay.delay(fromSpeed: 2), 2)
        XCTAssertEqual(Delay.delay(fromSpeed: 3), 2)  // 5 UI steps onto 4 device values
        XCTAssertEqual(Delay.delay(fromSpeed: 4), 1)
        XCTAssertEqual(Delay.delay(fromSpeed: 5), 0)
        XCTAssertEqual(Delay.delay(fromSpeed: 99), 0) // clamped
        XCTAssertEqual(Delay.delay(fromSpeed: 0), 3)  // clamped
    }

    // MARK: - Direction

    /// Wire: `04 09 01 06 01 03 00 00 ff` — 0x06+0x01+0x03+0xFF = 0x0109,
    /// stored little-endian as `09 01`.
    func testSetDirectionLeft() {
        XCTAssertEqual(GMMKPacket.setDirection(.left),
                       payload([0x09, 0x01, 0x06, 0x01, 0x03, 0x00, 0x00, 0xFF]))
    }

    /// Wire: `04 0a 00 06 01 03 00 00 00` — 0x06+0x01+0x03 = 0x0A.
    func testSetDirectionRight() {
        XCTAssertEqual(GMMKPacket.setDirection(.right),
                       payload([0x0A, 0x00, 0x06, 0x01, 0x03, 0x00, 0x00, 0x00]))
    }

    // MARK: - Rainbow

    /// Wire: `04 0c 00 06 01 04 00 00 01` — 0x06+0x01+0x04+0x01 = 0x0C.
    /// (Golden packet captured from the official Windows software.)
    func testSetRainbowOn() {
        XCTAssertEqual(GMMKPacket.setRainbow(true),
                       payload([0x0C, 0x00, 0x06, 0x01, 0x04, 0x00, 0x00, 0x01]))
    }

    /// Wire: `04 0b 00 06 01 04 00 00 00` — 0x06+0x01+0x04 = 0x0B.
    func testSetRainbowOff() {
        XCTAssertEqual(GMMKPacket.setRainbow(false),
                       payload([0x0B, 0x00, 0x06, 0x01, 0x04, 0x00, 0x00, 0x00]))
    }

    // MARK: - Colour

    /// Wire: `04 95 01 06 03 05 00 00 ff 88 00` —
    /// 0x06+0x03+0x05+0xFF+0x88+0x00 = 0x0195, stored little-endian as `95 01`.
    func testSetColorOrange() {
        XCTAssertEqual(GMMKPacket.setColor(red: 0xFF, green: 0x88, blue: 0x00),
                       payload([0x95, 0x01, 0x06, 0x03, 0x05, 0x00, 0x00, 0xFF, 0x88, 0x00]))
    }

    /// Black: 0x06+0x03+0x05 = 0x0E.
    func testSetColorBlack() {
        XCTAssertEqual(GMMKPacket.setColor(red: 0, green: 0, blue: 0),
                       payload([0x0E, 0x00, 0x06, 0x03, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00]))
    }

    /// White: 0x06+0x03+0x05 + 3×0xFF = 0x0E + 0x02FD = 0x030B.
    func testSetColorWhite() {
        XCTAssertEqual(GMMKPacket.setColor(red: 0xFF, green: 0xFF, blue: 0xFF),
                       payload([0x0B, 0x03, 0x06, 0x03, 0x05, 0x00, 0x00, 0xFF, 0xFF, 0xFF]))
    }

    // MARK: - Reactive variant

    /// 0x06+0x01+0x08+VV. Blue (3) → 0x12.
    func testSetReactiveVariant() {
        XCTAssertEqual(GMMKPacket.setReactiveVariant(.red),
                       payload([0x0F, 0x00, 0x06, 0x01, 0x08, 0x00, 0x00, 0x00]))
        XCTAssertEqual(GMMKPacket.setReactiveVariant(.blue),
                       payload([0x12, 0x00, 0x06, 0x01, 0x08, 0x00, 0x00, 0x03]))
    }

    // MARK: - Polling rate

    /// Wire: `04 19 00 06 01 0f 00 00 03` — 0x06+0x01+0x0F+0x03 = 0x19.
    func testSetPollingRate1000Hz() {
        XCTAssertEqual(GMMKPacket.setPollingRate(.hz1000),
                       payload([0x19, 0x00, 0x06, 0x01, 0x0F, 0x00, 0x00, 0x03]))
    }

    /// 125 Hz: 0x06+0x01+0x0F+0x00 = 0x16.
    func testSetPollingRate125Hz() {
        XCTAssertEqual(GMMKPacket.setPollingRate(.hz125),
                       payload([0x16, 0x00, 0x06, 0x01, 0x0F, 0x00, 0x00, 0x00]))
    }

    // MARK: - Per-key colours

    /// One key (index 1 = Esc), pure red. address = 1×3 = 3.
    /// 0x11+0x03+0x03+0xFF = 0x0116 → little-endian `16 01`.
    func testSetCustomColorSingleKey() {
        XCTAssertEqual(
            GMMKPacket.setCustomColors(startKeyIndex: 1,
                                       colors: [RGB(red: 0xFF, green: 0x00, blue: 0x00)]),
            payload([0x16, 0x01, 0x11, 0x03, 0x03, 0x00, 0x00, 0xFF, 0x00, 0x00]))
    }

    /// PrtSc is key index 106 → address 318 = 0x013E, little-endian `3e 01`.
    /// 0x11+0x03+0x3E+0x01+0x00+0x00+0xFF = 0x0152.
    func testCustomColorAddressIsKeyIndexTimesThree() {
        let p = GMMKPacket.setCustomColors(startKeyIndex: 106,
                                           colors: [RGB(red: 0x00, green: 0x00, blue: 0xFF)])
        XCTAssertEqual(Array(p[0..<10]),
                       [0x52, 0x01, 0x11, 0x03, 0x3E, 0x01, 0x00, 0x00, 0x00, 0xFF])
        // Backspace, index 98 → 294 = 0x0126.
        let q = GMMKPacket.setCustomColors(startKeyIndex: 98, colors: [RGB.black])
        XCTAssertEqual(q[4], 0x26)
        XCTAssertEqual(q[5], 0x01)
    }

    /// A full 18-key packet: count = 0x36 (54 bytes), address 3.
    /// 0x11+0x36+0x03 = 0x4A, plus 54×0xFF = 0x35CA → 0x3614 → `14 36`.
    func testFullCustomColorPacket() {
        let white = RGB(red: 0xFF, green: 0xFF, blue: 0xFF)
        let p = GMMKPacket.setCustomColors(startKeyIndex: 1,
                                           colors: Array(repeating: white, count: 18))
        var expected: [UInt8] = [0x14, 0x36, 0x11, 0x36, 0x03, 0x00, 0x00]
        expected += [UInt8](repeating: 0xFF, count: 54)
        XCTAssertEqual(p, payload(expected))   // 7 + 54 = 61, padded to 63
        XCTAssertEqual(p.count, 63)
    }

    /// 18 keys per packet; the 19th starts a second packet at address 19×3 = 57 = 0x39.
    func testCustomColorPacketChunking() {
        let colors = Array(repeating: RGB(red: 0x01, green: 0x02, blue: 0x03), count: 19)
        let packets = GMMKPacket.customColorPackets(startKeyIndex: 1, colors: colors)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0][3], 0x36)          // count 54
        XCTAssertEqual(packets[0][4], 0x03)          // address 3
        XCTAssertEqual(packets[0][5], 0x00)
        XCTAssertEqual(packets[1][3], 0x03)          // count 3
        XCTAssertEqual(packets[1][4], 0x39)          // address 57
        XCTAssertEqual(packets[1][5], 0x00)
    }

    /// The canonical `1 117` run: 117 keys → 7 packets, last one 9 keys (0x1B bytes).
    func testCanonicalFullKeyboardRun() {
        let colors = Array(repeating: RGB.black, count: 117)
        let packets = GMMKPacket.customColorPackets(startKeyIndex: 1, colors: colors)
        XCTAssertEqual(packets.count, 7)
        XCTAssertEqual(packets.last?[3], 0x1B)       // (117 - 108) × 3 = 27
        // Addresses advance by 54 each packet: 3, 57, 111, …
        XCTAssertEqual(packets[1][4], 0x39)
        XCTAssertEqual(packets[2][4], 0x6F)
    }

    // MARK: - Transactions

    func testSingleWriteIsBracketed() {
        let t = GMMKTransaction.single(GMMKPacket.setMode(.fixed))
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t[0], GMMKPacket.start())
        XCTAssertEqual(t[1], GMMKPacket.setMode(.fixed))
        XCTAssertEqual(t[2], GMMKPacket.end())
    }

    /// `docs/protocol.md` §2.2: solid orange at full brightness.
    func testSolidColorTransactionMatchesDocumentedExample() {
        let t = GMMKTransaction.solidColor(RGB(red: 0xFF, green: 0x88, blue: 0x00))
        XCTAssertEqual(t.count, 6)
        XCTAssertEqual(t[0], payload([0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(t[1], payload([0x0D, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x06]))
        XCTAssertEqual(t[2], payload([0x0C, 0x00, 0x06, 0x01, 0x01, 0x00, 0x00, 0x04]))
        XCTAssertEqual(t[3], payload([0x0B, 0x00, 0x06, 0x01, 0x04, 0x00, 0x00, 0x00]))
        XCTAssertEqual(t[4], payload([0x95, 0x01, 0x06, 0x03, 0x05, 0x00, 0x00, 0xFF, 0x88, 0x00]))
        XCTAssertEqual(t[5], payload([0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]))
    }

    func testCustomColorTransactionSetsModeFirst() {
        let t = GMMKTransaction.customColors(startKeyIndex: 1, colors: [RGB.black])
        XCTAssertEqual(t.count, 3 + 1)
        XCTAssertEqual(t[0], GMMKPacket.start())
        XCTAssertEqual(t[1], GMMKPacket.setMode(.custom))
        XCTAssertEqual(t[2][2], 0x11)
        XCTAssertEqual(t[3], GMMKPacket.end())
    }
}
