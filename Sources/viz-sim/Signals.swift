import AVFoundation
import Foundation
import GloriousVisualizer

/// One generated test case: audio plus the ground truth of what is in it.
///
/// The event list is the whole point. Without it "did the visualizer respond to
/// that hit" is a matter of opinion, which is how a detector that emitted 12.1
/// onsets per second on a pure sine wave survived a tuning pass.
struct Track {
    var samples: [Float]
    /// Every percussive event actually synthesised, in seconds.
    var events: [(time: Double, kind: OnsetKind)] = []
    /// Whether this case contains a periodic beat at all.
    var hasBeat = false
    /// Whether the case is stationary — the board is *supposed* to be still.
    var isStationary = false
    /// Whether the case is silent enough that a dark board is correct.
    var isSilence = false
}

/// The synthetic battery (§10.1).
///
/// Every case is generated: no copyrighted audio, no machine-specific files,
/// reproducible on any machine and in CI. They span the failure axes rather than
/// whatever two songs happened to be on the developer's laptop — which is the
/// methodology objection this redesign answers, not a detail of it.
enum Signal {
    /// Four-on-the-floor, 128 BPM. The main case: beat lock and gesture pacing.
    case edm128
    /// Kick-only variant, for the arbiter's phantom-snare test.
    case edm128KickOnly
    /// Sparse acoustic, 72 BPM, 18 dB crest factor, 2 s gaps. "Does it die on
    /// quiet material?"
    case ballad72
    /// Formant-modulated noise, 3–6 syllables/s, **no periodic beat**.
    case speech
    /// −45 dBFS → −6 dBFS over 20 s and back. AGC breathing and floor tracking.
    case crescendo
    /// Loud → silence → quiet → hard cut → loud, twice. Gate ramp-out and AGC
    /// recovery.
    case cutTransitions
    /// A steady sine. The ground-truth case: **zero onsets required.** Three
    /// registers, run separately rather than as segments of one file — a tone
    /// *starting* is a real onset, and the design's long average takes four
    /// seconds to forget the previous one, so segmenting would spend most of the
    /// run measuring the transitions rather than the stationary state.
    case sustainedTone(frequency: Double)
    case pink
    case white
    /// −60 dBFS noise. Must stay dark; must not be amplified into fireworks.
    case nearSilence
    /// Double-time breakbeat, 174 BPM. Gesture durations must stretch.
    case dnb174
    /// 3-against-4. Ambiguous tempo; must not free-run a wrong grid.
    case polyrhythm
    case file(URL)

    /// The battery, in the order it is reported.
    static let battery: [Signal] = [
        .edm128, .edm128KickOnly, .ballad72, .speech, .crescendo, .cutTransitions,
        .sustainedTone(frequency: 110), .sustainedTone(frequency: 440),
        .sustainedTone(frequency: 1_000),
        .pink, .white, .nearSilence, .dnb174, .polyrhythm,
    ]

    static func parse(_ text: String) -> Signal? {
        switch text {
        case "edm-128":         return .edm128
        case "edm-128-kick":    return .edm128KickOnly
        case "ballad-72":       return .ballad72
        case "speech":          return .speech
        case "crescendo":       return .crescendo
        case "cut-transitions": return .cutTransitions
        case "sustained-tone":  return .sustainedTone(frequency: 440)
        case "sustained-tone-110": return .sustainedTone(frequency: 110)
        case "sustained-tone-1k":  return .sustainedTone(frequency: 1_000)
        case "pink":            return .pink
        case "white":           return .white
        case "near-silence":    return .nearSilence
        case "dnb-174":         return .dnb174
        case "polyrhythm":      return .polyrhythm
        default:                return nil
        }
    }

    var name: String {
        switch self {
        case .edm128:          return "edm-128"
        case .edm128KickOnly:  return "edm-128-kick"
        case .ballad72:        return "ballad-72"
        case .speech:          return "speech"
        case .crescendo:       return "crescendo"
        case .cutTransitions:  return "cut-transitions"
        case .sustainedTone(let frequency): return "sustained-tone-\(Int(frequency))"
        case .pink:            return "pink"
        case .white:           return "white"
        case .nearSilence:     return "near-silence"
        case .dnb174:          return "dnb-174"
        case .polyrhythm:      return "polyrhythm"
        case .file(let url):   return url.lastPathComponent
        }
    }

