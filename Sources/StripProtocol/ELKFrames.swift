import Foundation

/// The nine-byte `7E … EF` protocol, and the five dialects of it this project
/// can speak.
///
/// This is the most common protocol on cheap Bluetooth strips and the one most
/// likely to be on an unbranded 5V USB controller. Frames are always exactly
/// nine bytes, start `0x7E` and end `0xEF`, and carry **no checksum and no
/// length** — the controller either recognises the command byte or ignores the
/// whole frame, which is what makes `strip try-all` safe.
///
/// ## Where these bytes come from
///
/// * `FergusInLondon/ELK-BLEDOM` `PROTCOL.md` — the original reverse
///   engineering; documents the frame shape and the payload table.
/// * `dave-code-ruiz/elkbledom` `custom_components/elkbledom/models.json` —
///   the Home Assistant integration's per-model frame templates, and the
///   source of every dialect below that is not plain BLEDOM.
/// * `8none1/elk-bledob` — nRF52840 sniffer captures of the real phone app
///   talking to a BLEDOB, which is how the BLEDOB templates were confirmed
///   independently of the HA integration.
/// * `arduino12/ble_rgb_led_strip_controller` — an independent capture of a
///   device literally named `ELK-BLEDOM`, agreeing byte-for-byte on colour.
///
/// ## The dialects are filler bytes, not different protocols
///
/// Bytes 1 and 7 of a colour frame are, in FergusInLondon's words, bytes the
/// app "sets to a unique value per command" and that "don't seem to affect
/// functionality" — `arduino12` calls them outright garbage. So the dialects
/// below mostly differ in bytes that may not matter at all. They are kept
/// distinct anyway because power and effect frames genuinely do differ, and
/// because if tomorrow's strip answers one dialect and not another, that is
/// evidence worth having recorded rather than smoothed away.
public struct ELKDialect: Sendable, Equatable {

    public let displayName: String

    /// Byte 1 of a colour frame — the "unique value per command" filler.
    public let colorTag: UInt8
    /// Byte 7 of a colour frame.
    public let colorTail: UInt8
    /// Whether the colour bytes go out R, **B**, G. True only for the
    /// `LED-`/`JACKYLED` rebadges (`models.json`).
    public let colorIsRBG: Bool

    /// The full nine bytes of power-on and power-off. Unlike the other
    /// commands these carry no argument, so there is nothing to template.
    public let powerOnBytes: [UInt8]
    public let powerOffBytes: [UInt8]

    /// Byte 1 and bytes 4…7 of a brightness frame (`7E <tag> 01 <value> …`).
    public let brightnessTag: UInt8
    public let brightnessTail: [UInt8]

    /// Byte 1 and bytes 4…7 of an effect frame (`7E <tag> 03 <effect> …`).
    public let effectTag: UInt8
    public let effectTail: [UInt8]

    /// Byte 1 and bytes 4…7 of a speed frame (`7E <tag> 02 <value> …`).
    public let speedTag: UInt8
    public let speedTail: [UInt8]

    /// Short writes some dialects need before they answer anything else.
    ///
    /// MELK units are documented as ignoring every command until these two
    /// three-byte writes have been sent (`elkbledom.py` `_ensure_connected`,
    /// and the integration's own README troubleshooting section). They are
    /// three bytes, not nine — not truncated frames, a different thing on the
    /// same characteristic. Empty for the dialects that need no login.
    public let loginWrites: [[UInt8]]
}

/// Builders for the nine-byte `7E … EF` frames.
public enum ELKFrames {

    public static let header: UInt8 = 0x7E
    public static let terminator: UInt8 = 0xEF
    public static let frameLength = 9

    /// Command byte (index 2) for each verb.
    public enum Command: UInt8, Sendable {
        case brightness = 0x01
        case speed      = 0x02
        case effect     = 0x03
        case power      = 0x04
        case color      = 0x05
    }

    /// `7E <tag> 05 03 <R> <G> <B> <tail> EF`.
    ///
    /// Golden, from `arduino12` and `linuxthings.co.uk` alike:
    /// red is `7E 00 05 03 FF 00 00 00 EF`.
    public static func color(_ rgb: StripRGB, dialect: ELKDialect) -> [UInt8] {
        let colour = dialect.colorIsRBG ? rgb.rbgBytes : rgb.rgbBytes
        return [header, dialect.colorTag, Command.color.rawValue, 0x03]
             + colour + [dialect.colorTail, terminator]
    }

