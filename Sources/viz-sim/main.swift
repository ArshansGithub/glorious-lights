import Foundation
import GMMKProtocol
import GloriousVisualizer

// viz-sim — runs the visualizer offline against generated signals or an audio
// file, and measures what it actually did.
//
// A development tool, not part of the shipped app: `Scripts/make-app.sh` builds
// only the GMMKLightsApp product, so this never lands in the bundle.
//
// It drives `VisualizerEngine` — the same object the app drives — with decoupled
// audio and display clocks, so a number measured here is a claim about the app
// rather than about a copy of it.

enum SimError: Error, CustomStringConvertible {
    case usage(String)
    case audioFileUnreadable(String)
    case audioFileFailed(String, String)
    case imageFailed(String)
    case movieFailed(String)

    var description: String {
        switch self {
        case .usage(let message):            return message
        case .audioFileUnreadable(let path): return "Could not read audio from '\(path)'."
        case .audioFileFailed(let path, let message):
            return "Could not decode '\(path)': \(message)"
        case .imageFailed(let path):         return "Could not write the PNG at '\(path)'."
        case .movieFailed(let message):      return "Could not write the movie: \(message)"
        }
    }
}

let usage = """
    viz-sim — run the keyboard visualizer offline and measure what it does

    USAGE:
      viz-sim --battery [options]
      viz-sim [--signal <name> | --file <path>] [options]

    THE BATTERY:
      --battery             Run every synthetic case × every mode × {no jitter,
                            measured jitter} and print each metric against its
                            pass threshold. This is the CI gate: a change that
                            regresses any bound is rejected regardless of how it
                            looks on any one track.
      --verbose             Print every check, not just the failures.

    INPUT (one of):
      --signal <name>       edm-128 | edm-128-kick | ballad-72 | speech |
                            crescendo | cut-transitions | sustained-tone |
                            pink | white | near-silence | dnb-174 | polyrhythm
      --file <path>         An audio file (wav / m4a / mp3 / anything AVAudioFile reads)

    PIPELINE OPTIONS (mirroring the app):
      --mode <name>         pulse | wave | ripple | spectrum | vu (default: pulse)
      --theme-colour        Paint in the desk colour instead of the brightness ramp
      --sensitivity <x>     Gain on the composed picture (default: 1.0)

    RUN OPTIONS:
      --fps <n>             Display frame rate (default: 30)
      --duration <seconds>  How much audio to run (default: 30)
      --jitter <ms>         Gaussian jitter on the display wake-up (default: 0)
      --stall <ms>@<hz>     Inject a transport stall of <ms> at <hz>
      --every <seconds>     How often to write a PNG (default: 0.15; 0 disables)
      --csv <path>          Per-frame per-LED lightness, which every metric is
                            computed from
      --out <directory>     Where PNGs, the movie and stats.txt go

    OUTPUT:
      <out>/animation.mp4         every frame — watch this; stills cannot show
                                  whether it flows with the music
      <out>/frame-<seconds>.png   one per --every of audio
      <out>/stats.txt             the full metric table
    """

// MARK: - Arguments

