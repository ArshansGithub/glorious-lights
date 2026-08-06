import Foundation
import StripProtocol
import StripBLE

// The `strip` command group for Bluetooth LE strip controllers.
//
// Unlike the keyboard and the mouse, this talks to a device whose protocol is
// not known in advance. Cheap strip controllers are sold under dozens of names
// across a handful of mutually incompatible wire formats, and the only reliable
// way to tell them apart is to connect and look at the GATT table. So the
// command group is shaped around identification first and control second:
// `scan` and `report` gather evidence, `try-all` settles the question by
// experiment, and only then are `color` and `power` worth using.
//
// These controllers ignore frames they do not understand — no checksum, no
// length, no handshake to get wrong — which is what makes `try-all` safe to
// point at an unknown device.

let stripUsage = """
    gmmk-cli strip — control a Bluetooth LE LED strip

    USAGE:
      gmmk-cli strip <subcommand> [arguments]

    IDENTIFYING (start here):
      scan [--seconds N]       List every BLE device in range with a ranked guess at
                               which controller family each one is. Default 6s.
      report <name|uuid>       Connect and dump the full GATT table — every service,
                               every characteristic and its properties — then rank the
                               families against it. THIS IS THE EVIDENCE. A name alone
                               is ambiguous; a characteristic set usually is not.
      families                 List every known family, its GATT signature and whether
                               this project can drive it.
      try-all <RRGGBB>         Send each family's colour frame in turn, one second
                               apart, labelling each one as it goes. Whichever label
                               was on screen when the strip changed colour is the
                               family. Safe: these controllers ignore frames they do
                               not recognise.

    CONTROLLING:
      color <name|uuid> <RRGGBB> [--family X]
                               Set a solid colour. Without --family the family is
                               identified from the GATT dump, and the command refuses
                               to guess if identification is not confident.
      power <name|uuid> <on|off> [--family X]
                               Switch the strip on or off.
      brightness <name|uuid> <0-100> [--family X]
                               Set brightness. Most families take a percentage; Triones
                               has no such command at all and scales the colour instead.

    OPTIONS:
      --seconds N              How long to scan. Longer helps: these controllers
                               advertise slowly and intermittently.
      --family <name>          Skip identification and use this family. Run
                               `gmmk-cli strip families` for the names.

    IF NOTHING APPEARS:
      A strip controller only advertises while powered and NOT already connected to
      something. One central at a time — if the phone app is connected, or if this
      Mac is still connected from a previous run, the strip is invisible to a scan.
      Force-quit the phone app, and check the strip has 5V.

    PERMISSION:
      macOS gates Bluetooth per-process. A CLI inherits its terminal's grant, so the
      entry to allow in System Settings > Privacy & Security > Bluetooth is "Terminal"
      (or iTerm), not anything named after this project.
    """

// MARK: - Shared helpers

/// Scans, connects, discovers, runs `body`, then always disconnects.
///
/// The disconnect matters more than usual here: these controllers accept one
/// central at a time, so a connection left open is a strip that neither the
/// phone app nor the next run of this command can see. Every path out — success,
/// thrown error, or `fail()` — goes through it.
func withStrip(matching query: String,
               scanSeconds: Double,
               _ body: (StripCentral, StripDeviceReport) throws -> Void) -> Never {
    let central = StripCentral()
    let report: StripDeviceReport
    do {
        report = try central.open(matching: query, scanSeconds: scanSeconds)
    } catch let error as StripBLEError {
        central.disconnectAndWait()
        switch error {
        case .unauthorized, .poweredOff, .unsupported:
            fail(error.description, .transport)
        case .deviceNotFound, .noDevicesFound, .ambiguousDevice:
            fail(error.description, .deviceNotFound)
        default:
            fail(error.description, .transport)
        }
    } catch {
        central.disconnectAndWait()
        fail("\(error)", .transport)
    }
    do {
        try body(central, report)
    } catch let error as StripBLEError {
        central.disconnectAndWait()
        fail(error.description, .transport)
    } catch {
        central.disconnectAndWait()
        fail("\(error)", .transport)
    }
    central.disconnectAndWait()
    exit(ExitCode.ok.rawValue)
}

