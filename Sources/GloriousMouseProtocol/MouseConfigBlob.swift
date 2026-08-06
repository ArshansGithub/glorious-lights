import Foundation

/// The FEATURE report 4 configuration blob, with typed accessors for every
/// field `docs/mouse-protocol.md` §5 documents.
///
/// Offsets include the leading report-ID byte at index 0, which is how both
/// libratbag and OpenRGB index this buffer — OpenRGB's `usb_buf[0x35]` and the
/// field at `MouseConfigBlob.Offset.effect` are the same byte.
///
/// **There is no checksum in this protocol.** Grepping libratbag's
/// `driver-sinowealth.c` and every OpenRGB Sinowealth file for one returns zero
/// hits (doc §1.2). Mutating a field therefore recomputes nothing; the only
/// derived byte is the *write marker* at `0x03`, and that is set deliberately by
/// ``preparedForWrite(profile:configSize:)`` rather than implicitly, because a
/// blob that carries a write marker is a blob someone intends to send.
///
/// Every unknown region is preserved verbatim: there are no setters for
/// `unknown1`…`unknown5`, so a read-modify-write cannot silently drop them.
public struct MouseConfigBlob: Equatable, Sendable {

    // MARK: - Offsets

    /// Byte offsets into the report-4 buffer, report ID included at 0.
    /// Cross-checked field by field against every literal offset OpenRGB uses;
    /// all sixteen agree (doc §5).
    public enum Offset {
        public static let reportID = 0x00
        public static let command = 0x01
        public static let unknown1 = 0x02
        public static let configWrite = 0x03
        public static let unknown2 = 0x04          // 5 bytes, 0x04–0x08
        public static let sensor = 0x09
        public static let pollingAndFlags = 0x0A
        public static let dpiCountAndActive = 0x0B
        public static let disabledDPIMask = 0x0C
        public static let dpiStages = 0x0D         // 16 bytes, 0x0D–0x1C
        public static let dpiStageColors = 0x1D    // 24 bytes, 0x1D–0x34
        public static let effect = 0x35
        public static let rainbowMode = 0x36
        public static let rainbowDirection = 0x37
        public static let singleMode = 0x38
        public static let singleColor = 0x39       // 3 bytes
        public static let breathing7Mode = 0x3C
        public static let breathing7ColorCount = 0x3D
        public static let breathing7Colors = 0x3E  // 21 bytes, 7 × RBG
        public static let tailMode = 0x53
        public static let spectrumBreathingMode = 0x54
        public static let constantMode = 0x55
        public static let constantColors = 0x56    // 18 bytes, 6 × RBG
        public static let unknown3 = 0x68          // 12 bytes, 0x68–0x73
        public static let raveMode = 0x74
        public static let raveColors = 0x75        // 6 bytes, 2 × RBG
        public static let randomMode = 0x7B
        public static let waveMode = 0x7C
        public static let breathing1Mode = 0x7D
        public static let breathing1Color = 0x7E   // 3 bytes, 0x7E–0x80
        public static let liftOffDistance = 0x81
        public static let unknown4 = 0x82
        public static let unknown5 = 0x83          // 36 bytes, "long mice only"
    }

    /// Bit 3 of the high nibble of `0x0A` — `SINOWEALTH_XY_INDEPENDENT`.
    /// libratbag's own comment admits the other bits of that nibble are unknown,
    /// so they are preserved and never interpreted.
    public static let xyIndependentFlag: UInt8 = 0b1000

    // MARK: - Storage

    /// The whole 520-byte report, report ID first.
    public private(set) var bytes: [UInt8]

    /// Bytes the device actually returned, when the transport could observe it.
    /// `nil` for a blob built from a file or synthesised in a test.
    ///
    /// Doc §11 item 1 makes this the single most important unknown: whether the
    /// config is 131 bytes or 167 decides the write marker and therefore whether
    /// a write is accepted at all.
    public var observedReadLength: Int?

    // MARK: - Init

    public enum ParseError: Error, CustomStringConvertible {
        case wrongLength(Int)
        case wrongReportID(UInt8)
        case unknownProfileCommand(UInt8)

