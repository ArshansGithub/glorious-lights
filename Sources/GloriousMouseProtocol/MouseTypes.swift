import Foundation

// MARK: - Colour

/// A 24-bit colour, stored in normal RGB order.
///
/// **On the wire this device stores colours as R, B, G** — libratbag's device
/// file says `LedType=RBG` and OpenRGB writes the same order (doc §5.2). Use
/// ``rbgBytes`` / ``init(rbgBytes:)`` for anything that touches the blob and
/// never index the raw bytes by hand; getting it wrong swaps green and blue
/// while leaving red looking correct.
public struct MouseRGB: Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = MouseRGB(red: 0, green: 0, blue: 0)

    /// The three bytes as the device stores them: red, **blue**, green.
    public var rbgBytes: [UInt8] { [red, blue, green] }

    /// Decodes three device bytes in R, B, G order. `nil` for anything that is
    /// not exactly three bytes — a public initializer that traps turns a
    /// caller's slicing mistake into a crash.
    public init?(rbgBytes bytes: ArraySlice<UInt8>) {
        guard bytes.count == 3 else { return nil }
        let b = Array(bytes)
        self.init(red: b[0], green: b[2], blue: b[1])
    }

    public init?(rbgBytes bytes: [UInt8]) {
        self.init(rbgBytes: bytes[...])
    }

    /// Parses `RRGGBB` or `#RRGGBB` — human order, not wire order.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 0xFF),
                  green: UInt8((value >> 8) & 0xFF),
                  blue: UInt8(value & 0xFF))
    }

    public var hexString: String {
        String(format: "%02x%02x%02x", red, green, blue)
    }
}

// MARK: - RGB effects

/// The effect ID at blob offset `0x35` (doc §5.1).
///
/// Each case knows where its own parameter byte and colour array live, so
/// callers never hardcode an offset.
public enum MouseRGBEffect: UInt8, CaseIterable, Sendable {
    case off              = 0x00
    /// libratbag `RGB_GLORIOUS`, OpenRGB `RAINBOW`, Glorious's "unicorn".
    case rainbow          = 0x01
    case single           = 0x02
    case breathing7       = 0x03
    case tail             = 0x04
    /// Full-spectrum breathing (OpenRGB `SPECTRUM_CYCLE`).
    case spectrumBreathing = 0x05
    /// Per-LED static across all six LEDs. Not exposed by Glorious's software
    /// and implemented by no published tool — doc §11 item 5.
    case constant         = 0x06
    case rave             = 0x07
    /// libratbag `RGB_RANDOM`, OpenRGB `EPILEPSY`.
    case random           = 0x08
    case wave             = 0x09
    case breathing1       = 0x0A

    /// `0xFF` (`RGB_NOT_SUPPORTED`) is deliberately **not** a case: it is what
    /// mice with no LEDs report, it is not a selectable effect, and writing it
    /// is forbidden (doc §5.1).
    public static let notSupportedRawValue: UInt8 = 0xFF

    /// Offset of this effect's packed speed/brightness byte (§5.3).
    public var modeByteOffset: Int {
        switch self {
        case .off:               return MouseConfigBlob.Offset.effect  // unused
        case .rainbow:           return MouseConfigBlob.Offset.rainbowMode
        case .single:            return MouseConfigBlob.Offset.singleMode
        case .breathing7:        return MouseConfigBlob.Offset.breathing7Mode
        case .tail:              return MouseConfigBlob.Offset.tailMode
        case .spectrumBreathing: return MouseConfigBlob.Offset.spectrumBreathingMode
        case .constant:          return MouseConfigBlob.Offset.constantMode
        case .rave:              return MouseConfigBlob.Offset.raveMode
        case .random:            return MouseConfigBlob.Offset.randomMode
        case .wave:              return MouseConfigBlob.Offset.waveMode
        case .breathing1:        return MouseConfigBlob.Offset.breathing1Mode
        }
    }

    /// Whether ``modeByteOffset`` addresses a real parameter byte. `off` has
    /// no parameters at all.
    public var hasModeByte: Bool { self != .off }

    /// Offset and count of this effect's colour array, if it has one.
    public var colorArray: (offset: Int, count: Int)? {
        switch self {
        case .single:     return (MouseConfigBlob.Offset.singleColor, 1)
        case .breathing7: return (MouseConfigBlob.Offset.breathing7Colors, 7)
        case .constant:   return (MouseConfigBlob.Offset.constantColors, GloriousMouseDevice.ledCount)
        case .rave:       return (MouseConfigBlob.Offset.raveColors, 2)
        case .breathing1: return (MouseConfigBlob.Offset.breathing1Color, 1)
        default:          return nil
        }
    }

    public var displayName: String {
        switch self {
        case .off:               return "Off"
        case .rainbow:           return "Rainbow"
        case .single:            return "Single Colour"
        case .breathing7:        return "Breathing (7 colours)"
        case .tail:              return "Tail"
        case .spectrumBreathing: return "Spectrum Breathing"
        case .constant:          return "Constant (per-LED)"
        case .rave:              return "Rave"
        case .random:            return "Random"
        case .wave:              return "Wave"
        case .breathing1:        return "Breathing (1 colour)"
        }
    }

