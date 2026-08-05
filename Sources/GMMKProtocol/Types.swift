import Foundation

// MARK: - Lighting mode

/// The 20 onboard effects, written to config RAM address `0x00`.
///
/// Names follow `rgb_keyboard`'s descriptive set; ``officialLabel`` carries the
/// label used by the official Windows utility where one is known.
/// `0x00` is not used by any known tool and is treated as invalid.
public enum LightingMode: UInt8, CaseIterable, Sendable {
    case horizontalWave     = 0x01
    case pulse              = 0x02
    case hurricane          = 0x03
    case breathingCycle     = 0x04
    case breathing          = 0x05
    /// Fixed / static — the plain "solid colour" mode.
    case fixed              = 0x06
    case reactiveSingle     = 0x07
    case reactiveRipple     = 0x08
    case reactiveHorizontal = 0x09
    case waterfall          = 0x0A
    case swirl              = 0x0B
    case verticalWave       = 0x0C
    case sine               = 0x0D
    case vortex             = 0x0E
    case rain               = 0x0F
    case diagonalWave       = 0x10
    /// Uses the reactive-colour variant byte at config `0x08`.
    case reactiveColor      = 0x11
    case ripple             = 0x12
    /// All LEDs off.
    case off                = 0x13
    /// Per-key colours from LED colour RAM.
    case custom             = 0x14

    /// Human-readable name for UI and CLI output.
    public var displayName: String {
        switch self {
        case .horizontalWave:     return "Horizontal Wave"
        case .pulse:              return "Pulse"
        case .hurricane:          return "Hurricane"
        case .breathingCycle:     return "Breathing (Color Cycle)"
        case .breathing:          return "Breathing"
        case .fixed:              return "Fixed"
        case .reactiveSingle:     return "Reactive Single"
        case .reactiveRipple:     return "Reactive Ripple"
        case .reactiveHorizontal: return "Reactive Horizontal"
        case .waterfall:          return "Waterfall"
        case .swirl:              return "Swirl"
        case .verticalWave:       return "Vertical Wave"
        case .sine:               return "Sine"
        case .vortex:             return "Vortex"
        case .rain:               return "Rain"
        case .diagonalWave:       return "Diagonal Wave"
        case .reactiveColor:      return "Reactive Color"
        case .ripple:             return "Ripple"
        case .off:                return "Off"
        case .custom:             return "Custom"
        }
    }

    /// Label the official Windows utility uses, where one was captured.
    public var officialLabel: String? {
        switch self {
        case .horizontalWave:  return "wave1"
        case .pulse:           return "wave2"
        case .hurricane:       return "spiralingwave"
        case .breathingCycle:  return "acid"
        case .breathing:       return "breathing"
        case .fixed:           return "normallyon"
        case .reactiveRipple:  return "ripplegraff"
        case .custom:          return "custom"
        default:               return nil
        }
    }

    /// Lowercase, punctuation-free identifier used by the CLI (e.g. `horizontalwave`).
    public var slug: String {
        displayName.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Resolves a user-supplied string: a slug, a display name, an official
    /// label, a decimal ID, or a `0x`-prefixed hex ID.
    public static func parse(_ input: String) -> LightingMode? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let normalized = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }

        if let mode = allCases.first(where: {
            $0.slug == normalized || $0.officialLabel == normalized
        }) {
            return mode
        }
        if trimmed.lowercased().hasPrefix("0x"),
           let id = UInt8(trimmed.dropFirst(2), radix: 16) {
            return LightingMode(rawValue: id)
        }
        if let id = UInt8(trimmed) {
            return LightingMode(rawValue: id)
        }
        return nil
    }
}

// MARK: - Direction

/// Effect direction, written to config RAM address `0x03`.
///
/// Polarity follows `gmmkctl`'s code and `rgb_keyboard`'s decoder (`0xFF` =
/// left), not `gmmk_led.txt`'s notes, which contradict both. The meaning is
/// per-effect: `left` also reads as up / inwards depending on the effect.
public enum Direction: UInt8, CaseIterable, Sendable {
    case left  = 0xFF
    case right = 0x00

    public var displayName: String { self == .left ? "Left" : "Right" }

    /// Accepts `l`/`left`/`up`/`in` and `r`/`right`/`down`/`out`.
    public static func parse(_ input: String) -> Direction? {
        switch input.lowercased() {
        case "l", "left", "up", "in", "inwards":    return .left
        case "r", "right", "down", "out", "outwards": return .right
        default: return nil
        }
    }
}

// MARK: - Brightness

/// Brightness levels for config RAM address `0x01`.
///
/// The safe range is `0`…`4` (five levels) per the official-software captures.
/// **Level 0 is off.**
public enum Brightness {
    public static let min: UInt8 = 0
    public static let max: UInt8 = 4

    /// Maps a 0–100 percentage onto the device's 0–4 scale.
    ///
    /// 0% maps to 0 (off); every non-zero percentage maps to at least 1 so a
    /// UI slider never silently blacks out the keyboard on a rounding edge.
    public static func level(fromPercent percent: Int) -> UInt8 {
        let clamped = Swift.max(0, Swift.min(100, percent))
        if clamped == 0 { return 0 }
        let scaled = Int((Double(clamped) / 100.0 * Double(max)).rounded())
        return UInt8(Swift.max(1, Swift.min(Int(max), scaled)))
    }
}

// MARK: - Delay / speed

/// Animation delay for config RAM address `0x02`.
///
/// The field is a *delay* (higher = slower). `gmmkctl` accepts 0–255 but only
/// `0`…`3` are corroborated as meaningful, so this clamps there.
public enum Delay {
    public static let min: UInt8 = 0
    public static let max: UInt8 = 3

    /// Maps a UI-facing speed of 1 (slowest) … 5 (fastest) onto a delay.
    ///
    /// Five UI steps compress onto four device values, so speeds 2 and 3 both
    /// land on delay 2.
    public static func delay(fromSpeed speed: Int) -> UInt8 {
        let clamped = Swift.max(1, Swift.min(5, speed))
        let scaled = (Double(5 - clamped) * Double(max) / 4.0).rounded()
        return UInt8(scaled)
    }
}

// MARK: - Reactive variant

/// Colour variant for mode `0x11` (reactive colour), config RAM address `0x08`.
public enum ReactiveVariant: UInt8, CaseIterable, Sendable {
    case red    = 0
    case yellow = 1
    case green  = 2
    case blue   = 3
}

// MARK: - Polling rate

/// USB polling rate, config RAM address `0x0F`. Not a lighting setting.
public enum PollingRate: UInt8, CaseIterable, Sendable {
    case hz125  = 0
    case hz250  = 1
    case hz500  = 2
    case hz1000 = 3
}

// MARK: - RGB

/// A 24-bit colour.
public struct RGB: Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = RGB(red: 0, green: 0, blue: 0)

    /// Parses `RRGGBB` or `#RRGGBB`.
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
