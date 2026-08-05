import Foundation

/// Byte-level packet construction for the GMMK v1 (SONiX `0x0C45:0x652F`)
/// lighting protocol. See `docs/protocol.md` for the reverse-engineered
/// reference this implements.
///
/// ## Payload convention (important)
///
/// On the wire a command is a **64-byte** HID report whose byte 0 is the
/// report ID `0x04`. macOS' `IOHIDDeviceSetReport` takes the report ID as a
/// *separate argument* and the buffer **without** the leading ID byte.
///
/// Therefore every builder in this file returns a **63-byte `[UInt8]`
/// payload with the leading `0x04` report-ID byte already stripped**. Hand it
/// straight to `IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 4, ptr, 63)`.
/// Offsets in the returned array are the wire offsets minus one:
///
/// | payload offset | wire offset | field |
/// |---|---|---|
/// | 0–1 | 1–2 | checksum, uint16 little-endian |
/// | 2   | 3   | command |
/// | 3   | 4   | count (bytes of data at offset 7) |
/// | 4–5 | 5–6 | address, uint16 little-endian |
/// | 6   | 7   | pad, always `0x00` |
/// | 7…  | 8…  | data, zero-padded to the end |
///
/// The checksum is nonetheless defined over the *wire* form (bytes 3…63), which
/// is exactly payload bytes 2…62 — i.e. every byte after the checksum field.
///
/// > Transport note: the transport re-attaches the `0x04` byte before calling
/// > `IOHIDDeviceSetReport`, because macOS does **not** prepend the report ID on
/// > this vendor pipe — see ``GMMKHID/GMMKKeyboard/send(payload:)`` and
/// > `docs/protocol.md` §6. Builders stay at 63 bytes; only the transport knows.
///
/// ## Profile-relative addressing
///
/// Config-RAM addresses are **offsets within a profile block**, not absolute
/// addresses. There are three 42-byte (`0x2A`) blocks at ``profileBases``, and
/// the effect engine reads its parameters from whichever profile the board is
/// currently running. Since nothing on this firmware reliably reports *which*
/// profile that is (see ``Command/readProfile``), the library writes every
/// logical change at all three bases — see ``GMMKTransaction``.
public enum GMMKPacket {

    /// The HID report ID all lighting commands use (wire byte 0).
    public static let reportID: UInt8 = 0x04

    /// Length of the payload handed to `IOHIDDeviceSetReport` (64 minus the ID byte).
    public static let payloadLength = 63

    // MARK: - Checksum

    /// Plain 16-bit sum of the unsigned bytes after the checksum field.
    ///
    /// No carry folding, no complement, natural wraparound mod 2^16. Covers
    /// wire bytes 3…63 inclusive (61 bytes), which is `payload[2...62]`,
    /// including the trailing zero padding.
    public static func checksum(payloadBody: ArraySlice<UInt8>) -> UInt16 {
        var sum: UInt16 = 0
        for byte in payloadBody { sum = sum &+ UInt16(byte) }
        return sum
    }

    /// Assembles a 63-byte payload and fills in its checksum.
    ///
    /// - Parameters:
    ///   - command: command byte (wire offset 3).
    ///   - address: 16-bit address in the target RAM, stored little-endian.
    ///   - data: up to 56 data bytes; `count` is derived from its length.
    /// - Precondition: `data.count <= 56`.
    public static func make(command: UInt8, address: UInt16, data: [UInt8]) -> [UInt8] {
        precondition(data.count <= 56, "GMMK packets carry at most 56 data bytes")
        var p = [UInt8](repeating: 0, count: payloadLength)
        p[2] = command
        p[3] = UInt8(data.count)
        p[4] = UInt8(address & 0xFF)
        p[5] = UInt8((address >> 8) & 0xFF)
        p[6] = 0x00
        for (i, b) in data.enumerated() { p[7 + i] = b }
        let sum = checksum(payloadBody: p[2...])
        p[0] = UInt8(sum & 0xFF)
        p[1] = UInt8((sum >> 8) & 0xFF)
        return p
    }