    /// Musical cases carry the M4 hold bounds; stationary and silent ones are
    /// exempt, because inert is the correct answer there.
    var isMusical: Bool {
        switch self {
        case .sustainedTone, .pink, .white, .nearSilence: return false
        default: return true
        }
    }

    /// Cases the M2 *lower* bound applies to — the three the design names. The
    /// bound exists to catch a visualizer that has been smoothed into
    /// inertness, and it is stated against material that is continuously
    /// playing; a case built out of hard cuts and silences spends much of its
    /// run correctly showing nothing.
    var carriesLivelinessBound: Bool {
        switch self {
        case .edm128, .ballad72, .crescendo: return true
        default: return false
        }
    }

    /// Cases the latency bounds apply to — the three the design names (§10.3,
    /// "rhythmic cases"). The kick-only variant is deliberately not one of them:
    /// it exists to test the arbiter's phantom-snare rate, and stripping a track
    /// of everything but its kick makes every detector miss a total miss with no
    /// other evidence of the beat, which measures the synthesised kick rather
    /// than the pipeline.
    var isRhythmic: Bool {
        switch self {
        case .edm128, .ballad72, .dnb174: return true
        default: return false
        }
    }

    /// Whether the case has a steady state at all.
    ///
    /// M6 bounds the *mean* of AVERAGE_RELATIVE, which is a statement about a
    /// signal whose level is statistically stationary. Two cases are built to
    /// have no steady state — a 39 dB crescendo and a sequence of hard cuts —
    /// and for them a short-over-long ratio above 1 is the correct answer, not a
    /// normalisation failure: the long average is *supposed* to lag a level that
    /// is deliberately still moving. They are covered instead by the
    /// cross-case brightness bound, which is the half of M6 that actually asks
    /// "does this need a per-genre constant".
    var hasSteadyState: Bool {
        switch self {
        case .crescendo, .cutTransitions: return false
        default: return true
        }
    }

    /// Cases that must produce exactly zero onsets.
    var mustBeSilentOfOnsets: Bool {
        switch self {
        case .sustainedTone, .pink, .white, .nearSilence: return true
        default: return false
        }
    }

    func track(sampleRate: Double, duration: Double) throws -> Track {
        var synth = Synth(sampleRate: sampleRate, duration: duration, seed: seed)
        switch self {
        case .edm128:         return synth.edm(bpm: 128, kickOnly: false)
        case .edm128KickOnly: return synth.edm(bpm: 128, kickOnly: true)
        case .ballad72:       return synth.ballad(bpm: 72)
        case .speech:         return synth.speech()
        case .crescendo:      return synth.crescendo()
        case .cutTransitions: return synth.cutTransitions()
        case .sustainedTone(let frequency): return synth.sustainedTone(frequency)
        case .pink:           return synth.noise(kind: .pink, amplitude: 0.2)
        case .white:          return synth.noise(kind: .white, amplitude: 0.2)
        case .nearSilence:    return synth.noise(kind: .white,
                                                 amplitude: pow(10, -60.0 / 20))
        case .dnb174:         return synth.breakbeat(bpm: 174)
        case .polyrhythm:     return synth.polyrhythm()
        case .file(let url):
            return Track(samples: try Synth.readFile(url, sampleRate: sampleRate,
                                                     duration: duration))
        }
    }

    /// FNV-1a over the case's name, **not** `String.hashValue`: Swift seeds its
    /// hasher per process, so the same case would generate different noise on
    /// every run and the battery would not be reproducible — which is the first
    /// thing the design asks of it.
    private var seed: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash | 1
    }
}

/// A small offline synthesiser: enough drums, tones and noise to build the
/// battery, and nothing more.
struct Synth {
    let sampleRate: Double
    let duration: Double
    var random: SeededRandom
    var buffer: [Float]