/// Resolves which family to drive: the `--family` override, or identification.
///
/// Refuses to act on a merely *possible* match. Writing a frame to the wrong
/// family is harmless — the controller ignores it — but silently doing nothing
/// while reporting success is the worst outcome during bring-up, because it
/// looks exactly like a hardware fault. `try-all` is the answer to an uncertain
/// device, and the error says so.
func resolveFamily(_ override: String?, from report: StripDeviceReport) -> StripFamily {
    if let override {
        guard let family = StripFamily(commandName: override) else {
            fail("unknown family '\(override)'. Run `gmmk-cli strip families` for the list.",
                 .usage)
        }
        return family
    }
    guard let best = report.candidates.first(where: { $0.score > 0 }) else {
        fail("""
            Could not identify \(report.displayName) as any known controller family.

            \(report.formatted())

            Try `gmmk-cli strip try-all <RRGGBB>` — it sends every family's colour frame \
            in turn and labels each one, so whichever label is on screen when the strip \
            changes colour is the answer. Then pass it with --family.
            """, .usage)
    }
    guard best.confidence == .confirmed || best.confidence == .likely else {
        fail("""
            \(report.displayName) looks like it might be \(best.family.displayName), but the \
            evidence is only "\(best.confidence.rawValue)": \
            \(best.reasons.joined(separator: "; ")).

            Refusing to guess, because a frame sent to the wrong family is silently ignored \
            and looks identical to broken hardware. Either run `gmmk-cli strip try-all \
            <RRGGBB>` to settle it by experiment, or pass --family \
            \(best.family.commandName) to override this check.
            """, .usage)
    }
    guard best.family.framesAvailable else {
        fail(StripBLEError.familyHasNoFrames(best.family).description, .usage)
    }
    return best.family
}

func parseStripColor(_ text: String) -> StripRGB {
    guard let rgb = StripRGB(hex: text) else {
        fail("'\(text)' is not a colour; expected RRGGBB, e.g. ff8800", .usage)
    }
    return rgb
}

/// One line per candidate, indented for a list.
func describeCandidates(_ candidates: [StripCandidate], indent: String) -> [String] {
    let ranked = candidates.filter { $0.score > 0 }.prefix(3)
    if ranked.isEmpty { return [indent + "no family matched"] }
    return ranked.map { candidate in
        indent + "\(candidate.confidence.rawValue): \(candidate.family.displayName)"
            + (candidate.reasons.isEmpty ? ""
               : " (" + candidate.reasons.joined(separator: "; ") + ")")
    }
}

extension StripFamily {
    /// The lower-case, hyphenated name used with `--family`.
    var commandName: String {
        switch self {
        case .elkBLEDOM: return "elk-bledom"
        case .elkBLEDOMAlternatePower: return "elk-bledom-alt-power"
        case .elkBLEDOB: return "elk-bledob"
        case .melk: return "melk"
        case .ledble: return "ledble"
        case .jackyLED: return "jackyled"
        case .triones: return "triones"
        case .lednetWF: return "lednetwf"
        case .spPixel: return "sp-pixel"
        case .idealLED: return "ideal-led"
        }
    }

    init?(commandName: String) {
        let wanted = commandName.lowercased()
        guard let match = Self.allCases.first(where: { $0.commandName == wanted }) else {
            return nil
        }
        self = match
    }
}

// MARK: - Dispatch

