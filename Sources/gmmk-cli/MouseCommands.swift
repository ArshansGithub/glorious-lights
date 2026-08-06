import Foundation
import GloriousMouseProtocol
import GloriousMouseHID

// The `mouse` command group: read-only bring-up for the wired Glorious
// Model O / O- (258A:0036), plus a restore of a previously saved blob.
//
// Deliberately no field-mutating commands. Hardware bring-up validates reads
// first (docs/mouse-protocol.md §12), and the one open question that gates every
// write — whether the config blob is 131 or 167 bytes — can only be answered by
// reading. `mouse dump` exists to be the backup you take before anything writes.

let mouseUsage = """
    gmmk-cli mouse — read the wired Glorious Model O / O- (258A:0036)

    USAGE:
      gmmk-cli mouse <subcommand> [arguments]

    SUBCOMMANDS:
      list                     Report whether the mouse's vendor collection was found
      info [profile]           Read a profile and print the decoded configuration
      dump <file> [profile]    Read a profile, write the raw 520-byte report to <file>,
                               and print the decode. TAKE THIS BEFORE ANYTHING WRITES —
                               it is the only way back to the mouse's current settings.
                               Refuses to overwrite an existing file.
      restore <file> --config-size N --yes
                               Write a previously dumped blob back. The only writing
                               subcommand. Prints everything it is about to do and
                               refuses without --yes. --config-size is required: it
                               sets byte 0x03 (= N - 8), the byte that decides whether
                               the write is accepted at all. `info` prints what to use.

      profile is 1, 2 or 3 (default 1).

    WHY THERE ARE NO SETTERS YET:
      The write marker at blob byte 0x03 must be <config size> - 8, and whether the
      config size is 131 or 167 on this device is unresolved: libratbag derives it
      from the transfer length, OpenRGB hardcodes 131 (docs/mouse-protocol.md §11
      item 1). `info` and `dump` print the observed length and where the trailing
      zeros begin, which is what settles it.

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

    case "color", "colour":
        // First mutating field command: set solid colour. Read-modify-write of
        // the whole blob, config size taken from the observed read length, and
        // a read-back diff to confirm the write landed.
        guard let hex = rest.first, let rgb = MouseRGB(hex: hex) else {
            fail("`mouse color` needs a hex colour, RRGGBB", .usage)
        }
        withMouse { mouse in
            var blob = try mouse.readConfig(profile: .one)
            guard let size = blob.observedConfigSize else {
                fail("could not observe the config size from the read; refusing to write", .transport)
            }
            blob.effect = .single
            try blob.setColors([rgb], for: .single)
            if let param = blob.modeParameter(for: .single) {
                try blob.setModeParameter(MouseModeParameter(speed: param.speed, brightness: 4),
                                          for: .single)
            }
            let prepared = blob.preparedForWrite(profile: .one, configSize: size)
            try mouse.writeConfig(prepared)
            let after = try mouse.readConfig(profile: .one)
            let ok = after.effect == .single
                && after.colors(for: .single)?.first == rgb
            print("color -> #\(rgb.hexString) (solid), write "
                  + (ok ? "verified by read-back" : "NOT confirmed by read-back — check the mouse"))
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