    /// Lowercase, punctuation-free identifier for CLI use.
    public var slug: String {
        displayName.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Short names for the effects whose slug is an awkward mouthful, because
    /// the slug is derived from the display name: `single` beats
    /// `singlecolour`, `breathing7` beats `breathing7colours`.
    static let aliases: [String: MouseRGBEffect] = [
        "single": .single,
        "singlecolor": .single,
        "breathing": .breathing1,
        "breathing1": .breathing1,
        "breathing1color": .breathing1,
        "breathing7": .breathing7,
        "breathing7color": .breathing7,
        "spectrum": .spectrumBreathing,
        "constant": .constant,
    ]

    /// Resolves a slug, an alias, a display name, a decimal ID or a
    /// `0x`-prefixed hex ID.
    public static func parse(_ input: String) -> MouseRGBEffect? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let normalized = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
        if let effect = allCases.first(where: { $0.slug == normalized }) { return effect }
        if let effect = aliases[normalized] { return effect }
        if trimmed.lowercased().hasPrefix("0x"), let id = UInt8(trimmed.dropFirst(2), radix: 16) {
            return MouseRGBEffect(rawValue: id)
        }
        if let id = UInt8(trimmed) { return MouseRGBEffect(rawValue: id) }
        return nil
    }
}

// MARK: - Speed / brightness

/// The packed speed/brightness byte every effect carries: **speed in the low
/// nibble, brightness in the high nibble** (doc §5.3).
///
/// OpenRGB composes exactly `((brightness & 0xF) << 4) | (speed & 0xF)`.
public struct MouseModeParameter: Equatable, Hashable, Sendable {
    /// `0` static, `1` slow, `2` normal, `3` fast. Stored as a raw nibble
    /// because the firmware's full range is not known to be 0–3 only.
    public var speed: UInt8
    /// `0` off, `1`–`4` low → high.
    public var brightness: UInt8

    public static let maxSpeed: UInt8 = 3
    public static let maxBrightness: UInt8 = 4

    public init(speed: UInt8, brightness: UInt8) {
        self.speed = speed & 0x0F
        self.brightness = brightness & 0x0F
    }

    public init(packed: UInt8) {
        self.speed = packed & 0x0F
        self.brightness = (packed >> 4) & 0x0F
    }

    public var packed: UInt8 { (brightness << 4) | speed }

    public var speedName: String {
        switch speed {
        case 0: return "static"
        case 1: return "slow"
        case 2: return "normal"
        case 3: return "fast"
        default: return "speed \(speed)"
        }
    }
}

// MARK: - Polling rate

/// Low nibble of blob offset `0x0A` (doc §7). `0` is libratbag's error
/// sentinel, not a rate, so it is not a case.
public enum MousePollingRate: UInt8, CaseIterable, Sendable {
    case hz125  = 1
    case hz250  = 2
    case hz500  = 3
    case hz1000 = 4

    public var hertz: Int {
        switch self {
        case .hz125: return 125
        case .hz250: return 250
        case .hz500: return 500
        case .hz1000: return 1000
        }
    }

    public init?(hertz: Int) {
        guard let match = Self.allCases.first(where: { $0.hertz == hertz }) else { return nil }
        self = match
    }
}

// MARK: - Lift-off distance

/// Blob byte `0x81` (doc §7).
///
/// `0xFF` means "this unit sets LOD through command `0x1b` instead" and
/// libratbag says explicitly it must not be overwritten. ``MouseConfigBlob``
/// enforces that; OpenRGB violates it by accident (doc §10).
public enum MouseLiftOffDistance: Equatable, Sendable {
    case mm2
    case mm3
    /// `0xFF` — managed by command `0x1b`, which does not work on this device.
    /// Leave alone.
    case commandManaged
    /// Anything else the firmware happens to have there.
    case other(UInt8)

    public init(raw: UInt8) {
        switch raw {
        case 0x01: self = .mm2
        case 0x02: self = .mm3
        case 0xFF: self = .commandManaged
        default:   self = .other(raw)
        }
    }

    public var raw: UInt8 {
        switch self {
        case .mm2: return 0x01
        case .mm3: return 0x02
        case .commandManaged: return 0xFF
        case .other(let value): return value
        }
    }

    public var displayName: String {
        switch self {
        case .mm2: return "2 mm"
        case .mm3: return "3 mm"
        case .commandManaged: return "0xFF (set via command 0x1b — do not overwrite)"
        case .other(let value): return String(format: "unknown (0x%02x)", value)
        }
    }
}

// MARK: - Rainbow direction

/// Blob byte `0x37`, meaningful only for ``MouseRGBEffect/rainbow``.
public enum MouseRainbowDirection: UInt8, CaseIterable, Sendable {
    case down = 0x00
    case up   = 0x01

    public var displayName: String { self == .up ? "up" : "down" }
}

// MARK: - DPI

/// One DPI slot, in DPI (not raw bytes).
///
/// `x` and `y` are equal unless the XY-independent flag (bit 3 of the high
/// nibble of blob `0x0A`) is set, in which case the 16-byte stage array holds
/// `{x, y}` pairs (doc §6).
public struct MouseDPIStage: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    /// Whether the slot is enabled; the blob stores this inverted, as a
    /// *disabled* bitmask at `0x0C`.
    public var isEnabled: Bool

    public init(x: Int, y: Int, isEnabled: Bool) {
        self.x = x
        self.y = y
        self.isEnabled = isEnabled
    }

    public init(dpi: Int, isEnabled: Bool = true) {
        self.init(x: dpi, y: dpi, isEnabled: isEnabled)
    }

    public var isSymmetric: Bool { x == y }

    public var displayValue: String { isSymmetric ? "\(x)" : "\(x)×\(y)" }
}
