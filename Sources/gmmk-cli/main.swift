import Foundation
import GMMKProtocol
import GMMKHID
import IOKit.hid

// Shared state for the probe0 diagnostic's C-function input callbacks.
final class ReplyLog { var entries: [(Int, UInt32, [UInt8])] = [] }
final class Probe0State {
    static let shared = Probe0State()
    var log: ReplyLog?
    var indexByDevice: [IOHIDDevice: Int] = [:]
}

// gmmk-cli — bring-up and debugging harness for the GMMK v1 lighting protocol.
// Hand-rolled argument parsing, no package dependencies.

// MARK: - Output helpers

func printErr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

/// Exit codes: 0 ok, 1 usage error, 2 device not found, 3 transport failure.
enum ExitCode: Int32 {
    case ok = 0
    case usage = 1
    case deviceNotFound = 2
    case transport = 3
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    printErr("gmmk-cli: " + message)
    exit(code.rawValue)
}

let usage = """
    gmmk-cli — control GMMK v1 (0C45:652F) RGB lighting

    USAGE:
      gmmk-cli <command> [arguments]

    COMMANDS:
      list                  Report whether the keyboard's vendor interface was found
      modes                 List every effect mode with its ID
      mode <name|id>        Set the effect mode (e.g. "fixed", "wave1", 6, 0x06)
      brightness <0-100>    Set brightness as a percentage (mapped onto the device's 0-4)
      speed <1-5>           Set animation speed (1 = slowest, 5 = fastest)
      color <RRGGBB>        Set the solid colour and turn the rainbow flag off
      direction <l|r>       Set the effect direction
      rainbow <on|off>      Set the rainbow (hue-cycling) flag
      paint <RRGGBB>        Switch to custom mode (0x14) and paint every per-key
                            LED that colour
      mouse <subcommand>    Read the wired Glorious Model O / O- (258A:0036).
                            A different device with a different protocol —
                            feature reports, no checksum, no START/END. Run
                            `gmmk-cli mouse` for its subcommands.
      strip <subcommand>    Control a Bluetooth LE LED strip. A third device on a
                            third transport, and the only one whose protocol is
                            not known in advance: cheap controllers ship under
                            dozens of names across several incompatible wire
                            formats. Start with `gmmk-cli strip scan`, which
                            ranks each device against the known families. Run
                            `gmmk-cli strip` for its subcommands.

      Each of these opens with a 0x03 "hello" read — without a recent one the
      firmware stores writes but never applies them — and then sends one
      START/END transaction writing its fields at all three profile bases (0x00,
      0x2A, 0x54), so the change applies whichever profile the board is running.
      Packets are paced on the firmware's replies. See docs/protocol-tkl-notes.md
      §13.

    DEBUG / BRING-UP:
      These exist to investigate the protocol, not to use the keyboard. They talk
      to the device directly and print what comes back.

      read [addr] [count] [cmd]
                            Read and dump the reply (hex args; defaults 0000 38 05).
                            Sent raw, without the hello read the user commands
                            open with. cmd 05 reads config RAM by address and
                            works as documented. cmd 03 does NOT return the config
                            block on firmware 1.08 — it answers with a device-info
                            block, which this command decodes (VID/PID, firmware
                            version, supported mode IDs), so it cannot be used to
                            read the active profile.
      probe0                Enumerate every HID service for 0c45:652f and find
                            which one answers on the input report.
      probe1                Send a 2-byte config write as a full 64-byte frame,
                            testing that macOS does not prepend the report ID.
      probe2                Replicate the official editor's session: one open,
                            read-before-write, reply drained after every packet.
      probe3                Paint the whole per-key colour RAM (cmd 0x11) over a
                            hand-rolled transport. Superseded by `paint`, which
                            does the same thing through the library; kept because
                            it prints a per-packet status byte.
      raw <hex bytes...>    Send raw payload bytes — the escape hatch.

    RAW:
      Bytes are given without the leading 0x04 report ID and are zero-padded to 63.
      The checksum is NOT recomputed; give it yourself in the first two bytes.
      Whitespace, commas and "0x" prefixes are ignored, so both of these work:
        gmmk-cli raw 0d 00 06 01 00 00 00 06
        gmmk-cli raw 0d0006010000 0006
      Raw payloads are sent unbracketed; add START/END yourself if the command needs it.

    EXIT CODES:
      0 success   1 usage error   2 keyboard not found   3 transport failure
    """

