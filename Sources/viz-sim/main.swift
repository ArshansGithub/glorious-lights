import Foundation
import GMMKProtocol
import GloriousVisualizer

// viz-sim — runs the visualizer's analysis and render pipeline offline, against
// generated signals or an audio file, and writes PNG frames plus statistics.
//
// A development tool, not part of the shipped app: `Scripts/make-app.sh` builds
// only the GMMKLightsApp product, so this never lands in the bundle.
//
// It exists so tuning does not need a human, a keyboard and a stereo. It runs
// the SAME code the app runs — `VisualizerPipeline` and `BarRenderer` — so a
// number measured here is a claim about the app, not about a copy of it.

enum SimError: Error, CustomStringConvertible {
    case usage(String)
    case audioFileUnreadable(String)
    case audioFileFailed(String, String)
    case imageFailed(String)

    var description: String {
        switch self {
        case .usage(let message):            return message
        case .audioFileUnreadable(let path): return "Could not read audio from '\(path)'."
        case .audioFileFailed(let path, let message):
            return "Could not decode '\(path)': \(message)"
        case .imageFailed(let path):         return "Could not write the PNG at '\(path)'."
        }
    }
}

let usage = """
    viz-sim — run the keyboard visualizer offline and look at what it would show

    USAGE:
      viz-sim [options]

    INPUT (one of):
      --signal <name>       Built-in test signal (default: pink)
                              sine:<hz>      a pure tone, e.g. sine:440
                              sweep          20 Hz → 18 kHz over the duration
                              bass-pulses    ~120 bpm kicks at 60-90 Hz over a quiet bed
                              white          white noise
                              pink           pink noise — should give a FLAT board
                              near-silence   -60 dBFS noise — should give a DARK board
      --file <path>         An audio file instead (wav / m4a / mp3 / anything AVAudioFile reads)

    PIPELINE OPTIONS (mirroring the app):
      --style theme|heat    Bar colours (default: heat)
      --sensitivity <x>     Gain multiplier (default: 2.0)
      --agc on|off          Auto gain (default: on)
      --noise-floor <dB>    Gate, in dBFS (default: -50; use -inf to disable)
      --eq on|off           Pink-noise equalisation (default: on)
      --legacy              Shorthand for --eq off --noise-floor -inf: the
                            behaviour before live-test tuning, for comparison

    RUN OPTIONS:
      --fps <n>             Display frame rate (default: 15)
      --duration <seconds>  How much audio to run (default: 10)
      --every <seconds>     How often to write a PNG (default: 0.15; 0 disables)
      --out <directory>     Where PNGs and stats.txt go (default: ./viz-sim-out)

    OUTPUT:
      <out>/frame-<seconds>.png   one per --every of audio
      <out>/stats.txt             per-column mean/max height, a frame-to-frame
                                  delta ("spazz metric"), and the fraction of
                                  frames with any bar lit
    """

// MARK: - Arguments

var signal: Signal = .pink
var style: VisualizerStyle = .heat
var sensitivity = 2.0
var autoGain = true
var noiseFloor = VisualizerPipeline.defaultNoiseFloorDB
var equalization = true
var fps = 15.0
var duration = 10.0
var every = 0.15
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
    case "--signal":
        let text = value("--signal")
        guard let parsed = Signal.parse(text) else { fail("unknown signal '\(text)'") }
        signal = parsed
    case "--file":
        signal = .file(URL(fileURLWithPath: value("--file")))
    case "--style":
        let text = value("--style")
        guard let parsed = VisualizerStyle(rawValue: text) else {
            fail("style must be theme or heat, got '\(text)'")
        }
        style = parsed
    case "--sensitivity":
        guard let parsed = Double(value("--sensitivity")) else { fail("--sensitivity needs a number") }
        sensitivity = parsed
    case "--agc":
        autoGain = value("--agc") != "off"
    case "--noise-floor":
        let text = value("--noise-floor")
        noiseFloor = text == "-inf" ? -.infinity : (Double(text) ?? { fail("bad --noise-floor") }())
    case "--eq":
        equalization = value("--eq") != "off"
    case "--legacy":
        equalization = false
        noiseFloor = -.infinity
    case "--fps":
        guard let parsed = Double(value("--fps")), parsed > 0 else { fail("--fps needs a number") }
        fps = parsed
    case "--duration":
        guard let parsed = Double(value("--duration")), parsed > 0 else {
            fail("--duration needs a number")
        }
        duration = parsed
    case "--every":
        guard let parsed = Double(value("--every")), parsed >= 0 else {
            fail("--every needs a number")
        }
        every = parsed
    case "--out":
        outputDirectory = URL(fileURLWithPath: value("--out"))
    default:
        fail("unknown option '\(option)'\n\n" + usage)
    }
}

// MARK: - Run

let sampleRate = 48_000.0
let bandCount = VisualizerLayout.columns.count

let samples: [Float]
do {
    samples = try signal.samples(sampleRate: sampleRate, duration: duration)
} catch {
    fail(String(describing: error))
}
guard !samples.isEmpty else { fail("the input produced no audio") }

