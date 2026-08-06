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

/// Curated looks, applied to whichever devices are present, in two groups.
///
/// The split is about the *keyboard's switch housings*, not about taste. A board
/// that mixes clear and tinted switches shows the mix worst on red-dominant
/// colours, because a cyan housing absorbs red and there is no headroom to
/// correct it back (see `SwitchCompensation` in the app). So the first group
/// stays green and blue, where both housings render nearly the same and the
/// board reads as one colour with no correction at all.
///
/// The second group ignores that on purpose. Saturated and warm looks are worth
/// having, and a user who picks Crimson has chosen loud knowing what their board
/// does with red — so nothing here is filtered, softened or desaturated. On a
/// keyboard with a tuned compensation profile they route through it exactly as a
/// manual colour pick does, which is the most that can be done for them; on an
/// untuned board they look how red looks on that board.
public enum DeskTheme {

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let look: DeskLook

        public init(_ name: String, _ look: DeskLook) {
            self.name = name
            self.look = look
        }
    }

    /// A named set of themes, shown as one block in the menu.
    public struct Group: Equatable, Sendable {
        public let name: String
        public let entries: [Entry]

        public init(_ name: String, _ entries: [Entry]) {
            self.name = name
            self.entries = entries
        }
    }

    /// Parses a hex literal that is known-good at the call site below.
    private static func color(_ hex: String) -> DeskColor {
        guard let color = DeskColor(hex: hex) else {
            preconditionFailure("malformed theme colour: \(hex)")
        }
        return color
    }

    /// Green and blue looks a mixed-switch board renders evenly — with one
    /// exception, Ember, which is warm but calm enough to belong here rather
    /// than in ``loud``. A test pins that it stays the only one.
    public static let switchFriendly = Group("Easy on the switches", [
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
    ])

    /// Saturated looks, full brightness unless noted. Crimson and Sunset are
    /// deliberately red-heavy — see the type's discussion.
    public static let loud = Group("Loud", [
        Entry("Magenta Blast",
              DeskLook(family: .solid, color: color("ff00ff"), brightness: 1.0)),
        Entry("Ultraviolet",
              DeskLook(family: .breathing, color: color("8800ff"),
                       brightness: 1.0, speed: 0.5)),
        Entry("Acid",
              DeskLook(family: .wave, color: color("66ff00"), brightness: 1.0, speed: 0.5)),
        Entry("Electric",
              DeskLook(family: .wave, color: color("00ffff"), brightness: 1.0, speed: 1.0)),
        Entry("Toxic",
              DeskLook(family: .solid, color: color("39ff14"), brightness: 1.0)),
        Entry("Synthwave",
              DeskLook(family: .rainbowCycle, color: color("ff00aa"),
                       brightness: 1.0, speed: 1.0)),
        Entry("Crimson",
              DeskLook(family: .breathing, color: color("ff0022"),
                       brightness: 1.0, speed: 0.5)),
        Entry("Sunset",
              DeskLook(family: .solid, color: color("ff4400"), brightness: 1.0)),
    ])

    public static let groups: [Group] = [switchFriendly, loud]

    /// Every theme, both groups, flattened.
    public static let all: [Entry] = groups.flatMap(\.entries)
}