        public var description: String {
            switch self {
            case .wrongLength(let n):
                return "Expected a \(GloriousMouseDevice.configReportLength)-byte report-4 "
                     + "buffer including the leading 0x04 report ID, got \(n)."
            case .wrongReportID(let id):
                return String(format: "Blob byte 0 is 0x%02x, expected 0x04 (the report ID).", id)
            case .unknownProfileCommand(let cmd):
                return String(format: "Blob byte 1 is 0x%02x, expected 0x11, 0x21 or 0x31.", cmd)
            }
        }
    }

    /// Wraps a full 520-byte report. Validates only the length and the report
    /// ID; every other field is presented as-is, because a bring-up dump of an
    /// unexpected device is exactly when you want to see the bytes.
    public init(report: [UInt8], observedReadLength: Int? = nil) throws {
        guard report.count == GloriousMouseDevice.configReportLength else {
            throw ParseError.wrongLength(report.count)
        }
        guard report[Offset.reportID] == GloriousMouseDevice.configReportID else {
            throw ParseError.wrongReportID(report[Offset.reportID])
        }
        self.bytes = report
        self.observedReadLength = observedReadLength
    }

    /// A zeroed blob with a valid report ID and profile command. For tests and
    /// for synthesising a request; never send one of these to hardware.
    public static func empty(profile: MouseProfile = .one) -> MouseConfigBlob {
        var report = [UInt8](repeating: 0, count: GloriousMouseDevice.configReportLength)
        report[Offset.reportID] = GloriousMouseDevice.configReportID
        report[Offset.command] = profile.rawValue
        // Length and ID are correct by construction.
        return try! MouseConfigBlob(report: report)
    }

    // MARK: - Header

    /// Byte `0x01` — which profile this blob belongs to. `nil` if the device
    /// answered with something that is not a profile command.
    public var profile: MouseProfile? {
        get { MouseProfile(rawValue: bytes[Offset.command]) }
        set { if let newValue { bytes[Offset.command] = newValue.rawValue } }
    }

    /// Byte `0x03` — `0x00` means "this is a read"; `configSize − 8` means
    /// "apply this". See ``preparedForWrite(profile:configSize:)``.
    public var writeMarker: UInt8 {
        get { bytes[Offset.configWrite] }
        set { bytes[Offset.configWrite] = newValue }
    }

    /// Whether this blob is marked as a write. A blob straight off the device
    /// is not, which is why a "verbatim restore" of a dump would be a no-op.
    public var isMarkedForWrite: Bool { writeMarker != 0x00 }

    /// Returns a copy marked for writing: report ID, profile command and the
    /// `configSize − 8` marker set (doc §4).
    ///
    /// `unknown2[2]` (offset `0x06`) is **preserved**, not zeroed. OpenRGB
    /// clears it with no explanation; preserving the read-back value is the
    /// conservative choice and doc §11 item 6 says so.
    public func preparedForWrite(profile: MouseProfile, configSize: Int) -> MouseConfigBlob {
        var copy = self
        copy.bytes[Offset.reportID] = GloriousMouseDevice.configReportID
        copy.bytes[Offset.command] = profile.rawValue
        copy.bytes[Offset.configWrite] = UInt8(clamping: configSize - 8)
        return copy
    }

    /// Where the trailing zeros begin, clamped into the documented
    /// `[123, 167]` window — the only way to guess the config size on a
    /// transport that cannot report the transfer length (doc §11 item 2).
    ///
    /// This is a *guess, and a lower bound*: every trailing zero byte of the
    /// real config subtracts from it. A 131-byte config whose `unknown4` byte
    /// (`0x82`) happens to be zero infers 130, and a blob whose tail past the
    /// effect bytes is zero infers the clamp floor of 123 — where both
    /// libratbag's `size − 8` and OpenRGB's hardcoded literal would give
    /// `0x7B`. Since byte `0x03` decides whether a write is accepted at all
    /// (doc §4, §11 item 1), never write a marker derived from this without
    /// saying out loud that that is what you are doing. Prefer
    /// ``observedReadLength`` when the transport supplied one.
    public var inferredConfigSize: Int {
        let lastNonZero = bytes.lastIndex(where: { $0 != 0 }).map { $0 + 1 } ?? 0
        return min(max(lastNonZero, GloriousMouseDevice.configSizeMin),
                   GloriousMouseDevice.configSizeMax)
    }

