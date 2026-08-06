import Foundation

/// The SP110E / SP107E addressable-pixel controllers — four bytes, command
/// **last**.
///
/// Included for one specific reason: PAUTIX's own catalogue leans on BanlanX
/// SP-series controllers (`SP611E`, `SP630E`, `SP643E`…) for several of its
/// products, and the SP wire format shares nothing with the `0x7E` and `0x56`
/// families. If tomorrow's strip turns out to be an SP unit, having only the
/// other families implemented would mean starting over.
///
/// ## Sources
///
/// * `mbullington`'s `sp110e.md` gist — the frame shape and the command table.
/// * `roslovets/SP110E` `driver.py` — an independent implementation that
///   agrees, and supplies the mode and speed ranges.
/// * `and7ey`'s SP107E gist — the sibling controller, where the sources start
///   to diverge (see ``powerOff``).
public enum SPPixelFrames {

    /// `[data0, data1, data2, command]`.
    ///
    /// The command byte is **last**, not first — the opposite of every other
    /// family here. Commands taking fewer than three data bytes ignore the
    /// rest; `mbullington` notes the app puts arbitrary filler there, and zero
    /// is used throughout below.
    ///
    /// There is no checksum on the four-byte commands.
    public static func frame(_ command: UInt8, data: [UInt8] = []) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, command]
        for (i, byte) in data.prefix(3).enumerated() { bytes[i] = byte }
        return bytes
    }

    /// Command bytes.
    public enum Command: UInt8, Sendable {
        case readParameters = 0x10
        case speed          = 0x03
        case color          = 0x1E
        case brightness     = 0x2A
        case mode           = 0x2C
        case pixelCount     = 0x2D
        case sequence       = 0x3C
        case icModel        = 0x1C
        case whiteBrightness = 0x69
        case powerOn        = 0xAA
        case powerOff       = 0xAB
        /// Mode 0 is not reachable through ``Command/mode``; `roslovets`
        /// special-cases it to this bare command.
        case autoMode       = 0x06
    }

    /// `<R> <G> <B> 1E`. Red is `FF 00 00 1E`.
    public static func color(_ rgb: StripRGB) -> [UInt8] {
        frame(Command.color.rawValue, data: rgb.rgbBytes)
    }

    /// `00 00 00 AA` on, `00 00 00 AB` off.
    ///
    /// **Sources disagree on off.** Both SP110E implementations say `0xAB`;
    /// the SP107E gist says `0xBB`. `0xAB` is used here as the SP110E-confirmed
    /// value, and ``powerOffSP107E`` carries the other so that a strip that
    /// takes colour but will not switch off has somewhere to go.
    public static func power(on: Bool) -> [UInt8] {
        frame(on ? Command.powerOn.rawValue : Command.powerOff.rawValue)
    }

    /// `00 00 00 BB` — the SP107E gist's off command.
    public static let powerOffSP107E: [UInt8] = [0x00, 0x00, 0x00, 0xBB]

    /// `<value> 00 00 2A`, 0…255. Unlike ELK and LEDnetWF this really is a
    /// full byte, not a percentage.
    public static func brightness(_ value: UInt8) -> [UInt8] {
        frame(Command.brightness.rawValue, data: [value])
    }

    /// `<mode> 00 00 2C`, modes 1…121. Mode 0 is ``autoMode``.
    public static func mode(_ mode: UInt8) -> [UInt8] {
        mode == 0 ? frame(Command.autoMode.rawValue)
                  : frame(Command.mode.rawValue, data: [mode])
    }

    /// `<speed> 00 00 03`.
    public static func speed(_ value: UInt8) -> [UInt8] {
        frame(Command.speed.rawValue, data: [value])
    }

    /// `00 00 00 10` — asks the controller to report its parameters on the
    /// notify characteristic.
    public static let readParameters: [UInt8] = [0x00, 0x00, 0x00, 0x10]

    /// The four-byte write `mbullington` reports is needed immediately after
    /// connecting "to prevent the connection from closing".
    ///
    /// `roslovets` does not send it and works, so it is exposed but not sent
    /// automatically — one unsourced write on connect is exactly the kind of
    /// thing that makes a bring-up session hard to reason about.
    public static let optionalInitWrite: [UInt8] = [0x01, 0xB7, 0xE3, 0xD5]
}
