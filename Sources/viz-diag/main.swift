import Foundation
import GloriousAudioCapture
import GloriousVisualizer

// viz-diag — starts a capture source and prints what is actually arriving.
//
// This exists because "the visualizer shows nothing" has too many causes to
// guess between: no permission, no frames, frames of silence, or frames that are
// fine and a render bug downstream. It drives the *same* capture objects the app
// uses, so what it reports is what the app would have seen.
//
// A development tool; the app bundle does not contain it.

let usage = """
    viz-diag — check what the visualizer's audio capture is actually receiving

    USAGE:
      viz-diag --source mic|system [--seconds N]

    OPTIONS:
      --source mic|system   Which capture to start (default: mic)
      --seconds <n>         How long to listen (default: 10)
      --interval <s>        Seconds between report lines (default: 0.2)

    OUTPUT:
      One line per interval: frames received, RMS and peak in dBFS, and a level
      meter. Then a verdict, and every OSStatus the transport recorded.

    PERMISSIONS — READ THIS IF YOU GET NOTHING:
      A command-line tool has no bundle of its own, so macOS attributes its
      permission requests to *the terminal application running it*. Whatever you
      launch this from — Terminal, iTerm, an editor's console — is what must
      appear and be enabled in:

        System Settings › Privacy & Security › Microphone        (--source mic)
        System Settings › Privacy & Security › Audio Recording   (--source system)

      That is a different grant from the one the app itself uses, so the app
      working and this tool failing (or the reverse) is expected rather than
      contradictory. There is no API to request the audio-recording permission
      up front: the prompt appears when the tap is created, and a refusal looks
      like a failed tap.

      --source system also needs macOS 14.2 or later, and it captures the global
      output mix — so play something audible while it runs, or every frame is
      legitimately silent.
    """

var sourceName = "mic"
var seconds = 10.0
var interval = 0.2

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("viz-diag: " + message + "\n").data(using: .utf8)!)
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
    case "--source":
        sourceName = value("--source")
    case "--seconds":
        guard let parsed = Double(value("--seconds")), parsed > 0 else {
            fail("--seconds needs a positive number")
        }
        seconds = parsed
    case "--interval":
        guard let parsed = Double(value("--interval")), parsed > 0 else {
            fail("--interval needs a positive number")
        }
        interval = parsed
    default:
        fail("unknown option '\(option)'\n\n" + usage)
    }
}

let source: AudioSource
switch sourceName {
case "mic", "microphone":   source = .microphone
case "system", "systemAudio", "system-audio": source = .systemAudio
default: fail("--source must be mic or system, got '\(sourceName)'")
}

// MARK: - Set up

print("viz-diag: source = \(source.displayName)")
print("          permission needed: \(source.permissionName) "
      + "(granted to the terminal running this, not to this tool)")

let authorization: AudioSourceAuthorization = source == .microphone
    ? AudioCapture.authorization
    : SystemAudio.authorization
print("          authorization before starting: \(authorization)")

if source == .systemAudio && !SystemAudio.isSupported {
    fail("system audio needs macOS 14.2 or later; this system does not have process taps")
}

let capture: AudioSourceCapturing
switch source {
case .microphone:
    let microphone = AudioCapture()
    if AudioCapture.authorization == .undetermined {
        print("          asking for microphone access…")
        let waiter = DispatchSemaphore(value: 0)
        AudioCapture.requestAuthorization { _ in waiter.signal() }
        // The callback lands on the main queue, which nothing is running here,
        // so the run loop is pumped rather than blocked on the semaphore.
        while waiter.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        print("          authorization now: \(AudioCapture.authorization)")
    }
    capture = microphone
case .systemAudio:
    guard let tap = SystemAudio.makeCapture() else {
        fail("could not create a system-audio capture on this system")
    }
    capture = tap
}

// MARK: - Measure

final class Meter {
    private let lock = NSLock()
    private var frames = 0
    private var sumOfSquares = 0.0
    private var peak: Float = 0
    private var callbacks = 0

