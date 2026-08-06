import Foundation
import CoreBluetooth
import StripProtocol

/// Failures from the Bluetooth transport.
///
/// The Bluetooth-unavailable cases are spelled out individually rather than
/// folded into one "Bluetooth error", because they need four different things
/// from the user and only one of them is fixable in Settings.
public enum StripBLEError: Error, CustomStringConvertible {

    /// The app has not been granted Bluetooth permission, or was denied it.
    case unauthorized
    /// Bluetooth is switched off.
    case poweredOff
    /// This machine has no Bluetooth LE.
    case unsupported
    /// The state never resolved within the time allowed.
    case stateNeverResolved(CBManagerState)

    /// A scan found nothing matching in the time allowed.
    case noDevicesFound(scanSeconds: Double)
    /// A name or identifier matched nothing that was seen.
    case deviceNotFound(String, seen: [String])
    /// A name or identifier matched more than one device.
    case ambiguousDevice(String, matches: [String])

    case connectFailed(String, underlying: String?)
    case disconnected(String, underlying: String?)
    case timedOut(during: String, seconds: Double)

    case serviceDiscoveryFailed(String)
    /// Connected and discovered, but none of the family's candidate write
    /// characteristics is present.
    case noWritableCharacteristic(family: StripFamily, found: [String])
    /// A write was attempted against a characteristic that cannot be written.
    case characteristicNotWritable(String)
    case writeFailed(String, underlying: String)
    case notConnected

    /// The family has no frame builder — only ``StripFamily/idealLED``.
    case familyHasNoFrames(StripFamily)

    public var description: String {
        switch self {
        case .unauthorized:
            return """
                This process is not allowed to use Bluetooth. Grant it in System Settings > \
                Privacy & Security > Bluetooth — add the app, or add Terminal when running \
                gmmk-cli from a shell — then run it again. A command-line tool inherits the \
                permission of the terminal that launched it, so the entry to look for may be \
                "Terminal" or "iTerm" rather than anything named after this project.
                """
        case .poweredOff:
            return "Bluetooth is switched off. Turn it on and try again."
        case .unsupported:
            return "This Mac reports no Bluetooth LE support."
        case .stateNeverResolved(let state):
            return """
                CoreBluetooth never reported a usable state (last seen: \
                \(Self.name(of: state))). This usually means the Bluetooth daemon is \
                restarting; wait a moment and try again.
                """
        case .noDevicesFound(let seconds):
            return """
                No Bluetooth LE devices advertised in \(Self.seconds(seconds)). Cheap strip \
                controllers only advertise while they are powered and not already connected \
                to something — check the strip has 5V, and that a phone app is not holding \
                the connection. Only one central can be connected at a time.
                """
        case .deviceNotFound(let wanted, let seen):
            let list = seen.isEmpty ? "nothing at all"
                                    : seen.joined(separator: ", ")
            return "No device matched '\(wanted)'. The scan saw: \(list)."
        case .ambiguousDevice(let wanted, let matches):
            return "'\(wanted)' matched \(matches.count) devices: "
                 + matches.joined(separator: ", ")
                 + ". Use the full name or the identifier UUID."
        case .connectFailed(let name, let underlying):
            return "Failed to connect to \(name)" + (underlying.map { ": \($0)" } ?? ".")
        case .disconnected(let name, let underlying):
            return "\(name) disconnected" + (underlying.map { ": \($0)" } ?? ".")
        case .timedOut(let during, let seconds):
            return "Timed out after \(Self.seconds(seconds)) during \(during)."
        case .serviceDiscoveryFailed(let message):
            return "Service discovery failed: \(message)"
        case .noWritableCharacteristic(let family, let found):
            let wanted = family.gatt.writeCharacteristics.map(\.shortDescription)
                                                         .joined(separator: ", ")
            let have = found.isEmpty ? "none" : found.joined(separator: ", ")
            return """
                Connected, but none of \(family.displayName)'s write characteristics \
                (\(wanted)) is present. The device exposes: \(have). Run `gmmk-cli strip \
                report` for the full dump — the characteristic list is what identifies the \
                family, and this device is not the one that was assumed.
                """
        case .characteristicNotWritable(let uuid):
            return "Characteristic \(uuid) advertises neither write nor write-without-response."
        case .writeFailed(let uuid, let underlying):
            return "Write to \(uuid) failed: \(underlying)"
        case .notConnected:
            return "Not connected to a strip; connect first."
        case .familyHasNoFrames(let family):
            return """
                \(family.displayName) is identified but deliberately not driven by this \
                project. Its commands are AES-encrypted under a fixed key, and the published \
                reverse engineering (8none1/idealLED, whizzy.org) reports that walking its \
                effect IDs past the range the phone app exposes permanently bricked a \
                controller. Identification only.
                """
        }
    }

    public var localizedDescription: String { description }

    /// Maps a CoreBluetooth state onto the error it means, or `nil` when the
    /// state is usable or still settling.
    ///
    /// Public because the app needs it too: it cannot use the blocking
    /// ``StripCentral/waitForPoweredOn(timeout:)`` and so has to translate a
    /// state it observes into the same message the CLI would print.
    public static func forState(_ state: CBManagerState) -> StripBLEError? {
        switch state {
        case .poweredOn: return nil
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .unsupported: return .unsupported
        case .resetting, .unknown: return nil
        @unknown default: return nil
        }
    }

    static func name(of state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "powered on"
        case .poweredOff: return "powered off"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unrecognised (\(state.rawValue))"
        }
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.1fs", value)
    }
}
