import Foundation

/// The GATT fingerprint of a controller family: what it advertises, what it
/// exposes once connected, and where to write.
///
/// Candidates are **ordered by preference**, not by importance — the transport
/// takes the first characteristic it actually finds. Several of these families
/// ship under many rebadged names with the same firmware and a different
/// characteristic, and the community integrations all handle it the same way:
/// probe a list rather than hardcode one pair (`led-ble` `const.py`,
/// `ha-triones` `_resolve_characteristics`).
public struct StripGATTSignature: Sendable, Equatable {
    /// Services worth discovering. Empty means "discover everything", which is
    /// what the transport does anyway when identification is uncertain.
    public let services: [StripUUID]
    /// Write characteristics, most likely first.
    public let writeCharacteristics: [StripUUID]
    /// Notify characteristics, most likely first.
    public let notifyCharacteristics: [StripUUID]
}

/// A controller family: a wire protocol plus the GATT signature it wears.
///
/// Nine families, of which eight have frame builders. The ninth, ``idealLED``,
/// is identify-only and deliberately so — see ``framesAvailable``.
public enum StripFamily: String, CaseIterable, Sendable {
    case elkBLEDOM
    case elkBLEDOMAlternatePower
    case elkBLEDOB
    case melk
    case ledble
    case jackyLED
    case triones
    case lednetWF
    case spPixel
    case idealLED

    public var displayName: String {
        switch self {
        case .elkBLEDOM: return "ELK-BLEDOM"
        case .elkBLEDOMAlternatePower: return "ELK-BLEDOM (alternate power)"
        case .elkBLEDOB: return "ELK-BLEDOB"
        case .melk: return "MELK"
        case .ledble: return "LEDBLE"
        case .jackyLED: return "JACKYLED / LED-"
        case .triones: return "Triones / HappyLighting"
        case .lednetWF: return "LEDnetWF"
        case .spPixel: return "SP110E / SP107E"
        case .idealLED: return "iDeal LED"
        }
    }

    /// The ELK dialect this family is, if it is one.
    public var elkDialect: ELKDialect? {
        switch self {
        case .elkBLEDOM: return .bledom
        case .elkBLEDOMAlternatePower: return .bledomAlternatePower
        case .elkBLEDOB: return .bledob
        case .melk: return .melk
        case .ledble: return .ledble
        case .jackyLED: return .jackyLED
        default: return nil
        }
    }

    /// Whether this project can build frames for the family at all.
    ///
    /// False only for ``idealLED``, for two reasons that compound. Its command
    /// packets are AES-128-ECB encrypted under a fixed key, so a frame builder
    /// would have to carry a block cipher into a target that is otherwise byte
    /// arithmetic. And `8none1/idealLED`'s README, along with the
    /// `whizzy.org/2023-12-14-bricked-xmas` writeup it comes from, reports that
    /// walking effect IDs past the range the phone app exposes **permanently
    /// bricked the controller**. A family that punishes exploration is not one
    /// to add to a brute-force command. It is still identified, because knowing
    /// that is what a `D44BC439-…` characteristic means is the whole value.
    public var framesAvailable: Bool { self != .idealLED }

    /// Whether brightness has to be faked by scaling the colour.
    ///
    /// True for Triones, whose only intensity command drives the separate white
    /// channel, and whose implementations (`led-ble`'s `set_brightness`) all
    /// scale RGB instead.
    public var scalesBrightnessByColor: Bool { self == .triones }

    /// Writes that must go out after connecting, before anything else.
    /// Empty for every family except ``melk``.
    public var loginWrites: [[UInt8]] { elkDialect?.loginWrites ?? [] }

    /// Whether the device is documented as requiring notifications to be
    /// enabled before it will accept commands.
    ///
    /// LEDnetWF is emphatic about this (`8none1/zengge_lednetwf` README). The
    /// transport subscribes to the notify characteristic for every family
    /// regardless, because a notification is free evidence during bring-up, but
    /// this flag is why a failure to subscribe is fatal here and a warning
    /// elsewhere.
    public var requiresNotifications: Bool { self == .lednetWF }

    // MARK: - GATT

    public var gatt: StripGATTSignature {
        // Every UUID here is a 16-bit assigned number except iDeal LED's, which
        // are genuinely vendor-allocated — and that is itself the tell.
        func u(_ value: UInt16) -> StripUUID { StripUUID(short: value) }

        switch self {
        case .elkBLEDOM, .elkBLEDOMAlternatePower, .elkBLEDOB, .melk:
            // Note: these advertise service 0x1812 (HID) and do not advertise
            // FFF0 at all — FergusInLondon's PROTCOL.md flags the HID service
            // as present but non-functional. FFF0 only appears after connecting
            // and discovering, which is why advertised-service matching cannot
            // carry identification on its own.
            return StripGATTSignature(services: [u(0xFFF0)],
                                      writeCharacteristics: [u(0xFFF3)],
                                      notifyCharacteristics: [u(0xFFF4)])
        case .ledble:
            return StripGATTSignature(services: [u(0xFFE0), u(0xFFF0)],
                                      writeCharacteristics: [u(0xFFE1), u(0xFFF3)],
                                      notifyCharacteristics: [u(0xFFE2), u(0xFFF4)])
        case .jackyLED:
            // Write and notify are the same characteristic on these rebadges
            // (`models.json`).
            return StripGATTSignature(services: [u(0xFFE0)],
                                      writeCharacteristics: [u(0xFFE1)],
                                      notifyCharacteristics: [u(0xFFE1)])
        case .triones:
            // Four write candidates, because `led-ble` and `ha-triones` both
            // probe rather than assume: on some units FFD5 is the write
            // characteristic itself rather than the service.
            return StripGATTSignature(
                services: [u(0xFFD5), u(0xFFE5), u(0xFFE0)],
                writeCharacteristics: [u(0xFFD9), u(0xFFD5), u(0xFFE9), u(0xFFE5)],
                notifyCharacteristics: [u(0xFFD4), u(0xFFD0), u(0xFFE4), u(0xFFE0)])
        case .lednetWF:
            return StripGATTSignature(services: [u(0xFFFF)],
                                      writeCharacteristics: [u(0xFF01)],
                                      notifyCharacteristics: [u(0xFF02)])
        case .spPixel:
            return StripGATTSignature(services: [u(0xFFE0)],
                                      writeCharacteristics: [u(0xFFE1)],
                                      notifyCharacteristics: [u(0xFFE1), u(0xFFE2)])
        case .idealLED:
            return StripGATTSignature(
                services: [u(0xFFF0)],
                writeCharacteristics: [.fixed("D44BC439-ABFD-45A2-B575-925416129600")],
                notifyCharacteristics: [.fixed("D44BC439-ABFD-45A2-B575-925416129601")])
        }
    }