    /// The config size to use for a write: the observed length if the transport
    /// could see one, otherwise the inference above.
    ///
    /// "Observed" means *inside the documented `[123, 167]` window* — the same
    /// rule the transport applies (doc §3). A length outside it is not a short
    /// config, it is evidence that something other than a config read answered
    /// (520 is IOKit echoing the buffer size), so it is discarded rather than
    /// clamped into range.
    public var effectiveConfigSize: Int { observedConfigSize ?? inferredConfigSize }

    /// ``observedReadLength`` if it lands inside the documented window, else
    /// `nil`. Also what tells a caller whether ``effectiveConfigSize`` is a
    /// measurement or a guess.
    public var observedConfigSize: Int? {
        guard let observed = observedReadLength,
              (GloriousMouseDevice.configSizeMin...GloriousMouseDevice.configSizeMax)
                .contains(observed) else { return nil }
        return observed
    }

    // MARK: - Sensor, polling, flags

    /// Byte `0x09`. Read-only on purpose (doc §5).
    public var sensor: MouseSensor? { MouseSensor(rawValue: bytes[Offset.sensor]) }
    public var sensorRawValue: UInt8 { bytes[Offset.sensor] }

    /// Low nibble of `0x0A`.
    public var pollingRate: MousePollingRate? {
        get { MousePollingRate(rawValue: bytes[Offset.pollingAndFlags] & 0x0F) }
        set {
            guard let newValue else { return }
            let flags = bytes[Offset.pollingAndFlags] & 0xF0
            bytes[Offset.pollingAndFlags] = flags | newValue.rawValue
        }
    }

    /// High nibble of `0x0A`. Only bit 3 has a known meaning; the rest are
    /// preserved because nobody knows what they do.
    public var configFlags: UInt8 { (bytes[Offset.pollingAndFlags] >> 4) & 0x0F }

    /// Whether the 16 DPI-stage bytes are 8 `{x, y}` pairs rather than 8 values.
    public var hasIndependentXYDPI: Bool {
        configFlags & Self.xyIndependentFlag != 0
    }

    // MARK: - DPI

    /// Low nibble of `0x0B`: how many of the 8 slots the device presents.
    public var dpiSlotCount: Int { Int(bytes[Offset.dpiCountAndActive] & 0x0F) }

    /// High nibble of `0x0B`. **One-based, and it counts only enabled slots**
    /// (doc §6): disable slot 2 of 6 and the fifth enabled slot is 5, not 6.
    public var activeDPIOrdinal: Int { Int((bytes[Offset.dpiCountAndActive] >> 4) & 0x0F) }

    /// Byte `0x0C`, **bit set = slot disabled**.
    public var disabledDPIMask: UInt8 {
        get { bytes[Offset.disabledDPIMask] }
        set { bytes[Offset.disabledDPIMask] = newValue }
    }

    public func isDPISlotEnabled(_ slot: Int) -> Bool {
        guard (0..<GloriousMouseDevice.dpiSlotCount).contains(slot) else { return false }
        return disabledDPIMask & (1 << UInt8(slot)) == 0
    }

    /// All 8 slots decoded to DPI using the sensor's scaling. Slots beyond
    /// ``dpiSlotCount`` are still returned — a bring-up dump should show them.
    public var dpiStages: [MouseDPIStage] {
        // A dump of an unknown unit should still show numbers; the PMW3360
        // scaling is the one this device is documented to use (doc §6). The
        // write side refuses instead — see `setDPIStage`.
        let sensor = self.sensor ?? .pmw3360
        let independent = hasIndependentXYDPI
        return (0..<GloriousMouseDevice.dpiSlotCount).map { slot in
            let base = Offset.dpiStages + (independent ? slot * 2 : slot)
            let x = sensor.dpi(raw: bytes[base])
            let y = independent ? sensor.dpi(raw: bytes[base + 1]) : x
            return MouseDPIStage(x: x, y: y, isEnabled: isDPISlotEnabled(slot))
        }
    }

