import XCTest
@testable import StripProtocol

/// Golden bytes for LEDnetWF, the one family with a transport layer.
///
/// The power and effect vectors are **verbatim sniffer captures** of the phone
/// app, published in `8none1/zengge_lednetwf`'s README; the transport layout
/// and checksum rule are from `8none1/lednetwf_ble`'s `protocol_docs/`.
final class LEDnetWFFrameTests: XCTestCase {

    // MARK: - Transport

    /// The reference encoder in `04_connection_transport.md`: version 0 flags,
    /// a sequence counter, `80 00` for a single fragment, a big-endian length,
    /// length + 1, then the command ID.
    func testTransportHeaderLayout() {
        let wrapped = LEDnetWFFrames.wrap([0xAA, 0xBB, 0xCC], sequence: 0x2A)
        XCTAssertEqual(Array(wrapped.prefix(8)),
                       [0x00, 0x2A, 0x80, 0x00, 0x00, 0x03, 0x04, 0x0B])
        XCTAssertEqual(Array(wrapped.suffix(3)), [0xAA, 0xBB, 0xCC])
    }

    /// The length is two bytes big-endian, so a payload over 255 must not
    /// wrap into byte 5 alone.
    func testTransportLengthIsBigEndianAcrossTwoBytes() {
        let long = [UInt8](repeating: 0, count: 300)
        let wrapped = LEDnetWFFrames.wrap(long, sequence: 0)
        XCTAssertEqual(wrapped[4], 0x01)
        XCTAssertEqual(wrapped[5], 0x2C)
        XCTAssertEqual(wrapped[6], 0x2D)
    }

    /// Byte 6 is `length + 1` and wraps in a byte; byte 1 is the counter and
    /// wraps too. Neither is allowed to trap on overflow, because a long
    /// visualizer session will reach both.
    func testTransportCountersWrapRatherThanTrap() {
        XCTAssertEqual(LEDnetWFFrames.wrap([UInt8](repeating: 0, count: 255),
                                           sequence: 0xFF)[6], 0x00)
        XCTAssertEqual(LEDnetWFFrames.wrap([0x00], sequence: 0xFF)[1], 0xFF)
    }

    /// `05_basic_commands.md`: "checksum = sum(data) & 0xFF". It covers the
    /// inner command only — never the eight transport bytes.
    func testChecksumIsTheSumOfTheInnerBytesModulo256() {
        XCTAssertEqual(LEDnetWFFrames.checksum([0x3B, 0xA1, 0x00, 0x64, 0x64]), 0xA4)
        XCTAssertEqual(LEDnetWFFrames.checksum([0xFF, 0xFF]), 0xFE)
        XCTAssertEqual(LEDnetWFFrames.checksum([]), 0x00)
    }

    func testChecksumExcludesTheTransportHeader() {
        let payload = LEDnetWFFrames.powerPayload(on: true)
        // Wrapping must not disturb the payload or its checksum.
        XCTAssertEqual(Array(LEDnetWFFrames.wrap(payload, sequence: 0x77).dropFirst(8)),
                       payload)
    }

    // MARK: - Power

    /// Verbatim from the retired README:
    /// `00 04 80 00 00 0d 0e 0b 3b 23 00 00 00 00 00 00 00 32 00 00 90`
    /// `00 5b 80 00 00 0d 0e 0b 3b 24 00 00 00 00 00 00 00 32 00 00 91`
    func testPowerGoldenFramesMatchTheCapturedTraffic() {
        XCTAssertEqual(LEDnetWFFrames.power(on: true, sequence: 0x04),
                       [0x00, 0x04, 0x80, 0x00, 0x00, 0x0D, 0x0E, 0x0B,
                        0x3B, 0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x32, 0x00, 0x00, 0x90])
        XCTAssertEqual(LEDnetWFFrames.power(on: false, sequence: 0x5B),
                       [0x00, 0x5B, 0x80, 0x00, 0x00, 0x0D, 0x0E, 0x0B,
                        0x3B, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x32, 0x00, 0x00, 0x91])
    }

    // MARK: - Colour

