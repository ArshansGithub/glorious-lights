import XCTest
@testable import StripProtocol

/// Golden bytes for the nine-byte `7E … EF` protocol.
///
/// Every vector here is quoted from a published source, named in the test's own
/// doc comment. Nothing is computed by this project and then asserted against
/// itself — that would test only that the code does what it does.
final class ELKFrameTests: XCTestCase {

    // MARK: - Frame shape

    func testEveryFrameIsNineBytesBetweenTheEnvelopeBytes() {
        for family in StripFamily.allCases {
            guard let dialect = family.elkDialect else { continue }
            let frames = [ELKFrames.color(.white, dialect: dialect),
                          ELKFrames.power(on: true, dialect: dialect),
                          ELKFrames.power(on: false, dialect: dialect),
                          ELKFrames.brightness(percent: 50, dialect: dialect),
                          ELKFrames.effect(.jumpRGB, dialect: dialect),
                          ELKFrames.speed(percent: 50, dialect: dialect)]
            for frame in frames {
                XCTAssertEqual(frame.count, 9, "\(dialect.displayName)")
                XCTAssertEqual(frame.first, 0x7E, "\(dialect.displayName)")
                XCTAssertEqual(frame.last, 0xEF, "\(dialect.displayName)")
            }
        }
    }

    // MARK: - Colour

    /// `arduino12/ble_rgb_led_strip_controller`, verbatim, captured from a
    /// device named `ELK-BLEDOM`; `linuxthings.co.uk` publishes the identical
    /// three vectors independently.
    func testBLEDOMColorGoldenBytes() {
        XCTAssertEqual(ELKFrames.color(StripRGB(red: 0xFF, green: 0, blue: 0), dialect: .bledom),
                       [0x7E, 0x00, 0x05, 0x03, 0xFF, 0x00, 0x00, 0x00, 0xEF])
        XCTAssertEqual(ELKFrames.color(StripRGB(red: 0, green: 0xFF, blue: 0), dialect: .bledom),
                       [0x7E, 0x00, 0x05, 0x03, 0x00, 0xFF, 0x00, 0x00, 0xEF])
        XCTAssertEqual(ELKFrames.color(StripRGB(red: 0, green: 0, blue: 0xFF), dialect: .bledom),
                       [0x7E, 0x00, 0x05, 0x03, 0x00, 0x00, 0xFF, 0x00, 0xEF])
    }

    /// The arbitrary-colour case, by substitution into the same template.
    func testBLEDOMColorPlacesRedGreenBlueAtBytesFourFiveSix() {
        XCTAssertEqual(ELKFrames.color(StripRGB(red: 0x11, green: 0x22, blue: 0x33),
                                       dialect: .bledom),
                       [0x7E, 0x00, 0x05, 0x03, 0x11, 0x22, 0x33, 0x00, 0xEF])
    }

    /// `dave-code-ruiz/elkbledom` `models.json`, `ELK-BLEDOB` entry:
    /// `[126, 7, 5, 3, r, g, b, 10, 239]`.
    func testBLEDOBColorGoldenBytes() {
        XCTAssertEqual(ELKFrames.color(StripRGB(red: 0x11, green: 0x22, blue: 0x33),
                                       dialect: .bledob),
                       [0x7E, 0x07, 0x05, 0x03, 0x11, 0x22, 0x33, 0x0A, 0xEF])
    }

    /// `8none1/elk-bledob`'s sniffer captures give `0x10` where `models.json`
    /// gives `0x0A` at byte 7. FergusInLondon records that this byte "tends to
    /// be set to either 16 or 0; doesn't seem to affect functionality".
    ///
    /// This test exists to pin the disagreement in place: if byte 7 ever needs
    /// changing, it should be a deliberate edit here and not a silent one.
    func testBLEDOBColorDiffersFromTheSnifferCaptureOnlyInByteSeven() {
        let ours = ELKFrames.color(StripRGB(red: 0x11, green: 0x22, blue: 0x33),
                                   dialect: .bledob)
        let sniffed: [UInt8] = [0x7E, 0x07, 0x05, 0x03, 0x11, 0x22, 0x33, 0x10, 0xEF]
        let differing = zip(ours, sniffed).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(differing.map(\.offset), [7])
    }

    /// `models.json`'s `LED-` / `JACKYLED` entry sends **red, blue, green**:
    /// `[126, 7, 5, 3, r, b, g, 0, 239]`.
    func testJackyLEDTransposesGreenAndBlue() {
        XCTAssertEqual(ELKFrames.color(StripRGB(red: 0x11, green: 0x22, blue: 0x33),
                                       dialect: .jackyLED),
                       [0x7E, 0x07, 0x05, 0x03, 0x11, 0x33, 0x22, 0x00, 0xEF])
    }