// MARK: - Device access

func withKeyboard(_ body: (GMMKKeyboard) throws -> Void) -> Never {
    let keyboard = GMMKKeyboard()
    // Bring-up overrides; must be applied before `open()`, which selects the
    // interface based on `transportProbe`.
    if let raw = ProcessInfo.processInfo.environment["GMMK_PACKET_DELAY_MS"],
       let ms = Double(raw) {
        keyboard.interPacketDelay = ms / 1000.0
    }
    if let raw = ProcessInfo.processInfo.environment["GMMK_TRANSPORT"],
       let probe = GMMKKeyboard.TransportProbe(rawValue: raw) {
        keyboard.transportProbe = probe
    }
    do {
        try keyboard.open()
    } catch let error as GMMKHIDError {
        switch error {
        case .deviceNotFound: fail(error.description, .deviceNotFound)
        default: fail(error.description, .transport)
        }
    } catch {
        fail("\(error)", .transport)
    }
    // Every path out of here is `exit()`, which does not unwind `defer` blocks
    // or run deinits — so close the device explicitly on each one.
    do {
        try body(keyboard)
    } catch let error as GMMKHIDError {
        keyboard.stop()
        fail(error.description, .transport)
    } catch {
        keyboard.stop()
        fail("\(error)", .transport)
    }
    keyboard.stop()
    exit(ExitCode.ok.rawValue)
}

/// Sends a START-bracketed transaction and exits.
///
/// Packets are paced by waiting for each one's echo, so no fixed delay is
/// needed. Timing overrides for hardware bring-up (both in milliseconds):
/// `GMMK_PACKET_DELAY_MS` — *extra* pause between packets on top of the echo
/// wait (default 0), for testing timing hypotheses.
/// `GMMK_SETTLE_MS` — pause after the last packet before the device is
/// closed, so a queued OUT report can't be cancelled by the close (default 0).
func send(_ packets: [[UInt8]], describing description: String) -> Never {
    withKeyboard { keyboard in
        try keyboard.send(packets: packets)
        if let raw = ProcessInfo.processInfo.environment["GMMK_SETTLE_MS"],
           let ms = Double(raw), ms > 0 {
            Thread.sleep(forTimeInterval: ms / 1000.0)
        }
        print(description)
    }
}

// MARK: - Argument parsing

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(ExitCode.usage.rawValue)
}
let rest = Array(args.dropFirst())

func requireOneArgument(_ command: String, _ hint: String) -> String {
    guard rest.count == 1 else {
        fail("`\(command)` takes exactly one argument: \(hint)", .usage)
    }
    return rest[0]
}

// MARK: - Commands