    /// Writes one slot's DPI, respecting the XY-independent flag and the
    /// sensor's scaling, and updates the disabled mask.
    ///
    /// The blob's *layout* changes with the flag, so this refuses an asymmetric
    /// stage when the flag is clear rather than silently dropping `y`.
    public mutating func setDPIStage(_ stage: MouseDPIStage, at slot: Int) throws {
        guard (0..<GloriousMouseDevice.dpiSlotCount).contains(slot) else {
            throw MouseFieldError.dpiSlotOutOfRange(slot)
        }
        // No `?? .pmw3360` here, unlike the read side: guessing the sensor when
        // decoding mis-displays a value, guessing it when encoding writes the
        // wrong raw byte into flash. The two scalings differ by one step
        // (doc §6), so a wrong guess is a silently wrong DPI.
        guard let sensor = self.sensor else {
            throw MouseFieldError.unknownSensor(sensorRawValue)
        }
        let independent = hasIndependentXYDPI
        if !independent && !stage.isSymmetric {
            throw MouseFieldError.asymmetricDPIWithoutFlag
        }
        let base = Offset.dpiStages + (independent ? slot * 2 : slot)
        bytes[base] = sensor.raw(dpi: stage.x)
        if independent { bytes[base + 1] = sensor.raw(dpi: stage.y) }

        let bit: UInt8 = 1 << UInt8(slot)
        if stage.isEnabled {
            bytes[Offset.disabledDPIMask] &= ~bit
        } else {
            bytes[Offset.disabledDPIMask] |= bit
        }
    }

    /// The 8 per-slot indicator colours at `0x1D`.
    public var dpiStageColors: [MouseRGB] {
        (0..<GloriousMouseDevice.dpiSlotCount).map { slot in
            let base = Offset.dpiStageColors + slot * 3
            // Always in range: the array ends at 0x34 in a 520-byte blob.
            return MouseRGB(rbgBytes: bytes[base..<(base + 3)]) ?? .black
        }
    }

    // MARK: - RGB

    /// Byte `0x35`. `nil` when the device reports `0xFF` (no LEDs) or an ID no
    /// source documents.
    public var effect: MouseRGBEffect? {
        get { MouseRGBEffect(rawValue: bytes[Offset.effect]) }
        set { if let newValue { bytes[Offset.effect] = newValue.rawValue } }
    }

    public var effectRawValue: UInt8 { bytes[Offset.effect] }

    /// The packed speed/brightness byte belonging to `effect`. `nil` for
    /// ``MouseRGBEffect/off``, which has no parameters.
    public func modeParameter(for effect: MouseRGBEffect) -> MouseModeParameter? {
        guard effect.hasModeByte else { return nil }
        return MouseModeParameter(packed: bytes[effect.modeByteOffset])
    }

    public mutating func setModeParameter(_ parameter: MouseModeParameter,
                                          for effect: MouseRGBEffect) throws {
        guard effect.hasModeByte else { throw MouseFieldError.effectHasNoParameters(effect) }
        bytes[effect.modeByteOffset] = parameter.packed
    }

    /// The colour array belonging to `effect`, decoded from R,B,G order.
    /// `nil` for effects that carry no colours.
    public func colors(for effect: MouseRGBEffect) -> [MouseRGB]? {
        guard let array = effect.colorArray else { return nil }
        return (0..<array.count).map { i in
            let base = array.offset + i * 3
            // Always in range: the last colour array ends at 0x80 (doc §5).
            return MouseRGB(rbgBytes: bytes[base..<(base + 3)]) ?? .black
        }
    }

    /// Writes `colors` into `effect`'s array. Fewer colours than the array
    /// holds leaves the remainder untouched — the array length is fixed in the
    /// blob and only ``breathing7ColorCount`` says how much of it is live.
    public mutating func setColors(_ colors: [MouseRGB], for effect: MouseRGBEffect) throws {
        guard let array = effect.colorArray else {
            throw MouseFieldError.effectHasNoColors(effect)
        }
        guard colors.count <= array.count else {
            throw MouseFieldError.tooManyColors(effect: effect,
                                                given: colors.count,
                                                maximum: array.count)
        }
        for (i, color) in colors.enumerated() {
            let base = array.offset + i * 3
            let rbg = color.rbgBytes
            bytes[base] = rbg[0]
            bytes[base + 1] = rbg[1]
            bytes[base + 2] = rbg[2]
        }
    }