    /// The captured red frame, again verbatim:
    /// `00 05 80 00 00 0d 0e 0b 3b a1 00 64 64 00 00 00 00 00 00 00 00`.
    ///
    /// The capture's last byte is `00` — the phone app did not bother with the
    /// checksum, which the README says the device ignores once connected. The
    /// correct value is `0xA4` and that is what is asserted; the capture is
    /// matched on every other byte.
    func testColorGoldenFrameForRedMatchesTheCaptureExceptItsBlankChecksum() {
        let ours = LEDnetWFFrames.color(StripRGB(red: 0xFF, green: 0, blue: 0),
                                        sequence: 0x05)
        let captured: [UInt8] = [0x00, 0x05, 0x80, 0x00, 0x00, 0x0D, 0x0E, 0x0B,
                                 0x3B, 0xA1, 0x00, 0x64, 0x64, 0x00, 0x00, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(ours.count, captured.count)
        XCTAssertEqual(Array(ours.dropLast()), Array(captured.dropLast()))
        XCTAssertEqual(ours.last, 0xA4)
    }

    /// `#112233` is R 17, G 34, B 51 → hue 210°, saturation 67%, value 20%.
    /// Packed: `(210 << 7) | 67` = 26947 = `0x6943`; value 20 = `0x14`;
    /// checksum `0x3B + 0xA1 + 0x69 + 0x43 + 0x14` = `0x19C` → `0x9C`.
    func testColorPacksHueAndSaturationIntoTwoBigEndianBytes() {
        XCTAssertEqual(LEDnetWFFrames.color(StripRGB(red: 0x11, green: 0x22, blue: 0x33),
                                            sequence: 0x00),
                       [0x00, 0x00, 0x80, 0x00, 0x00, 0x0D, 0x0E, 0x0B,
                        0x3B, 0xA1, 0x69, 0x43, 0x14, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x9C])
    }

    /// The transition-time field is a documented footgun — non-zero values
    /// delay the change, which on a visualizer would be a fixed lag that is
    /// very hard to attribute later.
    func testColorLeavesTheTransitionTimeFieldZero() {
        let frame = LEDnetWFFrames.color(.white, sequence: 9)
        XCTAssertEqual(frame[18], 0x00)
        XCTAssertEqual(frame[19], 0x00)
    }

    /// The legacy direct-RGB command, `[0x31, R, G, B, 0, 0, 0xF0, 0x0F, chk]`.
    /// Also computed rather than captured: `0x31 + 0xFF + 0xF0 + 0x0F`
    /// = 49 + 255 + 240 + 15 = 559 = `0x22F`, so the checksum is `0x2F`.
    func testLegacyDirectRGBPayloadGoldenBytes() {
        XCTAssertEqual(LEDnetWFFrames.colorLegacyPayload(StripRGB(red: 0xFF, green: 0, blue: 0)),
                       [0x31, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x0F, 0x2F])
    }

    // MARK: - Brightness

    /// Unlike the colour, power and effect vectors above, no source publishes a
    /// captured brightness frame — the checksum here is computed from the
    /// documented rule, so the arithmetic is written out to be checkable:
    /// `0x3B + 0x01 + 0x64 + 0x64` = 59 + 1 + 100 + 100 = 260 = `0x104`,
    /// so the checksum is `0x04`.
    func testBrightnessPayloadGoldenBytes() {
        XCTAssertEqual(LEDnetWFFrames.brightnessPayload(percent: 100),
                       [0x3B, 0x01, 0x00, 0x00, 0x64, 0x00, 0x64,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x04])
    }

    func testBrightnessClampsToPercent() {
        XCTAssertEqual(LEDnetWFFrames.brightnessPayload(percent: 300)[4], 100)
        XCTAssertEqual(LEDnetWFFrames.brightnessPayload(percent: -1)[4], 0)
    }

    // MARK: - Effects

    /// Verbatim: a fill light at effect 1, speed 1, brightness 100 —
    /// `00 06 80 00 00 04 05 0b 38 01 01 64`, and note the payload is four
    /// bytes with **no** checksum.
    func testFillLightEffectHasNoChecksum() {
        XCTAssertEqual(LEDnetWFFrames.effect(0x01, speed: 0x01, brightness: 0x64,
                                             command: .fillLight, sequence: 0x06),
                       [0x00, 0x06, 0x80, 0x00, 0x00, 0x04, 0x05, 0x0B,
                        0x38, 0x01, 0x01, 0x64])
    }

    /// Verbatim: `00 9c 80 00 00 05 06 0b 42 01 32 64 d9`, where
    /// `0x42 + 0x01 + 0x32 + 0x64 = 0xD9`.
    func testSymphonyEffectGoldenFrameIncludingChecksum() {
        XCTAssertEqual(LEDnetWFFrames.effect(0x01, speed: 0x32, brightness: 0x64,
                                             command: .symphony, sequence: 0x9C),
                       [0x00, 0x9C, 0x80, 0x00, 0x00, 0x05, 0x06, 0x0B,
                        0x42, 0x01, 0x32, 0x64, 0xD9])
    }

    /// `06_effect_commands.md`, in bold: "Brightness=0 powers OFF the device —
    /// always use minimum of 1, not 0."
    func testEffectBrightnessNeverGoesToZero() {
        let payload = LEDnetWFFrames.effectPayload(0x05, speed: 0x10, brightness: 0,
                                                   command: .symphony)
        XCTAssertEqual(payload[3], 1)
    }

    func testEffectCommandOpcodesAndRanges() {
        XCTAssertEqual(LEDnetWFFrames.EffectCommand.fillLight.opcode, 0x38)
        XCTAssertEqual(LEDnetWFFrames.EffectCommand.addressable.opcode, 0x38)
        XCTAssertEqual(LEDnetWFFrames.EffectCommand.symphony.opcode, 0x42)
        XCTAssertEqual(LEDnetWFFrames.EffectCommand.fillLight.effectIDRange, 1...113)
        XCTAssertEqual(LEDnetWFFrames.EffectCommand.addressable.effectIDRange, 1...44)
        XCTAssertEqual(LEDnetWFFrames.EffectCommand.symphony.effectIDRange, 1...100)
    }

    // MARK: - State query

    /// Verbatim from `tools/ble_scanner.py`:
    /// `00 01 80 00 00 04 05 0a 81 8a 8b 96`. Note `0x0A` at byte 7 — this is
    /// the one command that asks the device to answer.
    func testStateQueryGoldenFrameAsksForAResponse() {
        XCTAssertEqual(LEDnetWFFrames.stateQuery(),
                       [0x00, 0x01, 0x80, 0x00, 0x00, 0x04, 0x05, 0x0A,
                        0x81, 0x8A, 0x8B, 0x96])
    }

    func testEveryOtherCommandAsksForNoResponse() {
        XCTAssertEqual(LEDnetWFFrames.power(on: true, sequence: 0)[7], 0x0B)
        XCTAssertEqual(LEDnetWFFrames.color(.white, sequence: 0)[7], 0x0B)
        XCTAssertEqual(LEDnetWFFrames.brightness(percent: 50, sequence: 0)[7], 0x0B)
    }

    // MARK: - HSV

    /// The conversion the colour frame depends on, checked at the corners.
    func testRGBToHSVUsesTheProtocolsOwnUnits() {
        XCTAssertEqual(StripHSV(StripRGB(red: 255, green: 0, blue: 0)),
                       StripHSV(hue: 0, saturation: 100, value: 100))
        XCTAssertEqual(StripHSV(StripRGB(red: 0, green: 255, blue: 0)),
                       StripHSV(hue: 120, saturation: 100, value: 100))
        XCTAssertEqual(StripHSV(StripRGB(red: 0, green: 0, blue: 255)),
                       StripHSV(hue: 240, saturation: 100, value: 100))
        XCTAssertEqual(StripHSV(StripRGB(red: 0x11, green: 0x22, blue: 0x33)),
                       StripHSV(hue: 210, saturation: 67, value: 20))
    }

    /// Hue must never come back negative — the red branch straddles 0°, and a
    /// negative hue would shift into the saturation bits when packed.
    func testHueIsNeverNegativeOnTheRedBranch() {
        for green in 0...255 {
            for blue in stride(from: 0, through: 255, by: 51) {
                let hsv = StripHSV(StripRGB(red: 255,
                                            green: UInt8(green),
                                            blue: UInt8(blue)))
                XCTAssertTrue((0...360).contains(hsv.hue), "r=255 g=\(green) b=\(blue)")
            }
        }
    }

    func testGreyAndBlackHaveNoHueOrSaturation() {
        XCTAssertEqual(StripHSV(.black), StripHSV(hue: 0, saturation: 0, value: 0))
        XCTAssertEqual(StripHSV(StripRGB(red: 128, green: 128, blue: 128)),
                       StripHSV(hue: 0, saturation: 0, value: 50))
        XCTAssertEqual(StripHSV(.white), StripHSV(hue: 0, saturation: 0, value: 100))
    }
}
