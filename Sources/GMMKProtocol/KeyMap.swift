import Foundation

/// Physical-key table for a **US-ANSI TKL** GMMK 1: LED colour-RAM index and the
/// macOS virtual key code the key reports.
///
/// ## Where the LED indices come from
///
/// `docs/protocol.md` §4 gives the full-size (104-key) key-index map from
/// `gmmkctl/keymap-US-ANSI-fullsize.txt`. `docs/protocol-tkl-notes.md` §3 found
/// the official editor's per-key colour templates to be **byte-identical between
/// the TKL and Full Size packages**, which is positive evidence that the TKL
/// shares the full-size address space and simply lacks the numpad indices. The
/// table below is exactly that: the full-size map with the 17 numpad entries
/// (31–33, 48–50, 65–67, 82–84, 99–101, 116, 117) removed, leaving 87 keys.
///
/// The wire address of a key is `ledIndex * 3` — see
/// ``GMMKPacket/setCustomColors(startKeyIndex:colors:)``.
///
/// ## Where the key codes come from
///
/// `keyCode` is the macOS virtual key code (`kVK_*`, as delivered in
/// `NSEvent.keyCode`), which is a hardware-independent constant, so no AppKit or
/// Carbon import is needed to name them here.
///
/// Three groups are worth flagging as **less certain than the rest**, because
/// macOS has no first-class constant for the PC keys involved:
///
/// * `PrtSc` / `ScrLk` / `Pause` — a PC keyboard reports these through the
///   `F13` / `F14` / `F15` codes (`0x69` / `0x6B` / `0x71`).
/// * `Menu` (the application key) — `0x6E`, which has no `kVK_` name.
/// * `LGui` / `RGui` and `LAlt` / `RAlt` arrive as macOS Command and Option.
///
/// Everything here is one line per key on purpose: if the board lights the wrong
/// LED for a key, the marking phase of the switch-compensation tuner flashes it
/// white and the user sees immediately which line needs correcting.
public enum GMMKKeyMap {

    /// One physical key.
    public struct Key: Equatable, Sendable {
        /// Name as printed on the keycap, for UI and diagnostics.
        public let label: String
        /// macOS virtual key code (`NSEvent.keyCode`).
        public let keyCode: UInt16
        /// 1-based index into LED colour RAM; wire address is `ledIndex * 3`.
        public let ledIndex: UInt16

        public init(_ label: String, keyCode: UInt16, ledIndex: UInt16) {
            self.label = label
            self.keyCode = keyCode
            self.ledIndex = ledIndex
        }
    }

    // MARK: - Index space

    /// Lowest LED index the firmware uses. Index 0 is unused on this board.
    public static let minLEDIndex: UInt16 = 1

    /// Highest LED index the official Windows utility ever addresses
    /// (`GMMK_MAX_KEY` in `gmmkctl`).
    public static let maxLEDIndex: UInt16 = 126

    /// The contiguous run a whole-board paint covers, `1`…`126`.
    ///
    /// Wider than the 87 keys that physically exist: the gaps are unpopulated
    /// addresses, and painting straight through them keeps the packet chunking
    /// contiguous — the same 1…126 sweep that was verified on hardware.
    public static let paintableLEDIndices: ClosedRange<UInt16> = minLEDIndex...maxLEDIndex

    /// Number of keys on a US-ANSI TKL board.
    public static let ansiTKLKeyCount = 87

    // MARK: - The table