    public static func power(on: Bool, dialect: ELKDialect) -> [UInt8] {
        on ? dialect.powerOnBytes : dialect.powerOffBytes
    }

    /// `7E <tag> 01 <percent> <tail…> EF`.
    ///
    /// **The scale is 0…100, not 0…255** — `elkbledom`'s `get_brightness_cmd`
    /// converts with `int(intensity * 100 / 255)`. `percent` is clamped rather
    /// than rejected because a caller sweeping a fader should not have to
    /// handle an error per frame.
    ///
    /// Two independent warnings ride with this command: `linuxthings.co.uk`
    /// reports that setting it too low can leave the strip needing the phone
    /// app to recover, and `arduino12` reports it does nothing while an effect
    /// is running. `elkbledom` ships an RGB-scaling fallback for exactly this
    /// reason — see ``StripFamily/scalesBrightnessByColor``.
    public static func brightness(percent: Int, dialect: ELKDialect) -> [UInt8] {
        let value = UInt8(max(0, min(100, percent)))
        return [header, dialect.brightnessTag, Command.brightness.rawValue, value]
             + dialect.brightnessTail + [terminator]
    }

    /// `7E <tag> 03 <effect> <tail…> EF`, effect IDs `0x80`…`0x9C`.
    public static func effect(_ effect: ELKEffect, dialect: ELKDialect) -> [UInt8] {
        [header, dialect.effectTag, Command.effect.rawValue, effect.rawValue]
            + dialect.effectTail + [terminator]
    }

    /// `7E <tag> 02 <speed> <tail…> EF`, 0…100.
    public static func speed(percent: Int, dialect: ELKDialect) -> [UInt8] {
        let value = UInt8(max(0, min(100, percent)))
        return [header, dialect.speedTag, Command.speed.rawValue, value]
             + dialect.speedTail + [terminator]
    }

    /// `7E 00 01 FA 00 00 00 00 EF` — asks for a status notification.
    /// Replies arrive on the notify characteristic and are nine bytes with the
    /// same `0x7E`/`0xEF` envelope (`models.json` `query`).
    public static let statusQuery: [UInt8] =
        [header, 0x00, 0x01, 0xFA, 0x00, 0x00, 0x00, 0x00, terminator]

    /// Whether a notification looks like an ELK status reply.
    public static func isStatusReply(_ bytes: [UInt8]) -> Bool {
        bytes.count == frameLength && bytes[0] == header && bytes[8] == terminator
    }
}

// MARK: - Dialects

extension ELKDialect {

    /// Plain `ELK-BLEDOM`. The canonical dialect: every source agrees on its
    /// colour frame, and its filler bytes are zero.
    ///
    /// Power frames follow `models.json`'s `ELK-BTC`/`ELK-BLEDOM` entry
    /// (`7E 00 04 F0 00 01 FF 00 EF`). `arduino12` captured a shorter-armed
    /// variant on the same device name — `7E 00 04 01 00 00 00 00 EF` on,
    /// `7E 00 04 00 00 00 00 00 EF` off — which is why ``StripFamily`` offers
    /// ``ELKDialect/bledomAlternatePower`` as a separate try-all candidate
    /// rather than picking a winner between two captures of the same product.
    public static let bledom = ELKDialect(
        displayName: "ELK-BLEDOM",
        colorTag: 0x00, colorTail: 0x00, colorIsRBG: false,
        powerOnBytes:  [0x7E, 0x00, 0x04, 0xF0, 0x00, 0x01, 0xFF, 0x00, 0xEF],
        powerOffBytes: [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF],
        brightnessTag: 0x00, brightnessTail: [0xFF, 0x00, 0xFF, 0x00],
        effectTag: 0x00, effectTail: [0x03, 0x00, 0x00, 0x00],
        speedTag: 0x00, speedTail: [0x00, 0x00, 0x00, 0x00],
        loginWrites: [])