    /// Byte `0x3D` — how many of the seven breathing colours are in use, 1–7.
    /// (OpenRGB's comment calling this a "bank change" is wrong; doc §10.)
    public var breathing7ColorCount: UInt8 {
        get { bytes[Offset.breathing7ColorCount] }
        set { bytes[Offset.breathing7ColorCount] = min(max(newValue, 1), 7) }
    }

    /// Byte `0x37`, rainbow direction.
    public var rainbowDirection: MouseRainbowDirection? {
        get { MouseRainbowDirection(rawValue: bytes[Offset.rainbowDirection]) }
        set { if let newValue { bytes[Offset.rainbowDirection] = newValue.rawValue } }
    }

    // MARK: - Lift-off distance

    /// Byte `0x81`. Reading is free; writing is not — see ``setLiftOffDistance(_:)``.
    public var liftOffDistance: MouseLiftOffDistance {
        MouseLiftOffDistance(raw: bytes[Offset.liftOffDistance])
    }

    /// Writes the lift-off distance, refusing to destroy the `0xFF` sentinel.
    ///
    /// Two independent hazards live here (doc §7, §10): `0xFF` means the unit
    /// manages LOD through command `0x1b` and libratbag says explicitly not to
    /// overwrite it, and *no published source ever writes this byte at all* —
    /// OpenRGB only does so by accident, through a missing `break`. Treat the
    /// first successful write as an experiment and read it back.
    public mutating func setLiftOffDistance(_ distance: MouseLiftOffDistance) throws {
        if bytes[Offset.liftOffDistance] == 0xFF {
            throw MouseFieldError.liftOffDistanceIsCommandManaged
        }
        switch distance {
        case .mm2, .mm3:
            bytes[Offset.liftOffDistance] = distance.raw
        case .commandManaged, .other:
            throw MouseFieldError.unsupportedLiftOffDistance(distance.raw)
        }
    }

    // MARK: - Summary

    /// A decoded, human-readable dump for the CLI. Read-only; prints what the
    /// device said rather than what it ought to have said.
    public func summaryLines() -> [String] {
        var lines: [String] = []
        func hex(_ v: UInt8) -> String { String(format: "0x%02x", v) }

        lines.append("profile:        " + (profile.map { "\($0.displayName) (\(hex($0.rawValue)))" }
                                           ?? "unknown (\(hex(bytes[Offset.command])))"))
        lines.append("write marker:   \(hex(writeMarker))"
                     + (isMarkedForWrite ? "" : "  (0x00 = this is a read)"))
        if let observed = observedReadLength {
            lines.append("bytes returned: \(observed)")
        }
        lines.append("config size:    \(effectiveConfigSize)"
                     + (observedConfigSize == nil
                        ? "  (inferred from trailing zeros — a lower bound, see §11 item 1)"
                        : ""))
        lines.append("sensor:         " + (sensor.map { "\($0.displayName) (\(hex($0.rawValue)))" }
                                           ?? "unknown (\(hex(sensorRawValue)))"))
        lines.append("polling rate:   " + (pollingRate.map { "\($0.hertz) Hz" }
                                           ?? "invalid (\(hex(bytes[Offset.pollingAndFlags] & 0x0F)))"))
        lines.append("config flags:   \(hex(configFlags))"
                     + (hasIndependentXYDPI ? "  (XY-independent DPI)" : ""))

        lines.append("DPI slots:      \(dpiSlotCount) present, active ordinal "
                     + "\(activeDPIOrdinal) (1-based, enabled slots only)")
        for (i, stage) in dpiStages.enumerated() {
            let mark = stage.isEnabled ? " " : "x"
            let color = dpiStageColors[i].hexString
            lines.append("  [\(mark)] slot \(i + 1): \(stage.displayValue) dpi   #\(color)")
        }

        let effectLabel = effect.map { "\($0.displayName) (\(hex($0.rawValue)))" }
            ?? (effectRawValue == MouseRGBEffect.notSupportedRawValue
                ? "RGB_NOT_SUPPORTED (0xff) — this unit reports no LEDs"
                : "unknown (\(hex(effectRawValue)))")
        lines.append("RGB effect:     " + effectLabel)
        if let effect, let parameter = modeParameter(for: effect) {
            lines.append("  speed:        \(parameter.speed) (\(parameter.speedName))")
            lines.append("  brightness:   \(parameter.brightness)/\(MouseModeParameter.maxBrightness)")
        }
        if let effect, let colors = colors(for: effect) {
            let shown = effect == .breathing7
                ? Array(colors.prefix(Int(min(max(breathing7ColorCount, 1), 7))))
                : colors
            lines.append("  colours:      " + shown.map { "#" + $0.hexString }.joined(separator: " "))
        }
        if effect == .rainbow, let direction = rainbowDirection {
            lines.append("  direction:    \(direction.displayName)")
        }
        if effect == .breathing7 {
            lines.append("  colour count: \(breathing7ColorCount)")
        }

        lines.append("lift-off dist:  \(liftOffDistance.displayName)")
        return lines
    }

