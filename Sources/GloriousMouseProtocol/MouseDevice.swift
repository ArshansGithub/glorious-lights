import Foundation

/// Identity and report geometry of the wired Glorious Model O / O- mouse.
///
/// Source of truth: `docs/mouse-protocol.md` §1. **This is not the keyboard
/// protocol.** There is no `START`/`END` bracketing, no 64-byte command packet,
/// no interrupt OUT channel, and — see ``MouseConfigBlob`` — no checksum
/// anywhere. Nothing in `GMMKProtocol` transfers here.
public enum GloriousMouseDevice {

    /// USB vendor ID (SinoWealth).
    public static let vendorID = 0x258A
    /// USB product ID — wired Model O *and* Model O-. The two are the same
    /// device to software (doc §1); the wireless variants are different PIDs
    /// and are out of scope.
    public static let productID = 0x0036

    /// Vendor-defined usage page of the configuration collection.
    public static let vendorUsagePage = 0xFF00
    /// Vendor-defined usage of the configuration collection.
    public static let vendorUsage = 0x01

    /// FEATURE report carrying the whole configuration blob (doc §1.1).
    public static let configReportID: UInt8 = 0x04
    /// FEATURE report carrying 6-byte commands (doc §1.1, §2).
    public static let commandReportID: UInt8 = 0x05

    /// Total configuration report size **including** the leading report-ID
    /// byte — `SINOWEALTH_CONFIG_REPORT_SIZE` in libratbag, and the value
    /// measured as `MaxFeatureReportSize` on hardware.
    public static let configReportLength = 520
    /// Command report size including the report-ID byte (`SINOWEALTH_CMD_SIZE`).
    public static let commandReportLength = 6

    /// Smallest plausible payload length for a config read
    /// (`SINOWEALTH_CONFIG_SIZE_MIN` territory; libratbag accepts ≥ 123).
    public static let configSizeMin = 123
    /// Largest documented config size, `SINOWEALTH_CONFIG_SIZE_MAX` = `0xA7`.
    public static let configSizeMax = 167

    /// Number of RGB LEDs addressable individually by effect
    /// ``MouseRGBEffect/constant`` (`0x56`–`0x67` is 6 × 3 bytes).
    public static let ledCount = 6
    /// DPI slots present in the blob, whatever vendor software chooses to show.
    public static let dpiSlotCount = 8
    /// Onboard profiles (`SINOWEALTH_NUM_PROFILES_MAX`).
    public static let profileCount = 3
}

// MARK: - Profiles

/// One of the three onboard profiles.
///
/// The raw value is the command byte that both *selects* the profile for a read
/// (report 5) and identifies it in byte `0x01` of a blob write (doc §8).
public enum MouseProfile: UInt8, CaseIterable, Sendable {
    case one   = 0x11
    case two   = 0x21
    case three = 0x31

    /// Zero-based index, as a UI would number it.
    public var index: Int {
        switch self {
        case .one: return 0
        case .two: return 1
        case .three: return 2
        }
    }

    /// One-based index, which is how the device reports and accepts the
    /// *active* profile through command `0x02` (doc §8).
    public var oneBasedIndex: UInt8 { UInt8(index + 1) }

    public init?(index: Int) {
        switch index {
        case 0: self = .one
        case 1: self = .two
        case 2: self = .three
        default: return nil
        }
    }

    /// Parses `1`, `2`, `3` (one-based, as the device counts) or `0x11`-style
    /// command bytes.
    public static func parse(_ input: String) -> MouseProfile? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("0x"), let raw = UInt8(trimmed.dropFirst(2), radix: 16) {
            return MouseProfile(rawValue: raw)
        }
        if let n = Int(trimmed) { return MouseProfile(index: n - 1) }
        return nil
    }

    public var displayName: String { "profile \(index + 1)" }
}

// MARK: - Sensor

/// Optical sensor reported at blob offset `0x09`.
///
/// **Read-only. Never write this byte** (doc §5) — the DPI encoding depends on
/// it, and lying about it would silently rescale every stage.
public enum MouseSensor: UInt8, CaseIterable, Sendable {
    case pmw3360 = 0x06
    case pmw3212 = 0x08
    case pmw3327 = 0x0E
    case pmw3389 = 0x0F

    public var displayName: String {
        switch self {
        case .pmw3360: return "PMW3360"
        case .pmw3212: return "PMW3212"
        case .pmw3327: return "PMW3327"
        case .pmw3389: return "PMW3389"
        }
    }

    /// Highest DPI the sensor accepts.
    public var maximumDPI: Int {
        switch self {
        case .pmw3360, .pmw3389: return 12000
        case .pmw3327: return 10200
        case .pmw3212: return 3200
        }
    }

    /// DPI is always a multiple of this.
    public var dpiStep: Int { 100 }

    /// `raw` → DPI. PMW3360/3327 store `DPI/100 − 1`; the PMW3389 stores
    /// `DPI/100` (doc §6 — the easiest thing here to get wrong by 100 DPI).
    public func dpi(raw: UInt8) -> Int {
        switch self {
        case .pmw3389: return Int(raw) * 100
        default:       return (Int(raw) + 1) * 100
        }
    }

    /// DPI → `raw`, clamped to the sensor's range and snapped to a 100 step.
    public func raw(dpi: Int) -> UInt8 {
        let snapped = min(max(dpi, dpiStep), maximumDPI) / dpiStep * dpiStep
        switch self {
        case .pmw3389: return UInt8(clamping: snapped / 100)
        default:       return UInt8(clamping: snapped / 100 - 1)
        }
    }
}