    init(sampleRate: Double, duration: Double, seed: UInt64) {
        self.sampleRate = sampleRate
        self.duration = duration
        self.random = SeededRandom(seed: seed)
        self.buffer = [Float](repeating: 0, count: Int(sampleRate * duration))
    }

    var count: Int { buffer.count }
    func index(_ time: Double) -> Int { Int(time * sampleRate) }

    mutating func add(at time: Double, length: Double, _ body: (Double) -> Double) {
        let start = index(time)
        let samples = Int(length * sampleRate)
        guard start < count else { return }
        for offset in 0..<samples {
            let position = start + offset
            guard position >= 0, position < count else { continue }
            buffer[position] += Float(body(Double(offset) / sampleRate))
        }
    }

    /// A kick: 12 ms attack, 180 ms decay, a sine dropping from 90 to 50 Hz.
    mutating func kick(at time: Double, amplitude: Double = 0.9, decay: Double = 0.18) {
        var phase = 0.0
        let rate = sampleRate
        add(at: time, length: decay * 4) { u in
            let envelope = (1 - exp(-u / 0.012)) * exp(-u / decay)
            let frequency = 50 + 40 * exp(-u / 0.03)
            phase += 2 * .pi * frequency / rate
            return amplitude * envelope * sin(phase)
        }
    }

    /// A snare: a 200 Hz body plus band-limited noise.
    mutating func snare(at time: Double, amplitude: Double = 0.6, decay: Double = 0.12) {
        var noise = [Double](repeating: 0, count: Int(decay * 6 * sampleRate))
        for index in noise.indices { noise[index] = random.nextGaussian() }
        // Two poles, so the noise really is band-limited: a single pole leaves
        // enough energy at 8 kHz that the synthetic snare is half a hi-hat.
        noise = Filters.lowPass(Filters.lowPass(noise, cutoff: 3_000, sampleRate: sampleRate),
                                cutoff: 3_000, sampleRate: sampleRate)
        noise = Filters.highPass(noise, cutoff: 180, sampleRate: sampleRate)
        var offset = 0
        add(at: time, length: decay * 5) { u in
            let envelope = (1 - exp(-u / 0.004)) * exp(-u / decay)
            let body = 0.5 * sin(2 * .pi * 200 * u)
            let hiss = offset < noise.count ? noise[offset] : 0
            offset += 1
            return amplitude * envelope * (body + 0.9 * hiss)
        }
    }

    /// A hat: a short burst of noise with everything below 6 kHz removed, so it
    /// lands in band 7 and nowhere else.
    mutating func hat(at time: Double, amplitude: Double = 0.35, decay: Double = 0.035) {
        var noise = [Double](repeating: 0, count: Int(decay * 8 * sampleRate) + 8)
        for index in noise.indices { noise[index] = random.nextGaussian() }
        noise = Filters.highPass(Filters.highPass(noise, cutoff: 6_000, sampleRate: sampleRate),
                                 cutoff: 6_000, sampleRate: sampleRate)
        var offset = 0
        add(at: time, length: decay * 6) { u in
            let envelope = exp(-u / decay)
            let value = offset < noise.count ? noise[offset] : 0
            offset += 1
            return amplitude * envelope * value
        }
    }

    /// A harmonic stack — strings, a piano note, a saw bass, depending on the
    /// harmonic weighting and the envelope.
    mutating func tone(at time: Double, frequency: Double, amplitude: Double,
                       length: Double, harmonics: Int = 8,
                       attack: Double = 0.01, decay: Double = 1.0,
                       vibrato: Double = 0) {
        add(at: time, length: length) { u in
            let envelope = (1 - exp(-u / attack)) * exp(-u / decay)
            var value = 0.0
            let wobble = vibrato > 0 ? 1 + vibrato * sin(2 * .pi * 5.2 * u) : 1
            for harmonic in 1...harmonics {
                value += sin(2 * .pi * frequency * wobble * Double(harmonic) * u)
                    / Double(harmonic)
            }
            return amplitude * envelope * value / 2
        }
    }

    // MARK: - Cases

