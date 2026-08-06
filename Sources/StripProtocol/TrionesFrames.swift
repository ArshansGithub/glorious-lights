import Foundation

/// The Triones / HappyLighting protocol — `0x56` colour, `0xCC` power,
/// `0xBB` effect. Also called LEDENET "original" by `flux_led`.
///
/// The simplest of the families: no checksum, no length, no counter, no
/// terminator. Each command is its own fixed-width frame recognised by its
/// first byte.
///
/// ## Sources
///
/// * `madhead/saberlight` `protocols/Triones/protocol.md` — the fullest
///   writeup, with per-command golden bytes and the status-reply layout.
/// * `Aritzherrero4/trionesControl` and `sysofwan/ha-triones` — independent
///   implementations that agree byte for byte.
/// * `Bluetooth-Devices/led-ble` and `flux_led`'s
///   `ProtocolLEDENETOriginalRGBW` — the same frames reached from the
///   MagicHome/Zengge side, which is why `Triones:*`, `LEDBlue-*`, `QHM-*` and
///   `Dream~MAC` names all land here.
///
/// All four sources agree on colour and power with no disagreement at all —
/// unusually clean for this corner of the world.
public enum TrionesFrames {

    /// `0x56 <R> <G> <B> <white> <mode> 0xAA`.
    ///
    /// Byte 5 selects which channels the frame applies to: `0xF0` colours only,
    /// `0x0F` white only, `0x00` all (`flux_led` `LevelWriteMode`).
    public enum LevelMode: UInt8, Sendable {
        case all    = 0x00
        case colors = 0xF0
        case whites = 0x0F
    }

    /// `56 <R> <G> <B> 00 F0 AA`.
    ///
    /// Golden, verbatim from `saberlight`: red is `56 FF 00 00 00 F0 AA`.
    public static func color(_ rgb: StripRGB) -> [UInt8] {
        [0x56, rgb.red, rgb.green, rgb.blue, 0x00, LevelMode.colors.rawValue, 0xAA]
    }

    /// `56 00 00 00 <intensity> 0F AA` — the **white channel**, not RGB
    /// brightness.
    ///
    /// `saberlight` proves bytes 1…3 are ignored in this mode by filling them
    /// with `DE AD FF` in one example and `CA FE 00` in another; every shipping
    /// implementation zeroes them, as here. Intensity is a full 0…255, unlike
    /// ELK's 0…100.
    public static func white(intensity: UInt8) -> [UInt8] {
        [0x56, 0x00, 0x00, 0x00, intensity, LevelMode.whites.rawValue, 0xAA]
    }

    /// `CC 23 33` on, `CC 24 33` off. Unanimous across all four sources.
    public static func power(on: Bool) -> [UInt8] {
        [0xCC, on ? 0x23 : 0x24, 0x33]
    }

    /// `BB <effect> <speed> 44`.
    ///
    /// `speed` is `0x01` fastest. The slow end is the one thing `saberlight`
    /// contradicts itself on — its prose says `0xFF`, its own captured status
    /// replies annotate `0x1F` as "the slowest possible" — so the value is
    /// passed through unclamped and the ambiguity is documented rather than
    /// resolved by guess.
    public static func effect(_ effect: TrionesEffect, speed: UInt8) -> [UInt8] {
        [0xBB, effect.rawValue, speed, 0x44]
    }

    /// `EF 01 77` — asks for the twelve-byte status notification.
    public static let statusQuery: [UInt8] = [0xEF, 0x01, 0x77]

    /// The decoded form of a twelve-byte status reply (`saberlight`).
    public struct Status: Equatable, Sendable {
        public let isOn: Bool
        /// `0x41` means "showing a static colour"; `0x25`…`0x38` is a preset.
        public let mode: UInt8
        public let speed: UInt8
        public let color: StripRGB
        public let white: UInt8

        public var effect: TrionesEffect? { TrionesEffect(rawValue: mode) }
    }

    /// Decodes a status notification, or `nil` if it is not one.
    ///
    /// Golden, verbatim from `saberlight` — a strip on, showing static red:
    /// `66 15 23 41 20 00 FF 00 00 00 06 99`.
    public static func status(fromNotification bytes: [UInt8]) -> Status? {
        guard bytes.count == 12, bytes[0] == 0x66, bytes[11] == 0x99 else { return nil }
        guard bytes[2] == 0x23 || bytes[2] == 0x24 else { return nil }
        return Status(isOn: bytes[2] == 0x23,
                      mode: bytes[3],
                      speed: bytes[5],
                      color: StripRGB(red: bytes[6], green: bytes[7], blue: bytes[8]),
                      white: bytes[9])
    }
}

/// Triones preset effect IDs, `0x25`…`0x38`.
///
/// `saberlight`'s `mode.go` rejects anything outside this range outright, and
/// `trionesControl` bounds-checks the same 37…56, so the range is a hard edge
/// rather than a convention.
public enum TrionesEffect: UInt8, CaseIterable, Sendable {
    case sevenColorFade      = 0x25
    case redFade             = 0x26
    case greenFade           = 0x27
    case blueFade            = 0x28
    case yellowFade          = 0x29
    case cyanFade            = 0x2A
    case purpleFade          = 0x2B
    case whiteFade           = 0x2C
    case redGreenFade        = 0x2D
    case redBlueFade         = 0x2E
    case greenBlueFade       = 0x2F
    case sevenColorStrobe    = 0x30
    case redStrobe           = 0x31
    case greenStrobe         = 0x32
    case blueStrobe          = 0x33
    case yellowStrobe        = 0x34
    case cyanStrobe          = 0x35
    case purpleStrobe        = 0x36
    case whiteStrobe         = 0x37
    case sevenColorJump      = 0x38

    public var commandName: String {
        switch self {
        case .sevenColorFade: return "seven-color-fade"
        case .redFade: return "red-fade"
        case .greenFade: return "green-fade"
        case .blueFade: return "blue-fade"
        case .yellowFade: return "yellow-fade"
        case .cyanFade: return "cyan-fade"
        case .purpleFade: return "purple-fade"
        case .whiteFade: return "white-fade"
        case .redGreenFade: return "red-green-fade"
        case .redBlueFade: return "red-blue-fade"
        case .greenBlueFade: return "green-blue-fade"
        case .sevenColorStrobe: return "seven-color-strobe"
        case .redStrobe: return "red-strobe"
        case .greenStrobe: return "green-strobe"
        case .blueStrobe: return "blue-strobe"
        case .yellowStrobe: return "yellow-strobe"
        case .cyanStrobe: return "cyan-strobe"
        case .purpleStrobe: return "purple-strobe"
        case .whiteStrobe: return "white-strobe"
        case .sevenColorJump: return "seven-color-jump"
        }
    }

    public init?(commandName: String) {
        let wanted = commandName.lowercased()
        guard let match = Self.allCases.first(where: { $0.commandName == wanted }) else {
            return nil
        }
        self = match
    }
}
