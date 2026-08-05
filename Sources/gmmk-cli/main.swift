import Foundation
import GMMKProtocol
import GMMKHID

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
      raw <hex bytes...>    Send raw payload bytes (see below) — debugging escape hatch

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
func send(_ packets: [[UInt8]], describing description: String) -> Never {
    withKeyboard { keyboard in
        try keyboard.send(packets: packets)
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
    send(GMMKTransaction.single(GMMKPacket.setMode(mode)),
         describing: "mode -> \(mode.displayName) (0x\(String(mode.rawValue, radix: 16)))")

case "brightness":
    let value = requireOneArgument("brightness", "a percentage, 0-100")
    guard let percent = Int(value), (0...100).contains(percent) else {
        fail("brightness must be an integer 0-100, got '\(value)'", .usage)
    }
    let level = Brightness.level(fromPercent: percent)
    send(GMMKTransaction.single(GMMKPacket.setBrightness(level: level)),
         describing: "brightness -> \(percent)% (device level \(level)/\(Brightness.max))"
                     + (level == 0 ? " — this turns the LEDs off" : ""))

case "speed":
    let value = requireOneArgument("speed", "1-5, where 1 is slowest")
    guard let speed = Int(value), (1...5).contains(speed) else {
        fail("speed must be an integer 1-5, got '\(value)'", .usage)
    }
    let delay = Delay.delay(fromSpeed: speed)
    send(GMMKTransaction.single(GMMKPacket.setDelay(delay)),
         describing: "speed -> \(speed) (device delay \(delay))")

case "color", "colour":
    let value = requireOneArgument("color", "a hex colour, RRGGBB")
    guard let rgb = RGB(hex: value) else {
        fail("colour must be 6 hex digits (RRGGBB), got '\(value)'", .usage)
    }
    // Turn the rainbow flag off in the same transaction, otherwise the effect
    // keeps cycling hues and ignores the colour entirely.
    send(GMMKTransaction.bracket([
            GMMKPacket.setRainbow(false),
            GMMKPacket.setColor(red: rgb.red, green: rgb.green, blue: rgb.blue),
         ]),
         describing: "color -> #\(rgb.hexString) (rainbow off)")

case "direction":
    let value = requireOneArgument("direction", "l or r")
    guard let direction = Direction.parse(value) else {
        fail("direction must be l/left or r/right, got '\(value)'", .usage)
    }
    send(GMMKTransaction.single(GMMKPacket.setDirection(direction)),
         describing: "direction -> \(direction.displayName)")

case "rainbow":
    let value = requireOneArgument("rainbow", "on or off")
    let on: Bool
    switch value.lowercased() {
    case "on", "true", "1", "yes":  on = true
    case "off", "false", "0", "no": on = false
    default: fail("rainbow must be on or off, got '\(value)'", .usage)
    }
    send(GMMKTransaction.single(GMMKPacket.setRainbow(on)),
         describing: "rainbow -> \(on ? "on" : "off")")

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