    mutating func edm(bpm: Double, kickOnly: Bool) -> Track {
        var track = Track(samples: [], hasBeat: true)
        let beat = 60 / bpm
        var time = 0.0
        var index = 0
        while time < duration {
            kick(at: time)
            track.events.append((time, .kick))
            if !kickOnly {
                if index % 4 == 1 || index % 4 == 3 {
                    snare(at: time)
                    track.events.append((time, .snare))
                }
                hat(at: time + beat / 2)
                track.events.append((time + beat / 2, .hat))
            }
            time += beat
            index += 1
        }
        // A genuinely *sustained* saw bass, side-chained to the kick: one note
        // per bar, ducked and recovering rather than re-attacked. A bass that
        // re-attacks on every eighth is a rhythm part in its own right and would
        // make the "phantom snare" measurement a statement about the test signal
        // rather than about the arbiter.
        let rate = sampleRate
        add(at: 0, length: duration) { u in
            // One note for the whole run: a note change is a real onset, and
            // the phantom-snare measurement is supposed to be about the kick.
            let note = 55.0
            // A raised-cosine recovery rather than an exponential one: a real
            // side-chain releases smoothly, and an exponential's knee is a
            // transient in its own right — the test would then be measuring the
            // generator's release shape rather than the arbiter.
            // Not side-chained: a duck is a rise, and a synthetic duck's
            // recovery shape would decide the phantom-snare measurement instead
            // of the arbiter. A flat sustained bass is the harder test anyway —
            // it is the "sustained bass reads as a stream of hits" failure.
            let duck = 1.0
            var value = 0.0
            for harmonic in 1...6 {
                value += sin(2 * .pi * note * Double(harmonic) * u) / Double(harmonic)
            }
            _ = rate
            return 0.30 * duck * value / 2
        }
        track.samples = buffer
        return track
    }

    mutating func ballad(bpm: Double) -> Track {
        var track = Track(samples: [], hasBeat: true)
        let beat = 60 / bpm
        let bar = beat * 4
        var time = 0.0
        var barIndex = 0
        while time < duration {
            // Every fourth bar carries a two-second gap — the design's number —
            // rather than falling silent for the whole bar: a quarter of the run
            // in silence would make every statistic a statement about the gaps.
            let silent = barIndex % 4 == 3
            let playedSteps = silent ? 2 : 4
            if true {
                for step in 0..<playedSteps {
                    let at = time + Double(step) * beat
                    guard at < duration else { break }
                    if step == 0 || step == 2 {
                        kick(at: at, amplitude: 0.45, decay: 0.14)
                        track.events.append((at, .kick))
                    }
                    if step == 1 || step == 3 {
                        snare(at: at, amplitude: 0.22, decay: 0.09)
                        track.events.append((at, .snare))
                    }
                }
                // A decaying guitar-like stack, quiet between the hits: this is
                // where an 18 dB crest factor comes from.
                tone(at: time, frequency: 196 * (barIndex % 2 == 0 ? 1 : 1.25),
                     amplitude: 0.12, length: bar * Double(playedSteps) / 4,
                     harmonics: 10, attack: 0.005, decay: 0.9)
            }
            time += bar
            barIndex += 1
        }
        track.samples = buffer
        return track
    }

