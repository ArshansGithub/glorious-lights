import Foundation

/// The safe verbs of the report-5 command channel (doc §2.1).
///
/// This enum deliberately contains **only** commands this project is willing to
/// send. The destructive ISP verbs are not cases here; they live in
/// ``MouseISPGuard`` as things to refuse. See ``MouseISPGuard`` before adding
/// anything.
public enum MouseCommand: UInt8, CaseIterable, Sendable {
    /// Reply bytes 2‥5 are 4 ASCII characters, e.g. `V103`.
    case firmwareVersion = 0x01
    /// Read: `reply[2]` is the active profile, **1-based**. Write: `buf[2]` is
    /// index + 1.
    case activeProfile = 0x02
    /// Arms report 4 to return profile 1's blob.
    case readConfig1 = 0x11
    /// `reply[2] × 2` is the debounce time in milliseconds.
    case debounce = 0x1A
    case readConfig2 = 0x21
    case readConfig3 = 0x31

    public var displayName: String {
        switch self {
        case .firmwareVersion: return "firmware version"
        case .activeProfile: return "active profile"
        case .readConfig1: return "read config (profile 1)"
        case .debounce: return "debounce"
        case .readConfig2: return "read config (profile 2)"
        case .readConfig3: return "read config (profile 3)"
        }
    }
}

/// Builders for the six-byte FEATURE report 5 (doc §2).
///
/// Wire shape is always `05 <cmd> <arg0> <arg1> <arg2> <arg3>`, report ID
/// included at index 0, unused bytes zero.
public enum MouseCommandReport {

    public static let reportID = GloriousMouseDevice.commandReportID
    public static let length = GloriousMouseDevice.commandReportLength

    /// Debounce times the firmware and libratbag both accept, in milliseconds.
    /// (Hardware reportedly accepts 2 ms; Glorious's software refuses to offer
    /// it and libratbag rejects it, so neither do we.)
    public static let debounceTimesMilliseconds: [Int] = [4, 6, 8, 10, 12, 14, 16]

    /// Assembles a command report. `arguments` is zero-padded to fill the frame.
    public static func make(_ command: MouseCommand, arguments: [UInt8] = []) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: length)
        report[0] = reportID
        report[1] = command.rawValue
        for (i, byte) in arguments.prefix(length - 2).enumerated() {
            report[2 + i] = byte
        }
        return report
    }

    /// `05 01 00 00 00 00` — the cheapest proof the command channel works
    /// (doc §12 step 2).
    public static let firmwareVersion = make(.firmwareVersion)

    /// `05 02 00 00 00 00` — read the active profile.
    public static let readActiveProfile = make(.activeProfile)

    /// `05 02 <index+1> 00 00 00` — set the active profile, 1-based on the wire.
    public static func setActiveProfile(_ profile: MouseProfile) -> [UInt8] {
        make(.activeProfile, arguments: [profile.oneBasedIndex])
    }

    /// `05 11|21|31 00 00 00 00` — arms report 4 to return that profile's blob.
    public static func readConfig(_ profile: MouseProfile) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: length)
        report[0] = reportID
        report[1] = profile.rawValue
        return report
    }

    /// `05 1a 00 00 00 00` — read the debounce time.
    public static let readDebounce = make(.debounce)

    /// `05 1a <ms/2> 00 00 00`.
    ///
    /// - Throws: ``MouseCommandError/invalidDebounceTime(_:)`` outside the
    ///   documented 4–16 ms even values.
    public static func setDebounce(milliseconds: Int) throws -> [UInt8] {
        guard debounceTimesMilliseconds.contains(milliseconds) else {
            throw MouseCommandError.invalidDebounceTime(milliseconds)
        }
        return make(.debounce, arguments: [UInt8(milliseconds / 2)])
    }

    // MARK: - Reply decoding

    /// Whether a report-5 reply echoes `command` in byte 1 — libratbag's own
    /// validity oracle, and a `-EIO` for it when it fails (doc §2).
    ///
    /// Also the honest way to detect an *unsupported* command: doc §7 says a
    /// debounce read whose echo does not match means "unsupported", not "0 ms".
    public static func replyEchoes(_ command: MouseCommand, in reply: [UInt8]) -> Bool {
        reply.count >= 2 && reply[1] == command.rawValue
    }

    /// The four ASCII characters of a `FIRMWARE_VERSION` reply.
    public static func firmwareVersion(fromReply reply: [UInt8]) -> String? {
        guard replyEchoes(.firmwareVersion, in: reply), reply.count >= 6 else { return nil }
        let scalars = reply[2..<6].map { Character(UnicodeScalar($0)) }
        return String(scalars)
    }

    /// The active profile from an `ACTIVE_PROFILE` reply (`reply[2]` is 1-based).
    public static func activeProfile(fromReply reply: [UInt8]) -> MouseProfile? {
        guard replyEchoes(.activeProfile, in: reply), reply.count >= 3 else { return nil }
        return MouseProfile(index: Int(reply[2]) - 1)
    }

    /// Debounce milliseconds from a `DEBOUNCE` reply (`reply[2] × 2`).
    /// `nil` when the echo fails, which means the command is unsupported here.
    public static func debounceMilliseconds(fromReply reply: [UInt8]) -> Int? {
        guard replyEchoes(.debounce, in: reply), reply.count >= 3 else { return nil }
        return Int(reply[2]) * 2
    }
}

