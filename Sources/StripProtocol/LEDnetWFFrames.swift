import Foundation

/// LEDnetWF — the one family here with a real transport layer.
///
/// Devices advertising `LEDnetWF01…` / `LEDnetWF02…` do **not** speak the
/// `0x56` frames of the Triones/Zengge family they are otherwise related to.
/// Every command is an inner payload wrapped in an eight-byte header carrying a
/// sequence counter and a big-endian length, and the inner payload carries its
/// own checksum. `8none1/lednetwf_ble`'s `protocol_docs/04_connection_transport.md`
/// puts it plainly: "All commands MUST be wrapped in the transport layer. Raw
/// command bytes will NOT work."
///
/// ## Sources
///
/// * `8none1/lednetwf_ble` `protocol_docs/` — the current, fullest writeup:
///   transport layout, per-product effect tables, the checksum rule.
/// * `8none1/zengge_lednetwf` README — the retired predecessor, whose verbatim
///   sniffer captures are what the golden tests here assert against.
///
/// ## Two things the sources are emphatic about
///
/// * **Notifications must be enabled before the device accepts anything.**
///   Not a handshake blob — just a CCCD write on the notify characteristic.
///   The retired README: "you seem to have to do [this] in order for it to
///   accept commands".
/// * **Once connected, the counter and the checksum are ignored.** Same README,
///   in capitals. Both are computed correctly here anyway, because a frame that
///   is right for the wrong reason is not evidence of anything.
public enum LEDnetWFFrames {

    /// Bytes 0…7 of every frame, before the inner payload.
    public static let transportHeaderLength = 8

    /// Byte 7: whether the device should answer.
    ///
    /// `0x0A` asks for a response, `0x0B` does not. Everything except the state
    /// query uses `0x0B`.
    public enum CommandID: UInt8, Sendable {
        case expectsResponse = 0x0A
        case noResponse      = 0x0B
    }

    /// Wraps an inner payload in the eight-byte transport header.
    ///
    /// ```
    /// [0] 0x00        header flags, version 0
    /// [1] sequence    increments per command, wraps at 256
    /// [2] 0x80        fragment control: single / last fragment
    /// [3] 0x00
    /// [4] length hi   payload length, big-endian
    /// [5] length lo
    /// [6] length + 1
    /// [7] command ID  0x0A expects a response, 0x0B does not
    /// ```
    ///
    /// `payload` is the inner command **including** its own checksum byte,
    /// because the length fields count it — the reference encoder in
    /// `04_connection_transport.md` takes the finished command bytes.
    public static func wrap(_ payload: [UInt8],
                            sequence: UInt8,
                            commandID: CommandID = .noResponse) -> [UInt8] {
        let length = payload.count
        return [0x00,
                sequence,
                0x80,
                0x00,
                UInt8((length >> 8) & 0xFF),
                UInt8(length & 0xFF),
                UInt8((length + 1) & 0xFF),
                commandID.rawValue] + payload
    }

    /// The inner checksum: the arithmetic sum of every preceding inner byte,
    /// mod 256. It does **not** cover the eight transport header bytes.
    public static func checksum(_ inner: [UInt8]) -> UInt8 {
        UInt8(inner.reduce(0) { ($0 + Int($1)) & 0xFF })
    }

    /// Appends ``checksum(_:)`` to an inner payload.
    public static func checksummed(_ inner: [UInt8]) -> [UInt8] {
        inner + [checksum(inner)]
    }

    // MARK: - Colour

    /// The inner `0x3B 0xA1` HSV colour command, without the transport header.
    ///
    /// ```
    /// [0]     0x3B
    /// [1]     0xA1        HSV colour mode
    /// [2..3]  (hue << 7) | saturation, big-endian
    /// [4]     value (brightness), 0…100
    /// [5..9]  mode parameters and a redundant RGB copy — zero here
    /// [10..11] transition time — MUST be 00 00
    /// [12]    checksum
    /// ```
    ///
    /// Bytes 10…11 are a documented footgun: `05_basic_commands.md` says "Use
    /// `0x00, 0x00` for instant response! Non-zero values cause delays", and a
    /// strip that lags a visualizer by a fixed interval is exactly the bug that
    /// would be hard to find later. Zero, always.
    public static func colorPayload(_ hsv: StripHSV) -> [UInt8] {
        let packed = (hsv.hue << 7) | hsv.saturation
        return checksummed([0x3B, 0xA1,
                            UInt8((packed >> 8) & 0xFF),
                            UInt8(packed & 0xFF),
                            UInt8(hsv.value),
                            0x00, 0x00, 0x00, 0x00, 0x00,
                            0x00, 0x00])
    }

    /// A wrapped colour frame.
    ///
    /// Golden, against the retired README's verbatim capture of the phone app
    /// setting red at sequence 5:
    /// `00 05 80 00 00 0D 0E 0B 3B A1 00 64 64 00 00 00 00 00 00 00 …`
    /// (the capture's final byte is `00`, the device having ignored the
    /// checksum; `0xA4` is the correct value and what is sent here).
    public static func color(_ rgb: StripRGB, sequence: UInt8) -> [UInt8] {
        wrap(colorPayload(StripHSV(rgb)), sequence: sequence)
    }

