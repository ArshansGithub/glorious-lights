import Foundation

/// A Bluetooth UUID as a value, with no CoreBluetooth dependency.
///
/// This target is deliberately pure — the same reason ``GMMKProtocol`` knows
/// nothing about IOKit. `CBUUID` is a class, is not `Equatable` in the way
/// tests want, and drags CoreBluetooth (and therefore a run loop and a
/// permission prompt) into what is otherwise arithmetic on byte arrays. The
/// transport converts these to `CBUUID` at its own boundary.
///
/// Stored canonically: uppercase, 36 characters, dashed.
public struct StripUUID: Hashable, Sendable, CustomStringConvertible {

    /// The canonical `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` form, uppercase.
    public let uuidString: String

    /// The Bluetooth SIG base UUID, into which every 16-bit UUID expands.
    ///
    /// Every cheap strip controller in ``StripFamily`` advertises 16-bit
    /// UUIDs (`FFF3`, `FFD9`, `FF01`…), but CoreBluetooth reports the ones it
    /// discovers in whichever form the peripheral used, and comparing `"FFD9"`
    /// against `"0000FFD9-0000-1000-8000-00805F9B34FB"` as strings silently
    /// fails. Everything is expanded on the way in so comparison is exact.
    public static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// Accepts the three forms a UUID arrives in: 4 hex digits (`"ffd9"`),
    /// 32 undashed hex digits, or the 36-character dashed form. Case
    /// insensitive; a leading `0x` on the short form is ignored.
    ///
    /// - Returns: `nil` for anything else, rather than a UUID that will never
    ///   match anything.
    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("0X") { s.removeFirst(2) }

        if s.count == 4, s.allSatisfy(\.isHexDigit) {
            self.uuidString = "0000" + s + Self.baseSuffix
            return
        }
        if s.count == 8, s.allSatisfy(\.isHexDigit) {
            self.uuidString = s + Self.baseSuffix
            return
        }
        if s.count == 32, s.allSatisfy(\.isHexDigit) {
            let hex = Array(s)
            self.uuidString = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-"
                            + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-"
                            + String(hex[20..<32])
            return
        }
        guard s.count == 36 else { return nil }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts.map(\.count) == [8, 4, 4, 4, 12],
              parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return nil }
        self.uuidString = s
    }

    /// Expands a 16-bit assigned number into the Bluetooth base UUID.
    public init(short value: UInt16) {
        self.uuidString = String(format: "0000%04X", value) + Self.baseSuffix
    }

    /// The 16-bit form, when this UUID sits in the Bluetooth base range.
    /// `nil` for vendor UUIDs such as iDeal LED's `D44BC439-…`.
    public var shortValue: UInt16? {
        guard uuidString.hasSuffix(Self.baseSuffix) else { return nil }
        let head = uuidString.prefix(8)
        guard head.hasPrefix("0000"), let value = UInt16(head.suffix(4), radix: 16) else {
            return nil
        }
        return value
    }

    /// `FFD9` for base-range UUIDs, the full 36 characters otherwise — the
    /// form these protocols are written up in, and short enough to put in a
    /// terminal table.
    public var shortDescription: String {
        if let value = shortValue { return String(format: "%04X", value) }
        return uuidString
    }

    public var description: String { shortDescription }
}

extension StripUUID {
    /// A hardcoded vendor UUID, for the tables in this target only.
    ///
    /// Traps on a malformed argument, which is why it is spelled distinctly
    /// rather than offered as `ExpressibleByStringLiteral`: that conformance
    /// makes `StripUUID("FFD9")` at any call site silently resolve to a
    /// *trapping* initializer instead of the failable one, which is precisely
    /// backwards for a type whose whole job is parsing input off a radio.
    /// Anything that did not come from this source file goes through
    /// ``init(_:)``.
    static func fixed(_ string: String) -> StripUUID {
        guard let parsed = StripUUID(string) else {
            preconditionFailure("malformed UUID '\(string)' in StripProtocol's tables")
        }
        return parsed
    }
}