/// Refusals from ``MouseCommandReport``.
public enum MouseCommandError: Error, CustomStringConvertible {
    case invalidDebounceTime(Int)

    public var description: String {
        switch self {
        case .invalidDebounceTime(let ms):
            return "Debounce must be one of "
                 + MouseCommandReport.debounceTimesMilliseconds.map(String.init).joined(separator: ", ")
                 + " milliseconds, got \(ms)."
        }
    }
}

// MARK: - ISP hazard

/// ☠️ The never-send list (doc §9).
///
/// **The ISP bootloader shares report ID 5 with the configuration protocol.**
/// On the GMMK keyboard the bootloader door is a different interface that can
/// simply never be touched; here it is one wrong command byte away on the same
/// six-byte feature report as `FIRMWARE_VERSION`. `05 75 00 00 00 00` enters
/// DFU — named independently by both `sinowisp` and libratbag — after which the
/// device re-enumerates as `0603:1020`. That state is recoverable by replugging;
/// it becomes a brick only if something then erases or writes flash, which is
/// exactly what the other five verbs below do.
///
/// Consequences encoded here, not left to reviewer discipline:
///
/// * **Never sweep report 5.** A sweep of the command space hits `0x75`.
/// * **Never touch feature report `0x06`.** It does not exist on this device in
///   normal operation; if it answers, you are talking to the bootloader.
public enum MouseISPGuard {

    /// Command bytes that must never appear at index 1 of a report-5 frame.
    public static let forbiddenCommandBytes: Set<UInt8> = [
        0x45,  // CMD_ERASE — erases flash
        0x52,  // CMD_INIT_READ — arms a flash read
        0x55,  // CMD_ENABLE_FIRMWARE — writes an LJMP opcode into flash
        0x57,  // CMD_INIT_WRITE — arms a flash write
        0x5A,  // CMD_REBOOT
        0x75,  // DFU — enters the ISP bootloader
    ]

    /// Report IDs that must never be addressed at all. `0x06` is the
    /// bootloader's 2048-byte page-transfer channel.
    public static let forbiddenReportIDs: Set<UInt8> = [0x06]

    /// Commands that are not ISP verbs but are out of scope for a lighting app,
    /// and whose misuse costs the user their button map or macros (doc §9).
    public static let outOfScopeCommandBytes: Set<UInt8> = [
        0x12, 0x22, 0x32,  // button maps
        0x30,              // macro upload
        0x1B,              // LONG_ANGLESNAPPING_AND_LOD — does not work on this device
    ]

    /// Why a frame was refused.
    public enum Violation: Equatable, CustomStringConvertible {
        case ispCommand(UInt8)
        case ispReportID(UInt8)
        case outOfScopeCommand(UInt8)
        case unknownCommand(UInt8)
        /// A six-byte command frame whose byte 0 is not `0x05`.
        case wrongCommandReportID(UInt8)
        /// A command frame too short to be checked at all.
        case malformedCommandReport(Int)

