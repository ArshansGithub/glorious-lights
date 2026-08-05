import Foundation

/// Whole logical operations: the packet sequence to send for one user-visible
/// change, `START` / `END` bracketing included.
///
/// Every element of a returned array is a 63-byte payload; the transport
/// re-attaches the `0x04` report-ID byte — see ``GMMKPacket`` for the
/// convention.
///
/// ## Why every write is repeated three times
///
/// Config fields are profile-relative (``GMMKPacket/profileBases``) and the
/// board only displays the profile it is currently running. Firmware 1.08 gives
/// no dependable way to ask which that is: command `0x03`, which on other
/// firmwares returns the config block whose byte 10 names the active profile,
/// answers with a device-info block instead. So rather than track a profile the
/// board will not tell us about, each operation writes its fields at **all
/// three bases** inside one transaction. Verified on hardware: mode, colour and
/// rainbow then apply instantly regardless of which profile is active.
/// Brightness applies live and globally, so its repetition is redundant but
/// harmless, and it keeps all three profiles consistent.
///
/// Writes are field-major (mode at 0x00, 0x2A, 0x54; then rainbow at 0x04,
/// 0x2E, 0x58; …), matching the order the official editor emits.
public enum GMMKTransaction {

    /// Brackets `packets` with `START` and `END`.
    public static func bracket(_ packets: [[UInt8]]) -> [[UInt8]] {
        [GMMKPacket.start()] + packets + [GMMKPacket.end()]
    }

    /// A single write in its own transaction, at profile 0 only — the shape
    /// `gmmkctl` uses. Debugging convenience; the operations below are what the
    /// app and CLI send.
    public static func single(_ packet: [UInt8]) -> [[UInt8]] {
        bracket([packet])
    }

    /// Brackets one write per field, each repeated at every profile base.
    ///
    /// - Parameter fields: field builders, in the order they should go out;
    ///   each is called once per entry in ``GMMKPacket/profileBases``.
    public static func writingEveryProfile(_ fields: [(UInt16) -> [UInt8]]) -> [[UInt8]] {
        bracket(fields.flatMap(GMMKPacket.atEveryProfile))
    }

    // MARK: - Operations

    /// Sets the effect mode.
    public static func setMode(_ mode: LightingMode) -> [[UInt8]] {
        writingEveryProfile([{ GMMKPacket.setMode(mode, profileBase: $0) }])
    }

    /// Sets the effect mode by raw ID (`0x01`…`0x14`).
    public static func setModeID(_ id: UInt8) -> [[UInt8]] {
        writingEveryProfile([{ GMMKPacket.setModeID(id, profileBase: $0) }])
    }

    /// Sets brightness, `0`…`4` (`0` is off).
    public static func setBrightness(level: UInt8) -> [[UInt8]] {
        writingEveryProfile([{ GMMKPacket.setBrightness(level: level, profileBase: $0) }])
    }

    /// Sets the animation delay, `0`…`3` — higher is slower.
    public static func setDelay(_ delay: UInt8) -> [[UInt8]] {
        writingEveryProfile([{ GMMKPacket.setDelay(delay, profileBase: $0) }])
    }

    /// Sets the effect direction.
    public static func setDirection(_ direction: Direction) -> [[UInt8]] {
        writingEveryProfile([{ GMMKPacket.setDirection(direction, profileBase: $0) }])
    }

    /// Sets the rainbow (hue-cycling) flag.
    public static func setRainbow(_ on: Bool) -> [[UInt8]] {
        writingEveryProfile([{ GMMKPacket.setRainbow(on, profileBase: $0) }])
    }

    /// Sets the solid colour and clears the rainbow flag in the same
    /// transaction.
    ///
    /// The flag has to go with it: while rainbow is on the effect cycles hues
    /// and ignores the colour entirely, so a colour write on its own reads to
    /// the user as "nothing happened".
    public static func setColor(_ color: RGB) -> [[UInt8]] {
        writingEveryProfile([
            { GMMKPacket.setRainbow(false, profileBase: $0) },
            { GMMKPacket.setColor(red: color.red, green: color.green, blue: color.blue,
                                  profileBase: $0) },
        ])
    }

    /// Solid colour at a fixed brightness in mode `fixed` — the unambiguous
    /// smoke test. Unlike brightness 0 or mode `off`, the result cannot be
    /// confused with "nothing happened".
    public static func solidColor(_ color: RGB, brightness: UInt8 = Brightness.max) -> [[UInt8]] {
        writingEveryProfile([
            { GMMKPacket.setMode(.fixed, profileBase: $0) },
            { GMMKPacket.setBrightness(level: brightness, profileBase: $0) },
            { GMMKPacket.setRainbow(false, profileBase: $0) },
            { GMMKPacket.setColor(red: color.red, green: color.green, blue: color.blue,
                                  profileBase: $0) },
        ])
    }

    /// Per-key colours: mode `custom` at every profile, then the colour run,
    /// all inside a single transaction.
    ///
    /// - Note: **unresolved on firmware 1.08** — these writes are ACKed but had
    ///   no visible effect during bring-up. See ``GMMKPacket/setCustomColors(startKeyIndex:colors:)``
    ///   and `docs/protocol-tkl-notes.md` §13.
    public static func customColors(startKeyIndex: UInt16, colors: [RGB]) -> [[UInt8]] {
        bracket(GMMKPacket.atEveryProfile { GMMKPacket.setMode(.custom, profileBase: $0) }
                + GMMKPacket.customColorPackets(startKeyIndex: startKeyIndex, colors: colors))
    }
}