    mutating func speech() -> Track {
        // Voiced syllables: a pulse train through two formant resonators, with
        // natural pauses and no periodic structure at the beat scale.
        //
        // Syllables run **into each other inside a word** and the pauses fall
        // between words. Isolating every syllable with a gap turns speech into a
        // percussion part, which is a statement about the generator rather than
        // about the visualizer.
        var time = 0.2
        var syllablesLeft = 0
        while time < duration {
            let syllable = 0.10 + random.nextUniform() * 0.16
            let f0 = 95 + random.nextUniform() * 70
            let formant1 = 400 + random.nextUniform() * 400
            let formant2 = 1_200 + random.nextUniform() * 1_100
            var pulse = [Double](repeating: 0, count: Int(syllable * sampleRate) + 1)
            var phase = 0.0
            for index in pulse.indices {
                phase += f0 / sampleRate
                if phase >= 1 { phase -= 1; pulse[index] = 1 }
                pulse[index] += 0.15 * random.nextGaussian()
            }
            let voiced = Filters.resonate(Filters.resonate(pulse, frequency: formant1,
                                                           q: 8, sampleRate: sampleRate),
                                          frequency: formant2, q: 6, sampleRate: sampleRate)
            var offset = 0
            add(at: time, length: syllable) { u in
                // 60 ms: a voiced syllable does not start like a drum.
                let envelope = min(u / 0.06, 1) * min((syllable - u) / 0.06, 1)
                let value = offset < voiced.count ? voiced[offset] : 0
                offset += 1
                return 0.45 * max(0, envelope) * value
            }
            if syllablesLeft <= 0 {
                syllablesLeft = 2 + Int(random.nextUniform() * 4)
                time += syllable + 0.18 + random.nextUniform() * 0.35   // between words
            } else {
                syllablesLeft -= 1
                time += syllable * 0.9                                   // within a word
            }
        }
        return Track(samples: buffer)
    }

    mutating func crescendo() -> Track {
        // A string-like stack swelling from -45 dBFS to -6 dBFS over two thirds
        // of the run and back down over the rest, with chord changes so the
        // board has something to move to besides the overall level.
        let up = duration * 2 / 3
        let chord: [Double] = [146.8, 174.6, 220.0, 293.7]
        var time = 0.0
        var step = 0
        while time < duration {
            let length = 1.6
            let progress = time < up ? time / up : 1 - (time - up) / max(duration - up, 0.001)
            let db = -45 + 39 * clamp(progress, 0, 1)
            let amplitude = pow(10, db / 20)
            for (voice, note) in chord.enumerated() {
                tone(at: time, frequency: note * (step % 3 == 1 ? 1.2 : 1) * (voice == 3 ? 2 : 1),
                     amplitude: amplitude * 0.5, length: length * 1.4, harmonics: 8,
                     attack: 0.25, decay: 1.4, vibrato: 0.004)
            }
            time += length
            step += 1
        }
        return Track(samples: buffer)
    }

    mutating func cutTransitions() -> Track {
        var track = Track(samples: [])
        // 5 s loud EDM, 0.5 s digital silence, 5 s quiet piano, hard cut, twice.
        let block = duration / 2
        for half in 0..<2 {
            let base = Double(half) * block
            let beat = 60.0 / 128
            var time = base
            while time < base + block * 0.45 {
                kick(at: time)
                track.events.append((time, .kick))
                hat(at: time + beat / 2)
                track.events.append((time + beat / 2, .hat))
                tone(at: time, frequency: 55, amplitude: 0.30, length: beat,
                     harmonics: 6, attack: 0.05, decay: 0.3)
                time += beat
            }
            // 0.5 s of nothing, then a quiet piano figure at about -34 dBFS.
            time = base + block * 0.5
            var note = 0
            while time < base + block * 0.95 {
                tone(at: time, frequency: 261.6 * pow(2, Double(note % 5) / 12),
                     amplitude: 0.02, length: 0.6, harmonics: 12,
                     attack: 0.004, decay: 0.5)
                time += 0.4
                note += 1
            }
        }
        track.samples = buffer
        return track
    }

    mutating func sustainedTone(_ frequency: Double) -> Track {
        // The ground-truth case: a signal containing exactly zero onsets, on
        // which the old detector emitted 12.1 per second.
        let length = duration
        add(at: 0, length: length) { u in
            let fade = min(u / 0.02, 1) * min((length - u) / 0.02, 1)
            return 0.5 * max(0, fade) * sin(2 * .pi * frequency * u)
        }
        return Track(samples: buffer, isStationary: true)
    }

    enum NoiseKind { case white, pink }

    mutating func noise(kind: NoiseKind, amplitude: Double) -> Track {
        switch kind {
        case .white:
            for index in buffer.indices { buffer[index] = Float(amplitude * random.nextGaussian()) }
        case .pink:
            buffer = Self.pinkNoise(count: count, generator: &random, amplitude: amplitude)
        }
        return Track(samples: buffer, isStationary: true,
                     isSilence: amplitude < 0.01)
    }