    /// Every key of a US-ANSI TKL board, in reading order.
    public static let ansiTKL: [Key] = [
        // Function row. PrtSc / ScrLk / Pause report as F13 / F14 / F15.
        Key("Esc",       keyCode: 0x35, ledIndex: 1),
        Key("F1",        keyCode: 0x7A, ledIndex: 2),
        Key("F2",        keyCode: 0x78, ledIndex: 3),
        Key("F3",        keyCode: 0x63, ledIndex: 4),
        Key("F4",        keyCode: 0x76, ledIndex: 5),
        Key("F5",        keyCode: 0x60, ledIndex: 6),
        Key("F6",        keyCode: 0x61, ledIndex: 7),
        Key("F7",        keyCode: 0x62, ledIndex: 8),
        Key("F8",        keyCode: 0x64, ledIndex: 9),
        Key("F9",        keyCode: 0x65, ledIndex: 10),
        Key("F10",       keyCode: 0x6D, ledIndex: 11),
        Key("F11",       keyCode: 0x67, ledIndex: 12),
        Key("F12",       keyCode: 0x6F, ledIndex: 13),
        Key("PrtSc",     keyCode: 0x69, ledIndex: 106),
        Key("ScrLk",     keyCode: 0x6B, ledIndex: 107),
        Key("Pause",     keyCode: 0x71, ledIndex: 108),

        // Number row.
        Key("`",         keyCode: 0x32, ledIndex: 18),
        Key("1",         keyCode: 0x12, ledIndex: 19),
        Key("2",         keyCode: 0x13, ledIndex: 20),
        Key("3",         keyCode: 0x14, ledIndex: 21),
        Key("4",         keyCode: 0x15, ledIndex: 22),
        Key("5",         keyCode: 0x17, ledIndex: 23),
        Key("6",         keyCode: 0x16, ledIndex: 24),
        Key("7",         keyCode: 0x1A, ledIndex: 25),
        Key("8",         keyCode: 0x1C, ledIndex: 26),
        Key("9",         keyCode: 0x19, ledIndex: 27),
        Key("0",         keyCode: 0x1D, ledIndex: 28),
        Key("-",         keyCode: 0x1B, ledIndex: 29),
        Key("=",         keyCode: 0x18, ledIndex: 30),
        Key("Backspace", keyCode: 0x33, ledIndex: 98),
        Key("Insert",    keyCode: 0x72, ledIndex: 110),
        Key("Home",      keyCode: 0x73, ledIndex: 111),
        Key("PgUp",      keyCode: 0x74, ledIndex: 112),

        // Tab row.
        Key("Tab",       keyCode: 0x30, ledIndex: 35),
        Key("Q",         keyCode: 0x0C, ledIndex: 36),
        Key("W",         keyCode: 0x0D, ledIndex: 37),
        Key("E",         keyCode: 0x0E, ledIndex: 38),
        Key("R",         keyCode: 0x0F, ledIndex: 39),
        Key("T",         keyCode: 0x11, ledIndex: 40),
        Key("Y",         keyCode: 0x10, ledIndex: 41),
        Key("U",         keyCode: 0x20, ledIndex: 42),
        Key("I",         keyCode: 0x22, ledIndex: 43),
        Key("O",         keyCode: 0x1F, ledIndex: 44),
        Key("P",         keyCode: 0x23, ledIndex: 45),
        Key("[",         keyCode: 0x21, ledIndex: 46),
        Key("]",         keyCode: 0x1E, ledIndex: 47),
        Key("\\",        keyCode: 0x2A, ledIndex: 64),
        Key("Delete",    keyCode: 0x75, ledIndex: 113),
        Key("End",       keyCode: 0x77, ledIndex: 114),
        Key("PgDn",      keyCode: 0x79, ledIndex: 115),

        // Caps row.
        Key("Caps Lock", keyCode: 0x39, ledIndex: 52),
        Key("A",         keyCode: 0x00, ledIndex: 53),
        Key("S",         keyCode: 0x01, ledIndex: 54),
        Key("D",         keyCode: 0x02, ledIndex: 55),
        Key("F",         keyCode: 0x03, ledIndex: 56),
        Key("G",         keyCode: 0x05, ledIndex: 57),
        Key("H",         keyCode: 0x04, ledIndex: 58),
        Key("J",         keyCode: 0x26, ledIndex: 59),
        Key("K",         keyCode: 0x28, ledIndex: 60),
        Key("L",         keyCode: 0x25, ledIndex: 61),
        Key(";",         keyCode: 0x29, ledIndex: 62),
        Key("'",         keyCode: 0x27, ledIndex: 63),
        Key("Enter",     keyCode: 0x24, ledIndex: 81),

        // Shift row.
        Key("Left Shift",  keyCode: 0x38, ledIndex: 69),
        Key("Z",           keyCode: 0x06, ledIndex: 70),
        Key("X",           keyCode: 0x07, ledIndex: 71),
        Key("C",           keyCode: 0x08, ledIndex: 72),
        Key("V",           keyCode: 0x09, ledIndex: 73),
        Key("B",           keyCode: 0x0B, ledIndex: 74),
        Key("N",           keyCode: 0x2D, ledIndex: 75),
        Key("M",           keyCode: 0x2E, ledIndex: 76),
        Key(",",           keyCode: 0x2B, ledIndex: 77),
        Key(".",           keyCode: 0x2F, ledIndex: 78),
        Key("/",           keyCode: 0x2C, ledIndex: 79),
        Key("Right Shift", keyCode: 0x3C, ledIndex: 80),
        Key("Up",          keyCode: 0x7E, ledIndex: 96),

        // Bottom row. GUI arrives as Command, Alt as Option.
        Key("Left Ctrl",   keyCode: 0x3B, ledIndex: 86),
        Key("Left Cmd",    keyCode: 0x37, ledIndex: 87),
        Key("Left Opt",    keyCode: 0x3A, ledIndex: 88),
        Key("Space",       keyCode: 0x31, ledIndex: 89),
        Key("Right Opt",   keyCode: 0x3D, ledIndex: 90),
        Key("Right Cmd",   keyCode: 0x36, ledIndex: 91),
        Key("Menu",        keyCode: 0x6E, ledIndex: 92),
        Key("Right Ctrl",  keyCode: 0x3E, ledIndex: 93),
        Key("Left",        keyCode: 0x7B, ledIndex: 94),
        Key("Down",        keyCode: 0x7D, ledIndex: 95),
        Key("Right",       keyCode: 0x7C, ledIndex: 97),
    ]

    // MARK: - Lookups

    /// Virtual key code → LED index, built from ``ansiTKL``.
    public static let ledIndexByKeyCode: [UInt16: UInt16] =
        Dictionary(uniqueKeysWithValues: ansiTKL.map { ($0.keyCode, $0.ledIndex) })

    private static let keyByLEDIndex: [UInt16: Key] =
        Dictionary(uniqueKeysWithValues: ansiTKL.map { ($0.ledIndex, $0) })

    private static let keyByKeyCode: [UInt16: Key] =
        Dictionary(uniqueKeysWithValues: ansiTKL.map { ($0.keyCode, $0) })

    /// The LED lit by the key that reports `keyCode`, or `nil` for a key this
    /// board does not have (a numpad key on an external full-size keyboard, say).
    public static func ledIndex(forKeyCode keyCode: UInt16) -> UInt16? {
        ledIndexByKeyCode[keyCode]
    }

    /// The key that reports `keyCode`, or `nil` if it is not on this board.
    public static func key(forKeyCode keyCode: UInt16) -> Key? {
        keyByKeyCode[keyCode]
    }

    /// The key at `ledIndex`, or `nil` for one of the unpopulated gaps.
    public static func key(forLEDIndex ledIndex: UInt16) -> Key? {
        keyByLEDIndex[ledIndex]
    }
}