var battery = false
var verbose = false
var signal: Signal = .pink
var mode: VisualizerMode = .pulse
var useThemeColour = false
var sensitivity = 1.0
var fps = 30.0
var duration = 30.0
var jitterMilliseconds = 0.0
var stall: (length: Double, rate: Double)?
var every = 0.15
var csvPath: String?
var outputDirectory = URL(fileURLWithPath: "viz-sim-out")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("viz-sim: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
while let option = arguments.first {
    arguments.removeFirst()
    func value(_ name: String) -> String {
        guard let next = arguments.first else { fail("\(name) needs a value") }
        arguments.removeFirst()
        return next
    }
    switch option {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--battery":
        battery = true
    case "--verbose":
        verbose = true
    case "--signal":
        let text = value("--signal")
        guard let parsed = Signal.parse(text) else { fail("unknown signal '\(text)'") }
        signal = parsed
    case "--file":
        signal = .file(URL(fileURLWithPath: value("--file")))
    case "--mode":
        let text = value("--mode")
        guard let parsed = VisualizerMode(rawValue: text) else {
            fail("mode must be one of "
                 + VisualizerMode.allCases.map(\.rawValue).joined(separator: ", ")
                 + ", got '\(text)'")
        }
        mode = parsed
    case "--theme-colour", "--theme-color":
        useThemeColour = true
    case "--sensitivity":
        guard let parsed = Double(value("--sensitivity")) else { fail("--sensitivity needs a number") }
        sensitivity = parsed
    case "--fps":
        guard let parsed = Double(value("--fps")), parsed > 0 else { fail("--fps needs a number") }
        fps = parsed
    case "--duration":
        guard let parsed = Double(value("--duration")), parsed > 0 else {
            fail("--duration needs a number")
        }
        duration = parsed
    case "--jitter":
        guard let parsed = Double(value("--jitter")), parsed >= 0 else {
            fail("--jitter needs milliseconds")
        }
        jitterMilliseconds = parsed
    case "--stall":
        let text = value("--stall")
        let parts = text.split(separator: "@")
        guard parts.count == 2, let length = Double(parts[0]), let rate = Double(parts[1]) else {
            fail("--stall wants <ms>@<hz>, e.g. 200@0.5")
        }
        stall = (length / 1000, rate)
    case "--every":
        guard let parsed = Double(value("--every")), parsed >= 0 else {
            fail("--every needs a number")
        }
        every = parsed
    case "--csv":
        csvPath = value("--csv")
    case "--out":
        outputDirectory = URL(fileURLWithPath: value("--out"))
    default:
        fail("unknown option '\(option)'\n\n" + usage)
    }
}

let sampleRate = 48_000.0

// MARK: - Battery

/// Jitter measured on real hardware is not yet available (§10.5 gap 1), so the
/// battery's jittered arm uses a deliberately pessimistic 8 ms — a quarter of a
/// 30 fps frame. The point of the arm is that the *bounds still hold* when the
/// display wakes late, not that 8 ms is the true distribution.
let batteryJitter = 0.008

if battery {
    var rows: [(String, [Metrics.Check])] = []
    var failures = 0
    var checksRun = 0
    let start = Date()

    print("viz-sim --battery — \(Signal.battery.count) signals × "
          + "\(VisualizerMode.allCases.count) modes × 2 jitter arms, "
          + "\(Int(duration)) s each at \(Int(fps)) fps")
    print("")

    for signal in Signal.battery {
        for mode in VisualizerMode.allCases {
            for jitter in [0.0, batteryJitter] {
                var run = SimRun(signal: signal, mode: mode, sampleRate: sampleRate,
                                 frameRate: fps, duration: duration, jitter: jitter)
                run.sensitivity = sensitivity
                let result: SimRun.Result
                do {
                    result = try run.run()
                } catch {
                    fail(String(describing: error))
                }
                let metrics = Metrics.measure(result, signal: signal)
                let checks = metrics.checks(for: signal, frameInterval: result.frameInterval,
                                            perOnsetMode: mode == .pulse || mode == .ripple)
                let label = "\(signal.name)/\(mode.rawValue)"
                    + (jitter > 0 ? "/jitter" : "")
                rows.append((label, checks))
                checksRun += checks.count
                failures += checks.filter { !$0.passed }.count
            }
        }
    }

    var report = ""
    for (label, checks) in rows {
        let failed = checks.filter { !$0.passed }
        guard verbose || !failed.isEmpty else { continue }
        report += "\n\(label)\n"
        for check in (verbose ? checks : failed) {
            report += String(format: "  %-24@ %-10@ %-16@ %@\n",
                             check.name as NSString, check.value as NSString,
                             check.bound as NSString,
                             (check.passed ? "PASS" : "FAIL") as NSString)
        }
    }
    if !verbose && failures == 0 {
        report += "\nEvery check passed. Run with --verbose to see them.\n"
    }
    print(report)
    print(String(format: "%d checks over %d runs, %d failed, %.0f s",
                 checksRun, rows.count, failures, Date().timeIntervalSince(start)))
    print(failures == 0 ? "BATTERY: PASS" : "BATTERY: FAIL")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Single run

var run = SimRun(signal: signal, mode: mode, sampleRate: sampleRate, frameRate: fps,
                 duration: duration, jitter: jitterMilliseconds / 1000, stall: stall,
                 sensitivity: sensitivity, useThemeColour: useThemeColour)

let result: SimRun.Result
do {
    result = try run.run()
} catch {
    fail(String(describing: error))
}
let metrics = Metrics.measure(result, signal: signal)

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create '\(outputDirectory.path)': \(error.localizedDescription)")
}

let movie: MovieWriter?
do {
    movie = try MovieWriter(url: outputDirectory.appendingPathComponent("animation.mp4"),
                            size: FrameImage.imageSize,
                            frameRate: fps)
} catch {
    fail(String(describing: error))
}

var lastImageTime = -Double.infinity
var imagesWritten = 0
for (index, colors) in result.colors.enumerated() {
    let time = result.frameTimes[index]
    do {
        try movie?.append(try FrameImage.image(colors: colors))
    } catch {
        fail(String(describing: error))
    }
    if every > 0, time - lastImageTime >= every - 1e-9 {
        lastImageTime = time
        let name = String(format: "frame-%06.2fs.png", time)
        do {
            try FrameImage.write(colors: colors,
                                 to: outputDirectory.appendingPathComponent(name))
            imagesWritten += 1
        } catch {
            fail(String(describing: error))
        }
    }
}
do { try movie?.finish() } catch { fail(String(describing: error)) }

if let csvPath {
    var csv = "time," + (0..<(result.levels.first?.count ?? 0)).map { "led\($0)" }
        .joined(separator: ",") + "\n"
    for (index, frame) in result.levels.enumerated() {
        csv += String(format: "%.4f", result.frameTimes[index]) + ","
            + frame.map { String(format: "%.4f", $0) }.joined(separator: ",") + "\n"
    }
    do {
        try csv.write(to: URL(fileURLWithPath: csvPath), atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write '\(csvPath)': \(error.localizedDescription)")
    }
}

var report = """
    viz-sim
      signal:       \(signal.name)
      mode:         \(mode.rawValue)
      duration:     \(String(format: "%.1f", duration)) s at \(Int(fps)) fps \
    (\(result.levels.count) frames, \(result.droppedFrames) dropped)
      jitter:       \(String(format: "%.1f", jitterMilliseconds)) ms
      PNGs written: \(imagesWritten)

    tempo
      median BPM:        \(String(format: "%.1f", percentile(result.bpm, 0.5)))
      mean confidence:   \(String(format: "%.3f", mean(result.tempoConfidence)))

    onsets (\(metrics.onsetCount) total, \(String(format: "%.2f", metrics.onsetRate)) per second)
    """
for kind in OnsetKind.allCases {
    let count = result.detectedOnsets.filter { $0.kind == kind }.count
    report += String(format: "\n      %-6@ %4d  (%.2f/s)", kind.rawValue as NSString, count,
                     Double(count) / max(duration, 0.001))
}

if ProcessInfo.processInfo.environment["VIZ_MISS"] != nil {
    let missed = result.events.filter { $0.kind == .kick }
        .filter { truth in
            !result.detectedOnsets.contains { abs($0.time - truth.time) < 0.05 }
        }
        .map { String(format: "%.2f", $0.time) }
    print("missed kicks (\(missed.count) of "
          + "\(result.events.filter { $0.kind == .kick }.count)): "
          + missed.joined(separator: " "))
}
report += "\n      first: "
    + result.detectedOnsets.prefix(12)
        .map { String(format: "%.2f%@", $0.time, String($0.kind.rawValue.prefix(1))) }
        .joined(separator: " ")
report += "\n\n    metrics\n"
for check in metrics.checks(for: signal, frameInterval: result.frameInterval,
                            perOnsetMode: mode == .pulse || mode == .ripple) {
    report += String(format: "      %-24@ %-10@ %-16@ %@\n",
                     check.name as NSString, check.value as NSString,
                     check.bound as NSString, (check.passed ? "PASS" : "FAIL") as NSString)
}
report += String(format: """

        board mean brightness: %.3f
        frames dropped:        %d
        stale frames:          %.2f%%

    """, metrics.boardMeanBrightness, metrics.droppedFrames, metrics.staleFraction * 100)

do {
    try report.write(to: outputDirectory.appendingPathComponent("stats.txt"),
                     atomically: true, encoding: .utf8)
} catch {
    fail("cannot write stats.txt: \(error.localizedDescription)")
}

print(report)
print("output: \(outputDirectory.path)")