    /// Advertised-name prefixes, upper-cased, that point at this family.
    ///
    /// Prefixes are **not** decisive on their own — `LEDBLE-` appears in both
    /// the ELK and Triones ecosystems, and `QHM-` is a Triones device despite
    /// looking like nothing in particular. ``StripIdentifier`` weights a
    /// discovered characteristic above any name.
    public var namePrefixes: [String] {
        switch self {
        case .elkBLEDOM, .elkBLEDOMAlternatePower:
            return ["ELK-BLEDOM", "ELK-BLE", "ELK-BTC", "ELK-BULB", "ELK-LAMPL",
                    "ELK-BLEDDM", "XSL-", "LED LIGHT STRIP"]
        case .elkBLEDOB: return ["ELK-BLEDOB"]
        case .melk: return ["MELK"]
        case .ledble: return ["LEDBLE"]
        case .jackyLED: return ["LED-", "JACKYLED", "XROCKER"]
        case .triones: return ["TRIONES", "LEDBLUE", "QHM-", "DREAM~"]
        case .lednetWF: return ["LEDNETWF"]
        case .spPixel: return ["SP1", "SP6", "SP5", "SP0", "BLE-SPI"]
        case .idealLED: return []
        }
    }

    // MARK: - Frames

    /// A colour frame, or `nil` when the family has no builder.
    ///
    /// `sequence` is used only by ``lednetWF``; every other family ignores it.
    /// It is on the shared signature rather than hidden inside the transport so
    /// that the frame a caller sends is a pure function of its arguments and
    /// can be asserted in a test.
    public func colorFrame(_ rgb: StripRGB, sequence: UInt8 = 0) -> [UInt8]? {
        if let dialect = elkDialect { return ELKFrames.color(rgb, dialect: dialect) }
        switch self {
        case .triones: return TrionesFrames.color(rgb)
        case .lednetWF: return LEDnetWFFrames.color(rgb, sequence: sequence)
        case .spPixel: return SPPixelFrames.color(rgb)
        case .idealLED: return nil
        default: return nil
        }
    }

    public func powerFrame(on: Bool, sequence: UInt8 = 0) -> [UInt8]? {
        if let dialect = elkDialect { return ELKFrames.power(on: on, dialect: dialect) }
        switch self {
        case .triones: return TrionesFrames.power(on: on)
        case .lednetWF: return LEDnetWFFrames.power(on: on, sequence: sequence)
        case .spPixel: return SPPixelFrames.power(on: on)
        case .idealLED: return nil
        default: return nil
        }
    }

    /// A brightness frame, or `nil` when the family has none of its own.
    ///
    /// `nil` for ``triones``, which is not a gap in this implementation —
    /// see ``scalesBrightnessByColor``.
    public func brightnessFrame(percent: Int, sequence: UInt8 = 0) -> [UInt8]? {
        if let dialect = elkDialect {
            return ELKFrames.brightness(percent: percent, dialect: dialect)
        }
        switch self {
        case .lednetWF: return LEDnetWFFrames.brightness(percent: percent, sequence: sequence)
        case .spPixel:
            // SP takes a full byte where the others take a percentage.
            let scaled = UInt8(max(0, min(100, percent)) * 255 / 100)
            return SPPixelFrames.brightness(scaled)
        case .triones, .idealLED: return nil
        default: return nil
        }
    }

    /// The status/state query, where the family documents one. Answers arrive
    /// on the notify characteristic.
    public var statusQueryFrame: [UInt8]? {
        if elkDialect != nil { return ELKFrames.statusQuery }
        switch self {
        case .triones: return TrionesFrames.statusQuery
        case .lednetWF: return LEDnetWFFrames.stateQuery()
        case .spPixel: return SPPixelFrames.readParameters
        case .idealLED: return nil
        default: return nil
        }
    }

    /// Every family with a colour builder, in the order `strip try-all` should
    /// send them.
    ///
    /// Ordered most to least likely for an unbranded 5V USB strip: the ELK
    /// dialects first (by far the most common), then Triones, then the two that
    /// need a different transport shape. The two ELK power variants are
    /// adjacent so that a strip which lights up but will not switch off is
    /// diagnosed in one run.
    public static let tryAllOrder: [StripFamily] = [
        .elkBLEDOM, .elkBLEDOMAlternatePower, .elkBLEDOB, .melk,
        .ledble, .jackyLED, .triones, .lednetWF, .spPixel,
    ]
}
