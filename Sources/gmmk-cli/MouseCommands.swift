import Foundation
import GloriousMouseProtocol
import GloriousMouseHID

// The `mouse` command group for the wired Glorious Model O / O- (258A:0036).
//
// Every setting except debounce lives in one 520-byte configuration blob, so
// every setter is a read-modify-write of the whole thing followed by a read-back
// check (docs/mouse-protocol.md §4). Debounce is the exception: it is command
// 0x1a on the command channel and is not in the blob at all — which also means
// `mouse dump` does not back it up.

let mouseUsage = """
    gmmk-cli mouse — configure the wired Glorious Model O / O- (258A:0036)

    USAGE:
      gmmk-cli mouse <subcommand> [arguments]

    READING:
      list                     Report whether the mouse's vendor collection was found
      info [profile]           Read a profile and print the decoded configuration
      effects                  List every RGB effect with its ID
      dump <file> [profile]    Read a profile, write the raw 520-byte report to <file>,
                               and print the decode. TAKE THIS BEFORE ANYTHING WRITES —
                               it is the only way back to the mouse's current settings.
                               Refuses to overwrite an existing file.

    WRITING:
      color <RRGGBB>           Solid colour (effect 0x02) at full brightness
      effect <name|id> [--speed 1-3] [--brightness 1-4]
                               Set the RGB effect. The two flags write the effect's own
                               packed speed/brightness byte; each is optional and leaves
                               the other nibble as it was. `off` takes neither.
      polling <125|250|500|1000>
                               USB polling rate
      dpi <slot> <value>       Set a DPI stage. Slots are 1-8; the value must be a
                               multiple of 100 inside the sensor's range.
      dpi-enable <slot> <on|off>
                               Enable or disable a DPI stage
      dpi-active <ordinal>     Select the active stage. 1-BASED OVER ENABLED SLOTS
                               ONLY — with slot 2 of 6 disabled, the last stage is 5,
                               not 6 (docs/mouse-protocol.md §6).
      debounce <ms>            Debounce time: 4, 6, 8, 10, 12, 14 or 16. This is
                               command 0x1a, NOT a blob field, so `dump` does not save
                               it and it may be unsupported on this unit.
      lod <2|3> --experimental
                               Lift-off distance in mm. Gated: no published tool writes
                               this byte, and it is refused outright when the mouse has
                               0xFF there. See the warning it prints.
      restore <file> --config-size N --yes
                               Write a previously dumped blob back verbatim. --config-size
                               is required: it sets byte 0x03 (= N - 8), the byte that
                               decides whether the write is accepted at all.

      profile is 1, 2 or 3 (default 1). Setters write profile 1.

    HOW WRITES WORK:
      Read the blob, change the field, stamp byte 0x03 with <config size> - 8, send
      all 520 bytes back, read it again and check. There is no separate save command:
      the blob write is the commit and it survives a replug. A setter refuses if the
      config size could not be observed from the read, because guessing that byte
      wrong means the device silently ignores the write.

    SAFETY:
      The ISP bootloader shares feature report 5 with the configuration protocol.
      05 75 00 00 00 00 enters DFU. Every command this CLI sends goes through an
      allow-list of the six documented safe verbs; report 6 is refused outright.
      Never sweep report 5. See docs/mouse-protocol.md §9.
    """

/// Opens the mouse, runs `body`, closes, exits. Mirrors `withKeyboard`.
func withMouse(_ body: (GloriousMouse) throws -> Void) -> Never {
    let mouse = GloriousMouse()
    do {
        try mouse.open()
    } catch let error as GloriousMouseHIDError {
        switch error {
        case .deviceNotFound: fail(error.description, .deviceNotFound)
        default: fail(error.description, .transport)
        }
    } catch {
        fail("\(error)", .transport)
    }
    // Every exit path here is `exit()`, which does not unwind defers.
    do {
        try body(mouse)
    } catch let error as GloriousMouseHIDError {
        mouse.close()
        fail(error.description, .transport)
    } catch {
        mouse.close()
        fail("\(error)", .transport)
    }
    mouse.close()
    exit(ExitCode.ok.rawValue)
}

