import Foundation
import IOKit.hid

/// Failures from the HID transport.
public enum GMMKHIDError: Error, CustomStringConvertible {
    /// No device matching VID `0x0C45` / PID `0x652F` with the vendor usage
    /// pair `(0xFF1C, 0x92)` is currently attached.
    case deviceNotFound
    /// `IOHIDDeviceOpen` failed.
    case openFailed(IOReturn)
    /// A send was attempted while no device was open.
    case notConnected
    /// `IOHIDDeviceSetReport` failed.
    case setReportFailed(IOReturn)
    /// The payload was not the expected 63 bytes.
    case invalidPayloadLength(Int)

    public var description: String {
        switch self {
        case .deviceNotFound:
            return """
                GMMK keyboard not found (expected USB 0C45:652F with vendor usage page \
                0xFF1C usage 0x92). Check that the keyboard is plugged in.
                """
        case .openFailed(let code):
            return """
                Failed to open the GMMK vendor HID interface (IOReturn 0x\
                \(String(UInt32(bitPattern: code), radix: 16))). macOS usually blocks \
                opening a keyboard HID device until the running process is granted \
                Input Monitoring permission: System Settings > Privacy & Security > \
                Input Monitoring, add the app (or Terminal, when running the CLI from \
                a shell), then restart it.
                """
        case .notConnected:
            return "No GMMK keyboard is open; call open() first."
        case .setReportFailed(let code):
            return """
                IOHIDDeviceSetReport failed (IOReturn 0x\
                \(String(UInt32(bitPattern: code), radix: 16))). The device may have \
                been unplugged, or the process lacks Input Monitoring permission.
                """
        case .invalidPayloadLength(let n):
            return "Expected a 63-byte payload without the leading 0x04 report ID, got \(n)."
        }
    }

    public var localizedDescription: String { description }
}