    /// Builds a read-request packet: `count` is the number of bytes requested
    /// starting at `address`; the data area is empty. The firmware answers on
    /// the vendor Input report with the same framing.
    ///
    /// Only use with the read commands (`Command.readConfig`,
    /// `Command.readProfile`, `Command.readCustomColors`).
    public static func makeRead(command: UInt8, address: UInt16, count: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: payloadLength)
        p[2] = command
        p[3] = count
        p[4] = UInt8(address & 0xFF)
        p[5] = UInt8((address >> 8) & 0xFF)
        let sum = checksum(payloadBody: p[2...])
        p[0] = UInt8(sum & 0xFF)
        p[1] = UInt8((sum >> 8) & 0xFF)
        return p
    }

    // MARK: - Commands

    /// Command bytes (wire offset 3). Remap/macro commands are deliberately absent.
    public enum Command {
        /// Begin a transaction.
        public static let start: UInt8 = 0x01
        /// End / commit a transaction.
        public static let end: UInt8 = 0x02
        /// Read a 44-byte block.
        ///
        /// On the GMMK 1 TKL running firmware 1.08 this does **not** return the
        /// config block the community tools describe: it answers with a
        /// device-info block (`55 aa` magic, VID/PID, firmware version, then the
        /// list of supported mode IDs). Use ``readConfig`` to read config RAM.
        public static let readProfile: UInt8 = 0x03
        /// Read config RAM by address. Works as documented on firmware 1.08.
        public static let readConfig: UInt8 = 0x05
        /// Write config RAM (all lighting parameters).
        public static let writeConfig: UInt8 = 0x06
        /// Read custom (per-key) colour RAM.
        public static let readCustomColors: UInt8 = 0x10
        /// Write custom (per-key) colour RAM.
        public static let writeCustomColors: UInt8 = 0x11
    }

    /// Field offsets **within a profile block**. See `docs/protocol.md` §2.
    ///
    /// A field's wire address is `profileBase + offset`; the offsets alone are
    /// only valid for profile 0.
    public enum ConfigOffset {
        public static let mode: UInt16 = 0x00
        public static let brightness: UInt16 = 0x01
        public static let delay: UInt16 = 0x02
        public static let direction: UInt16 = 0x03
        public static let rainbow: UInt16 = 0x04
        public static let color: UInt16 = 0x05
        public static let reactiveVariant: UInt16 = 0x08
        public static let pollingRate: UInt16 = 0x0F
    }

    // MARK: - Profiles

    /// Distance between consecutive profile blocks in config RAM: 42 bytes.
    ///
    /// Not to be confused with the 44-byte (`0x2C`) transfer size commands
    /// `0x03`/`0x04` use — that is a block transfer length, not a stride.
    public static let profileStride: UInt16 = 0x2A

    /// Config-RAM base address of each onboard profile: `0x0000`, `0x002A`,
    /// `0x0054`.
    ///
    /// The board applies the fields of whichever profile it is running, and on
    /// firmware 1.08 there is no reliable way to ask which one that is — command
    /// `0x03` returns a device-info block rather than the config block that
    /// holds the active-profile byte. Writing a field at every base sidesteps
    /// the question entirely and is what ``GMMKTransaction`` does.
    public static let profileBases: [UInt16] = [0, profileStride, profileStride * 2]

    /// Applies a profile-base-taking builder once per entry in ``profileBases``.
    ///
    /// ```swift
    /// GMMKPacket.atEveryProfile { GMMKPacket.setMode(.fixed, profileBase: $0) }
    /// ```
    public static func atEveryProfile(_ build: (UInt16) -> [UInt8]) -> [[UInt8]] {
        profileBases.map(build)
    }

    // MARK: - Replies

    /// What the firmware's echo says about the command that produced it.
    public enum ReplyStatus: Equatable, Sendable {
        /// The firmware accepted the command (status `0x00`).
        case ok
        /// The firmware rejected it: `0xFF` or `0xFE`.
        case rejected(UInt8)
        /// A status byte that is neither. Treated as accepted — the official
        /// software only special-cases `0xFF` and `0xFE` — but reported
        /// distinctly so bring-up can notice it.
        case other(UInt8)
        /// The report was too short to contain a status byte.
        case malformed
    }

    /// Wire offset of the status byte in a reply. Same framing as a command:
    /// the byte that is a zero pad on the way out is the status on the way back.
    public static let replyStatusOffset = 7

    /// Reads the status byte out of an input report.
    ///
    /// Firmware 1.08 echoes every command on input report ID 4 with the status
    /// at wire offset 7. Input reports on this pipe arrive with the leading
    /// `0x04` intact — the same asymmetry that makes ``payloadLength`` wrong for
    /// `SetReport`, see `docs/protocol.md` §6 — so for a 64-byte report the
    /// status is at index 7. A 63-byte report (ID stripped) is also accepted and
    /// read one earlier, since which form arrives is a property of the OS rather
    /// than of the protocol.
    public static func replyStatus(inReport report: [UInt8]) -> ReplyStatus {
        let index: Int
        switch report.count {
        case payloadLength: index = replyStatusOffset - 1
        case let n where n > payloadLength: index = replyStatusOffset
        default: return .malformed
        }
        switch report[index] {
        case 0x00: return .ok
        case 0xFF, 0xFE: return .rejected(report[index])
        case let byte: return .other(byte)
        }
    }

    // MARK: - Transaction bracketing

    /// `04 01 00 01 00 …` — opens a transaction. Byte-exact and invariant.
    public static func start() -> [UInt8] {
        make(command: Command.start, address: 0, data: [])
    }

    /// `04 02 00 02 00 …` — commits a transaction. Byte-exact and invariant.
    public static func end() -> [UInt8] {
        make(command: Command.end, address: 0, data: [])
    }

    // MARK: - Config writes

    /// Writes one config field at `profileBase + offset`.
    private static func writeConfig(_ offset: UInt16,
                                    _ profileBase: UInt16,
                                    _ data: [UInt8]) -> [UInt8] {
        make(command: Command.writeConfig, address: profileBase &+ offset, data: data)
    }

    /// Sets the onboard effect mode (config offset `0x00`).
    ///
    /// - Parameter profileBase: one of ``profileBases``; defaults to profile 0.
    ///   Only the *running* profile's mode is displayed, so prefer
    ///   ``GMMKTransaction/setMode(_:)`` over calling this for one base.
    public static func setMode(_ mode: LightingMode, profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.mode, profileBase, [mode.rawValue])
    }

    /// Sets the raw effect-mode ID (config offset `0x00`). Valid IDs are `0x01`…`0x14`.
    public static func setModeID(_ id: UInt8, profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.mode, profileBase, [id])
    }

    /// Sets brightness (config offset `0x01`).
    ///
    /// Verified to apply live and globally on firmware 1.08, unlike mode and
    /// colour, which are read from the running profile.
    ///
    /// - Parameter level: `0`…`4`; **`0` is off**, `4` is maximum. Clamped.
    public static func setBrightness(level: UInt8, profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.brightness, profileBase, [min(level, Brightness.max)])
    }

    /// Sets the animation delay (config offset `0x02`).
    ///
    /// This is a *delay*, not a speed: **higher is slower**. `0`…`3` are the
    /// values known to be meaningful; larger values are accepted by the
    /// firmware but untested. Clamped to `0`…`3`.
    public static func setDelay(_ delay: UInt8, profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.delay, profileBase, [min(delay, Delay.max)])
    }

    /// Sets the effect direction (config offset `0x03`).
    ///
    /// The concrete meaning is per-effect: some effects read it as up/down or
    /// inward/outward rather than left/right.
    public static func setDirection(_ direction: Direction, profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.direction, profileBase, [direction.rawValue])
    }

    /// Sets the "colorful" / rainbow flag (config offset `0x04`).
    ///
    /// When on, the effect cycles hues and ignores the solid colour; when off
    /// it uses the colour at config offset `0x05`.
    public static func setRainbow(_ on: Bool, profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.rainbow, profileBase, [on ? 0x01 : 0x00])
    }

    /// Sets the solid / animation colour (config offsets `0x05`…`0x07`).
    ///
    /// Byte order is R, G, B — verified on hardware. Only visible when the
    /// rainbow flag is off.
    public static func setColor(red: UInt8, green: UInt8, blue: UInt8,
                                profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.color, profileBase, [red, green, blue])
    }

    /// Sets the reactive-colour variant (config offset `0x08`), meaningful only
    /// in mode `0x11` (reactive colour).
    public static func setReactiveVariant(_ variant: ReactiveVariant,
                                          profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.reactiveVariant, profileBase, [variant.rawValue])
    }

    /// Sets the USB polling rate (config offset `0x0F`). Not a lighting setting;
    /// exposed for completeness only.
    public static func setPollingRate(_ rate: PollingRate, profileBase: UInt16 = 0) -> [UInt8] {
        writeConfig(ConfigOffset.pollingRate, profileBase, [rate.rawValue])
    }

    // MARK: - Per-key colours

    /// > Unresolved on firmware 1.08. The board **ACKs** `0x11` writes with
    /// > status `0x00`, but nothing observed on the display path changes —
    /// > writes at `address = keyIndex * 3` had no visible effect even in mode
    /// > `0x14` (custom) with the whole array painted. Either the address space
    /// > differs from the full-size boards these builders were derived from, or
    /// > another step is needed to latch LED RAM. The builders below are kept
    /// > because they are byte-correct against the community tools, but nothing
    /// > in the app exposes them. See `docs/protocol-tkl-notes.md` §13.

    /// Maximum data bytes in one `0x11` packet: `(64 - 8) / 3 * 3`.
    public static let maxCustomColorBytesPerPacket = 54
    /// Maximum keys addressed by one `0x11` packet.
    public static let maxKeysPerPacket = maxCustomColorBytesPerPacket / 3

    /// Writes per-key colours starting at `startKeyIndex` (command `0x11`).
    ///
    /// LED colour RAM is a flat array of RGB triplets and the wire address is a
    /// *byte* address: `address = keyIndex * 3`. Key indices are 1-based.
    ///
    /// - Parameters:
    ///   - startKeyIndex: 1-based index of the first key in `colors`.
    ///   - colors: up to 18 RGB triplets.
    /// - Precondition: `colors.count <= 18`.
    /// - Note: the colours only become visible in mode `0x14` (custom).
    ///   Key indexing on the TKL board is unverified — see `docs/protocol.md` §7.1.
    public static func setCustomColors(startKeyIndex: UInt16, colors: [RGB]) -> [UInt8] {
        precondition(colors.count <= maxKeysPerPacket,
                     "at most \(maxKeysPerPacket) keys fit in one packet")
        var data = [UInt8]()
        data.reserveCapacity(colors.count * 3)
        for c in colors { data.append(contentsOf: [c.red, c.green, c.blue]) }
        return make(command: Command.writeCustomColors,
                    address: startKeyIndex &* 3,
                    data: data)
    }

    /// Splits an arbitrarily long run of per-key colours into as many `0x11`
    /// packets as needed, 18 keys each.
    ///
    /// The caller must bracket the whole run in a single ``start()`` /
    /// ``end()`` pair.
    public static func customColorPackets(startKeyIndex: UInt16, colors: [RGB]) -> [[UInt8]] {
        var packets = [[UInt8]]()
        var index = startKeyIndex
        var remaining = colors[...]
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(maxKeysPerPacket))
            packets.append(setCustomColors(startKeyIndex: index, colors: chunk))
            index &+= UInt16(chunk.count)
            remaining = remaining.dropFirst(chunk.count)
        }
        return packets
    }
}