switch command {

case "help", "-h", "--help":
    print(usage)
    exit(ExitCode.ok.rawValue)

case "list":
    if GMMKKeyboard.isDevicePresent() {
        print(String(format: "GMMK vendor interface found (%04x:%04x, usage page 0x%04x usage 0x%02x)",
                     GMMKKeyboard.vendorID, GMMKKeyboard.productID,
                     GMMKKeyboard.vendorUsagePage, GMMKKeyboard.vendorUsage))
        exit(ExitCode.ok.rawValue)
    } else {
        printErr(GMMKHIDError.deviceNotFound.description)
        exit(ExitCode.deviceNotFound.rawValue)
    }

case "modes":
    for mode in LightingMode.allCases {
        let official = mode.officialLabel.map { "(official: \($0))" } ?? ""
        let slug = mode.slug.padding(toLength: 22, withPad: " ", startingAt: 0)
        print(String(format: "  0x%02X  %2d  ", Int(mode.rawValue), Int(mode.rawValue))
              + slug + official)
    }
    exit(ExitCode.ok.rawValue)

case "mode":
    let value = requireOneArgument("mode", "a mode name or ID (see `gmmk-cli modes`)")
    guard let mode = LightingMode.parse(value) else {
        fail("unknown mode '\(value)'. Run `gmmk-cli modes` for the list.", .usage)
    }
    send(GMMKTransaction.setMode(mode),
         describing: "mode -> \(mode.displayName) (0x\(String(mode.rawValue, radix: 16)))")

case "brightness":
    let value = requireOneArgument("brightness", "a percentage, 0-100")
    guard let percent = Int(value), (0...100).contains(percent) else {
        fail("brightness must be an integer 0-100, got '\(value)'", .usage)
    }
    let level = Brightness.level(fromPercent: percent)
    send(GMMKTransaction.setBrightness(level: level),
         describing: "brightness -> \(percent)% (device level \(level)/\(Brightness.max))"
                     + (level == 0 ? " — this turns the LEDs off" : ""))

case "speed":
    let value = requireOneArgument("speed", "1-5, where 1 is slowest")
    guard let speed = Int(value), (1...5).contains(speed) else {
        fail("speed must be an integer 1-5, got '\(value)'", .usage)
    }
    let delay = Delay.delay(fromSpeed: speed)
    send(GMMKTransaction.setDelay(delay),
         describing: "speed -> \(speed) (device delay \(delay))")

case "color", "colour":
    let value = requireOneArgument("color", "a hex colour, RRGGBB")
    guard let rgb = RGB(hex: value) else {
        fail("colour must be 6 hex digits (RRGGBB), got '\(value)'", .usage)
    }
    // Turn the rainbow flag off in the same transaction, otherwise the effect
    // keeps cycling hues and ignores the colour entirely.
    send(GMMKTransaction.setColor(rgb),
         describing: "color -> #\(rgb.hexString) (rainbow off)")

case "paint":
    let value = requireOneArgument("paint", "a hex colour, RRGGBB")
    guard let rgb = RGB(hex: value) else {
        fail("colour must be 6 hex digits (RRGGBB), got '\(value)'", .usage)
    }
    // Per-key colours are only visible in mode 0x14, which the transaction sets
    // at all three profile bases before the colour run.
    send(GMMKTransaction.paintUniform(rgb),
         describing: "paint -> #\(rgb.hexString) on LED indices "
                     + "\(GMMKKeyMap.minLEDIndex)-\(GMMKKeyMap.maxLEDIndex) (mode custom)")

case "direction":
    let value = requireOneArgument("direction", "l or r")
    guard let direction = Direction.parse(value) else {
        fail("direction must be l/left or r/right, got '\(value)'", .usage)
    }
    send(GMMKTransaction.setDirection(direction),
         describing: "direction -> \(direction.displayName)")

case "rainbow":
    let value = requireOneArgument("rainbow", "on or off")
    let on: Bool
    switch value.lowercased() {
    case "on", "true", "1", "yes":  on = true
    case "off", "false", "0", "no": on = false
    default: fail("rainbow must be on or off, got '\(value)'", .usage)
    }
    send(GMMKTransaction.setRainbow(on),
         describing: "rainbow -> \(on ? "on" : "off")")

case "mouse":
    runMouseCommand(rest)

case "strip":
    runStripCommand(rest)

case "read":
    // Bring-up/debug: read from the keyboard and print the reply.
    // Usage: read [addr-hex] [count-hex] [cmd-hex] — defaults: 0000, 38, 05.
    // cmd 05 = config RAM by address; cmd 03 = the device-info block on fw 1.08,
    // NOT the config block — see docs/protocol-tkl-notes.md §13.4.
    let addr = UInt16(rest.count > 0 ? rest[0] : "0000", radix: 16) ?? 0
    let count = UInt8(rest.count > 1 ? rest[1] : "38", radix: 16) ?? 0x38
    let readCmd = UInt8(rest.count > 2 ? rest[2] : "05", radix: 16) ?? GMMKPacket.Command.readConfig
    withKeyboard { keyboard in
        print("sent read: cmd 0x\(String(format: "%02x", readCmd)) "
              + "addr 0x\(String(format: "%04x", addr)) "
              + "count 0x\(String(format: "%02x", count))")
        let reply = try keyboard.readRaw(command: readCmd, address: addr, count: count)
        let hex = reply.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("reply (\(reply.count) bytes): \(hex)")
        print("status: \(GMMKPacket.replyStatus(inReport: reply))")
        if let info = GMMKDeviceInfo(reply: reply) {
            print("device info: \(String(format: "%04x:%04x", info.vendorID, info.productID)) "
                  + "fw \(info.firmwareVersionString)")
            print("supported modes (\(info.supportedModeIDs.count)): "
                  + info.supportedModeIDs.map { String(format: "0x%02x", $0) }
                        .joined(separator: " "))
        }
    }

case "probe0":
    // Reply-channel diagnostic (docs/protocol-tkl-notes.md §6 Probe 0).
    // Enumerates EVERY IOHIDDevice for the keyboard, listens on all of them,
    // and sends START + config-block-read only to vendor-usage candidates.
    // Read-only towards the boot interface; never sends feature reports.
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                 IOHIDManagerOptions.independentDevices.rawValue)
    IOHIDManagerSetDeviceMatching(mgr, [
        kIOHIDVendorIDKey: 0x0C45, kIOHIDProductIDKey: 0x652F,
    ] as CFDictionary)
    guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
          !deviceSet.isEmpty else {
        fail("no HID services for 0c45:652f", .deviceNotFound)
    }
    let devices = Array(deviceSet)
    var buffers: [UnsafeMutablePointer<UInt8>] = []
    let log = ReplyLog()

    for (i, dev) in devices.enumerated() {
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(dev, key as CFString) }
        let pairs = (prop(kIOHIDDeviceUsagePairsKey) as? [[String: Any]])?
            .compactMap { p -> String? in
                guard let pg = p[kIOHIDDeviceUsagePageKey as String] as? Int,
                      let us = p[kIOHIDDeviceUsageKey as String] as? Int else { return nil }
                return String(format: "(%04x,%02x)", pg, us)
            }.joined(separator: " ") ?? "?"
        print("[\(i)] location=\(prop(kIOHIDLocationIDKey) ?? "?") pairs=\(pairs) "
              + "maxIn=\(prop(kIOHIDMaxInputReportSizeKey) ?? "?") "
              + "maxOut=\(prop(kIOHIDMaxOutputReportSizeKey) ?? "?")")

        let openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            print("[\(i)] open failed: 0x\(String(UInt32(bitPattern: openResult), radix: 16))")
            continue
        }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers.append(buf)
        // Context carries the device index; ReplyLog is reached via a global.
        Probe0State.shared.log = log
        Probe0State.shared.indexByDevice[dev] = i
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { _, _, sender, _, reportID, report, length in
            guard let sender else { return }
            let dev = Unmanaged<IOHIDDevice>.fromOpaque(UnsafeRawPointer(sender)).takeUnretainedValue()
            let idx = Probe0State.shared.indexByDevice[dev] ?? -1
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Probe0State.shared.log?.entries.append((idx, reportID, bytes))
        }, nil)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    func pump(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }
    func sendTo(_ dev: IOHIDDevice, _ payload: [UInt8], label: String, index: Int) {
        let r = payload.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 4, $0.baseAddress!, $0.count)
        }
        print("→ [\(index)] \(label): "
              + (r == kIOReturnSuccess ? "sent" : "FAILED 0x\(String(UInt32(bitPattern: r), radix: 16))"))
    }

    let vendorIndices = devices.indices.filter { GMMKKeyboard.isVendorInterface(devices[$0]) }
    print("vendor-capable services: \(vendorIndices)")
    for i in vendorIndices {
        let before = log.entries.count
        sendTo(devices[i], GMMKPacket.start(), label: "START", index: i)
        pump(1.0)
        sendTo(devices[i],
               GMMKPacket.makeRead(command: GMMKPacket.Command.readProfile, address: 0, count: 0x2C),
               label: "block-read 0x03/2C", index: i)
        pump(1.5)
        sendTo(devices[i], GMMKPacket.end(), label: "END", index: i)
        pump(0.5)
        print("replies attributable to service [\(i)]: \(log.entries.count - before)")
    }

    if log.entries.isEmpty {
        print("RESULT: no input reports from any service")
    } else {
        for (idx, reportID, bytes) in log.entries {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("REPLY from [\(idx)] id=\(reportID) len=\(bytes.count): \(hex)")
        }
    }
    for dev in devices { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
    buffers.forEach { $0.deallocate() }
    exit(log.entries.isEmpty ? ExitCode.transport.rawValue : ExitCode.ok.rawValue)

case "probe1":
    // Tests whether the firmware wants the FULL 64-byte wire packet (leading
    // 0x04 included) passed as the SetReport payload — i.e. whether macOS is
    // NOT prepending the report ID on the interrupt pipe. Sends
    // START, 2-byte config write (mode=static, brightness=0), END — all as
    // 64-byte buffers — then restores brightness 4 the same way.
    // Phantom input warning: firmware reply echoes parse as key events.
    let mgr1 = IOHIDManagerCreate(kCFAllocatorDefault,
                                  IOHIDManagerOptions.independentDevices.rawValue)
    IOHIDManagerSetDeviceMatching(mgr1, [
        kIOHIDVendorIDKey: 0x0C45, kIOHIDProductIDKey: 0x652F,
    ] as CFDictionary)
    guard let set1 = IOHIDManagerCopyDevices(mgr1) as? Set<IOHIDDevice>,
          let vendor = set1.first(where: { GMMKKeyboard.isVendorInterface($0) }) else {
        fail("vendor interface not found", .deviceNotFound)
    }
    guard IOHIDDeviceOpen(vendor, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
        fail("open failed (Input Monitoring?)", .transport)
    }
    let buf1 = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    Probe0State.shared.log = ReplyLog()
    Probe0State.shared.indexByDevice[vendor] = 0
    IOHIDDeviceRegisterInputReportCallback(vendor, buf1, 64, { _, _, sender, _, reportID, report, length in
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        Probe0State.shared.log?.entries.append((0, reportID, bytes))
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(vendor, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    func wire64(_ body: [UInt8]) -> [UInt8] {
        // body = bytes 3..: cmd, count, addr lo, addr hi, pad, data...
        var p = [UInt8](repeating: 0, count: 64)
        p[0] = 0x04
        for (i, b) in body.enumerated() { p[3 + i] = b }
        var sum: UInt32 = 0
        for i in 3..<64 { sum = (sum &+ UInt32(p[i])) & 0xFFFF }
        p[1] = UInt8(sum & 0xFF)
        p[2] = UInt8((sum >> 8) & 0xFF)
        return p
    }
    func send64(_ p: [UInt8], _ label: String) {
        let r = p.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(vendor, kIOHIDReportTypeOutput, 4, $0.baseAddress!, $0.count)
        }
        print("\(label): " + (r == kIOReturnSuccess ? "sent (64B)" : "FAILED 0x\(String(UInt32(bitPattern: r), radix: 16))"))
        let until = Date(timeIntervalSinceNow: 0.4)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    let probeMode = UInt8(rest.count > 0 ? rest[0] : "06", radix: 16) ?? 0x06
    let probeBright = UInt8(rest.count > 1 ? rest[1] : "00", radix: 16) ?? 0x00
    send64(wire64([0x01]), "START")
    send64(wire64([0x06, 0x02, 0x00, 0x00, 0x00, probeMode, probeBright]),
           "write mode=\(String(format: "%02x", probeMode)) bright=\(probeBright)")
    Thread.sleep(forTimeInterval: 0.010)
    send64(wire64([0x02]), "END")
    print("-- replies so far --")
    for (_, id, bytes) in Probe0State.shared.log?.entries ?? [] {
        print("id=\(id) len=\(bytes.count): " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
    }
    IOHIDDeviceClose(vendor, IOOptionBits(kIOHIDOptionsTypeNone))
    buf1.deallocate()
    exit(ExitCode.ok.rawValue)

case "probe2":
    // Full official-editor session replication: one open, read-before-write,
    // and a drained reply after EVERY packet (like hidapi hid_read w/ 300ms
    // timeout). Usage: probe2 [mode-hex] (default 06 static).
    let wantMode = UInt8(rest.count > 0 ? rest[0] : "06", radix: 16) ?? 0x06
    let mgr2 = IOHIDManagerCreate(kCFAllocatorDefault,
                                  IOHIDManagerOptions.independentDevices.rawValue)
    IOHIDManagerSetDeviceMatching(mgr2, [
        kIOHIDVendorIDKey: 0x0C45, kIOHIDProductIDKey: 0x652F,
    ] as CFDictionary)
    guard let set2 = IOHIDManagerCopyDevices(mgr2) as? Set<IOHIDDevice>,
          let vendor2 = set2.first(where: { GMMKKeyboard.isVendorInterface($0) }) else {
        fail("vendor interface not found", .deviceNotFound)
    }
    guard IOHIDDeviceOpen(vendor2, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
        fail("open failed (Input Monitoring?)", .transport)
    }
    let buf2 = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    Probe0State.shared.log = ReplyLog()
    IOHIDDeviceRegisterInputReportCallback(vendor2, buf2, 64, { _, _, _, _, reportID, report, length in
        Probe0State.shared.log?.entries.append((0, reportID, Array(UnsafeBufferPointer(start: report, count: length))))
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(vendor2, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    func wire(_ body: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 64)
        p[0] = 0x04
        for (i, b) in body.enumerated() { p[3 + i] = b }
        var sum: UInt32 = 0
        for i in 3..<64 { sum = (sum &+ UInt32(p[i])) & 0xFFFF }
        p[1] = UInt8(sum & 0xFF); p[2] = UInt8((sum >> 8) & 0xFF)
        return p
    }
    // Sends and then pumps the run loop until a reply arrives (or 350 ms),
    // mirroring the official editor's write→read(300ms)→retry loop.
    func xfer(_ body: [UInt8], _ label: String) {
        let countBefore = Probe0State.shared.log?.entries.count ?? 0
        for attempt in 1...4 {
            let p = wire(body)
            let r = p.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(vendor2, kIOHIDReportTypeOutput, 4, $0.baseAddress!, $0.count)
            }
            guard r == kIOReturnSuccess else {
                print("\(label): send FAILED 0x\(String(UInt32(bitPattern: r), radix: 16))"); return
            }
            let deadline = Date(timeIntervalSinceNow: 0.35)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
                if (Probe0State.shared.log?.entries.count ?? 0) > countBefore { break }
            }
            if let entries = Probe0State.shared.log?.entries, entries.count > countBefore {
                let reply = entries.last!.2
                let status = reply.count > 7 ? reply[7] : 0xEE
                print("\(label): reply status=0x\(String(format: "%02x", status)) (attempt \(attempt))")
                return
            }
            print("\(label): no reply, retrying (attempt \(attempt))")
        }
    }

    xfer([0x03, 0x2C], "read block 0x03")
    xfer([0x05, 0x38], "read config 0x05")
    xfer([0x01], "START")
    xfer([0x06, 0x01, 0x00, 0x00, 0x00, wantMode], "mode@0x00")
    xfer([0x06, 0x01, 0x2A, 0x00, 0x00, wantMode], "mode@0x2A")
    xfer([0x06, 0x01, 0x54, 0x00, 0x00, wantMode], "mode@0x54")
    xfer([0x06, 0x01, 0x04, 0x00, 0x00, 0x00], "rainbow@0x04")
    xfer([0x06, 0x01, 0x2E, 0x00, 0x00, 0x00], "rainbow@0x2E")
    xfer([0x06, 0x01, 0x58, 0x00, 0x00, 0x00], "rainbow@0x58")
    Thread.sleep(forTimeInterval: 0.010)
    xfer([0x02], "END")
    IOHIDDeviceClose(vendor2, IOOptionBits(kIOHIDOptionsTypeNone))
    buf2.deallocate()
    exit(ExitCode.ok.rawValue)

case "probe3":
    // Paint the whole per-key colour RAM one colour (cmd 0x11), reply-drained.
    // Usage: probe3 [RRGGBB] (default ff8800). Keeps the current mode.
    let rgbHex = rest.count > 0 ? rest[0] : "ff8800"
    guard let rgb3 = RGB(hex: rgbHex) else { fail("bad colour '\(rgbHex)'", .usage) }
    let mgr3 = IOHIDManagerCreate(kCFAllocatorDefault,
                                  IOHIDManagerOptions.independentDevices.rawValue)
    IOHIDManagerSetDeviceMatching(mgr3, [
        kIOHIDVendorIDKey: 0x0C45, kIOHIDProductIDKey: 0x652F,
    ] as CFDictionary)
    guard let set3 = IOHIDManagerCopyDevices(mgr3) as? Set<IOHIDDevice>,
          let vendor3 = set3.first(where: { GMMKKeyboard.isVendorInterface($0) }) else {
        fail("vendor interface not found", .deviceNotFound)
    }
    guard IOHIDDeviceOpen(vendor3, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
        fail("open failed (Input Monitoring?)", .transport)
    }
    let buf3 = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    Probe0State.shared.log = ReplyLog()
    IOHIDDeviceRegisterInputReportCallback(vendor3, buf3, 64, { _, _, _, _, reportID, report, length in
        Probe0State.shared.log?.entries.append((0, reportID, Array(UnsafeBufferPointer(start: report, count: length))))
    }, nil)
    IOHIDDeviceScheduleWithRunLoop(vendor3, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    func wire3(_ body: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 64)
        p[0] = 0x04
        for (i, b) in body.enumerated() { p[3 + i] = b }
        var sum: UInt32 = 0
        for i in 3..<64 { sum = (sum &+ UInt32(p[i])) & 0xFFFF }
        p[1] = UInt8(sum & 0xFF); p[2] = UInt8((sum >> 8) & 0xFF)
        return p
    }
    func xfer3(_ body: [UInt8], _ label: String) {
        let before = Probe0State.shared.log?.entries.count ?? 0
        let p = wire3(body)
        let r = p.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(vendor3, kIOHIDReportTypeOutput, 4, $0.baseAddress!, $0.count)
        }
        guard r == kIOReturnSuccess else {
            print("\(label): send FAILED"); return
        }
        let deadline = Date(timeIntervalSinceNow: 0.35)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            if (Probe0State.shared.log?.entries.count ?? 0) > before { break }
        }
        let status = (Probe0State.shared.log?.entries.last?.2.count ?? 0) > 7
            ? Probe0State.shared.log!.entries.last!.2[7] : 0xEE
        print("\(label): status=0x\(String(format: "%02x", status))")
    }

    xfer3([0x01], "START")
    // Key indices 1...126 (full-size superset; TKL is a subset), addr = idx*3.
    // 18 keys (54 bytes) per packet.
    var idx = 1
    while idx <= 126 {
        let chunk = min(18, 127 - idx)
        var body: [UInt8] = [0x11, UInt8(chunk * 3),
                             UInt8((idx * 3) & 0xFF), UInt8(((idx * 3) >> 8) & 0xFF), 0x00]
        for _ in 0..<chunk { body.append(contentsOf: [rgb3.red, rgb3.green, rgb3.blue]) }
        xfer3(body, "keys \(idx)-\(idx + chunk - 1)")
        idx += chunk
    }
    Thread.sleep(forTimeInterval: 0.010)
    xfer3([0x02], "END")
    IOHIDDeviceClose(vendor3, IOOptionBits(kIOHIDOptionsTypeNone))
    buf3.deallocate()
    exit(ExitCode.ok.rawValue)

case "raw":
    guard !rest.isEmpty else {
        fail("`raw` needs at least one hex byte", .usage)
    }
    let cleaned = rest.joined()
        .replacingOccurrences(of: "0x", with: "")
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
    guard cleaned.count % 2 == 0 else {
        fail("raw needs an even number of hex digits, got \(cleaned.count)", .usage)
    }
    var bytes = [UInt8]()
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
            fail("'\(cleaned[index..<next])' is not a hex byte", .usage)
        }
        bytes.append(byte)
        index = next
    }
    guard bytes.count <= GMMKPacket.payloadLength else {
        fail("raw payload is \(bytes.count) bytes; the maximum without the report ID "
             + "byte is \(GMMKPacket.payloadLength)", .usage)
    }
    let padded = bytes + [UInt8](repeating: 0,
                                count: GMMKPacket.payloadLength - bytes.count)
    let hex = padded.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
    send([padded], describing: "raw -> 04 \(hex) … (\(padded.count) bytes, checksum as given)")

default:
    printErr("gmmk-cli: unknown command '\(command)'\n")
    printErr(usage)
    exit(ExitCode.usage.rawValue)
}