    /// The transposition must be the *only* difference from LEDBLE, which
    /// shares its filler bytes — otherwise a swapped-colour symptom tomorrow
    /// would not isolate to the colour order.
    func testJackyLEDDiffersFromLEDBLEOnlyInColorOrder() {
        let rgb = StripRGB(red: 0x11, green: 0x22, blue: 0x33)
        let jacky = ELKFrames.color(rgb, dialect: .jackyLED)
        let ledble = ELKFrames.color(rgb, dialect: .ledble)
        XCTAssertEqual(zip(jacky, ledble).enumerated()
                        .filter { $0.element.0 != $0.element.1 }.map(\.offset),
                       [5, 6])
    }

    // MARK: - Power

    /// `models.json`, `ELK-BLEDOM` / `ELK-BTC`; the same bytes appear in
    /// `linuxthings.co.uk` as `7e0004f00001ff00ef` / `7e0004000000ff00ef`.
    func testBLEDOMPowerGoldenBytes() {
        XCTAssertEqual(ELKFrames.power(on: true, dialect: .bledom),
                       [0x7E, 0x00, 0x04, 0xF0, 0x00, 0x01, 0xFF, 0x00, 0xEF])
        XCTAssertEqual(ELKFrames.power(on: false, dialect: .bledom),
                       [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF])
    }

    /// `arduino12`, verbatim — the second capture of the same device name, and
    /// the reason ``StripFamily/elkBLEDOMAlternatePower`` exists.
    func testBLEDOMAlternatePowerGoldenBytes() {
        XCTAssertEqual(ELKFrames.power(on: true, dialect: .bledomAlternatePower),
                       [0x7E, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0xEF])
        XCTAssertEqual(ELKFrames.power(on: false, dialect: .bledomAlternatePower),
                       [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0xEF])
    }

    /// The two BLEDOM dialects must agree on colour — they are one device with
    /// two power captures, not two devices.
    func testBothBLEDOMDialectsAgreeOnColor() {
        let rgb = StripRGB(red: 0x40, green: 0x80, blue: 0xC0)
        XCTAssertEqual(ELKFrames.color(rgb, dialect: .bledom),
                       ELKFrames.color(rgb, dialect: .bledomAlternatePower))
    }

    /// `models.json` `ELK-BLEDOB`, confirmed byte for byte by `8none1`'s
    /// independent sniffer captures.
    func testBLEDOBPowerGoldenBytes() {
        XCTAssertEqual(ELKFrames.power(on: true, dialect: .bledob),
                       [0x7E, 0x07, 0x04, 0xFF, 0x00, 0x01, 0x02, 0x01, 0xEF])
        XCTAssertEqual(ELKFrames.power(on: false, dialect: .bledob),
                       [0x7E, 0x07, 0x04, 0x00, 0x00, 0x00, 0x02, 0x01, 0xEF])
    }

    /// `kloptops/LEDBLE-Strip`: `[126, 4, 4, 1, 255, 255, 255, 0, 239]`.
    func testLEDBLEPowerGoldenBytes() {
        XCTAssertEqual(ELKFrames.power(on: true, dialect: .ledble),
                       [0x7E, 0x04, 0x04, 0x01, 0xFF, 0xFF, 0xFF, 0x00, 0xEF])
        XCTAssertEqual(ELKFrames.power(on: false, dialect: .ledble),
                       [0x7E, 0x04, 0x04, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xEF])
    }

    // MARK: - Brightness

    /// `arduino12`, verbatim: `7e00013200000000ef` is 50%.
    ///
    /// Note the scale: 0x32 is 50, not 128. `elkbledom` converts an 8-bit
    /// intensity with `int(intensity * 100 / 255)`.
    func testBLEDOMBrightnessIsAPercentageNotAByte() {
        XCTAssertEqual(ELKFrames.brightness(percent: 50, dialect: .bledomAlternatePower),
                       [0x7E, 0x00, 0x01, 0x32, 0x00, 0x00, 0x00, 0x00, 0xEF])
    }

    /// `8none1/elk-bledob`, verbatim, at 1%, 50% and 100%:
    /// `7e 04 01 01 01 ff 02 01 ef`, `…32…`, `…64…`.
    func testBLEDOBBrightnessGoldenBytes() {
        XCTAssertEqual(ELKFrames.brightness(percent: 1, dialect: .bledob),
                       [0x7E, 0x04, 0x01, 0x01, 0x01, 0xFF, 0x02, 0x01, 0xEF])
        XCTAssertEqual(ELKFrames.brightness(percent: 50, dialect: .bledob),
                       [0x7E, 0x04, 0x01, 0x32, 0x01, 0xFF, 0x02, 0x01, 0xEF])
        XCTAssertEqual(ELKFrames.brightness(percent: 100, dialect: .bledob),
                       [0x7E, 0x04, 0x01, 0x64, 0x01, 0xFF, 0x02, 0x01, 0xEF])
    }

