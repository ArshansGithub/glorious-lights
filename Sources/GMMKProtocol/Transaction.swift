import Foundation

/// Convenience builders that wrap one or more config writes in the required
/// `START` / `END` bracketing.
///
/// Every element of the returned array is a 63-byte payload ready for
/// `IOHIDDeviceSetReport` with report ID 4 — see ``GMMKPacket`` for the
/// convention.
public enum GMMKTransaction {

    /// Brackets `packets` with `START` and `END`.
    public static func bracket(_ packets: [[UInt8]]) -> [[UInt8]] {
        [GMMKPacket.start()] + packets + [GMMKPacket.end()]
    }

    /// A single config write in its own transaction — the shape `gmmkctl` uses.
    public static func single(_ packet: [UInt8]) -> [[UInt8]] {
        bracket([packet])
    }

    /// The recommended first smoke test: solid colour, full brightness,
    /// rainbow off, mode `fixed`. Unambiguous visually — unlike brightness 0
    /// or mode `off`, both of which look identical to "nothing happened".
    public static func solidColor(_ color: RGB, brightness: UInt8 = Brightness.max) -> [[UInt8]] {
        bracket([
            GMMKPacket.setMode(.fixed),
            GMMKPacket.setBrightness(level: brightness),
            GMMKPacket.setRainbow(false),
            GMMKPacket.setColor(red: color.red, green: color.green, blue: color.blue),
        ])
    }

    /// Per-key colours: mode `custom` followed by the colour run, all inside a
    /// single transaction.
    ///
    /// - Note: TKL key indexing is unverified. See `docs/protocol.md` §7.1.
    public static func customColors(startKeyIndex: UInt16, colors: [RGB]) -> [[UInt8]] {
        bracket([GMMKPacket.setMode(.custom)]
                + GMMKPacket.customColorPackets(startKeyIndex: startKeyIndex, colors: colors))
    }
}
