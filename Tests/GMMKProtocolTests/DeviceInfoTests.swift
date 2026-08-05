import XCTest
@testable import GMMKProtocol

/// Tests for the device-info block command `0x03` returns on firmware 1.08,
/// driven by a real captured reply.
final class DeviceInfoTests: XCTestCase {

    /// The data area of a real `0x03` reply from the GMMK 1 TKL, fw 1.08.
    /// `55 aa` magic, `ff 02`, VID `45 0c`, PID `2f 65`, version `08 01`,
    /// six unidentified bytes, then the mode-ID list ending in `ff`.
    private let capturedData: [UInt8] = [
        0x55, 0xAA, 0xFF, 0x02, 0x45, 0x0C, 0x2F, 0x65,
        0x08, 0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x07,
        0x09, 0x0B, 0x0A, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x14, 0xFF,
    ]

    /// Wraps a data area in the reply framing the firmware sends: report ID,
    /// checksum, command, count, address, pad, then the data from offset 8.
    private func report(data: [UInt8], length: Int = 64) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: length)
        let start = length == GMMKPacket.payloadLength
            ? GMMKPacket.replyDataOffset - 1
            : GMMKPacket.replyDataOffset
        report[0] = GMMKPacket.reportID
        for (i, byte) in data.enumerated() where start + i < length {
            report[start + i] = byte
        }
        return report
    }

    // MARK: - The captured block

    func testParsesTheCapturedReply() throws {
        let info = try XCTUnwrap(GMMKDeviceInfo(reply: report(data: capturedData)))
        XCTAssertEqual(info.vendorID, 0x0C45)
        XCTAssertEqual(info.productID, 0x652F)
        XCTAssertEqual(info.firmwareVersion, 0x0108)
        XCTAssertEqual(info.firmwareVersionString, "1.08")
    }

    /// The IDs the board reports are the ones the transport matches on.
    func testReportedIDsMatchTheDeviceWeTalkTo() throws {
        let info = try XCTUnwrap(GMMKDeviceInfo(reply: report(data: capturedData)))
        XCTAssertEqual(Int(info.vendorID), 0x0C45)
        XCTAssertEqual(Int(info.productID), 0x652F)
    }

    /// 19 modes, ending at the `0xFF` terminator. The firmware lists them in its
    /// own order — 0x08 before 0x07, 0x0B before 0x0A — which is preserved.
    func testParsesTheSupportedModeList() throws {
        let info = try XCTUnwrap(GMMKDeviceInfo(reply: report(data: capturedData)))
        XCTAssertEqual(info.supportedModeIDs, [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x07, 0x09, 0x0B,
            0x0A, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x14,
        ])
        XCTAssertEqual(info.supportedModeIDs.count, 19)
        XCTAssertFalse(info.supportedModeIDs.contains(0xFF), "terminator must not be included")
    }

    /// Every ID the firmware lists is one this library knows, and mode `0x13`
    /// (off) is the one it does *not* advertise — worth noticing before a UI
    /// offers it.
    func testEveryReportedModeIsKnownAndOffIsAbsent() throws {
        let info = try XCTUnwrap(GMMKDeviceInfo(reply: report(data: capturedData)))
        XCTAssertEqual(info.supportedModes.count, info.supportedModeIDs.count)
        XCTAssertFalse(info.supportedModeIDs.contains(LightingMode.off.rawValue))
        XCTAssertTrue(info.supportedModes.contains(.fixed))
        XCTAssertTrue(info.supportedModes.contains(.custom))
    }

    // MARK: - Framing

    /// A 63-byte delivery (report ID stripped) shifts the data area one earlier
    /// and must parse identically.
    func testParsesAnIDLessReport() throws {
        let long = try XCTUnwrap(GMMKDeviceInfo(reply: report(data: capturedData)))
        let short = try XCTUnwrap(
            GMMKDeviceInfo(reply: report(data: capturedData,
                                         length: GMMKPacket.payloadLength)))
        XCTAssertEqual(short, long)
    }

    // MARK: - Rejection

    /// A command echo is not an info block; without the magic, parsing must fail
    /// rather than read framing bytes as a firmware version.
    func testRejectsAnOrdinaryEcho() {
        let echo = [GMMKPacket.reportID] + GMMKPacket.setMode(.fixed)
        XCTAssertNil(GMMKDeviceInfo(reply: echo))
    }

    func testRejectsWrongMagic() {
        var data = capturedData
        data[0] = 0x54
        XCTAssertNil(GMMKDeviceInfo(reply: report(data: data)))
    }

    func testRejectsATruncatedReport() {
        XCTAssertNil(GMMKDeviceInfo(reply: []))
        XCTAssertNil(GMMKDeviceInfo(reply: [0x04, 0x00, 0x00, 0x03]))
        // Long enough for the magic, too short for the mode list.
        XCTAssertNil(GMMKDeviceInfo(reply: report(data: Array(capturedData.prefix(12)),
                                                  length: 24)))
    }

    // MARK: - Version formatting

    /// The low byte is zero-padded: 0x0108 is "1.08", not "1.8".
    func testVersionStringPadsTheMinor() {
        func version(_ raw: UInt16) -> String {
            GMMKDeviceInfo(vendorID: 0, productID: 0,
                           firmwareVersion: raw, supportedModeIDs: []).firmwareVersionString
        }
        XCTAssertEqual(version(0x0108), "1.08")
        XCTAssertEqual(version(0x0100), "1.00")
        XCTAssertEqual(version(0x0210), "2.16")
        XCTAssertEqual(version(0x0A63), "10.99")
    }

    // MARK: - Truncation guard

    /// A list that runs into the packet's zero padding stops there: `0x00` is no
    /// more a valid mode ID than the `0xFF` terminator is.
    func testModeListStopsAtPadding() throws {
        var data = Array(capturedData.prefix(GMMKDeviceInfo.modeListOffset))
        data += [0x01, 0x02, 0x00, 0x05]
        let info = try XCTUnwrap(GMMKDeviceInfo(reply: report(data: data)))
        XCTAssertEqual(info.supportedModeIDs, [0x01, 0x02])
    }
}