    /// `ELK-BLEDOM` as `arduino12/ble_rgb_led_strip_controller` captured it:
    /// identical except that power is a plain `01`/`00` at byte 3.
    ///
    /// Only the power frames differ, so this exists to be tried when colour
    /// already works and the strip will not switch off.
    public static let bledomAlternatePower = ELKDialect(
        displayName: "ELK-BLEDOM (arduino12 power capture)",
        colorTag: 0x00, colorTail: 0x00, colorIsRBG: false,
        powerOnBytes:  [0x7E, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0xEF],
        powerOffBytes: [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0xEF],
        brightnessTag: 0x00, brightnessTail: [0x00, 0x00, 0x00, 0x00],
        effectTag: 0x00, effectTail: [0x03, 0x00, 0x00, 0x00],
        speedTag: 0x00, speedTail: [0x00, 0x00, 0x00, 0x00],
        loginWrites: [])

    /// `ELK-BLEDOB`, confirmed twice over: `models.json` and `8none1`'s sniffer
    /// captures agree on power, brightness and effects byte for byte.
    ///
    /// The one disagreement is byte 7 of a colour frame: `models.json` says
    /// `0x0A`, `8none1`'s captures say `0x10`. `models.json` is followed here
    /// because it is the more widely deployed of the two, and FergusInLondon
    /// records that this byte "tends to be set to either 16 or 0; doesn't seem
    /// to affect functionality" — so the choice is very likely immaterial.
    public static let bledob = ELKDialect(
        displayName: "ELK-BLEDOB",
        colorTag: 0x07, colorTail: 0x0A, colorIsRBG: false,
        powerOnBytes:  [0x7E, 0x07, 0x04, 0xFF, 0x00, 0x01, 0x02, 0x01, 0xEF],
        powerOffBytes: [0x7E, 0x07, 0x04, 0x00, 0x00, 0x00, 0x02, 0x01, 0xEF],
        brightnessTag: 0x04, brightnessTail: [0x01, 0xFF, 0x02, 0x01],
        effectTag: 0x07, effectTail: [0x03, 0xFF, 0xFF, 0x00],
        speedTag: 0x07, speedTail: [0x00, 0x00, 0x00, 0x00],
        loginWrites: [])

    /// `MELK-…`. Shares BLEDOB's brightness frame and needs a login first.
    ///
    /// `models.json` does not publish a distinct colour template for MELK, so
    /// the canonical BLEDOM colour frame is used. That is an assumption, and
    /// the honest place for it is `strip try-all`: if MELK's login is what
    /// tomorrow's strip wants, the colour frame that lands will identify
    /// itself.
    public static let melk = ELKDialect(
        displayName: "MELK",
        colorTag: 0x00, colorTail: 0x00, colorIsRBG: false,
        powerOnBytes:  [0x7E, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0xEF],
        powerOffBytes: [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF],
        brightnessTag: 0x04, brightnessTail: [0x01, 0xFF, 0x02, 0x01],
        effectTag: 0x05, effectTail: [0x06, 0xFF, 0xFF, 0x00],
        speedTag: 0x04, speedTail: [0xFF, 0xFF, 0xFF, 0x00],
        // Write-without-response, three bytes each, before anything else
        // (`elkbledom.py` `_ensure_connected`; the README shows the same two
        // as `gatttool -n 7e0783` / `-n 7e0404`).
        loginWrites: [[0x7E, 0x07, 0x83], [0x7E, 0x04, 0x04]])

    /// `LEDBLE-…`, per `kloptops/LEDBLE-Strip`. Same envelope, different
    /// characteristic (`FFE1`, not `FFF3`) and its own power frames.
    ///
    /// `models.json` has a `LEDBLE` entry whose power frames are the BLEDOM
    /// ones instead; `kloptops` is followed here because it was written against
    /// `LEDBLE`-named hardware specifically. Note also that `LEDBLE-` names
    /// appear in the Triones ecosystem too — see ``StripFamily/triones``.
    public static let ledble = ELKDialect(
        displayName: "LEDBLE",
        colorTag: 0x07, colorTail: 0x00, colorIsRBG: false,
        powerOnBytes:  [0x7E, 0x04, 0x04, 0x01, 0xFF, 0xFF, 0xFF, 0x00, 0xEF],
        powerOffBytes: [0x7E, 0x04, 0x04, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xEF],
        brightnessTag: 0x00, brightnessTail: [0xFF, 0x00, 0xFF, 0x00],
        effectTag: 0x00, effectTail: [0x03, 0x00, 0x00, 0x00],
        speedTag: 0x00, speedTail: [0x00, 0x00, 0x00, 0x00],
        loginWrites: [])

