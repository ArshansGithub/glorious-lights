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
      restore <file> [--config-size N] --yes
                               Write a previously dumped blob back. The only writing
                               subcommand. Prints everything it is about to do and
                               refuses without --yes.

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
            try Data(blob.bytes).write(to: url)
            print("")
            print("wrote \(blob.bytes.count) raw bytes to \(url.path)")
            print("")
            blob.summaryLines().forEach { print($0) }
            printTransferLengthNote(mouse)
            print("")
            print("raw report (first \(GloriousMouseDevice.configSizeMax) bytes):")
            blob.hexDumpLines(upTo: GloriousMouseDevice.configSizeMax).forEach { print("  " + $0) }
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
        // the write marker is stamped, and its value is the open question of
        // doc §11 item 1 — hence the explicit override and the printed source.
        let configSize = configSizeOverride ?? saved.inferredConfigSize
        let blob = saved.preparedForWrite(profile: profile, configSize: configSize)

        print("restore \(path)")
        print("  profile:      \(profile.displayName) (byte 1 = "
              + String(format: "0x%02x", profile.rawValue) + ")")
        print("  config size:  \(configSize)"
              + (configSizeOverride == nil ? "  (inferred from trailing zeros — see §11 item 1)"
                                           : "  (--config-size)"))
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
/// asks exactly this, and bring-up should record the answer.
private func printTransferLengthNote(_ mouse: GloriousMouse) {
    if let raw = mouse.lastConfigTransferLength {
        print("IOKit reported \(raw) bytes transferred for the config read.")
    } else {
        print("IOKit did not report a usable transfer length for the config read; "
              + "the config size above is inferred from where the trailing zeros begin.")
    }
}