        public var description: String {
            switch self {
            case .ispCommand(let byte):
                return String(format: """
                    Refusing to send command 0x%02x on feature report 5: it is a SinoWealth ISP \
                    bootloader verb (docs/mouse-protocol.md §9). 0x75 enters DFU; \
                    0x45/0x52/0x55/0x57/0x5a erase, arm or reboot flash. This is the one \
                    channel on this device that can brick it.
                    """, byte)
            case .ispReportID(let id):
                return String(format: """
                    Refusing to address feature report 0x%02x. Report 0x06 is the ISP \
                    bootloader's page-transfer channel and does not exist on this device in \
                    normal operation (docs/mouse-protocol.md §9).
                    """, id)
            case .outOfScopeCommand(let byte):
                return String(format: """
                    Refusing to send command 0x%02x: it is outside this project's scope \
                    (button maps, macros, or the angle-snapping/LOD command that does not \
                    work on the Model O). A bad write there costs the user their button \
                    configuration.
                    """, byte)
            case .unknownCommand(let byte):
                return String(format: """
                    Refusing to send command 0x%02x: it is not one of the documented safe \
                    verbs (docs/mouse-protocol.md §2.1). The command byte has no length or \
                    checksum protection and the destructive verbs sit amid the safe ones, so \
                    unknown bytes are never sent.
                    """, byte)
            case .wrongCommandReportID(let id):
                return String(format: """
                    Refusing to send a six-byte command frame addressed to feature report \
                    0x%02x. The command channel is report 0x%02x and nothing else \
                    (docs/mouse-protocol.md §2); a six-byte frame on report 0x04 would be a \
                    truncated write to the 520-byte configuration blob, and the safe-verb \
                    allow-list below only means anything on report 5.
                    """, id, GloriousMouseDevice.commandReportID)
            case .malformedCommandReport(let count):
                return String(format: """
                    Refusing to send a %d-byte frame on the command channel: a report-5 frame \
                    is exactly %d bytes, report ID included (docs/mouse-protocol.md §2). A \
                    frame too short to carry a command byte cannot be checked, so it is \
                    refused rather than passed through.
                    """, count, GloriousMouseDevice.commandReportLength)
            }
        }
    }

    /// Checks a full six-byte report-5 frame, report ID included.
    ///
    /// Allow-list, not deny-list: anything that is not a documented safe verb is
    /// refused, because the deny-list alone would still let a typo through into
    /// unexplored command space.
    ///
    /// The **report ID is part of the check**, not context: byte 0 must be
    /// `0x05`. A six-byte frame carrying `0x04` at byte 0 is not a command at
    /// all — it is a truncated configuration write, and the config report's own
    /// guards (520-byte length, write marker) live in the transport, not here.
    /// Anything shorter than two bytes is refused rather than waved through,
    /// because "nothing to check" is not "nothing wrong".
    public static func check(commandReport report: [UInt8]) -> Violation? {
        guard let id = report.first else { return .malformedCommandReport(report.count) }
        if forbiddenReportIDs.contains(id) { return .ispReportID(id) }
        guard id == GloriousMouseDevice.commandReportID else { return .wrongCommandReportID(id) }
        guard report.count >= 2 else { return .malformedCommandReport(report.count) }
        let command = report[1]
        if forbiddenCommandBytes.contains(command) { return .ispCommand(command) }
        if outOfScopeCommandBytes.contains(command) { return .outOfScopeCommand(command) }
        // The three profile-read verbs 0x11/0x21/0x31 are cases of
        // `MouseCommand` too, so this one check covers them.
        return MouseCommand(rawValue: command) == nil ? .unknownCommand(command) : nil
    }

    /// Checks a report ID on its own, before any transfer.
    public static func check(reportID id: UInt8) -> Violation? {
        forbiddenReportIDs.contains(id) ? .ispReportID(id) : nil
    }
}
