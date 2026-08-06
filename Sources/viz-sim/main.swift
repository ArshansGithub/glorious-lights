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
      --mode <name>         pulse | wave | ripple | spectrum | vu (default: pulse)
      --theme-colour        Paint in the desk colour instead of the brightness ramp
      --sensitivity <x>     Gain multiplier on top of the normalisation (default: 1.0)
      --agc on|off          Auto gain (default: on)
      --gate-margin <dB>    How far above the observed noise floor a band must sit
                            to count as signal (default: 9; use -inf to disable)
      --eq on|off           Pink-noise equalisation (default: on)
      --legacy              Shorthand for --eq off --gate-margin -inf with a flat
                            2x gain: the behaviour before live-test tuning

    RUN OPTIONS:
      --fps <n>             Display frame rate (default: 15)
      --duration <seconds>  How much audio to run (default: 10)
      --every <seconds>     How often to write a PNG (default: 0.15; 0 disables)
      --out <directory>     Where PNGs and stats.txt go (default: ./viz-sim-out)

    OUTPUT:
      <out>/animation.mp4         every frame at --fps — watch this, stills cannot
                                  show whether it flows with the music
      <out>/frame-<seconds>.png   one per --every of audio (0 disables)
      <out>/stats.txt             tempo, onsets, gesture coherence and levels
    """

// MARK: - Arguments

var signal: Signal = .pink
var mode: VisualizerMode = .pulse
var useThemeColour = false
var sensitivity = 1.0
var autoGain = true
var gateMargin = VisualizerPipeline.defaultGateMarginDB
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
    case "--agc":
        autoGain = value("--agc") != "off"
    case "--gate-margin":
        let text = value("--gate-margin")
        gateMargin = text == "-inf" ? -.infinity : (Double(text) ?? { fail("bad --gate-margin") }())
    case "--eq":
        equalization = value("--eq") != "off"
    case "--legacy":
        equalization = false
        gateMargin = -.infinity
        sensitivity = 2.0
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
                  gateMarginDB: gateMargin,
                  equalization: equalization))
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create '\(outputDirectory.path)': \(error.localizedDescription)")
}

let frameInterval = 1 / fps
let samplesPerFrame = Int(sampleRate * frameInterval)
let frameCount = max(1, samples.count / samplesPerFrame)

let renderer = ModeRenderer(mode: mode,
                            themeColor: RGB(red: 0x00, green: 0xCC, blue: 0xAA),
                            useThemeColor: useThemeColour)

var heightsPerFrame: [[Float]] = []
var referencePerFrame: [Float] = []
var floorPerFrame: [Float] = []
var litFractionPerFrame: [Double] = []
var coherencePerFrame: [Double] = []
var bpmSamples: [Double] = []
var confidenceSamples: [Double] = []
var onsetCounts: [OnsetKind: Int] = [:]
var lastImageTime = -Double.infinity
var imagesWritten = 0

let movie: MovieWriter?
do {
    movie = try MovieWriter(url: outputDirectory.appendingPathComponent("animation.mp4"),
                            size: FrameImage.imageSize,
                            frameRate: fps)
} catch {
    fail(String(describing: error))
}

/// Measures the *shape* of the bright region: how much of the board is
/// meaningfully lit, and whether those columns form runs rather than specks.
///
/// The threshold is relative to the frame's own brightest key, not absolute.
/// Most modes paint a dim ambient bed so the board is never dead, which means
/// almost every key is technically non-black — measuring that would report
/// perfect coherence for a mode that was in fact producing confetti on top of a
/// wash. What matters is the shape a viewer actually sees.
func gestureCoherence(_ colors: [RGB]) -> (lit: Double, coherence: Double) {
    func luminance(_ color: RGB) -> Double {
        (0.2126 * Double(color.red) + 0.7152 * Double(color.green)
         + 0.0722 * Double(color.blue)) / 255
    }
    let peak = colors.map(luminance).max() ?? 0
    guard peak > 0.02 else { return (0, 1) }
    let threshold = peak * 0.45

    var columnLit = [Bool](repeating: false, count: VisualizerLayout.columns.count)
    var litKeys = 0
    var totalKeys = 0
    for (index, column) in VisualizerLayout.columns.enumerated() {
        for row in column.levelRows {
            for led in row {
                totalKeys += 1
                let offset = Int(led) - Int(GMMKKeyMap.minLEDIndex)
                guard colors.indices.contains(offset),
                      luminance(colors[offset]) >= threshold else { continue }
                litKeys += 1
                columnLit[index] = true
            }
        }
    }
    guard litKeys > 0 else { return (0, 1) }

    // Walk the columns, measuring how many lit ones sit in runs of >= 2.
    var inRun = 0
    var coherent = 0
    for lit in columnLit {
        if lit {
            inRun += 1
        } else {
            if inRun >= 2 { coherent += inRun }
            inRun = 0
        }
    }
    if inRun >= 2 { coherent += inRun }
    let litColumns = columnLit.filter { $0 }.count
    return (Double(litKeys) / Double(totalKeys),
            litColumns > 0 ? Double(coherent) / Double(litColumns) : 1)
}

for frame in 0..<frameCount {
    let time = Double(frame) * frameInterval
    let end = min((frame + 1) * samplesPerFrame, samples.count)
    let start = max(0, end - samplesPerFrame)
    pipeline.analyze(Array(samples[start..<end]))

    let musical = pipeline.musicalFrame(elapsed: frameInterval)
    heightsPerFrame.append(musical.bandLevels)
    referencePerFrame.append(pipeline.lastReference)
    if !pipeline.lastNoiseFloor.isEmpty {
        floorPerFrame.append(pipeline.lastNoiseFloor.reduce(0, +)
                             / Float(pipeline.lastNoiseFloor.count))
    }
    for (kind, strength) in musical.onsets where strength > 0 {
        onsetCounts[kind, default: 0] += 1
    }
    if musical.tempo.bpm > 0 {
        bpmSamples.append(musical.tempo.bpm)
        confidenceSamples.append(musical.tempo.confidence)
    }

    let colors = renderer.render(musical, elapsed: frameInterval)
    let measured = gestureCoherence(colors)
    litFractionPerFrame.append(measured.lit)
    coherencePerFrame.append(measured.coherence)

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

// MARK: - Statistics

func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

let bpmMean = mean(bpmSamples)
let bpmSorted = bpmSamples.sorted()
let bpmMedian = bpmSorted.isEmpty ? 0 : bpmSorted[bpmSorted.count / 2]
// Fraction of frames sitting within 3% of the median — a far better read than
// standard deviation, which is dominated by the seconds before the estimate
// first settles.
let bpmSettled = bpmSamples.isEmpty ? 0
    : Double(bpmSamples.filter { abs($0 - bpmMedian) / max(bpmMedian, 1) < 0.03 }.count)
        / Double(bpmSamples.count)
// Where it ended up, which is what a listener would have seen most of.
let bpmFinal = bpmSamples.last ?? 0
// Stability matters more than the absolute value: a tempo that wanders is
// useless to a mode trying to lock to it.
let bpmDeviation = bpmSamples.count > 1
    ? sqrt(mean(bpmSamples.map { ($0 - bpmMean) * ($0 - bpmMean) }))
    : 0
let totalOnsets = onsetCounts.values.reduce(0, +)
let durationSeconds = Double(heightsPerFrame.count) * frameInterval

var report = """
    viz-sim
      signal:       \(signal.name)
      mode:         \(mode.rawValue)
      duration:     \(String(format: "%.1f", durationSeconds)) s at \(Int(fps)) fps \
    (\(heightsPerFrame.count) frames)
      sensitivity:  \(String(format: "%.2f", sensitivity))
      auto gain:    \(autoGain ? "on" : "off")
      gate margin:  \(gateMargin == -.infinity ? "disabled" : String(format: "%.0f dB above floor", gateMargin))
      equalisation: \(equalization ? "on" : "off")
      PNGs written: \(imagesWritten)

    tempo
      median BPM:          \(String(format: "%.1f", bpmMedian))
      final BPM:           \(String(format: "%.1f", bpmFinal))
      mean BPM:            \(String(format: "%.1f", bpmMean))
      within 3% of median: \(String(format: "%.1f%%", bpmSettled * 100))  (high = stable lock)
      BPM std deviation:   \(String(format: "%.2f", bpmDeviation))
      mean confidence:     \(String(format: "%.3f", mean(confidenceSamples)))
      frames with a tempo: \(bpmSamples.count) of \(heightsPerFrame.count)

    onsets (\(totalOnsets) total, \(String(format: "%.2f", Double(totalOnsets) / max(durationSeconds, 0.001))) per second)
    """
for kind in OnsetKind.allCases {
    let count = onsetCounts[kind] ?? 0
    report += String(format: "\n      %-6@ %4d  (%.2f/s)", kind.rawValue as NSString, count,
                     Double(count) / max(durationSeconds, 0.001))
}

report += """


    gesture
      mean lit fraction:   \(String(format: "%.3f", mean(litFractionPerFrame)))  (of all level keys)
      gesture coherence:   \(String(format: "%.3f", mean(coherencePerFrame)))  \
    (1 = every lit column sits in a run of 2+, 0 = confetti)

    levelling
      mean noise floor:         \(String(format: "%.6f", floorPerFrame.isEmpty ? 0 : Double(floorPerFrame.reduce(0, +)) / Double(floorPerFrame.count)))
      final loudness reference: \(String(format: "%.6f", Double(referencePerFrame.last ?? 0)))

    """

do {
    try report.write(to: outputDirectory.appendingPathComponent("stats.txt"),
                     atomically: true, encoding: .utf8)
} catch {
    fail("cannot write stats.txt: \(error.localizedDescription)")
}

print(report)
print("output: \(outputDirectory.path)")
