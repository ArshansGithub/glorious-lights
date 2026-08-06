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

    // MARK: - Reply status

    /// Builds a reply as the firmware delivers it: 64 bytes, report ID intact,
    /// status at wire offset 7.
    private func reply(status: UInt8, length: Int = 64) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: length)
        let index = length == GMMKPacket.payloadLength
            ? GMMKPacket.replyStatusOffset - 1
            : GMMKPacket.replyStatusOffset
        report[index] = status
        return report
    }

    func testStatusOffsetIsSeven() {
        XCTAssertEqual(GMMKPacket.replyStatusOffset, 7)
    }

    func testReplyStatusOK() {
        XCTAssertEqual(GMMKPacket.replyStatus(inReport: reply(status: 0x00)), .ok)
    }

    /// The two values the official software treats as errors.
    func testReplyStatusRejected() {
        XCTAssertEqual(GMMKPacket.replyStatus(inReport: reply(status: 0xFF)), .rejected(0xFF))
        XCTAssertEqual(GMMKPacket.replyStatus(inReport: reply(status: 0xFE)), .rejected(0xFE))
    }

    /// Anything else is reported distinctly but is not an error — the official
    /// software only special-cases 0xFF and 0xFE.
    func testReplyStatusOther() {
        XCTAssertEqual(GMMKPacket.replyStatus(inReport: reply(status: 0x42)), .other(0x42))
    }

    /// A 63-byte delivery (report ID stripped) shifts the status one earlier.
    /// Which form arrives is the OS's choice, not the protocol's.
    func testReplyStatusInAnIDLessReport() {
        let short = reply(status: 0xFF, length: GMMKPacket.payloadLength)
        XCTAssertEqual(short[6], 0xFF)
        XCTAssertEqual(GMMKPacket.replyStatus(inReport: short), .rejected(0xFF))
    }

    func testReplyStatusOfATooShortReport() {
        XCTAssertEqual(GMMKPacket.replyStatus(inReport: []), .malformed)
        XCTAssertEqual(GMMKPacket.replyStatus(inReport: [0x04, 0x00, 0x00]), .malformed)
    }

    /// A plain echo of a command carries the outgoing packet's zero pad at
    /// offset 7, which reads as "accepted" — the same byte serves both
    /// directions.
    func testEchoOfAWriteReadsAsOK() {
        let echo = [GMMKPacket.reportID] + GMMKPacket.setMode(.fixed, profileBase: 0x2A)
        XCTAssertEqual(echo.count, 64)
        XCTAssertEqual(GMMKPacket.replyStatus(inReport: echo), .ok)
    }

    // MARK: - Profile bases

    /// Three 42-byte blocks at 0x0000 / 0x002A / 0x0054.
    func testProfileBases() {
        XCTAssertEqual(GMMKPacket.profileStride, 0x2A)
        XCTAssertEqual(GMMKPacket.profileBases, [0x0000, 0x002A, 0x0054])
    }

    /// Verified on hardware: mode 6 at profile 1 is
    /// `04 37 00 06 01 2a 00 00 06` — 0x06+0x01+0x2A+0x06 = 0x37.
    func testSetModeAtProfileOne() {
        XCTAssertEqual(GMMKPacket.setMode(.fixed, profileBase: 0x2A),
                       payload([0x37, 0x00, 0x06, 0x01, 0x2A, 0x00, 0x00, 0x06]))
    }

    /// Profile 2: `04 61 00 06 01 54 00 00 06` — 0x06+0x01+0x54+0x06 = 0x61.
    func testSetModeAtProfileTwo() {
        XCTAssertEqual(GMMKPacket.setMode(.fixed, profileBase: 0x54),
                       payload([0x61, 0x00, 0x06, 0x01, 0x54, 0x00, 0x00, 0x06]))
    }

    /// Verified on hardware: rainbow off at profile 1 (offset 4 → address 0x2E)
    /// is `04 35 00 06 01 2e 00 00 00` — 0x06+0x01+0x2E = 0x35.
    func testSetRainbowAtProfileOne() {
        XCTAssertEqual(GMMKPacket.setRainbow(false, profileBase: 0x2A),
                       payload([0x35, 0x00, 0x06, 0x01, 0x2E, 0x00, 0x00, 0x00]))
    }

    /// Verified on hardware: colour ff8800 at profile 1 (offset 5 → address
    /// 0x2F) is `04 bf 01 06 03 2f 00 00 ff 88 00` —
    /// 0x06+0x03+0x2F+0xFF+0x88 = 0x01BF, little-endian `bf 01`.
    func testSetColorAtProfileOne() {
        XCTAssertEqual(
            GMMKPacket.setColor(red: 0xFF, green: 0x88, blue: 0x00, profileBase: 0x2A),
            payload([0xBF, 0x01, 0x06, 0x03, 0x2F, 0x00, 0x00, 0xFF, 0x88, 0x00]))
    }

    /// Field offsets are relative: every field's address is base + offset, and
    /// the profile-0 form is exactly the offset itself.
    func testEveryFieldIsProfileRelative() {
        for base in GMMKPacket.profileBases {
            XCTAssertEqual(GMMKPacket.setMode(.fixed, profileBase: base)[4],
                           UInt8(base + GMMKPacket.ConfigOffset.mode))
            XCTAssertEqual(GMMKPacket.setBrightness(level: 4, profileBase: base)[4],
                           UInt8(base + GMMKPacket.ConfigOffset.brightness))
            XCTAssertEqual(GMMKPacket.setDelay(1, profileBase: base)[4],
                           UInt8(base + GMMKPacket.ConfigOffset.delay))
            XCTAssertEqual(GMMKPacket.setDirection(.left, profileBase: base)[4],
                           UInt8(base + GMMKPacket.ConfigOffset.direction))
            XCTAssertEqual(GMMKPacket.setRainbow(true, profileBase: base)[4],
                           UInt8(base + GMMKPacket.ConfigOffset.rainbow))
            XCTAssertEqual(GMMKPacket.setColor(red: 1, green: 2, blue: 3, profileBase: base)[4],
                           UInt8(base + GMMKPacket.ConfigOffset.color))
        }
        // Profile 0 is the no-argument form.
        XCTAssertEqual(GMMKPacket.setMode(.fixed), GMMKPacket.setMode(.fixed, profileBase: 0))
    }

    /// Addresses stay inside the low byte for all three profiles, so the
    /// address-high byte is always 0.
    func testProfileAddressesFitInOneByte() {
        for base in GMMKPacket.profileBases {
            XCTAssertEqual(GMMKPacket.setPollingRate(.hz1000, profileBase: base)[5], 0x00)
        }
    }

    func testAtEveryProfileBuildsOnePacketPerBase() {
        let packets = GMMKPacket.atEveryProfile { GMMKPacket.setMode(.fixed, profileBase: $0) }
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets.map { $0[4] }, [0x00, 0x2A, 0x54])
    }

    // MARK: - Transactions

    func testSingleWriteIsBracketed() {
        let t = GMMKTransaction.single(GMMKPacket.setMode(.fixed))
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t[0], GMMKPacket.start())
        XCTAssertEqual(t[1], GMMKPacket.setMode(.fixed))
        XCTAssertEqual(t[2], GMMKPacket.end())
    }

    /// One field, three bases, bracketed — `docs/protocol-tkl-notes.md` §8.2.
    func testSetModeTransactionWritesEveryProfile() {
        let t = GMMKTransaction.setMode(.fixed)
        XCTAssertEqual(t, [
            payload([0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),
            payload([0x0D, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x06]),
            payload([0x37, 0x00, 0x06, 0x01, 0x2A, 0x00, 0x00, 0x06]),
            payload([0x61, 0x00, 0x06, 0x01, 0x54, 0x00, 0x00, 0x06]),
            payload([0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]),
        ])
    }

    /// Rainbow off across the three profiles: addresses 0x04, 0x2E, 0x58.
    func testSetRainbowTransaction() {
        let t = GMMKTransaction.setRainbow(false)
        XCTAssertEqual(t, [
            payload([0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),
            payload([0x0B, 0x00, 0x06, 0x01, 0x04, 0x00, 0x00, 0x00]),
            payload([0x35, 0x00, 0x06, 0x01, 0x2E, 0x00, 0x00, 0x00]),
            payload([0x5F, 0x00, 0x06, 0x01, 0x58, 0x00, 0x00, 0x00]),
            payload([0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]),
        ])
    }

    /// Setting a colour also clears the rainbow flag, so it is two fields ×
    /// three bases, field-major.
    func testSetColorTransactionClearsRainbowFirst() {
        let t = GMMKTransaction.setColor(RGB(red: 0xFF, green: 0x88, blue: 0x00))
        XCTAssertEqual(t.count, 8)
        XCTAssertEqual(t[1...3].map { $0[4] }, [0x04, 0x2E, 0x58])   // rainbow
        XCTAssertEqual(t[4...6].map { $0[4] }, [0x05, 0x2F, 0x59])   // colour
        XCTAssertEqual(t[1], payload([0x0B, 0x00, 0x06, 0x01, 0x04, 0x00, 0x00, 0x00]))
        XCTAssertEqual(t[5], payload([0xBF, 0x01, 0x06, 0x03, 0x2F, 0x00, 0x00, 0xFF, 0x88, 0x00]))
    }

    /// The whole smoke test, byte for byte: mode, brightness, rainbow, colour —
    /// each at 0x00 / 0x2A / 0x54 — inside one START/END pair. The profile-0
    /// packets are the `docs/protocol.md` §2.2 example unchanged.
    func testSolidColorTransactionIsFieldMajorAcrossProfiles() {
        let t = GMMKTransaction.solidColor(RGB(red: 0xFF, green: 0x88, blue: 0x00))
        XCTAssertEqual(t, [
            payload([0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),                       // START
            payload([0x0D, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x06]),                 // mode
            payload([0x37, 0x00, 0x06, 0x01, 0x2A, 0x00, 0x00, 0x06]),
            payload([0x61, 0x00, 0x06, 0x01, 0x54, 0x00, 0x00, 0x06]),
            payload([0x0C, 0x00, 0x06, 0x01, 0x01, 0x00, 0x00, 0x04]),                 // brightness
            payload([0x36, 0x00, 0x06, 0x01, 0x2B, 0x00, 0x00, 0x04]),
            payload([0x60, 0x00, 0x06, 0x01, 0x55, 0x00, 0x00, 0x04]),
            payload([0x0B, 0x00, 0x06, 0x01, 0x04, 0x00, 0x00, 0x00]),                 // rainbow off
            payload([0x35, 0x00, 0x06, 0x01, 0x2E, 0x00, 0x00, 0x00]),
            payload([0x5F, 0x00, 0x06, 0x01, 0x58, 0x00, 0x00, 0x00]),
            payload([0x95, 0x01, 0x06, 0x03, 0x05, 0x00, 0x00, 0xFF, 0x88, 0x00]),     // colour
            payload([0xBF, 0x01, 0x06, 0x03, 0x2F, 0x00, 0x00, 0xFF, 0x88, 0x00]),
            payload([0xE9, 0x01, 0x06, 0x03, 0x59, 0x00, 0x00, 0xFF, 0x88, 0x00]),
            payload([0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]),                       // END
        ])
    }

    /// Every operation is bracketed exactly once and writes 3 packets per field.
    func testEveryOperationIsBracketedAndTripled() {
        let operations: [(String, [[UInt8]], Int)] = [
            ("setMode",       GMMKTransaction.setMode(.fixed), 1),
            ("setModeID",     GMMKTransaction.setModeID(0x06), 1),
            ("setBrightness", GMMKTransaction.setBrightness(level: 2), 1),
            ("setDelay",      GMMKTransaction.setDelay(1), 1),
            ("setDirection",  GMMKTransaction.setDirection(.left), 1),
            ("setRainbow",    GMMKTransaction.setRainbow(true), 1),
            ("setColor",      GMMKTransaction.setColor(.black), 2),
            ("solidColor",    GMMKTransaction.solidColor(.black), 4),
        ]
        for (name, packets, fieldCount) in operations {
            XCTAssertEqual(packets.count, 2 + fieldCount * 3, "\(name) packet count")
            XCTAssertEqual(packets.first, GMMKPacket.start(), "\(name) START")
            XCTAssertEqual(packets.last, GMMKPacket.end(), "\(name) END")
            for packet in packets.dropFirst().dropLast() {
                XCTAssertEqual(packet[2], GMMKPacket.Command.writeConfig, "\(name) command")
            }
        }
    }

    /// A whole look is five fields at three bases inside one transaction,
    /// field-major: mode, brightness, delay, rainbow, colour.
    func testApplyLookWritesEveryFieldAtEveryProfile() {
        let t = GMMKTransaction.applyLook(mode: .horizontalWave,
                                          rainbow: true,
                                          brightness: 3,
                                          delay: 1,
                                          color: RGB(red: 0xFF, green: 0x88, blue: 0x00))
        XCTAssertEqual(t.count, 2 + 5 * 3)
        XCTAssertEqual(t.first, GMMKPacket.start())
        XCTAssertEqual(t.last, GMMKPacket.end())
        // Field-major: each field's three packets sit together, at 0x00/0x2A/0x54
        // plus the field's own offset.
        XCTAssertEqual(t[1...3].map { $0[4] }, [0x00, 0x2A, 0x54])   // mode
        XCTAssertEqual(t[4...6].map { $0[4] }, [0x01, 0x2B, 0x55])   // brightness
        XCTAssertEqual(t[7...9].map { $0[4] }, [0x02, 0x2C, 0x56])   // delay
        XCTAssertEqual(t[10...12].map { $0[4] }, [0x04, 0x2E, 0x58]) // rainbow
        XCTAssertEqual(t[13...15].map { $0[4] }, [0x05, 0x2F, 0x59]) // colour
        XCTAssertEqual(t[1][7], LightingMode.horizontalWave.rawValue)
        XCTAssertEqual(t[4][7], 3)
        XCTAssertEqual(t[7][7], 1)
        XCTAssertEqual(t[10][7], 0x01)                                // rainbow on
        XCTAssertEqual(Array(t[13][7..<10]), [0xFF, 0x88, 0x00])
    }

    /// The rainbow flag is written either way, so a look that turns it off
    /// clears one left on by a previous look.
    func testApplyLookAlwaysWritesTheRainbowFlag() {
        let t = GMMKTransaction.applyLook(mode: .fixed, rainbow: false, brightness: 4,
                                          delay: 0, color: .black)
        XCTAssertEqual(t[10][7], 0x00)
        XCTAssertEqual(t[10][4], UInt8(GMMKPacket.ConfigOffset.rainbow))
    }

    func testCustomColorTransactionSetsModeAtEveryProfileFirst() {
        let t = GMMKTransaction.customColors(startKeyIndex: 1, colors: [RGB.black])
        XCTAssertEqual(t.count, 3 + 3)
        XCTAssertEqual(t[0], GMMKPacket.start())
        XCTAssertEqual(Array(t[1...3]),
                       GMMKPacket.atEveryProfile { GMMKPacket.setMode(.custom, profileBase: $0) })
        XCTAssertEqual(t[4][2], 0x11)
        XCTAssertEqual(t[5], GMMKPacket.end())
    }
}