    mutating func breakbeat(bpm: Double) -> Track {
        var track = Track(samples: [], hasBeat: true)
        let beat = 60 / bpm
        let bar = beat * 4
        var time = 0.0
        while time < duration {
            // An amen-ish pattern: kick on 1 and the "and" of 3, snare on 2 and 4.
            kick(at: time, amplitude: 0.85, decay: 0.12)
            track.events.append((time, .kick))
            snare(at: time + beat, amplitude: 0.55, decay: 0.10)
            track.events.append((time + beat, .snare))
            kick(at: time + beat * 2.5, amplitude: 0.7, decay: 0.12)
            track.events.append((time + beat * 2.5, .kick))
            snare(at: time + beat * 3, amplitude: 0.55, decay: 0.10)
            track.events.append((time + beat * 3, .snare))
            for sixteenth in 0..<8 {
                let at = time + Double(sixteenth) * beat / 2
                guard at < duration else { break }
                hat(at: at, amplitude: 0.22)
                track.events.append((at, .hat))
            }
            tone(at: time, frequency: 41.2, amplitude: 0.25, length: bar,
                 harmonics: 5, attack: 0.02, decay: 1.2)
            time += bar
        }
        track.samples = buffer
        return track
    }

    mutating func polyrhythm() -> Track {
        // Three against four over the same span: two periodicities, neither of
        // which is "the" tempo. A grid locked to either is visibly wrong, so the
        // right behaviour is low confidence and envelope-driven gestures.
        var track = Track(samples: [])
        let span = 1.5
        var time = 0.0
        while time < duration {
            for step in 0..<3 {
                let at = time + Double(step) * span / 3
                guard at < duration else { break }
                kick(at: at, amplitude: 0.6, decay: 0.12)
                track.events.append((at, .kick))
            }
            for step in 0..<4 {
                let at = time + Double(step) * span / 4
                guard at < duration else { break }
                hat(at: at, amplitude: 0.3)
                track.events.append((at, .hat))
            }
            time += span
        }
        track.samples = buffer
        return track
    }

    // MARK: - Helpers

    /// Voss-McCartney pink noise: octave-spaced random sources summed, each
    /// updated half as often as the one below it.
    static func pinkNoise(count: Int, generator: inout SeededRandom,
                          amplitude: Double) -> [Float] {
        let octaves = 16
        var rows = [Double](repeating: 0, count: octaves)
        for index in rows.indices { rows[index] = generator.nextGaussian() }
        var runningSum = rows.reduce(0, +)
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
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

    static func readFile(_ url: URL, sampleRate: Double, duration: Double) throws -> [Float] {
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

/// One-pole filters and a two-pole resonator: enough to shape noise into drums
/// and pulses into speech.
enum Filters {
    static func lowPass(_ input: [Double], cutoff: Double, sampleRate: Double) -> [Double] {
        let a = 1 - exp(-2 * .pi * cutoff / sampleRate)
        var y = 0.0
        return input.map { x in
            y += a * (x - y)
            return y
        }
    }

    static func highPass(_ input: [Double], cutoff: Double, sampleRate: Double) -> [Double] {
        let low = lowPass(input, cutoff: cutoff, sampleRate: sampleRate)
        return zip(input, low).map(-)
    }

    /// A two-pole resonator, for formants.
    static func resonate(_ input: [Double], frequency: Double, q: Double,
                         sampleRate: Double) -> [Double] {
        let omega = 2 * .pi * frequency / sampleRate
        let r = exp(-omega / (2 * q))
        let a1 = 2 * r * cos(omega)
        let a2 = -r * r
        var y1 = 0.0, y2 = 0.0
        return input.map { x in
            let y = x * (1 - r) + a1 * y1 + a2 * y2
            y2 = y1
            y1 = y
            return y
        }
    }
}

/// A reproducible generator, so two runs of the battery produce identical
/// numbers and a code change is the only thing that can move them.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextUniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Box-Muller, so the noise is Gaussian rather than uniform — which matters
    /// for anything measuring a noise floor in dB.
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUniform(), 1e-12)
        let u2 = nextUniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