    func add(_ samples: [Float]) {
        lock.lock()
        frames += samples.count
        callbacks += 1
        for sample in samples {
            sumOfSquares += Double(sample) * Double(sample)
            peak = max(peak, abs(sample))
        }
        lock.unlock()
    }

    /// Reads and clears, so each line describes its own interval.
    func drain() -> (frames: Int, callbacks: Int, rms: Double, peak: Float) {
        lock.lock()
        defer {
            frames = 0
            sumOfSquares = 0
            peak = 0
            callbacks = 0
            lock.unlock()
        }
        let rms = frames > 0 ? sqrt(sumOfSquares / Double(frames)) : 0
        return (frames, callbacks, rms, peak)
    }
}

func decibels(_ amplitude: Double) -> String {
    guard amplitude > 1e-9 else { return "  -inf" }
    return String(format: "%6.1f", 20 * log10(amplitude))
}

/// A 20-character meter spanning -60 dBFS to 0.
func bar(_ amplitude: Double) -> String {
    guard amplitude > 1e-9 else { return String(repeating: "·", count: 20) }
    let db = 20 * log10(amplitude)
    let filled = Int(((db + 60) / 60 * 20).rounded())
    let clamped = min(max(filled, 0), 20)
    return String(repeating: "█", count: clamped) + String(repeating: "·", count: 20 - clamped)
}

let meter = Meter()
capture.onSamples = { meter.add($0) }

do {
    try capture.start()
} catch {
    print("")
    print("FAILED TO START: \(error)")
    for line in SystemAudio.diagnosticLines(for: capture) ?? [] { print("  " + line) }
    print("")
    print("If this is a permission problem, grant the terminal you are running "
          + "this from access under System Settings › Privacy & Security › "
          + "\(source.permissionName).")
    exit(2)
}

print("          started; sample rate \(Int(capture.sampleRate)) Hz")
if source == .systemAudio {
    print("          NOTE: the aggregate device waits for a tapped process to "
          + "produce audio, so play something audible now.")
}
print("")
print("   time  callbacks  frames      rms      peak  level")

var totalFrames = 0
var totalCallbacks = 0
var loudestPeak: Float = 0
let start = Date()

while Date().timeIntervalSince(start) < seconds {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: interval))
    let reading = meter.drain()
    totalFrames += reading.frames
    totalCallbacks += reading.callbacks
    loudestPeak = max(loudestPeak, reading.peak)
    print(String(format: "  %5.1fs  %9d  %6d  %@ dB  %@ dB  %@",
                 Date().timeIntervalSince(start),
                 reading.callbacks,
                 reading.frames,
                 decibels(reading.rms),
                 decibels(Double(reading.peak)),
                 bar(Double(reading.peak))))
}

capture.stop()

// MARK: - Verdict

print("")
if let lines = SystemAudio.diagnosticLines(for: capture) {
    print("process tap")
    for line in lines { print("  " + line) }
    print("")
}

if totalFrames == 0 {
    print("VERDICT: no frames arrived in \(Int(seconds))s (\(totalCallbacks) callbacks).")
    if source == .systemAudio {
        print("  If the IO proc callback count is also zero, the aggregate device never "
              + "ran — most likely nothing was playing, since it waits for a tapped "
              + "process, or the Audio Recording permission was refused.")
        print("  If callbacks arrived but frames did not, the tap is running but capturing "
              + "no processes.")
    } else {
        print("  Check that the terminal running this has Microphone access and that an "
              + "input device is selected in Sound settings.")
    }
    exit(3)
}

print("VERDICT: captured \(totalFrames) frames over \(totalCallbacks) callbacks; "
      + "loudest peak \(decibels(Double(loudestPeak))) dBFS.")
if loudestPeak < 1e-5 {
    print("  Frames arrived but they are digitally silent — capture works, the source "
          + "was not producing audio.")
}