let pipeline = VisualizerPipeline(
    sampleRate: Float(sampleRate),
    bandCount: bandCount,
    tuning: .init(sensitivity: sensitivity,
                  autoGain: autoGain,
                  noiseFloorDB: noiseFloor,
                  equalization: equalization))
let renderer = BarRenderer(style: style, themeColor: RGB(red: 0x00, green: 0xCC, blue: 0xAA))

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create '\(outputDirectory.path)': \(error.localizedDescription)")
}

let frameInterval = 1 / fps
let samplesPerFrame = Int(sampleRate * frameInterval)
let window = SpectrumAnalyzer.windowSize
let frameCount = max(1, samples.count / samplesPerFrame)

var heightsPerFrame: [[Float]] = []
var lastImageTime = -Double.infinity
var imagesWritten = 0

for frame in 0..<frameCount {
    let time = Double(frame) * frameInterval
    // Each display frame analyses the most recent window ending at "now",
    // which is what the live path sees: the audio thread hands over whatever
    // buffer arrived last.
    let end = min((frame + 1) * samplesPerFrame, samples.count)
    let start = max(0, end - window)
    pipeline.analyze(Array(samples[start..<end]))

    let heights = pipeline.advance(elapsed: frameInterval)
    heightsPerFrame.append(heights)

    if every > 0, time - lastImageTime >= every - 1e-9 {
        lastImageTime = time
        let name = String(format: "frame-%06.2fs.png", time)
        do {
            try FrameImage.write(colors: renderer.frame(levels: heights),
                                 to: outputDirectory.appendingPathComponent(name))
            imagesWritten += 1
        } catch {
            fail(String(describing: error))
        }
    }
}

// MARK: - Statistics

func mean(_ values: [Float]) -> Double {
    values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
}

var columnMeans = [Double](repeating: 0, count: bandCount)
var columnMaxima = [Float](repeating: 0, count: bandCount)
for heights in heightsPerFrame {
    for column in 0..<bandCount {
        columnMeans[column] += Double(heights[column])
        columnMaxima[column] = max(columnMaxima[column], heights[column])
    }
}
for column in 0..<bandCount { columnMeans[column] /= Double(heightsPerFrame.count) }

// Spazz metric: mean absolute change per column per frame. High means the bars
// are jittering rather than moving.
var totalDelta = 0.0
for index in 1..<max(heightsPerFrame.count, 1) {
    let previous = heightsPerFrame[index - 1]
    let current = heightsPerFrame[index]
    for column in 0..<bandCount {
        totalDelta += Double(abs(current[column] - previous[column]))
    }
}
let deltaPerColumnFrame = heightsPerFrame.count > 1
    ? totalDelta / Double((heightsPerFrame.count - 1) * bandCount)
    : 0

// Any bar lit at all — the near-silence check, and a useful sanity number for
// every other signal too.
let litFrames = heightsPerFrame.filter { heights in
    heights.contains { BarRenderer.rowsLit(level: $0, rowCount: 5) > 0 }
}.count
let litFraction = Double(litFrames) / Double(heightsPerFrame.count)

// Flatness: how evenly the energy is spread across the board. 1.0 is perfectly
// flat; the pink-noise case is the one that should approach it.
let overallMean = columnMeans.reduce(0, +) / Double(bandCount)
let spread = overallMean > 0
    ? (columnMeans.max()! - columnMeans.min()!) / overallMean
    : 0

var report = """
    viz-sim
      signal:       \(signal.name)
      duration:     \(String(format: "%.1f", duration)) s at \(Int(fps)) fps \
    (\(heightsPerFrame.count) frames)
      style:        \(style.rawValue)
      sensitivity:  \(String(format: "%.2f", sensitivity))
      auto gain:    \(autoGain ? "on" : "off")
      noise floor:  \(noiseFloor == -.infinity ? "disabled" : String(format: "%.0f dBFS", noiseFloor))
      equalisation: \(equalization ? "on" : "off")
      PNGs written: \(imagesWritten)

    per-column bar height (0-1)
      column   mean    max
    """
for column in 0..<bandCount {
    report += String(format: "\n      %2d     %.3f  %.3f",
                     column + 1, columnMeans[column], Double(columnMaxima[column]))
}
report += """


    summary
      mean height overall:      \(String(format: "%.4f", overallMean))
      spread (max-min)/mean:    \(String(format: "%.3f", spread))  (0 = perfectly flat board)
      frame-to-frame delta:     \(String(format: "%.4f", deltaPerColumnFrame))  (absolute)
      delta / mean height:      \(String(format: "%.3f", overallMean > 0 ? deltaPerColumnFrame / overallMean : 0))  \
    (spazz metric — scale-free, so it is comparable across settings that change bar height)
      frames with any bar lit:  \(String(format: "%.1f%%", litFraction * 100))

    """

do {
    try report.write(to: outputDirectory.appendingPathComponent("stats.txt"),
                     atomically: true, encoding: .utf8)
} catch {
    fail("cannot write stats.txt: \(error.localizedDescription)")
}

print(report)
print("output: \(outputDirectory.path)")