    /// Out-of-range percentages clamp rather than throw or wrap. A fader
    /// overshooting by a point must not produce a frame with 0xFF where the
    /// device expects 0…100.
    func testBrightnessClampsToTheDocumentedPercentageRange() {
        XCTAssertEqual(ELKFrames.brightness(percent: 500, dialect: .bledob)[3], 100)
        XCTAssertEqual(ELKFrames.brightness(percent: -20, dialect: .bledob)[3], 0)
    }

    // MARK: - Effects and speed

    /// `8none1/elk-bledob`, verbatim: `7e 07 03 93 03 ff ff 00 ef` and
    /// `7e 07 03 98 03 ff ff 00 ef`.
    func testBLEDOBEffectGoldenBytes() {
        XCTAssertEqual(ELKFrames.effect(.fadeRedBlue, dialect: .bledob),
                       [0x7E, 0x07, 0x03, 0x93, 0x03, 0xFF, 0xFF, 0x00, 0xEF])
        XCTAssertEqual(ELKFrames.effect(.blinkBlue, dialect: .bledob),
                       [0x7E, 0x07, 0x03, 0x98, 0x03, 0xFF, 0xFF, 0x00, 0xEF])
    }

    /// `models.json` `ELK-BLEDOM`: `[126, 0, 3, v, 3, 0, 0, 0, 239]`.
    func testBLEDOMEffectGoldenBytes() {
        XCTAssertEqual(ELKFrames.effect(.jumpRGB, dialect: .bledom),
                       [0x7E, 0x00, 0x03, 0x87, 0x03, 0x00, 0x00, 0x00, 0xEF])
    }

    /// `arduino12`'s effect table runs `0x80`…`0x9C` with no gaps, the first
    /// seven being static colours.
    func testEffectIDsCoverTheDocumentedRangeWithoutGaps() {
        XCTAssertEqual(ELKEffect.allCases.map(\.rawValue), Array(0x80...0x9C))
        XCTAssertEqual(ELKEffect.staticRed.rawValue, 0x80)
        XCTAssertEqual(ELKEffect.blinkWhite.rawValue, 0x9C)
    }

    func testEffectNamesRoundTripThroughTheCommandLineSpelling() {
        for effect in ELKEffect.allCases {
            XCTAssertEqual(ELKEffect(commandName: effect.commandName), effect)
            XCTAssertEqual(ELKEffect(commandName: effect.commandName.uppercased()), effect)
        }
        XCTAssertNil(ELKEffect(commandName: "not-an-effect"))
    }

    /// `models.json`: `[126, 0, 2, v, 0, 0, 0, 0, 239]` for BLEDOM.
    func testSpeedGoldenBytes() {
        XCTAssertEqual(ELKFrames.speed(percent: 100, dialect: .bledom),
                       [0x7E, 0x00, 0x02, 0x64, 0x00, 0x00, 0x00, 0x00, 0xEF])
    }

    // MARK: - Status and login

    /// `models.json` `query`: `7e 00 01 fa 00 00 00 00 ef`.
    func testStatusQueryGoldenBytes() {
        XCTAssertEqual(ELKFrames.statusQuery,
                       [0x7E, 0x00, 0x01, 0xFA, 0x00, 0x00, 0x00, 0x00, 0xEF])
    }

    func testStatusReplyRecognisesTheEnvelopeAndNothingElse() {
        XCTAssertTrue(ELKFrames.isStatusReply([0x7E, 0, 0, 0, 0, 0, 0, 0, 0xEF]))
        XCTAssertFalse(ELKFrames.isStatusReply([0x7E, 0, 0, 0, 0, 0, 0, 0, 0x00]))
        XCTAssertFalse(ELKFrames.isStatusReply([0x66, 0, 0, 0, 0, 0, 0, 0, 0xEF]))
        XCTAssertFalse(ELKFrames.isStatusReply([0x7E, 0xEF]))
    }

    /// `elkbledom.py` `_ensure_connected`: two three-byte writes, and MELK is
    /// the only dialect documented as needing them. Their length is the point —
    /// they are not truncated nine-byte frames.
    func testOnlyMELKHasLoginWritesAndTheyAreThreeBytes() {
        XCTAssertEqual(ELKDialect.melk.loginWrites,
                       [[0x7E, 0x07, 0x83], [0x7E, 0x04, 0x04]])
        for family in StripFamily.allCases where family != .melk {
            XCTAssertTrue(family.loginWrites.isEmpty, "\(family.displayName)")
        }
        XCTAssertTrue(StripFamily.melk.loginWrites.allSatisfy { $0.count == 3 })
    }
}
