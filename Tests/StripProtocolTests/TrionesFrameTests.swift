import XCTest
@testable import StripProtocol

/// Golden bytes for the Triones / HappyLighting protocol.
///
/// Vectors are quoted from `madhead/saberlight`
/// `protocols/Triones/protocol.md`, which publishes literal example frames;
/// `trionesControl`, `ha-triones` and `flux_led` agree with all of them.
final class TrionesFrameTests: XCTestCase {

    /// saberlight, verbatim.
    func testColorGoldenBytes() {
        XCTAssertEqual(TrionesFrames.color(StripRGB(red: 0xFF, green: 0, blue: 0)),
                       [0x56, 0xFF, 0x00, 0x00, 0x00, 0xF0, 0xAA])
        XCTAssertEqual(TrionesFrames.color(StripRGB(red: 0, green: 0xFF, blue: 0)),
                       [0x56, 0x00, 0xFF, 0x00, 0x00, 0xF0, 0xAA])
        XCTAssertEqual(TrionesFrames.color(StripRGB(red: 0, green: 0, blue: 0xFF)),
                       [0x56, 0x00, 0x00, 0xFF, 0x00, 0xF0, 0xAA])
    }

    /// saberlight's "static violet", verbatim: `56 5A 00 9D 00 F0 AA`.
    func testColorGoldenBytesForANonPrimary() {
        XCTAssertEqual(TrionesFrames.color(StripRGB(red: 0x5A, green: 0x00, blue: 0x9D)),
                       [0x56, 0x5A, 0x00, 0x9D, 0x00, 0xF0, 0xAA])
        XCTAssertEqual(TrionesFrames.color(StripRGB(red: 0x11, green: 0x22, blue: 0x33)),
                       [0x56, 0x11, 0x22, 0x33, 0x00, 0xF0, 0xAA])
    }

    /// `CC 23 33` / `CC 24 33` — the one thing all four sources state
    /// identically.
    func testPowerGoldenBytes() {
        XCTAssertEqual(TrionesFrames.power(on: true), [0xCC, 0x23, 0x33])
        XCTAssertEqual(TrionesFrames.power(on: false), [0xCC, 0x24, 0x33])
    }

    /// The white channel is mode `0x0F`, and the three colour bytes are
    /// ignored — saberlight proves it by filling them with `DE AD FF` in one
    /// example and `CA FE 00` in another and getting the same result. Zeroed
    /// here, as every shipping implementation does.
    func testWhiteUsesTheWhiteModeByteAndZeroesTheColorBytes() {
        XCTAssertEqual(TrionesFrames.white(intensity: 0x01),
                       [0x56, 0x00, 0x00, 0x00, 0x01, 0x0F, 0xAA])
        XCTAssertEqual(TrionesFrames.white(intensity: 0xFF),
                       [0x56, 0x00, 0x00, 0x00, 0xFF, 0x0F, 0xAA])
    }

    /// saberlight, verbatim: `BB 27 1F 44` is green gradual change at its
    /// slowest, `BB 34 10 44` is a fast yellow strobe.
    func testEffectGoldenBytes() {
        XCTAssertEqual(TrionesFrames.effect(.greenFade, speed: 0x1F),
                       [0xBB, 0x27, 0x1F, 0x44])
        XCTAssertEqual(TrionesFrames.effect(.yellowStrobe, speed: 0x10),
                       [0xBB, 0x34, 0x10, 0x44])
    }

    /// saberlight's `mode.go` rejects anything outside `0x25`…`0x38`, and
    /// `trionesControl` bounds-checks the same 37…56.
    func testEffectIDsCoverTheDocumentedRangeWithoutGaps() {
        XCTAssertEqual(TrionesEffect.allCases.map(\.rawValue), Array(0x25...0x38))
    }

    func testEffectNamesRoundTrip() {
        for effect in TrionesEffect.allCases {
            XCTAssertEqual(TrionesEffect(commandName: effect.commandName), effect)
        }
        XCTAssertNil(TrionesEffect(commandName: "rainbow"))
    }

    func testStatusQueryGoldenBytes() {
        XCTAssertEqual(TrionesFrames.statusQuery, [0xEF, 0x01, 0x77])
    }

    /// saberlight, verbatim — a strip that is on and showing static red:
    /// `66 15 23 41 20 00 FF 00 00 00 06 99`.
    func testStatusReplyDecodesTheGoldenNotification() throws {
        let bytes: [UInt8] = [0x66, 0x15, 0x23, 0x41, 0x20, 0x00,
                              0xFF, 0x00, 0x00, 0x00, 0x06, 0x99]
        let status = try XCTUnwrap(TrionesFrames.status(fromNotification: bytes))
        XCTAssertTrue(status.isOn)
        XCTAssertEqual(status.mode, 0x41)
        XCTAssertEqual(status.color, StripRGB(red: 0xFF, green: 0, blue: 0))
        XCTAssertEqual(status.white, 0x00)
        // 0x41 is "showing a static colour", which is not a preset effect.
        XCTAssertNil(status.effect)
    }

    /// The same reply with the power byte flipped to `0x24`.
    func testStatusReplyReadsThePowerByte() throws {
        var bytes: [UInt8] = [0x66, 0x15, 0x23, 0x41, 0x20, 0x00,
                              0xFF, 0x00, 0x00, 0x00, 0x06, 0x99]
        bytes[2] = 0x24
        XCTAssertEqual(try XCTUnwrap(TrionesFrames.status(fromNotification: bytes)).isOn, false)
    }

    /// A notification that is the wrong length, or lacks either magic byte, or
    /// carries a power byte that is neither on nor off, is not a status reply.
    /// Guessing at a malformed one would put invented state on screen during
    /// the exact session where the screen is the only evidence.
    func testStatusReplyRejectsAnythingThatIsNotOne() {
        let good: [UInt8] = [0x66, 0x15, 0x23, 0x41, 0x20, 0x00,
                             0xFF, 0x00, 0x00, 0x00, 0x06, 0x99]
        XCTAssertNil(TrionesFrames.status(fromNotification: Array(good.dropLast())))
        var wrongHead = good; wrongHead[0] = 0x7E
        XCTAssertNil(TrionesFrames.status(fromNotification: wrongHead))
        var wrongTail = good; wrongTail[11] = 0x00
        XCTAssertNil(TrionesFrames.status(fromNotification: wrongTail))
        var wrongPower = good; wrongPower[2] = 0x00
        XCTAssertNil(TrionesFrames.status(fromNotification: wrongPower))
    }
}
