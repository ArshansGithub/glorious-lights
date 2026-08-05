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

    // MARK: - Commands

    /// Command bytes (wire offset 3). Remap/macro commands are deliberately absent.
    public enum Command {
        /// Begin a transaction.
        public static let start: UInt8 = 0x01
        /// End / commit a transaction.
        public static let end: UInt8 = 0x02
        /// Read a profile block.
        public static let readProfile: UInt8 = 0x03
        /// Read config RAM.
        public static let readConfig: UInt8 = 0x05
        /// Write config RAM (all lighting parameters).
        public static let writeConfig: UInt8 = 0x06
        /// Read custom (per-key) colour RAM.
        public static let readCustomColors: UInt8 = 0x10
        /// Write custom (per-key) colour RAM.
        public static let writeCustomColors: UInt8 = 0x11
    }

    /// Config-RAM addresses within profile 1. See `docs/protocol.md` §2.
    public enum ConfigAddress {
        public static let mode: UInt16 = 0x00
        public static let brightness: UInt16 = 0x01
        public static let delay: UInt16 = 0x02
        public static let direction: UInt16 = 0x03
        public static let rainbow: UInt16 = 0x04
        public static let color: UInt16 = 0x05
        public static let reactiveVariant: UInt16 = 0x08
        public static let pollingRate: UInt16 = 0x0F
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

    /// Sets the onboard effect mode (config `0x00`).
    public static func setMode(_ mode: LightingMode) -> [UInt8] {
        make(command: Command.writeConfig, address: ConfigAddress.mode, data: [mode.rawValue])
    }

    /// Sets the raw effect-mode ID (config `0x00`). Valid IDs are `0x01`…`0x14`.
    public static func setModeID(_ id: UInt8) -> [UInt8] {
        make(command: Command.writeConfig, address: ConfigAddress.mode, data: [id])
    }

    /// Sets brightness (config `0x01`).
    ///
    /// - Parameter level: `0`…`4`; **`0` is off**, `4` is maximum. Clamped.
    public static func setBrightness(level: UInt8) -> [UInt8] {
        make(command: Command.writeConfig,
             address: ConfigAddress.brightness,
             data: [min(level, Brightness.max)])
    }

    /// Sets the animation delay (config `0x02`).
    ///
    /// This is a *delay*, not a speed: **higher is slower**. `0`…`3` are the
    /// values known to be meaningful; larger values are accepted by the
    /// firmware but untested. Clamped to `0`…`3`.
    public static func setDelay(_ delay: UInt8) -> [UInt8] {
        make(command: Command.writeConfig,
             address: ConfigAddress.delay,
             data: [min(delay, Delay.max)])
    }

    /// Sets the effect direction (config `0x03`).
    ///
    /// The concrete meaning is per-effect: some effects read it as up/down or
    /// inward/outward rather than left/right.
    public static func setDirection(_ direction: Direction) -> [UInt8] {
        make(command: Command.writeConfig,
             address: ConfigAddress.direction,
             data: [direction.rawValue])
    }

    /// Sets the "colorful" / rainbow flag (config `0x04`).
    ///
    /// When on, the effect cycles hues and ignores the solid colour; when off
    /// it uses the colour at config `0x05`.
    public static func setRainbow(_ on: Bool) -> [UInt8] {
        make(command: Command.writeConfig,
             address: ConfigAddress.rainbow,
             data: [on ? 0x01 : 0x00])
    }

    /// Sets the solid / animation colour (config `0x05`…`0x07`).
    ///
    /// Only visible when the rainbow flag is off.
    public static func setColor(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        make(command: Command.writeConfig,
             address: ConfigAddress.color,
             data: [red, green, blue])
    }

    /// Sets the reactive-colour variant (config `0x08`), meaningful only in
    /// mode `0x11` (reactive colour).
    public static func setReactiveVariant(_ variant: ReactiveVariant) -> [UInt8] {
        make(command: Command.writeConfig,
             address: ConfigAddress.reactiveVariant,
             data: [variant.rawValue])
    }

    /// Sets the USB polling rate (config `0x0F`). Not a lighting setting;
    /// exposed for completeness only.
    public static func setPollingRate(_ rate: PollingRate) -> [UInt8] {
        make(command: Command.writeConfig,
             address: ConfigAddress.pollingRate,
             data: [rate.rawValue])
    }

    // MARK: - Per-key colours

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