    /// `offset: xx xx xx …` lines, 16 bytes each, for a raw dump.
    public func hexDumpLines(upTo limit: Int? = nil) -> [String] {
        let end = min(limit ?? bytes.count, bytes.count)
        return stride(from: 0, to: end, by: 16).map { row in
            let slice = bytes[row..<min(row + 16, end)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            return String(format: "%04x  ", row) + hex
        }
    }
}

// MARK: - Errors

/// Refusals from ``MouseConfigBlob``'s typed setters.
public enum MouseFieldError: Error, CustomStringConvertible {
    case dpiSlotOutOfRange(Int)
    case asymmetricDPIWithoutFlag
    case unknownSensor(UInt8)
    case effectHasNoParameters(MouseRGBEffect)
    case effectHasNoColors(MouseRGBEffect)
    case tooManyColors(effect: MouseRGBEffect, given: Int, maximum: Int)
    case liftOffDistanceIsCommandManaged
    case unsupportedLiftOffDistance(UInt8)

    public var description: String {
        switch self {
        case .dpiSlotOutOfRange(let slot):
            return "DPI slot \(slot) is out of range 0…\(GloriousMouseDevice.dpiSlotCount - 1)."
        case .asymmetricDPIWithoutFlag:
            return """
                Separate X and Y DPI needs the XY-independent flag (bit 3 of the high nibble \
                of blob 0x0A) set, which changes the layout of the whole 16-byte stage array. \
                Set the flag deliberately or give a symmetric stage.
                """
        case .unknownSensor(let raw):
            return String(format: """
                Blob byte 0x09 is 0x%02x, which is not a sensor any source documents. The DPI \
                encoding depends on the sensor (docs/mouse-protocol.md §6), so writing a DPI \
                stage here would guess the scaling and store the wrong raw byte. Reading is \
                still fine.
                """, raw)
        case .effectHasNoParameters(let effect):
            return "Effect \(effect.displayName) has no speed/brightness byte."
        case .effectHasNoColors(let effect):
            return "Effect \(effect.displayName) has no colour array in the blob."
        case .tooManyColors(let effect, let given, let maximum):
            return "Effect \(effect.displayName) holds \(maximum) colours, got \(given)."
        case .liftOffDistanceIsCommandManaged:
            return """
                Blob byte 0x81 is 0xFF, meaning this unit sets lift-off distance through \
                command 0x1b instead. libratbag documents that this sentinel must not be \
                overwritten (docs/mouse-protocol.md §7), and command 0x1b does not work on \
                the Model O either. Leave it alone.
                """
        case .unsupportedLiftOffDistance(let raw):
            return String(format: "Lift-off distance 0x%02x is not one of the two documented "
                          + "values (0x01 = 2 mm, 0x02 = 3 mm).", raw)
        }
    }
}
