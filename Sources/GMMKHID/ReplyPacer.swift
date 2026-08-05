import Foundation
import GMMKProtocol

/// How one paced packet ended.
public enum PacedSendOutcome: Equatable, Sendable {
    /// The firmware echoed the packet with an accepting status.
    /// `attempts` counts transmissions, so `1` means it answered first time.
    case acknowledged(attempts: Int)
    /// The firmware echoed the packet with status `0xFF` or `0xFE`.
    case rejected(status: UInt8, attempts: Int)
    /// No echo arrived within the timeout on any attempt.
    case unacknowledged(attempts: Int)
}

/// The write → wait-for-echo → retry loop, with the I/O factored out so it can
/// be tested without hardware.
///
/// Firmware 1.08 only latches a config change into the running effect engine
/// when packets are **paced**: a blind burst is stored in config RAM but is not
/// applied. Waiting for each packet's echo before sending the next is both the
/// pacing and the acknowledgement, and it is what the official editor does
/// (write, then `hid_read` with a 300 ms timeout, retrying up to four times).
/// Echoes come back within a few milliseconds, so this is fast — far faster
/// than the ~350 ms fixed gaps that were the other thing observed to work.
///
/// See `docs/protocol-tkl-notes.md` §13.7.
public enum ReplyPacer {

    /// Transmissions per packet before giving up, matching the official editor.
    public static let defaultMaxAttempts = 4

    /// How long to wait for one echo, matching the official editor's
    /// `hid_read` timeout.
    public static let defaultReplyTimeout: TimeInterval = 0.300

    /// Sends one packet and waits for its echo, retrying on silence.
    ///
    /// - Parameters:
    ///   - maxAttempts: transmissions before giving up. Values below 1 are
    ///     treated as 1.
    ///   - transmit: performs one `SetReport`. A throw propagates immediately —
    ///     a transport failure is not something a retry can fix.
    ///   - awaitReply: blocks for up to the reply timeout and returns the echo,
    ///     or `nil` if none arrived.
    /// - Returns: how it ended. A timeout is *not* an error: writes are known to
    ///   land even when the echo is missed, so the caller should carry on to the
    ///   next packet rather than abandon the transaction.
    public static func send(maxAttempts: Int = defaultMaxAttempts,
                            transmit: () throws -> Void,
                            awaitReply: () -> [UInt8]?) rethrows -> PacedSendOutcome {
        let attemptLimit = max(1, maxAttempts)
        for attempt in 1...attemptLimit {
            try transmit()
            guard let reply = awaitReply() else { continue }
            switch GMMKPacket.replyStatus(inReport: reply) {
            case .rejected(let status):
                return .rejected(status: status, attempts: attempt)
            case .ok, .other, .malformed:
                // A malformed echo still proves the firmware answered, which is
                // all the pacing needs; only an explicit rejection is a failure.
                return .acknowledged(attempts: attempt)
            }
        }
        return .unacknowledged(attempts: attemptLimit)
    }
}
