import Foundation
import IOKit.hid
import GloriousMouseProtocol

/// Failures from the mouse HID transport.
public enum GloriousMouseHIDError: Error, CustomStringConvertible {
    /// No device matching VID `0x258A` / PID `0x0036` with the vendor usage
    /// pair `(0xFF00, 0x01)` is currently attached.
    case deviceNotFound
    /// `IOHIDDeviceOpen` failed — almost always Input Monitoring.
    case openFailed(IOReturn)
    /// A transfer was attempted while no device was open.
    case notConnected
    /// `IOHIDDeviceSetReport` failed.
    case setReportFailed(reportID: UInt8, IOReturn)
    /// `IOHIDDeviceGetReport` failed.
    case getReportFailed(reportID: UInt8, IOReturn)
    /// A report-5 reply did not echo the command byte — libratbag's own
    /// validity oracle. Also what an *unsupported* command looks like.
    case commandNotEchoed(sent: UInt8, echoed: UInt8)
    /// The config read came back with a command byte that is not the profile
    /// that was asked for.
    case configReadNotEchoed(expected: UInt8, got: UInt8)
    /// The device returned fewer bytes than any documented config size.
    case configReadTooShort(Int)
    /// A blob was handed to ``GloriousMouse/writeConfig(_:)`` without the
    /// `configSize − 8` write marker at byte `0x03`.
    case blobNotMarkedForWrite
    /// A payload was the wrong size for its report.
    case invalidReportLength(reportID: UInt8, expected: Int, got: Int)
    /// ☠️ The frame matched the ISP never-send list. See doc §9.
    case ispHazard(MouseISPGuard.Violation)

    public var description: String {
        switch self {
        case .deviceNotFound:
            return """
                Glorious Model O / O- not found (expected USB 258a:0036 with vendor usage \
                page 0xFF00 usage 0x01). Check that the mouse is plugged in, and that it is \
                the wired model — the wireless Model O uses different product IDs and a \
                different controller entirely.
                """
        case .openFailed(let code):
            return """
                Failed to open the mouse's vendor HID interface (IOReturn 0x\
                \(String(UInt32(bitPattern: code), radix: 16))). macOS blocks opening a \
                pointing-device HID interface until the running process is granted Input \
                Monitoring permission: System Settings > Privacy & Security > Input \
                Monitoring, add the app (or Terminal, when running the CLI from a shell), \
                then restart it.
                """
        case .notConnected:
            return "No Glorious mouse is open; call open() first."
        case .setReportFailed(let id, let code):
            return String(format: "IOHIDDeviceSetReport on feature report 0x%02x failed ", id)
                 + "(IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16))). The device may "
                 + "have been unplugged, or the process lacks Input Monitoring permission."
        case .getReportFailed(let id, let code):
            return String(format: "IOHIDDeviceGetReport on feature report 0x%02x failed ", id)
                 + "(IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16))). The device may "
                 + "have been unplugged, or the process lacks Input Monitoring permission."
        case .commandNotEchoed(let sent, let echoed):
            return String(format: """
                The mouse answered command 0x%02x with 0x%02x in byte 1. libratbag treats a \
                missing echo as an I/O error; for command 0x1a (debounce) it more likely means \
                the command is unsupported on this unit rather than that anything went wrong.
                """, sent, echoed)
        case .configReadNotEchoed(let expected, let got):
            return String(format: """
                The configuration blob came back with command byte 0x%02x, expected 0x%02x. \
                The read was not armed by the report-5 command, so the contents cannot be \
                trusted — do not write this blob back.
                """, got, expected)
        case .configReadTooShort(let n):
            return """
                The mouse returned \(n) configuration bytes; the documented range is \
                \(GloriousMouseDevice.configSizeMin)…\(GloriousMouseDevice.configSizeMax). \
                Something other than the config blob answered.
                """
        case .blobNotMarkedForWrite:
            return """
                Refusing to write a blob whose byte 0x03 is 0x00. That value means "read"; the \
                device would ignore the write. Use MouseConfigBlob.preparedForWrite(profile:\
                configSize:) — and be sure of the config size first, because it is the single \
                most important open question in docs/mouse-protocol.md (§11 item 1).
                """
        case .invalidReportLength(let id, let expected, let got):
            return String(format: "Feature report 0x%02x takes %d bytes including the report ID, "
                          + "got %d.", id, expected, got)
        case .ispHazard(let violation):
            return violation.description
        }
    }

    public var localizedDescription: String { description }
}
