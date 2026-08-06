import AVFoundation
import Foundation

/// Test signals, so tuning does not need a human, a room and a stereo.
///
/// Each generator returns mono `Float` samples at `sampleRate`. They are chosen
/// to exercise the specific things the live test complained about: `pink` should
/// produce a flat board, `near-silence` should produce a dark one, and
/// `bass-pulses` is the case where the bottom columns pin while the rest stays
/// dark.
enum Signal {
    case sine(frequency: Double)
    case sweep
    case bassPulses
    case white
    case pink
    case nearSilence
    case file(URL)

    static func parse(_ text: String) -> Signal? {
        if text.hasPrefix("sine:") {
            guard let frequency = Double(text.dropFirst("sine:".count)) else { return nil }
            return .sine(frequency: frequency)
        }
        switch text {
        case "sine":         return .sine(frequency: 440)
        case "sweep":        return .sweep
        case "bass-pulses":  return .bassPulses
        case "white":        return .white
        case "pink":         return .pink
        case "near-silence": return .nearSilence
        default:             return nil
        }
    }

    var name: String {
        switch self {
        case .sine(let frequency): return "sine:\(Int(frequency))"
        case .sweep:               return "sweep"
        case .bassPulses:          return "bass-pulses"
        case .white:               return "white"
        case .pink:                return "pink"
        case .nearSilence:         return "near-silence"
        case .file(let url):       return url.lastPathComponent
        }
    }

    /// `duration` seconds of mono samples.
    func samples(sampleRate: Double, duration: Double) throws -> [Float] {
        let count = Int(sampleRate * duration)
        switch self {
        case .sine(let frequency):
            return (0..<count).map { index in
                0.5 * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
            }

        case .sweep:
            // Exponential 20 Hz → 18 kHz: linear in *octaves*, which is what a
            // log-banded display should sweep across evenly.
            let low = 20.0, high = 18_000.0
            return (0..<count).map { index in
                let t = Double(index) / sampleRate
                let progress = min(t / max(duration, 0.001), 1)
                // Phase is the integral of the instantaneous frequency.
                let k = log(high / low)
                let phase = 2 * .pi * low * duration / k * (exp(progress * k) - 1)
                return 0.5 * Float(sin(phase))
            }

        case .bassPulses:
            // ~120 bpm kick-like bursts at 60-90 Hz over a quiet bed, which is
            // the shape of the "low columns pin, board stays dark" complaint.
            var generator = SeededRandom(seed: 7)
            let beat = 60.0 / 120.0
            return (0..<count).map { index in
                let t = Double(index) / sampleRate
                let phase = t.truncatingRemainder(dividingBy: beat)
                let envelope = exp(-phase * 18)
                let frequency = 90 - 30 * min(phase * 8, 1)
                let kick = 0.9 * envelope * sin(2 * .pi * frequency * t)
                let bed = 0.01 * generator.nextGaussian()
                return Float(kick + bed)
            }

        case .white:
            var generator = SeededRandom(seed: 11)
            return (0..<count).map { _ in Float(0.2 * generator.nextGaussian()) }

        case .pink:
            return Self.pinkNoise(count: count, seed: 13, amplitude: 0.2)

        case .nearSilence:
            // -60 dBFS noise: below the gate, and the case where the old build
            // still lit bars.
            var generator = SeededRandom(seed: 17)
            let amplitude = pow(10.0, -60.0 / 20.0)
            return (0..<count).map { _ in Float(amplitude * generator.nextGaussian()) }

        case .file(let url):
            return try Self.readFile(url, sampleRate: sampleRate, duration: duration)
        }
    }

    /// Voss-McCartney pink noise: several octave-spaced random sources summed,
    /// each updated half as often as the one below it. Cheap, and its `1/f`
    /// slope is accurate enough across the display's range to be the reference
    /// the equalisation is tested against.
    static func pinkNoise(count: Int, seed: UInt64, amplitude: Double) -> [Float] {
        var generator = SeededRandom(seed: seed)
        let octaves = 16
        var rows = [Double](repeating: 0, count: octaves)
        for index in rows.indices { rows[index] = generator.nextGaussian() }
        var runningSum = rows.reduce(0, +)

        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            // The lowest set bit of the counter says which row to refresh, so
            // row k changes every 2^k samples.
            let counter = UInt64(index &+ 1)
            let row = counter.trailingZeroBitCount
            if row < octaves {
                runningSum -= rows[row]
                rows[row] = generator.nextGaussian()
                runningSum += rows[row]
            }
            output[index] = Float(amplitude * runningSum / Double(octaves) * 4)
        }
        return output
    }

    private static func readFile(_ url: URL, sampleRate: Double, duration: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw SimError.audioFileUnreadable(url.path)
        }

        let wanted = AVAudioFrameCount(sampleRate * duration)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else {
            throw SimError.audioFileUnreadable(url.path)
        }

        var finished = false
        var error: NSError?
        converter.convert(to: output, error: &error) { packets, status in
            if finished {
                status.pointee = .endOfStream
                return nil
            }
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: packets) else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: packets)
            } catch {
                status.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return input
        }
        if let error { throw SimError.audioFileFailed(url.path, error.localizedDescription) }

        guard let channel = output.floatChannelData?[0] else {
            throw SimError.audioFileUnreadable(url.path)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// A reproducible generator, so two runs of the simulator produce identical
/// numbers and a tuning change is the only thing that can move them.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Box-Muller, so the noise is Gaussian rather than uniform — which matters
    /// for anything measuring a noise floor in dB.
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUniform(), 1e-12)
        let u2 = nextUniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