func runStripCommand(_ arguments: [String]) -> Never {
    guard let subcommand = arguments.first else {
        print(stripUsage)
        exit(ExitCode.usage.rawValue)
    }
    var rest = Array(arguments.dropFirst())

    // Flags are pulled out wherever they appear, so `--family` can follow the
    // positional arguments the way every other command group here allows.
    var scanSeconds = 6.0
    var familyOverride: String?
    var index = 0
    var positional: [String] = []
    while index < rest.count {
        switch rest[index] {
        case "--seconds":
            guard index + 1 < rest.count, let value = Double(rest[index + 1]), value > 0 else {
                fail("--seconds needs a positive number of seconds", .usage)
            }
            scanSeconds = value
            index += 2
        case "--family":
            guard index + 1 < rest.count else { fail("--family needs a family name", .usage) }
            familyOverride = rest[index + 1]
            index += 2
        default:
            positional.append(rest[index])
            index += 1
        }
    }
    rest = positional

    switch subcommand {

    case "families":
        print("known controller families\n")
        for family in StripFamily.allCases {
            let gatt = family.gatt
            print("  \(family.commandName)")
            print("    name:      \(family.displayName)")
            print("    write:     "
                  + gatt.writeCharacteristics.map(\.shortDescription).joined(separator: ", "))
            print("    notify:    "
                  + gatt.notifyCharacteristics.map(\.shortDescription).joined(separator: ", "))
            if !family.namePrefixes.isEmpty {
                print("    names:     " + family.namePrefixes.joined(separator: ", "))
            }
            if !family.framesAvailable {
                print("    NOTE:      identification only — this project does not write to it")
            }
            if family.scalesBrightnessByColor {
                print("    NOTE:      no brightness command; brightness scales the colour")
            }
            if !family.loginWrites.isEmpty {
                print("    NOTE:      needs a login write before it accepts commands")
            }
            if family.requiresNotifications {
                print("    NOTE:      ignores commands until notifications are enabled")
            }
            print("")
        }
        exit(ExitCode.ok.rawValue)

    case "scan":
        let central = StripCentral()
        var printed = Set<UUID>()
        print("scanning for \(String(format: "%.0f", scanSeconds))s…\n")
        let results: [StripScanResult]
        do {
            results = try central.scan(seconds: scanSeconds) { result in
                // Print as they arrive; a silent six seconds looks like a hang.
                guard !printed.contains(result.identifier) else { return }
                printed.insert(result.identifier)
                print("  \(result.displayName)  [\(result.rssi) dBm]")
            }
        } catch let error as StripBLEError {
            fail(error.description, .transport)
        } catch {
            fail("\(error)", .transport)
        }

        guard !results.isEmpty else {
            fail(StripBLEError.noDevicesFound(scanSeconds: scanSeconds).description,
                 .deviceNotFound)
        }

        print("\n\(results.count) device(s), strongest first:\n")
        for result in results {
            print("  \(result.displayName)")
            print("    identifier: \(result.identifier.uuidString)")
            print("    rssi:       \(result.rssi) dBm"
                  + (result.isConnectable ? "" : "  (not connectable)"))
            if !result.advertisedServiceUUIDs.isEmpty {
                print("    advertised: "
                      + result.advertisedServiceUUIDs.map(\.shortDescription)
                            .joined(separator: ", "))
            }
            for line in describeCandidates(result.candidates, indent: "    ") { print(line) }
            print("")
        }
        print("""
            A scan sees only the advertisement, and these controllers advertise almost \
            nothing useful — several advertise a HID service they do not implement. Run \
            `gmmk-cli strip report <name>` on the likely one to connect and read its real \
            GATT table, which is what actually identifies the family.
            """)
        exit(ExitCode.ok.rawValue)

    case "report":
        guard let query = rest.first else {
            fail("`strip report` needs a device name or identifier", .usage)
        }
        withStrip(matching: query, scanSeconds: scanSeconds) { _, report in
            print(report.formatted())
            print("")
            if let best = report.candidates.first(where: { $0.score > 0 }),
               best.family.framesAvailable {
                print("""
                    Next: `gmmk-cli strip color \(query) ff0000 --family \
                    \(best.family.commandName)`
                    """)
            } else {
                print("""
                    Next: `gmmk-cli strip try-all \(query) ff0000` — it sends every family's \
                    colour frame in turn and labels each, so whichever label is on screen \
                    when the strip changes colour is the family.
                    """)
            }
        }

    case "color":
        guard rest.count >= 2 else {
            fail("`strip color` needs a device and a colour, e.g. "
                 + "`strip color ELK-BLEDOM ff8800`", .usage)
        }
        let query = rest[0]
        let rgb = parseStripColor(rest[1])
        withStrip(matching: query, scanSeconds: scanSeconds) { central, report in
            let family = resolveFamily(familyOverride, from: report)
            try central.prepare(for: family, on: report)
            guard let frame = family.colorFrame(rgb, sequence: central.nextSequence()) else {
                fail(StripBLEError.familyHasNoFrames(family).description, .usage)
            }
            let target = try central.send(frame, as: family, on: report)
            print("\(report.displayName): \(family.displayName)")
            print("  -> \(target.uuid.shortDescription)  \(hexBytes(frame))")
            print("  colour #\(rgb.hexString)")
            // Without-response writes return immediately; give the frame time
            // to actually leave before the process tears the link down.
            central.idle(for: 0.3)
        }

    case "power":
        guard rest.count >= 2, let on = parseOnOff(rest[1]) else {
            fail("`strip power` needs a device and on|off", .usage)
        }
        let query = rest[0]
        withStrip(matching: query, scanSeconds: scanSeconds) { central, report in
            let family = resolveFamily(familyOverride, from: report)
            try central.prepare(for: family, on: report)
            guard let frame = family.powerFrame(on: on, sequence: central.nextSequence()) else {
                fail(StripBLEError.familyHasNoFrames(family).description, .usage)
            }
            let target = try central.send(frame, as: family, on: report)
            print("\(report.displayName): \(family.displayName)")
            print("  -> \(target.uuid.shortDescription)  \(hexBytes(frame))")
            print("  power \(on ? "on" : "off")")
            central.idle(for: 0.3)
        }

    case "brightness":
        guard rest.count >= 2, let percent = Int(rest[1]), (0...100).contains(percent) else {
            fail("`strip brightness` needs a device and a percentage 0-100", .usage)
        }
        let query = rest[0]
        withStrip(matching: query, scanSeconds: scanSeconds) { central, report in
            let family = resolveFamily(familyOverride, from: report)
            try central.prepare(for: family, on: report)
            guard let frame = family.brightnessFrame(percent: percent,
                                                     sequence: central.nextSequence()) else {
                if family.scalesBrightnessByColor {
                    fail("""
                        \(family.displayName) has no brightness command — its only intensity \
                        command drives a separate white channel, not the RGB output. Every \
                        implementation of this protocol scales the colour instead, so use \
                        `strip color` with a dimmed value.
                        """, .usage)
                }
                fail(StripBLEError.familyHasNoFrames(family).description, .usage)
            }
            let target = try central.send(frame, as: family, on: report)
            print("\(report.displayName): \(family.displayName)")
            print("  -> \(target.uuid.shortDescription)  \(hexBytes(frame))")
            print("  brightness \(percent)%")
            central.idle(for: 0.3)
        }

    case "try-all":
        guard rest.count >= 2 else {
            fail("`strip try-all` needs a device and a colour, e.g. "
                 + "`strip try-all ELK-BLEDOM ff0000`", .usage)
        }
        let query = rest[0]
        let rgb = parseStripColor(rest[1])
        withStrip(matching: query, scanSeconds: scanSeconds) { central, report in
            print("""
                \(report.displayName)

                Sending each family's colour frame for #\(rgb.hexString) in turn, one second \
                apart. Watch the strip: whichever line is the last one printed when it changes \
                colour is the family. These controllers ignore frames they do not recognise, so \
                the ones that do nothing cost nothing.

                """)
            var attempted = 0
            for family in StripFamily.tryAllOrder {
                guard let target = report.writeCharacteristic(for: family) else {
                    print("  skip  \(family.displayName) — "
                          + "no write characteristic on this device")
                    continue
                }
                guard let frame = family.colorFrame(rgb, sequence: central.nextSequence()) else {
                    continue
                }
                // Login writes first for the families that need them, so a
                // MELK-style controller is not skipped over for staying silent.
                if !family.loginWrites.isEmpty {
                    for login in family.loginWrites {
                        try? central.write(login, to: target)
                        central.idle(for: 0.1)
                    }
                }
                do {
                    try central.write(frame, to: target)
                    attempted += 1
                    print("  send  \(family.displayName)")
                    print("          --family \(family.commandName)")
                    print("          \(target.uuid.shortDescription)  \(hexBytes(frame))")
                } catch {
                    print("  fail  \(family.displayName): \(error)")
                }
                central.idle(for: 1.0)
            }
            print("")
            if attempted == 0 {
                print("""
                    Nothing could be sent — none of the known families' write characteristics \
                    is present on this device. Run `gmmk-cli strip report \(query)` and compare \
                    the dump against `gmmk-cli strip families`.
                    """)
            } else {
                print("""
                    \(attempted) frame(s) sent. Re-run with `--family <name>` (the second line \
                    of each block above) to use whichever one worked.

                    If the colour was right but green and blue were swapped, the family is \
                    jackyled. If the strip lit but will not switch off, try \
                    elk-bledom-alt-power.
                    """)
            }
        }

    default:
        printErr("gmmk-cli: unknown strip subcommand '\(subcommand)'\n")
        printErr(stripUsage)
        exit(ExitCode.usage.rawValue)
    }
}

// `parseOnOff` is shared with the mouse command group; it lives in
// MouseCommands.swift.

func hexBytes(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}