/// Prints the device-level facts that are not in the blob: firmware string and
/// active profile. Both are cheap reads and both validate the command channel
/// (doc §12 steps 2–3). Failures are reported, not fatal — a unit that will not
/// answer these can still have its blob dumped.
func printMouseDeviceFacts(_ mouse: GloriousMouse) {
    if let version = try? mouse.firmwareVersion() {
        print("firmware:       \(version)")
    } else {
        print("firmware:       (no valid reply to command 0x01)")
    }
    if let active = try? mouse.activeProfile() {
        print("active profile: \(active.index + 1) of \(GloriousMouseDevice.profileCount)")
    } else {
        print("active profile: (no valid reply to command 0x02)")
    }
    // Command 0x1a is documented as possibly unsupported on short-config
    // devices; a nil here is an answer, not a failure (doc §11 item 4).
    // `try?` flattens the optional, so this one binding covers both "the
    // transfer failed" and "the command is not supported here".
    if let debounce = try? mouse.debounceMilliseconds() {
        print("debounce:       \(debounce) ms")
    } else {
        print("debounce:       unsupported or not answered (command 0x1a)")
    }
}

/// The read-modify-write every mouse setter is: read the blob, apply `mutate`,
/// stamp the write marker from the *observed* config size, send it, read it back
/// and say whether the change is actually there.
///
/// The observed size is required rather than inferred. Byte `0x03` decides
/// whether the device accepts the write at all (doc §4), and the trailing-zero
/// inference is a lower bound that can be a byte or two short — which would make
/// the write a silent no-op rather than an error.
func mutateMouseConfig(profile: MouseProfile = .one,
                       mutate: (inout MouseConfigBlob) throws -> Void,
                       report: (MouseConfigBlob) -> String) -> Never {
    withMouse { mouse in
        var blob = try mouse.readConfig(profile: profile)
        guard let size = blob.observedConfigSize else {
            mouse.close()
            fail("""
                could not observe the config size from the read, so the write marker at \
                byte 0x03 would be a guess — and a wrong one makes the device ignore the \
                write silently. Run `gmmk-cli mouse info` to see what IOKit reports.
                """, .transport)
        }
        try mutate(&blob)
        try mouse.writeConfig(blob.preparedForWrite(profile: profile, configSize: size))
        let after = try mouse.readConfig(profile: profile)
        print(report(after))
    }
}

/// `--speed` / `--brightness`, both optional, for `mouse effect`.
struct MouseModeFlags {
    var speed: UInt8?
    var brightness: UInt8?

    var isEmpty: Bool { speed == nil && brightness == nil }

    /// Applies whichever flags were given on top of the effect's current byte,
    /// so setting one nibble never clears the other.
    func applied(to current: MouseModeParameter) -> MouseModeParameter {
        MouseModeParameter(speed: speed ?? current.speed,
                           brightness: brightness ?? current.brightness)
    }

    /// Parses the flags out of a trailing argument list, failing on anything else.
    static func parse(_ arguments: [String]) -> MouseModeFlags {
        var flags = MouseModeFlags()
        var rest = arguments
        while let option = rest.first {
            rest.removeFirst()
            func value(_ name: String, _ limit: UInt8) -> UInt8 {
                guard let raw = rest.first, let n = UInt8(raw), (1...limit).contains(n) else {
                    fail("\(name) takes a value 1-\(limit)", .usage)
                }
                rest.removeFirst()
                return n
            }
            switch option {
            case "--speed":
                flags.speed = value("--speed", MouseModeParameter.maxSpeed)
            case "--brightness":
                flags.brightness = value("--brightness", MouseModeParameter.maxBrightness)
            default:
                fail("unknown option '\(option)' for `mouse effect`", .usage)
            }
        }
        return flags
    }
}

/// Parses the on/off words the CLI accepts elsewhere. `nil` for anything else.
func parseOnOff(_ input: String) -> Bool? {
    switch input.lowercased() {
    case "on", "true", "1", "yes", "enable", "enabled":   return true
    case "off", "false", "0", "no", "disable", "disabled": return false
    default: return nil
    }
}

