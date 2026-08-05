import Foundation

/// What the keyboard reports about itself in reply to command `0x03`.
///
/// On firmware 1.08 command `0x03` (count `0x2C`, address 0) does **not** return
/// the 44-byte config block the community tools describe — it returns this
/// device-info block. That is also why the block is worth reading at all beyond
/// curiosity: the read is what lets subsequent config writes latch (see
/// ``GMMKPacket/Command/readProfile`` and `docs/protocol-tkl-notes.md` §13.8).
///
/// Layout, as offsets into the reply's data area (wire offset 8 onwards),
/// decoded from a real capture:
///
/// ```
/// 55 aa ff 02 45 0c 2f 65 08 01 00 08 00 00 00 00 01 02 … 14 ff
/// ^^^^^       ^^^^^ ^^^^^ ^^^^^                         ^^^^^^^^
/// magic       VID   PID   fw 1.08                       mode IDs, 0xFF-terminated
/// ```
///
/// | data offset | wire offset | field |
/// |---|---|---|
/// | 0–1 | 8–9 | magic `55 aa` |
/// | 2–3 | 10–11 | unidentified (`ff 02` observed) |
/// | 4–5 | 12–13 | USB vendor ID, little-endian |
/// | 6–7 | 14–15 | USB product ID, little-endian |
/// | 8–9 | 16–17 | firmware version, little-endian (`08 01` = 1.08) |
/// | 10–15 | 18–23 | unidentified (`00 08 00 00 00 00` observed) |
/// | 16… | 24… | supported effect-mode IDs, terminated by `0xFF` |
public struct GMMKDeviceInfo: Equatable, Sendable {

    /// USB vendor ID the board reports — expected to be `0x0C45`.
    public let vendorID: UInt16
    /// USB product ID the board reports — expected to be `0x652F`.
    public let productID: UInt16
    /// Firmware version as the raw little-endian word, e.g. `0x0108`.
    public let firmwareVersion: UInt16
    /// Effect-mode IDs the firmware says it supports, in the order it lists
    /// them. Firmware 1.08 reports 19 and omits `0x13` (off).
    public let supportedModeIDs: [UInt8]

    /// Firmware version as the vendor writes it: high byte, dot, low byte
    /// zero-padded to two digits — `0x0108` becomes `"1.08"`.
    public var firmwareVersionString: String {
        String(format: "%d.%02d", firmwareVersion >> 8, firmwareVersion & 0xFF)
    }

    /// ``supportedModeIDs`` mapped onto ``LightingMode``, dropping any ID this
    /// library does not know.
    public var supportedModes: [LightingMode] {
        supportedModeIDs.compactMap(LightingMode.init(rawValue:))
    }

    public init(vendorID: UInt16,
                productID: UInt16,
                firmwareVersion: UInt16,
                supportedModeIDs: [UInt8]) {
        self.vendorID = vendorID
        self.productID = productID
        self.firmwareVersion = firmwareVersion
        self.supportedModeIDs = supportedModeIDs
    }

    // MARK: - Parsing

    /// Magic the data area opens with. A reply that does not start with it is
    /// not an info block and is rejected rather than guessed at.
    public static let magic: [UInt8] = [0x55, 0xAA]

    /// Offset of the mode-ID list within the data area.
    static let modeListOffset = 16

    /// Parses an input report as an info block.
    ///
    /// - Returns: `nil` if the report is too short or does not carry the magic.
    public init?(reply: [UInt8]) {
        guard let data = GMMKPacket.replyData(inReport: reply),
              data.count > Self.modeListOffset,
              Array(data.prefix(Self.magic.count)) == Self.magic else {
            return nil
        }
        let body = Array(data)

        func word(at offset: Int) -> UInt16 {
            UInt16(body[offset]) | (UInt16(body[offset + 1]) << 8)
        }

        vendorID = word(at: 4)
        productID = word(at: 6)
        firmwareVersion = word(at: 8)
        // The list ends at 0xFF. It is also cut short by a 0x00, which is not a
        // valid mode ID either — that is the packet's zero padding, reached when
        // a reply is truncated before its terminator.
        supportedModeIDs = Array(body[Self.modeListOffset...]
            .prefix { $0 != 0xFF && $0 != 0x00 })
    }
}
