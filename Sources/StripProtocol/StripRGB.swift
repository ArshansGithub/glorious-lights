import Foundation

/// A 24-bit colour, in this target's own vocabulary.
///
/// Deliberately not shared with ``GMMKProtocol/RGB`` or the mouse's colour
/// type, for the same reason those two do not share one: a strip is a third
/// device with a third protocol, and the translation layer between devices is
/// `GloriousSync`, not a common type dropped into the middle of three
/// protocols. The conversion is three bytes wide and lives at the call site.
public struct StripRGB: Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = StripRGB(red: 0, green: 0, blue: 0)
    public static let white = StripRGB(red: 255, green: 255, blue: 255)

    /// Parses `RRGGBB`, `#RRGGBB` or `0xRRGGBB` — human order, not wire order.
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

    /// The three bytes in wire order for the families that send R, G, B.
    public var rgbBytes: [UInt8] { [red, green, blue] }

    /// The three bytes in R, **B**, G order.
    ///
    /// The `LED-` / `JACKYLED` / `XROCKER` rebadges of the ELK controller send
    /// green and blue transposed relative to every other ELK dialect
    /// (`dave-code-ruiz/elkbledom` `models.json`). If a colour comes out with
    /// green and blue swapped tomorrow, that swap *is* the identification.
    public var rbgBytes: [UInt8] { [red, blue, green] }
}

// MARK: - HSV

/// A colour in the hue/saturation/value space LEDnetWF speaks natively.
///
/// Ranges are the protocol's, not the usual normalised ones: hue is 0…360
/// degrees, saturation and value are 0…100 **percent**, because that is what
/// `0x3B 0xA1` packs into its bytes (`8none1/lednetwf_ble`,
/// `protocol_docs/05_basic_commands.md`). Keeping the protocol's own units here
/// means the frame builder does no arithmetic a golden test cannot check.
public struct StripHSV: Equatable, Hashable, Sendable {
    /// 0…360 degrees.
    public var hue: Int
    /// 0…100 percent.
    public var saturation: Int
    /// 0…100 percent.
    public var value: Int

    public init(hue: Int, saturation: Int, value: Int) {
        self.hue = max(0, min(360, hue))
        self.saturation = max(0, min(100, saturation))
        self.value = max(0, min(100, value))
    }

    /// Converts 8-bit RGB to the protocol's HSV units, rounding to nearest.
    ///
    /// Worked example, checked in `StripLEDnetWFTests`: `#112233` is
    /// R 17, G 34, B 51 → max 51, min 17, delta 34. Value is 51/255 = 20%,
    /// saturation is 34/51 = 66.67% → 67%, and blue being the maximum puts hue
    /// on the `60 × (4 + (r − g) / delta)` branch = 60 × 3.5 = 210°.
    public init(_ rgb: StripRGB) {
        let r = Double(rgb.red), g = Double(rgb.green), b = Double(rgb.blue)
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let delta = maximum - minimum

        let degrees: Double
        if delta == 0 {
            degrees = 0
        } else if maximum == r {
            // The modulo keeps the red branch positive; `(g - b) / delta` runs
            // −1…1 and a bare multiply would give −60° for magenta-ish reds.
            degrees = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6) + 6)
                          .truncatingRemainder(dividingBy: 6)
        } else if maximum == g {
            degrees = 60 * (((b - r) / delta) + 2)
        } else {
            degrees = 60 * (((r - g) / delta) + 4)
        }

        self.init(hue: Int(degrees.rounded()),
                  saturation: maximum == 0 ? 0 : Int((delta / maximum * 100).rounded()),
                  value: Int((maximum / 255 * 100).rounded()))
    }
}