/// Parses a 1-based DPI slot argument into the 0-based index the blob uses.
func parseMouseDPISlot(_ argument: String) -> Int {
    guard let slot = Int(argument), (1...GloriousMouseDevice.dpiSlotCount).contains(slot) else {
        fail("DPI slot must be 1-\(GloriousMouseDevice.dpiSlotCount), got '\(argument)'", .usage)
    }
    return slot - 1
}

func parseMouseProfile(_ argument: String?) -> MouseProfile {
    guard let argument else { return .one }
    guard let profile = MouseProfile.parse(argument) else {
        fail("profile must be 1, 2 or 3, got '\(argument)'", .usage)
    }
    return profile
}

/// Runs `gmmk-cli mouse …`. Never returns.
func runMouseCommand(_ arguments: [String]) -> Never {
    guard let subcommand = arguments.first else {
        print(mouseUsage)
        exit(ExitCode.usage.rawValue)
    }
    let rest = Array(arguments.dropFirst())

    switch subcommand {

    case "help", "-h", "--help":
        print(mouseUsage)
        exit(ExitCode.ok.rawValue)

    case "list":
        if GloriousMouse.isDevicePresent() {
            print(String(format: "Glorious mouse vendor collection found "
                         + "(%04x:%04x, usage page 0x%04x usage 0x%02x)",
                         GloriousMouse.vendorID, GloriousMouse.productID,
                         GloriousMouse.vendorUsagePage, GloriousMouse.vendorUsage))
            let matches = GloriousMouse.vendorInterfaceCount()
            if matches > 1 {
                print("\(matches) collections match. This CLI does not probe for the one that "
                      + "answers 05 11 00 00 00 00 (docs/mouse-protocol.md §1.1); it opens the "
                      + "first in registry order. If reads fail with a transport error rather "
                      + "than a permissions error, that is the likely reason.")
            }
            exit(ExitCode.ok.rawValue)
        } else {
            printErr(GloriousMouseHIDError.deviceNotFound.description)
            exit(ExitCode.deviceNotFound.rawValue)
        }

    case "info":
        guard rest.count <= 1 else {
            fail("`mouse info` takes at most one argument: the profile (1-3)", .usage)
        }
        let profile = parseMouseProfile(rest.first)
        withMouse { mouse in
            printMouseDeviceFacts(mouse)
            let blob = try mouse.readConfig(profile: profile)
            print("")
            blob.summaryLines().forEach { print($0) }
            printTransferLengthNote(mouse)
        }

    case "dump":
        guard (1...2).contains(rest.count) else {
            fail("`mouse dump` takes a file path and an optional profile (1-3)", .usage)
        }
        let path = rest[0]
        let profile = parseMouseProfile(rest.count > 1 ? rest[1] : nil)
        withMouse { mouse in
            printMouseDeviceFacts(mouse)
            let blob = try mouse.readConfig(profile: profile)
            let url = URL(fileURLWithPath: path)
            // `.withoutOverwriting`: this file is the only way back to the
            // mouse's current settings, so a second dump must not silently
            // replace the first one.
            do {
                try Data(blob.bytes).write(to: url, options: .withoutOverwriting)
            } catch {
                mouse.close()
                fail("cannot write '\(url.path)': \(error.localizedDescription). "
                     + "`mouse dump` never overwrites an existing file — a dump is the only "
                     + "way back to the mouse's current settings. Choose another path.",
                     .usage)
            }
            print("")
            print("wrote \(blob.bytes.count) raw bytes to \(url.path)")
            print("")
            blob.summaryLines().forEach { print($0) }
            printTransferLengthNote(mouse)
            print("")
            print("raw report (first \(GloriousMouseDevice.configSizeMax) bytes):")
            blob.hexDumpLines(upTo: GloriousMouseDevice.configSizeMax).forEach { print("  " + $0) }
        }

    case "effects":
        for effect in MouseRGBEffect.allCases {
            let slug = effect.slug.padding(toLength: 22, withPad: " ", startingAt: 0)
            let params = effect.hasModeByte ? "speed, brightness" : "no parameters"
            let colors = effect.colorArray.map { " · \($0.count) colour\($0.count == 1 ? "" : "s")" } ?? ""
            print(String(format: "  0x%02X  %2d  ", Int(effect.rawValue), Int(effect.rawValue))
                  + slug + params + colors)
        }
        exit(ExitCode.ok.rawValue)

    case "color", "colour":
        // Set solid colour: effect 0x02 plus its one-colour array, at full
        // brightness so the change is unmistakable.
        guard rest.count == 1, let rgb = MouseRGB(hex: rest[0]) else {
            fail("`mouse color` needs a hex colour, RRGGBB", .usage)
        }
        mutateMouseConfig { blob in
            blob.effect = .single
            try blob.setColors([rgb], for: .single)
            if let current = blob.modeParameter(for: .single) {
                try blob.setModeParameter(
                    MouseModeParameter(speed: current.speed, brightness: 4), for: .single)
            }
        } report: { after in
            let ok = after.effect == .single && after.colors(for: .single)?.first == rgb
            return "color -> #\(rgb.hexString) (solid), write "
                + (ok ? "verified by read-back" : "NOT confirmed by read-back — check the mouse")
        }

    case "effect":
        guard let name = rest.first else {
            fail("`mouse effect` needs an effect name or ID (see `gmmk-cli mouse effects`)", .usage)
        }
        guard let effect = MouseRGBEffect.parse(name) else {
            fail("unknown effect '\(name)'. Run `gmmk-cli mouse effects` for the list.", .usage)
        }
        let flags = MouseModeFlags.parse(Array(rest.dropFirst()))
        if !flags.isEmpty && !effect.hasModeByte {
            fail("\(effect.displayName) has no speed or brightness byte — it is the one effect "
                 + "with no parameters at all.", .usage)
        }
        mutateMouseConfig { blob in
            blob.effect = effect
            if !flags.isEmpty, let current = blob.modeParameter(for: effect) {
                try blob.setModeParameter(flags.applied(to: current), for: effect)
            }
        } report: { after in
            var line = "effect -> \(effect.displayName) "
                + String(format: "(0x%02x)", effect.rawValue)
            if let parameter = after.modeParameter(for: effect) {
                line += ", speed \(parameter.speed) (\(parameter.speedName)), "
                    + "brightness \(parameter.brightness)/\(MouseModeParameter.maxBrightness)"
            }
            return line + ", write "
                + (after.effect == effect ? "verified by read-back"
                                          : "NOT confirmed by read-back — check the mouse")
        }

    case "polling":
        guard rest.count == 1, let hertz = Int(rest[0]),
              let rate = MousePollingRate(hertz: hertz) else {
            fail("`mouse polling` takes one of "
                 + MousePollingRate.allCases.map { "\($0.hertz)" }.joined(separator: ", "), .usage)
        }
        mutateMouseConfig { blob in
            blob.pollingRate = rate
        } report: { after in
            "polling -> \(rate.hertz) Hz, write "
                + (after.pollingRate == rate ? "verified by read-back"
                                             : "NOT confirmed by read-back — check the mouse")
        }

    case "dpi":
        guard rest.count == 2 else {
            fail("`mouse dpi` takes a slot (1-\(GloriousMouseDevice.dpiSlotCount)) and a DPI value",
                 .usage)
        }
        let slot = parseMouseDPISlot(rest[0])
        guard let dpi = Int(rest[1]) else {
            fail("DPI must be a whole number, got '\(rest[1])'", .usage)
        }
        mutateMouseConfig { blob in
            // Keep the slot's enabled state: `mouse dpi` changes a value, and
            // `dpi-enable` is the command that changes membership.
            let existing = blob.dpiStages[slot]
            try blob.setDPIStage(MouseDPIStage(dpi: dpi, isEnabled: existing.isEnabled), at: slot)
        } report: { after in
            let stage = after.dpiStages[slot]
            return "dpi slot \(slot + 1) -> \(dpi), write "
                + (stage.x == dpi && stage.y == dpi ? "verified by read-back"
                                                    : "NOT confirmed by read-back (reads back as "
                                                      + "\(stage.displayValue)) — check the mouse")
        }

    case "dpi-enable":
        guard rest.count == 2, let on = parseOnOff(rest[1]) else {
            fail("`mouse dpi-enable` takes a slot (1-\(GloriousMouseDevice.dpiSlotCount)) and on|off",
                 .usage)
        }
        let slot = parseMouseDPISlot(rest[0])
        mutateMouseConfig { blob in
            try blob.setDPISlotEnabled(on, at: slot)
        } report: { after in
            "dpi slot \(slot + 1) -> \(on ? "enabled" : "disabled") "
                + "(\(after.enabledDPISlotCount) enabled, active ordinal "
                + "\(after.activeDPIOrdinal)), write "
                + (after.isDPISlotEnabled(slot) == on ? "verified by read-back"
                                                      : "NOT confirmed by read-back — check the mouse")
        }

    case "dpi-active":
        guard rest.count == 1, let ordinal = Int(rest[0]) else {
            fail("`mouse dpi-active` takes a 1-based ordinal over the ENABLED slots "
                 + "(docs/mouse-protocol.md §6)", .usage)
        }
        mutateMouseConfig { blob in
            try blob.setActiveDPIOrdinal(ordinal)
        } report: { after in
            let slotNote = after.activeDPISlot.map { " (slot \($0 + 1))" } ?? ""
            return "active dpi -> ordinal \(ordinal)\(slotNote), write "
                + (after.activeDPIOrdinal == ordinal ? "verified by read-back"
                                                     : "NOT confirmed by read-back — check the mouse")
        }

    case "debounce":
        guard rest.count == 1, let ms = Int(rest[0]) else {
            fail("`mouse debounce` takes a time in milliseconds: "
                 + MouseCommandReport.debounceTimesMilliseconds.map(String.init)
                    .joined(separator: ", "), .usage)
        }
        guard MouseCommandReport.debounceTimesMilliseconds.contains(ms) else {
            fail(MouseCommandError.invalidDebounceTime(ms).description, .usage)
        }
        // Not a blob field: command 0x1a writes it directly, so there is no
        // read-modify-write and no write marker here (doc §7).
        withMouse { mouse in
            try mouse.setDebounce(milliseconds: ms)
            let readBack = try mouse.debounceMilliseconds()
            switch readBack {
            case ms:
                print("debounce -> \(ms) ms, verified by read-back")
            case nil:
                print("debounce -> \(ms) ms sent, but command 0x1a does not answer on this unit, "
                      + "so it cannot be confirmed — libratbag warns it may not work on "
                      + "short-config devices at all (docs/mouse-protocol.md §11 item 4).")
            case let other?:
                print("debounce -> \(ms) ms sent, but it reads back as \(other) ms — "
                      + "the mouse did not take it.")
            }
            print("Note: debounce lives on the command channel, not in the config blob, "
                  + "so `mouse dump` does not back it up.")
        }

    case "lod":
        // Writing blob byte 0x81 is unverified by any published source: libratbag
        // reads it and never writes it, and OpenRGB only writes it through a
        // missing `break` (doc §7, §10, §11 item 3). Hence the gate.
        guard let value = rest.first else {
            fail("`mouse lod` takes 2 or 3 (millimetres) and --experimental", .usage)
        }
        let distance: MouseLiftOffDistance
        switch value {
        case "2": distance = .mm2
        case "3": distance = .mm3
        default: fail("lift-off distance must be 2 or 3 millimetres, got '\(value)'", .usage)
        }
        guard Array(rest.dropFirst()) == ["--experimental"] else {
            fail("""
                `mouse lod` needs --experimental.

                No published tool writes this byte. libratbag reads blob 0x81 and never \
                writes it; OpenRGB writes it only by accident, through a missing `break` \
                that also destroys the 0xFF sentinel (docs/mouse-protocol.md §7, §10, §11 \
                item 3). So this command is an experiment, not a supported setting: take a \
                `mouse dump` first, run it, and read the value back.

                If your mouse has 0xFF at 0x81 this command will refuse outright — that \
                value means the unit manages lift-off through command 0x1b, which does not \
                work on the Model O either, and libratbag says explicitly it must not be \
                overwritten.
                """, .usage)
        }
        printErr("gmmk-cli: writing blob byte 0x81 is unverified by any source. "
                 + "Take a `mouse dump` first if you have not.")
        mutateMouseConfig { blob in
            // Throws `liftOffDistanceIsCommandManaged` on the 0xFF sentinel,
            // which is the refusal the doc demands rather than a warning.
            try blob.setLiftOffDistance(distance)
        } report: { after in
            "lift-off -> \(distance.displayName), reads back as \(after.liftOffDistance.displayName)"
        }

    case "leds":
        // Experimental: effect 0x06 ("constant") addresses all six LEDs
        // individually via colours at 0x56-0x67 — present in the firmware but
        // absent from Glorious's own software and unimplemented by OpenRGB and
        // libratbag alike (docs/mouse-protocol.md §11 item 5). Takes 1-6
        // colours; missing ones repeat the last.
        guard !rest.isEmpty, rest.count <= 6 else {
            fail("`mouse leds` takes 1-6 hex colours (RRGGBB), one per LED", .usage)
        }
        var ledColors: [MouseRGB] = []
        for hexArg in rest {
            guard let rgb = MouseRGB(hex: hexArg) else {
                fail("'\(hexArg)' is not a hex colour (RRGGBB)", .usage)
            }
            ledColors.append(rgb)
        }
        while ledColors.count < 6 { ledColors.append(ledColors.last!) }
        withMouse { mouse in
            var blob = try mouse.readConfig(profile: .one)
            guard let size = blob.observedConfigSize else {
                fail("could not observe the config size from the read; refusing to write", .transport)
            }
            blob.effect = .constant
            try blob.setColors(ledColors, for: .constant)
            if let param = blob.modeParameter(for: .constant) {
                try blob.setModeParameter(MouseModeParameter(speed: param.speed, brightness: 4),
                                          for: .constant)
            }
            let prepared = blob.preparedForWrite(profile: .one, configSize: size)
            try mouse.writeConfig(prepared)
            let after = try mouse.readConfig(profile: .one)
            let ok = after.effect == .constant && after.colors(for: .constant) == ledColors
            print("per-LED constant mode: "
                  + ledColors.map { "#\($0.hexString)" }.joined(separator: " ")
                  + "\nwrite " + (ok ? "verified by read-back" : "NOT confirmed by read-back"))
        }

    case "restore":
        guard let path = rest.first else {
            fail("`mouse restore` needs the path of a file written by `mouse dump`", .usage)
        }
        var options = Array(rest.dropFirst())
        var confirmed = false
        var configSizeOverride: Int?
        while let option = options.first {
            options.removeFirst()
            switch option {
            case "--yes", "-y":
                confirmed = true
            case "--config-size":
                guard let value = options.first, let size = Int(value) else {
                    fail("--config-size needs a byte count", .usage)
                }
                options.removeFirst()
                guard (GloriousMouseDevice.configSizeMin...GloriousMouseDevice.configSizeMax)
                        .contains(size) else {
                    fail("--config-size must be between \(GloriousMouseDevice.configSizeMin) and "
                         + "\(GloriousMouseDevice.configSizeMax), got \(size)", .usage)
                }
                configSizeOverride = size
            default:
                fail("unknown option '\(option)' for `mouse restore`", .usage)
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            fail("cannot read '\(path)': \(error.localizedDescription)", .usage)
        }
        guard data.count == GloriousMouseDevice.configReportLength else {
            fail("'\(path)' is \(data.count) bytes; a dumped blob is exactly "
                 + "\(GloriousMouseDevice.configReportLength)", .usage)
        }
        let saved: MouseConfigBlob
        do {
            saved = try MouseConfigBlob(report: [UInt8](data))
        } catch let error as MouseConfigBlob.ParseError {
            fail(error.description, .usage)
        } catch {
            fail("\(error)", .usage)
        }
        guard let profile = saved.profile else {
            fail(String(format: "'%@' has 0x%02x at byte 1, which is not a profile command "
                        + "(0x11/0x21/0x31). Refusing to write it.", path,
                        saved.bytes[MouseConfigBlob.Offset.command]), .usage)
        }

        // The dump carries the read marker (0x00 at byte 0x03), so a literally
        // verbatim write would be a no-op. The bytes are restored verbatim; only
        // the write marker is stamped — and byte 0x03 is what decides whether
        // the device accepts the write at all (doc §4, §11 item 1).
        //
        // There is deliberately no default. The trailing-zero inference is a
        // lower bound: any zero at the tail of the real config subtracts from
        // it, so a 131-byte config with a zero `unknown4` infers 130 and marks
        // 0x7A where both sources would say 0x7B. A guess that quiet has no
        // business being the default path of the one subcommand that writes.
        guard let configSize = configSizeOverride else {
            fail("""
                `mouse restore` needs --config-size N. Byte 0x03 of the write is \
                <config size> - 8, and that byte is what decides whether the device accepts \
                the write at all (docs/mouse-protocol.md §4).

                Run `gmmk-cli mouse info` first: if IOKit reports a transfer length inside \
                \(GloriousMouseDevice.configSizeMin)…\(GloriousMouseDevice.configSizeMax), \
                that is the answer. If it does not, the candidates are 131 (OpenRGB hardcodes \
                the resulting marker 0x7b for this device) and 167 \
                (SINOWEALTH_CONFIG_SIZE_MAX) — §11 item 1. This file's trailing zeros begin \
                at \(saved.inferredConfigSize), which is a lower bound, not a measurement.
                """, .usage)
        }
        let blob = saved.preparedForWrite(profile: profile, configSize: configSize)

        print("restore \(path)")
        print("  profile:      \(profile.displayName) (byte 1 = "
              + String(format: "0x%02x", profile.rawValue) + ")")
        print("  config size:  \(configSize)  (--config-size; trailing zeros in this file "
              + "begin at \(saved.inferredConfigSize))")
        print("  write marker: " + String(format: "0x%02x", blob.writeMarker)
              + " at byte 0x03")
        print("  payload:      \(blob.bytes.count) bytes, otherwise byte-for-byte as saved")
        guard confirmed else {
            printErr("")
            printErr("gmmk-cli: this is the only mouse subcommand that writes to the device. "
                     + "Re-run with --yes to send it.")
            exit(ExitCode.usage.rawValue)
        }
        withMouse { mouse in
            try mouse.writeConfig(blob)
            print("")
            print("sent. The blob write is itself the commit — there is no save command, and "
                  + "the settings survive a replug.")
            let readBack = try mouse.readConfig(profile: profile)
            // Byte 0x03 differs by design: it is the write marker going out and
            // the read marker coming back.
            let sameExceptMarker = zip(readBack.bytes, blob.bytes).enumerated().allSatisfy {
                $0.offset == MouseConfigBlob.Offset.configWrite || $0.element.0 == $0.element.1
            }
            print(sameExceptMarker
                  ? "read-back matches the blob that was sent."
                  : "read-back DIFFERS from what was sent — inspect with `mouse info`.")
        }

    default:
        printErr("gmmk-cli: unknown mouse subcommand '\(subcommand)'\n")
        printErr(mouseUsage)
        exit(ExitCode.usage.rawValue)
    }
}

/// Surfaces whether the transfer length was observable at all — doc §11 item 2
/// asks exactly this, and bring-up should record the answer. The three outcomes
/// are distinguishable here on purpose: "IOKit echoed the buffer size" is an
/// answer to that question, not an absence of one.
private func printTransferLengthNote(_ mouse: GloriousMouse) {
    guard let raw = mouse.lastConfigTransferLength else {
        print("No config read has happened, so there is no transfer length to report.")
        return
    }
    print("IOKit reported \(raw) bytes transferred for the config read.")
    if mouse.lastConfigObservedLength == nil {
        if raw == GloriousMouseDevice.configReportLength {
            print("  That is exactly the buffer size it was handed, so it is not an "
                  + "observation of the config size (§11 item 2 — answered: no).")
        } else if raw == 0 {
            print("  Zero bytes reported, so the length is not observable this way "
                  + "(§11 item 2 — answered: no).")
        } else {
            print("  That is outside the documented "
                  + "\(GloriousMouseDevice.configSizeMin)…\(GloriousMouseDevice.configSizeMax) "
                  + "window, so it is not being treated as the config size.")
        }
        print("  The config size above is inferred from where the trailing zeros begin, "
              + "which is a lower bound — see §11 item 1.")
    } else {
        print("  That lands inside the documented "
              + "\(GloriousMouseDevice.configSizeMin)…\(GloriousMouseDevice.configSizeMax) "
              + "window and settles §11 items 1 and 2. Use it as --config-size.")
    }
}
