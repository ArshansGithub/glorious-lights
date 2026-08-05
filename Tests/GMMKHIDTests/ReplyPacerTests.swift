import XCTest
@testable import GMMKHID
import GMMKProtocol

/// Tests for the write → wait-for-echo → retry loop, driven with fake replies.
/// No hardware is involved: ``ReplyPacer`` exists precisely so the retry
/// bookkeeping can be checked without a keyboard on the desk.
final class ReplyPacerTests: XCTestCase {

    /// A 64-byte echo as the firmware delivers it: report ID intact, status at
    /// index 7.
    private func echo(status: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = GMMKPacket.reportID
        report[GMMKPacket.replyStatusOffset] = status
        return report
    }

    // MARK: - Happy path

    func testAcknowledgedOnFirstAttempt() {
        var transmissions = 0
        let outcome = ReplyPacer.send(transmit: { transmissions += 1 },
                                      awaitReply: { self.echo(status: 0x00) })
        XCTAssertEqual(outcome, .acknowledged(attempts: 1))
        XCTAssertEqual(transmissions, 1)
    }

    /// A missed echo re-sends the *same* packet; the reply on attempt 3 ends it,
    /// and nothing is sent afterwards.
    func testRetriesUntilAnEchoArrives() {
        var transmissions = 0
        let outcome = ReplyPacer.send(
            transmit: { transmissions += 1 },
            awaitReply: { transmissions >= 3 ? self.echo(status: 0x00) : nil })
        XCTAssertEqual(outcome, .acknowledged(attempts: 3))
        XCTAssertEqual(transmissions, 3)
    }

    // MARK: - Giving up

    /// Four attempts total, matching the official editor, and then the packet is
    /// reported unacknowledged rather than throwing — a missed echo is not a
    /// missed write.
    func testGivesUpAfterFourAttempts() {
        var transmissions = 0
        let outcome = ReplyPacer.send(transmit: { transmissions += 1 },
                                      awaitReply: { nil })
        XCTAssertEqual(outcome, .unacknowledged(attempts: 4))
        XCTAssertEqual(transmissions, 4)
        XCTAssertEqual(ReplyPacer.defaultMaxAttempts, 4)
    }

    func testAttemptLimitIsConfigurableAndNeverBelowOne() {
        var transmissions = 0
        _ = ReplyPacer.send(maxAttempts: 2,
                            transmit: { transmissions += 1 },
                            awaitReply: { nil })
        XCTAssertEqual(transmissions, 2)

        transmissions = 0
        let outcome = ReplyPacer.send(maxAttempts: 0,
                                      transmit: { transmissions += 1 },
                                      awaitReply: { nil })
        XCTAssertEqual(transmissions, 1, "a zero limit must still send once")
        XCTAssertEqual(outcome, .unacknowledged(attempts: 1))
    }

    // MARK: - Rejection

    /// An explicit rejection stops immediately — retrying a packet the firmware
    /// understood and refused would just be refused again.
    func testRejectionStopsWithoutRetrying() {
        for status: UInt8 in [0xFF, 0xFE] {
            var transmissions = 0
            let outcome = ReplyPacer.send(
                transmit: { transmissions += 1 },
                awaitReply: { self.echo(status: status) })
            XCTAssertEqual(outcome, .rejected(status: status, attempts: 1))
            XCTAssertEqual(transmissions, 1, "status 0x\(String(status, radix: 16))")
        }
    }

    /// A rejection after two silent attempts still reports the attempt it
    /// arrived on.
    func testRejectionAfterRetriesReportsTheAttemptCount() {
        var transmissions = 0
        let outcome = ReplyPacer.send(
            transmit: { transmissions += 1 },
            awaitReply: { transmissions >= 3 ? self.echo(status: 0xFF) : nil })
        XCTAssertEqual(outcome, .rejected(status: 0xFF, attempts: 3))
    }

    // MARK: - Odd replies

    /// Any answer at all is enough for the pacing, so an unrecognised status and
    /// a too-short report both count as acknowledged rather than triggering a
    /// re-send. Only 0xFF/0xFE are failures.
    func testUnusualRepliesCountAsAcknowledged() {
        var transmissions = 0
        let odd = ReplyPacer.send(transmit: { transmissions += 1 },
                                  awaitReply: { self.echo(status: 0x42) })
        XCTAssertEqual(odd, .acknowledged(attempts: 1))

        transmissions = 0
        let short = ReplyPacer.send(transmit: { transmissions += 1 },
                                    awaitReply: { [0x04, 0x00] })
        XCTAssertEqual(short, .acknowledged(attempts: 1))
        XCTAssertEqual(transmissions, 1)
    }

    // MARK: - Transport failures

    /// A `SetReport` failure is not something a retry fixes, so it propagates
    /// out of the first attempt untouched.
    func testTransmitErrorPropagatesImmediately() {
        var transmissions = 0
        XCTAssertThrowsError(
            try ReplyPacer.send(transmit: {
                transmissions += 1
                throw GMMKHIDError.notConnected
            }, awaitReply: { nil })
        ) { error in
            guard case GMMKHIDError.notConnected = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(transmissions, 1)
    }

    // MARK: - Timeout constant

    /// 300 ms, matching the official editor's `hid_read` timeout.
    func testDefaultReplyTimeout() {
        XCTAssertEqual(ReplyPacer.defaultReplyTimeout, 0.300, accuracy: 0.0001)
    }
}
