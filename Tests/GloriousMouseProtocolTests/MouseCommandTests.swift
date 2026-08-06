import XCTest
@testable import GloriousMouseProtocol

/// Golden bytes for the report-5 command channel, taken from
/// `docs/mouse-protocol.md` §2–§3 and §12.
final class MouseCommandTests: XCTestCase {

    // MARK: - Frame shape

    func testCommandFrameIsSixBytesWithReportIDFirst() {
        let frame = MouseCommandReport.make(.firmwareVersion)
        XCTAssertEqual(frame.count, 6)
        XCTAssertEqual(frame[0], 0x05)
    }

    /// Doc §12 step 2: `05 01 00 00 00 00`.
    func testFirmwareVersionGoldenBytes() {
        XCTAssertEqual(MouseCommandReport.firmwareVersion,
                       [0x05, 0x01, 0x00, 0x00, 0x00, 0x00])
    }

    /// Doc §3: `05 11 00 00 00 00` arms the report-4 read for profile 1.
    func testReadConfigGoldenBytesPerProfile() {
        XCTAssertEqual(MouseCommandReport.readConfig(.one),
                       [0x05, 0x11, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(MouseCommandReport.readConfig(.two),
                       [0x05, 0x21, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(MouseCommandReport.readConfig(.three),
                       [0x05, 0x31, 0x00, 0x00, 0x00, 0x00])
    }

    /// Doc §8: the active profile is 1-based on the wire.
    func testSetActiveProfileIsOneBased() {
        XCTAssertEqual(MouseCommandReport.setActiveProfile(.one),
                       [0x05, 0x02, 0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(MouseCommandReport.setActiveProfile(.three),
                       [0x05, 0x02, 0x03, 0x00, 0x00, 0x00])
    }

    /// Doc §7: `05 1a <ms/2> 00 00 00`.
    func testDebounceEncodesHalfMilliseconds() throws {
        XCTAssertEqual(try MouseCommandReport.setDebounce(milliseconds: 4),
                       [0x05, 0x1A, 0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(try MouseCommandReport.setDebounce(milliseconds: 16),
                       [0x05, 0x1A, 0x08, 0x00, 0x00, 0x00])
        XCTAssertEqual(MouseCommandReport.readDebounce,
                       [0x05, 0x1A, 0x00, 0x00, 0x00, 0x00])
    }

    /// libratbag rejects anything outside 4–16 ms even though the hardware
    /// reportedly accepts 2 ms (doc §7).
    func testDebounceRejectsUndocumentedTimes() {
        XCTAssertThrowsError(try MouseCommandReport.setDebounce(milliseconds: 2))
        XCTAssertThrowsError(try MouseCommandReport.setDebounce(milliseconds: 5))
        XCTAssertThrowsError(try MouseCommandReport.setDebounce(milliseconds: 18))
    }

    // MARK: - Reply decoding

    /// Doc §2: byte 1 must echo the command; libratbag treats a mismatch as -EIO.
    func testReplyEchoIsTheValidityOracle() {
        let good: [UInt8] = [0x05, 0x01, 0x56, 0x31, 0x30, 0x33]
        XCTAssertTrue(MouseCommandReport.replyEchoes(.firmwareVersion, in: good))
        let bad: [UInt8] = [0x05, 0x00, 0x56, 0x31, 0x30, 0x33]
        XCTAssertFalse(MouseCommandReport.replyEchoes(.firmwareVersion, in: bad))
    }

    func testFirmwareVersionDecodesFourASCIIBytes() {
        let reply: [UInt8] = [0x05, 0x01, 0x56, 0x31, 0x30, 0x33]  // "V103"
        XCTAssertEqual(MouseCommandReport.firmwareVersion(fromReply: reply), "V103")
    }

    func testFirmwareVersionRefusesUnechoedReply() {
        let reply: [UInt8] = [0x05, 0x11, 0x56, 0x31, 0x30, 0x33]
        XCTAssertNil(MouseCommandReport.firmwareVersion(fromReply: reply))
    }

    func testActiveProfileDecodesOneBasedReply() {
        XCTAssertEqual(MouseCommandReport.activeProfile(
            fromReply: [0x05, 0x02, 0x01, 0, 0, 0]), .one)
        XCTAssertEqual(MouseCommandReport.activeProfile(
            fromReply: [0x05, 0x02, 0x03, 0, 0, 0]), .three)
        // 0 is not a profile: the device counts from 1.
        XCTAssertNil(MouseCommandReport.activeProfile(fromReply: [0x05, 0x02, 0x00, 0, 0, 0]))
    }

    func testDebounceReplyDoublesTheByte() {
        XCTAssertEqual(MouseCommandReport.debounceMilliseconds(
            fromReply: [0x05, 0x1A, 0x05, 0, 0, 0]), 10)
    }

    /// Doc §7: a non-echoing debounce reply means "unsupported", not "0 ms".
    func testUnechoedDebounceReplyIsNilNotZero() {
        XCTAssertNil(MouseCommandReport.debounceMilliseconds(
            fromReply: [0x05, 0x00, 0x05, 0, 0, 0]))
    }

    // MARK: - Profiles

    func testProfileParsingIsOneBasedForHumans() {
        XCTAssertEqual(MouseProfile.parse("1"), .one)
        XCTAssertEqual(MouseProfile.parse("3"), .three)
        XCTAssertEqual(MouseProfile.parse("0x21"), .two)
        XCTAssertNil(MouseProfile.parse("0"))
        XCTAssertNil(MouseProfile.parse("4"))
    }

    func testProfileIndexAndWireValueDoNotDrift() {
        for profile in MouseProfile.allCases {
            XCTAssertEqual(Int(profile.oneBasedIndex), profile.index + 1)
            XCTAssertEqual(MouseProfile(index: profile.index), profile)
        }
    }
}