    /// The older direct-RGB `0x31` command, for pre-Symphony product IDs.
    ///
    /// `[0x31, R, G, B, warm, cold, mode, persist, checksum]`, mode `0xF0`
    /// RGB-only, persist `0x0F` meaning "do not write to flash". Persisting is
    /// deliberately not offered: a visualizer writing flash at 20 Hz would wear
    /// the controller out.
    public static func colorLegacyPayload(_ rgb: StripRGB) -> [UInt8] {
        checksummed([0x31, rgb.red, rgb.green, rgb.blue, 0x00, 0x00, 0xF0, 0x0F])
    }

    // MARK: - Power

    /// `[0x3B, 0x23|0x24, 0×7, 0x32, 0x00, 0x00, checksum]`.
    ///
    /// Golden, verbatim from the retired README:
    /// on  `00 04 80 00 00 0D 0E 0B 3B 23 00 00 00 00 00 00 00 32 00 00 90`
    /// off `00 5B 80 00 00 0D 0E 0B 3B 24 00 00 00 00 00 00 00 32 00 00 91`
    /// (bytes `04` and `5B` are just the counter at capture time).
    ///
    /// Note the `0x32` at index 9 — this is the one command whose transition
    /// field is non-zero in the captures, and it is reproduced rather than
    /// zeroed because a power frame has nothing to be late for.
    public static func powerPayload(on: Bool) -> [UInt8] {
        checksummed([0x3B, on ? 0x23 : 0x24,
                     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                     0x32, 0x00, 0x00])
    }

    public static func power(on: Bool, sequence: UInt8) -> [UInt8] {
        wrap(powerPayload(on: on), sequence: sequence)
    }

    // MARK: - Brightness

    /// `[0x3B, 0x01, 0x00, 0x00, b, 0x00, b, delay×3, gradient×2, checksum]`,
    /// `b` in 0…100. Firmware v9 and later.
    public static func brightnessPayload(percent: Int) -> [UInt8] {
        let value = UInt8(max(0, min(100, percent)))
        return checksummed([0x3B, 0x01, 0x00, 0x00, value, 0x00, value,
                            0x00, 0x00, 0x00, 0x00, 0x00])
    }

    public static func brightness(percent: Int, sequence: UInt8) -> [UInt8] {
        wrap(brightnessPayload(percent: percent), sequence: sequence)
    }

    // MARK: - Effects

    /// Which effect command a unit takes, selected by its product ID.
    ///
    /// There is no way to know this before reading the device's state, which is
    /// why it is a parameter rather than a constant. The ID ranges come from
    /// `06_effect_commands.md`.
    public enum EffectCommand: Sendable, Equatable {
        /// Product `0x1D` (fill light / ring light): four bytes, **no
        /// checksum**, effect IDs 1…113.
        case fillLight
        /// Products `0x54`, `0x55`, `0x5B`, `0x62` (addressable strip):
        /// `0x38` with a checksum, effect IDs 1…44.
        case addressable
        /// Products `0x56`, `0x80`, `0xA1`…`0xAD` (music / symphony):
        /// `0x42` with a checksum, effect IDs 1…100.
        case symphony

        public var opcode: UInt8 {
            switch self {
            case .fillLight, .addressable: return 0x38
            case .symphony: return 0x42
            }
        }

        public var effectIDRange: ClosedRange<UInt8> {
            switch self {
            case .fillLight: return 1...113
            case .addressable: return 1...44
            case .symphony: return 1...100
            }
        }
    }

    /// `[opcode, effect, speed, brightness]` (+ checksum, except fill lights).
    ///
    /// Golden, verbatim from the retired README's captures:
    /// fill light `38 01 01 64` wrapped as `00 06 80 00 00 04 05 0B 38 01 01 64`,
    /// symphony `42 01 32 64 D9` wrapped as `00 9C 80 00 00 05 06 0B 42 01 32 64 D9`.
    ///
    /// `brightness` is clamped to a **minimum of 1**: `06_effect_commands.md`
    /// warns in bold that "Brightness=0 powers OFF the device", so a caller
    /// fading an effect to nothing would otherwise turn the strip off and have
    /// no way to bring it back with the same command.
    public static func effectPayload(_ effect: UInt8,
                                     speed: UInt8,
                                     brightness: UInt8,
                                     command: EffectCommand) -> [UInt8] {
        let inner = [command.opcode, effect, speed, max(1, brightness)]
        return command == .fillLight ? inner : checksummed(inner)
    }

    public static func effect(_ effect: UInt8,
                              speed: UInt8,
                              brightness: UInt8,
                              command: EffectCommand,
                              sequence: UInt8) -> [UInt8] {
        wrap(effectPayload(effect, speed: speed, brightness: brightness, command: command),
             sequence: sequence)
    }

    // MARK: - State query

    /// The wrapped state query, verbatim from `tools/ble_scanner.py`:
    /// `00 01 80 00 00 04 05 0A 81 8A 8B 96`.
    ///
    /// Note the `0x0A` — this is the one command that asks for an answer.
    /// Sending it after enabling notifications is the cheapest confirmation
    /// that a device really is LEDnetWF.
    public static func stateQuery(sequence: UInt8 = 1) -> [UInt8] {
        wrap(checksummed([0x81, 0x8A, 0x8B]),
             sequence: sequence, commandID: .expectsResponse)
    }
}
