import Foundation
import GMMKProtocol
import GloriousMouseProtocol

/// One look, expressed in device-neutral terms.
///
/// The keyboard and the mouse have nothing in common at the protocol level —
/// different vendors, different transports, different effect vocabularies — so
/// "make the desk match" needs a description that belongs to neither of them.
/// This is that description; ``GloriousSync`` turns it into what each device
/// actually understands.
///
/// The fields are deliberately abstract. Brightness and speed are `0…1` rather
/// than either device's scale, because those scales disagree: the keyboard has
/// five brightness levels including off, the mouse has five including off but
/// treats 0 as "LEDs dark", and their speed fields run in opposite directions.
/// Normalising once here means the disagreements are resolved in one tested
/// place instead of at every call site.
public struct DeskLook: Equatable, Sendable {

    public var family: DeskEffectFamily
    public var color: DeskColor
    /// `0` darkest … `1` brightest.
    public var brightness: Double
    /// `0` slowest … `1` fastest. Ignored by ``DeskEffectFamily/solid``.
    public var speed: Double

    public init(family: DeskEffectFamily,
                color: DeskColor,
                brightness: Double = 1.0,
                speed: Double = 0.5) {
        self.family = family
        self.color = color
        self.brightness = brightness
        self.speed = speed
    }

    /// `brightness` clamped into `0…1`.
    public var clampedBrightness: Double { min(max(brightness, 0), 1) }
    /// `speed` clamped into `0…1`.
    public var clampedSpeed: Double { min(max(speed, 0), 1) }
}

// MARK: - Effect family

/// The effects both devices can express, named for what they look like rather
/// than for either device's ID.
///
/// This is the intersection, not the union: an effect only belongs here if both
/// devices have something honest to map it to. The keyboard's twenty modes and
/// the mouse's eleven both reach well beyond it, and picking one of those from a
/// device's own section is not a desk look — it is that device doing its own
/// thing, which is why ``GloriousSync/family(forKeyboardMode:rainbow:)`` and its
/// mouse counterpart return `nil` rather than guessing.
public enum DeskEffectFamily: String, CaseIterable, Sendable {
    /// One steady colour.
    case solid
    /// One colour, fading in and out.
    case breathing
    /// The colour travelling across the device.
    case wave
    /// Hue cycling; the look's colour is not used.
    case rainbowCycle

    public var displayName: String {
        switch self {
        case .solid:        return "Solid"
        case .breathing:    return "Breathing"
        case .wave:         return "Wave"
        case .rainbowCycle: return "Rainbow Cycle"
        }
    }

    /// Whether the look's colour is visible on **at least one** device.
    ///
    /// Not the same as "visible on both". Rainbow cycling ignores it on both,
    /// so this is false. ``wave`` is the awkward one: the keyboard's wave
    /// carries the colour, but the mouse renders a travelling effect as a hue
    /// sweep with no colour parameter at all, so the same look is coloured on
    /// one device and rainbow on the other. Anything that needs the per-device
    /// truth should ask ``GloriousSync/mousePlan(for:)`` whether its plan
    /// carries a colour, not this.
    public var usesColor: Bool { self != .rainbowCycle }

    /// Whether the family animates, i.e. whether ``DeskLook/speed`` matters.
    public var isAnimated: Bool { self != .solid }
}

// MARK: - Colour

/// A colour that belongs to neither device's type system.
///
/// Both device protocols have their own colour type with their own wire order —
/// the keyboard stores R,G,B and the mouse stores R,B,G — and a desk look should
/// not have to know which. Conversions are one-way accessors, so the wire order
/// stays the responsibility of the protocol that owns it.
public struct DeskColor: Equatable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `RRGGBB` or `#RRGGBB` — human order.
    public init?(hex: String) {
        guard let rgb = RGB(hex: hex) else { return nil }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    public var hexString: String { String(format: "%02x%02x%02x", red, green, blue) }

    /// As the keyboard's colour type.
    public var keyboardColor: RGB { RGB(red: red, green: green, blue: blue) }
    /// As the mouse's colour type. The R,B,G wire order is applied inside
    /// ``MouseRGB``, not here.
    public var mouseColor: MouseRGB { MouseRGB(red: red, green: green, blue: blue) }

    public init(_ rgb: RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    public init(_ rgb: MouseRGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - Themes

/// Curated looks, applied to whichever devices are present.
///
/// The palette leans green and blue on purpose: those are the hues a tinted
/// switch housing barely changes (see `SwitchFriendlyPalette` in the app), so a
/// theme looks the same across a mixed-switch keyboard *and* matches the mouse,
/// which has no such problem. Ember is the deliberate exception — a warm look
/// is worth having even though it is the case switch compensation exists for.
public enum DeskTheme {

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let look: DeskLook

        public init(_ name: String, _ look: DeskLook) {
            self.name = name
            self.look = look
        }
    }

    /// Parses a hex literal that is known-good at the call site below.
    private static func color(_ hex: String) -> DeskColor {
        guard let color = DeskColor(hex: hex) else {
            preconditionFailure("malformed theme colour: \(hex)")
        }
        return color
    }

    public static let all: [Entry] = [
        Entry("Mint Uniform",
              DeskLook(family: .solid, color: color("66ffaa"), brightness: 1.0)),
        Entry("Seafoam Wave",
              DeskLook(family: .wave, color: color("44ffcc"), brightness: 1.0, speed: 0.5)),
        Entry("Ocean",
              DeskLook(family: .rainbowCycle, color: color("00e5ff"),
                       brightness: 1.0, speed: 0.4)),
        Entry("Ember",
              DeskLook(family: .breathing, color: color("ff5500"),
                       brightness: 0.8, speed: 0.35)),
        Entry("Ice",
              DeskLook(family: .solid, color: color("99e6ff"), brightness: 1.0)),
        Entry("Midnight",
              DeskLook(family: .solid, color: color("3344ff"), brightness: 0.25)),
    ]
}
