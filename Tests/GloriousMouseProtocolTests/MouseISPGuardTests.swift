import XCTest
@testable import GloriousMouseProtocol

/// ☠️ The never-send list from `docs/mouse-protocol.md` §9.
///
/// These tests exist because the ISP bootloader shares report ID 5 with the
/// configuration protocol: the difference between reading the firmware version
/// and entering DFU is one byte. If any of these ever start failing, stop.
final class MouseISPGuardTests: XCTestCase {

    /// `05 75 00 00 00 00` — named independently by both sinowisp and
    /// libratbag. The device drops off the bus and re-enumerates as the
    /// bootloader.
    func testDFUCommandIsRefused() {
        let frame: [UInt8] = [0x05, 0x75, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(MouseISPGuard.check(commandReport: frame), .ispCommand(0x75))
    }

    func testEveryFlashVerbIsRefused() {
        for command: UInt8 in [0x45, 0x52, 0x55, 0x57, 0x5A, 0x75] {
            let frame: [UInt8] = [0x05, command, 0, 0, 0, 0]
            XCTAssertEqual(MouseISPGuard.check(commandReport: frame), .ispCommand(command),
                           String(format: "command 0x%02x must be refused", command))
        }
    }

    /// Report 6 is the bootloader's page-transfer channel and does not exist on
    /// this device in normal operation.
    func testFeatureReportSixIsRefused() {
        XCTAssertEqual(MouseISPGuard.check(reportID: 0x06), .ispReportID(0x06))
        XCTAssertEqual(MouseISPGuard.check(commandReport: [0x06, 0x72, 0, 0, 0, 0]),
                       .ispReportID(0x06))
    }

    func testConfigAndCommandReportIDsAreAllowed() {
        XCTAssertNil(MouseISPGuard.check(reportID: 0x04))
        XCTAssertNil(MouseISPGuard.check(reportID: 0x05))
    }

    /// Button maps and macro uploads are out of scope; a bad write there costs
    /// the user their button configuration.
    func testOutOfScopeCommandsAreRefused() {
        for command: UInt8 in [0x12, 0x22, 0x32, 0x30, 0x1B] {
            let frame: [UInt8] = [0x05, command, 0, 0, 0, 0]
            XCTAssertEqual(MouseISPGuard.check(commandReport: frame),
                           .outOfScopeCommand(command),
                           String(format: "command 0x%02x must be refused", command))
        }
    }

    /// The guard is an allow-list, not a deny-list: a typo landing in
    /// unexplored command space is refused too, because that space contains
    /// `0x75`.
    func testUndocumentedCommandsAreRefused() {
        for command: UInt8 in [0x00, 0x03, 0x10, 0x74, 0x76, 0xFF] {
            let frame: [UInt8] = [0x05, command, 0, 0, 0, 0]
            XCTAssertEqual(MouseISPGuard.check(commandReport: frame),
                           .unknownCommand(command),
                           String(format: "command 0x%02x must be refused", command))
        }
    }

    /// Everything this project actually sends must pass, or the guard is
    /// useless in practice and someone will disable it.
    func testEverySafeVerbPasses() {
        for command in MouseCommand.allCases {
            let frame = MouseCommandReport.make(command)
            XCTAssertNil(MouseISPGuard.check(commandReport: frame),
                         "\(command.displayName) must be allowed")
        }
        for profile in MouseProfile.allCases {
            XCTAssertNil(MouseISPGuard.check(commandReport: MouseCommandReport.readConfig(profile)))
        }
        XCTAssertNil(MouseISPGuard.check(commandReport: MouseCommandReport.setActiveProfile(.two)))
    }

    /// No safe verb may collide with a forbidden byte — the whole guard rests
    /// on those two sets being disjoint.
    func testSafeVerbsNeverOverlapTheNeverSendList() {
        let safe = Set(MouseCommand.allCases.map(\.rawValue))
        XCTAssertTrue(safe.isDisjoint(with: MouseISPGuard.forbiddenCommandBytes))
        XCTAssertTrue(safe.isDisjoint(with: MouseISPGuard.outOfScopeCommandBytes))
    }
}