    /// `LED-…` / `JACKYLED` / `XROCKER` — **red, blue, green on the wire.**
    ///
    /// The only dialect with a transposed colour order (`models.json`). Worth
    /// keeping precisely because its failure mode is legible: if `strip color`
    /// on another dialect lights the strip but green and blue are swapped,
    /// this is the dialect the controller actually wanted.
    public static let jackyLED = ELKDialect(
        displayName: "JACKYLED / LED-",
        colorTag: 0x07, colorTail: 0x00, colorIsRBG: true,
        powerOnBytes:  [0x7E, 0x04, 0x04, 0x01, 0xFF, 0xFF, 0xFF, 0x00, 0xEF],
        powerOffBytes: [0x7E, 0x04, 0x04, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xEF],
        brightnessTag: 0x00, brightnessTail: [0xFF, 0x00, 0xFF, 0x00],
        effectTag: 0x00, effectTail: [0x03, 0x00, 0x00, 0x00],
        speedTag: 0x00, speedTail: [0x00, 0x00, 0x00, 0x00],
        loginWrites: [])
}

// MARK: - Effects

/// ELK effect IDs, `0x80`…`0x9C`.
///
/// `0x80`…`0x86` are the seven static colours the controller can hold without
/// being sent RGB; `0x87` upwards are the animations. Names follow
/// `dave-code-ruiz/elkbledom` `definitions.json`, which `TheSylex`'s
/// independent implementation matches exactly.
///
/// The mic-reactive range documented at `0x80`…`0x87` on command `7E 05 03 …
/// 04 …` is deliberately not modelled: it overlaps this range on a *different*
/// sub-command byte, and conflating the two would make an effect ID mean two
/// things.
public enum ELKEffect: UInt8, CaseIterable, Sendable {
    case staticRed     = 0x80
    case staticGreen   = 0x81
    case staticBlue    = 0x82
    case staticYellow  = 0x83
    case staticCyan    = 0x84
    case staticMagenta = 0x85
    case staticWhite   = 0x86

    case jumpRGB       = 0x87
    case jumpRGBYCMW   = 0x88
    case fadeRGB       = 0x89
    case fadeRGBYCMW   = 0x8A
    case fadeRed       = 0x8B
    case fadeGreen     = 0x8C
    case fadeBlue      = 0x8D
    case fadeYellow    = 0x8E
    case fadeCyan      = 0x8F
    case fadeMagenta   = 0x90
    case fadeWhite     = 0x91
    case fadeRedGreen  = 0x92
    case fadeRedBlue   = 0x93
    case fadeGreenBlue = 0x94
    case blinkRGBYCMW  = 0x95
    case blinkRed      = 0x96
    case blinkGreen    = 0x97
    case blinkBlue     = 0x98
    case blinkYellow   = 0x99
    case blinkCyan     = 0x9A
    case blinkMagenta  = 0x9B
    case blinkWhite    = 0x9C

    /// The lower-case name used on the command line.
    public var commandName: String {
        switch self {
        case .staticRed: return "static-red"
        case .staticGreen: return "static-green"
        case .staticBlue: return "static-blue"
        case .staticYellow: return "static-yellow"
        case .staticCyan: return "static-cyan"
        case .staticMagenta: return "static-magenta"
        case .staticWhite: return "static-white"
        case .jumpRGB: return "jump-rgb"
        case .jumpRGBYCMW: return "jump-rgbycmw"
        case .fadeRGB: return "fade-rgb"
        case .fadeRGBYCMW: return "fade-rgbycmw"
        case .fadeRed: return "fade-red"
        case .fadeGreen: return "fade-green"
        case .fadeBlue: return "fade-blue"
        case .fadeYellow: return "fade-yellow"
        case .fadeCyan: return "fade-cyan"
        case .fadeMagenta: return "fade-magenta"
        case .fadeWhite: return "fade-white"
        case .fadeRedGreen: return "fade-red-green"
        case .fadeRedBlue: return "fade-red-blue"
        case .fadeGreenBlue: return "fade-green-blue"
        case .blinkRGBYCMW: return "blink-rgbycmw"
        case .blinkRed: return "blink-red"
        case .blinkGreen: return "blink-green"
        case .blinkBlue: return "blink-blue"
        case .blinkYellow: return "blink-yellow"
        case .blinkCyan: return "blink-cyan"
        case .blinkMagenta: return "blink-magenta"
        case .blinkWhite: return "blink-white"
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
