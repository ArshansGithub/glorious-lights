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
    /// **Exact beat times**, for M8. The whole reason the click cases exist:
    /// alignment error is a real number rather than an estimate, because the
    /// generator knows where the beats are.
    var beats: [Double] = []
    /// Per-hop RMS of the generated audio, for M9b and M9c.
    ///
    /// Ground truth from the *signal*, never from our own analyser — deriving it
    /// inside the metric would be measuring the analyser against itself.
    var rmsEnvelope: [(time: Double, rms: Double)] = []
    /// Whether this case contains a periodic beat at all.
    var hasBeat = false
    /// Whether the case is stationary — the board is *supposed* to be still.
    var isStationary = false
    /// Whether the case is silent enough that a dark board is correct.
    var isSilence = false
    /// **Ground-truth silence windows** — stretches in which the generator put
    /// no programme material at all, only digital silence or a room-tone noise
    /// floor.
    ///
    /// M9c's complement is asserted against these rather than against a
    /// percentile of the run's own RMS. A percentile cannot express "this is a
    /// noise floor, not quiet music": a stationary noise bed's own p05 sits
    /// inside the bed, so the run reads as continuously playing and the one
    /// clause that says the board must go dark is never emitted. The generator
    /// knows where it stopped playing; nothing else does.
    var silenceWindows: [ClosedRange<Double>] = []

    /// Fills ``rmsEnvelope`` from the samples, at the analysis hop rate.
    mutating func measureRMS(sampleRate: Double, hop: Int = 512) {
        rmsEnvelope.removeAll(keepingCapacity: true)
        var index = 0
        while index + hop <= samples.count {
            var sum = 0.0
            for offset in index..<(index + hop) {
                let value = Double(samples[offset])
                sum += value * value
            }
            rmsEnvelope.append((Double(index + hop) / sampleRate,
                                (sum / Double(hop)).squareRoot()))
            index += hop
        }
    }
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
    /// A bare click track — **M8's ground truth.** Beat times are known
    /// exactly, so alignment error is a real number rather than an estimate.
    case click(bpm: Double)
    /// 90 BPM for 10 s, ramping to 100 over 10 s, then 100 for 10 s. Prediction
    /// must not overshoot on a tempo change.
    case clickRamp
    /// `click-120` with four seconds muted mid-run. **The phantom-gesture
    /// test:** §2.3.4's credit rule must stop the board beating through the gap.
    case clickGap
    /// 8 s intro → 16 s build → 1 s pre-drop silence → 12 s drop → 8 s
    /// breakdown. **M9's main case**, and deliberately not a synthetic
    /// abstraction: it is the shape of the material the user was listening to
    /// when they used the word "cliff".
    case buildDrop
    /// **Music, then a room.** 20 s of four-on-the-floor followed by 55 s of a
    /// −45 dBFS noise floor — the level a microphone in a quiet room actually
    /// sits at, not the −60 dBFS of `near-silence`.
    ///
    /// It exists because M9c's silence complement was emitted **zero** times by
    /// the whole battery: `cut-transitions`' silences are 0.5 s and the clause
    /// needs ten seconds, so "the board must be dark ten seconds into a
    /// silence" was never once asserted, and a board that relights on room tone
    /// and holds a bright floor indefinitely passed every check in the table.
    case roomTone
    case file(URL)

    /// The battery, in the order it is reported.
    static let battery: [Signal] = [
        .edm128, .edm128KickOnly, .ballad72, .speech, .crescendo, .cutTransitions,
        .sustainedTone(frequency: 110), .sustainedTone(frequency: 440),
        .sustainedTone(frequency: 1_000),
        .pink, .white, .nearSilence, .dnb174, .polyrhythm,
        .click(bpm: 120), .click(bpm: 112), .clickRamp, .clickGap, .buildDrop,
        .roomTone,
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
        case "click-120":       return .click(bpm: 120)
        case "click-112":       return .click(bpm: 112)
        case "click-90-ramp":   return .clickRamp
        case "click-120-gap":   return .clickGap
        case "build-drop":      return .buildDrop
        case "music-then-room": return .roomTone
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
        case .click(let bpm):  return "click-\(Int(bpm))"
        case .clickRamp:       return "click-90-ramp"
        case .clickGap:        return "click-120-gap"
        case .buildDrop:       return "build-drop"
        case .roomTone:        return "music-then-room"
        case .file(let url):   return url.lastPathComponent
        }
    }

    /// Musical cases carry the M4 hold bounds; stationary and silent ones are
    /// exempt, because inert is the correct answer there.
    var isMusical: Bool {
        switch self {
        case .sustainedTone, .pink, .white, .nearSilence, .roomTone: return false
        default: return true
        }
    }

    /// How long this case runs. Everything is 30 s except `build-drop`, whose
    /// whole point is a structure that takes 45 s to state: 8 s intro, 16 s
    /// build, 1 s pre-drop silence, 12 s drop, 8 s breakdown.
    func duration(default fallback: Double) -> Double {
        switch self {
        case .buildDrop: return max(fallback, 45)
        // 20 s of music, then 55 s of room tone: the complement needs ten
        // seconds inside the silence before it collects anything, and a board
        // that merely takes a long time to give up must be visible as such.
        case .roomTone:  return max(fallback, 75)
        default:         return fallback
        }
    }

    /// Cases M8 is asserted on: the two exact click tracks plus the two musical
    /// cases with a stated tempo (§10.3).
    var carriesBeatAlignment: Bool {
        switch self {
        case .click, .clickRamp, .edm128, .dnb174: return true
        default: return false
        }
    }

    /// M9a's slow-band fraction, and the threshold it must clear. `crescendo`
    /// and `build-drop` are the two cases built to *have* structure, so they
    /// carry the higher bar.
    var slowBandFloor: Double? {
        switch self {
        case .edm128, .ballad72, .dnb174: return 0.35
        case .crescendo, .buildDrop:      return 0.55
        default:                          return nil
        }
    }

    /// The intro and drop windows M9b's contrast is measured between.
    var dropWindows: (intro: ClosedRange<Double>, drop: ClosedRange<Double>)? {
        switch self {
        case .buildDrop: return (0...8, 25...37)
        default:         return nil
        }
    }

    /// `click-90-ramp` is allowed a wider MAE during its tempo ramp: the ±2 %
    /// per beat rate limit is what is being exercised, and a grid that snapped
    /// to the new tempo would be the failure, not the pass.
    var isTempoRamp: Bool {
        if case .clickRamp = self { return true }
        return false
    }

    /// M9b: the cases with a ground-truth RMS shape worth correlating against.
    var carriesBuildShape: Bool {
        switch self {
        case .buildDrop, .crescendo: return true
        default: return false
        }
    }

    /// M9c: the fraction of playing frames allowed to be dark.
    var deadFractionCeiling: Double? {
        switch self {
        case .cutTransitions: return 0.05
        // Two thirds of this case is deliberately *not* playing, and its own
        // p20 therefore falls inside the noise floor — so "music is genuinely
        // playing" cannot be defined from a percentile here. The case carries
        // the complement instead.
        case .sustainedTone, .pink, .white, .nearSilence, .roomTone: return nil
        default: return 0.01
        }
    }

    /// M10 is a claim about musical material; a stationary tone has nothing to
    /// propagate and a click track is one register repeating.
    var carriesSpatialDiversity: Bool {
        switch self {
        case .edm128, .edm128KickOnly, .ballad72, .dnb174, .polyrhythm,
             .crescendo, .buildDrop:
            return true
        default:
            return false
        }
    }

    /// The stricter M10a bound (§10.3): `edm-128` and, separately, spectrum
    /// mode, where the columns literally *are* registers.
    var carriesWideHueSpread: Bool {
        if case .edm128 = self { return true }
        return false
    }

    /// M10c's `|mean x̄ − 8| ≥ 0.5` clause. VU is exempt from this clause only —
    /// it is a centre-out meter by design (§9.5) — but not from the two below it.
    var carriesCentreOffset: Bool {
        switch self {
        case .edm128, .dnb174, .ballad72: return true
        default: return false
        }
    }

    /// Cases the M2 *lower* bound applies to — the three the design names. The
    /// bound exists to catch a visualizer that has been smoothed into
    /// inertness, and it is stated against material that is continuously
    /// playing; a case built out of hard cuts and silences spends much of its
    /// run correctly showing nothing.
    var carriesLivelinessBound: Bool {
        switch self {
        case .edm128, .ballad72, .crescendo, .buildDrop: return true
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

    /// A click track is a bare transient on digital silence: it has a beat and
    /// exact ground truth, but no sustained material, so the hold, liveliness
    /// and trigger-rate bounds stated for *music* do not describe it.
    var isClick: Bool {
        switch self {
        case .click, .clickRamp, .clickGap: return true
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
        case .crescendo, .cutTransitions, .buildDrop, .clickGap, .roomTone: return false
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
        var track = try generate(sampleRate: sampleRate, duration: duration)
        // Ground truth, filled centrally so no case can forget it. The beat grid
        // of a synthesised case is known exactly — it is the number the
        // generator was given — and M8 is only meaningful against a beat time
        // nobody estimated.
        if track.beats.isEmpty, let bpm = groundTruthBPM {
            var time = 0.0
            while time < duration {
                track.beats.append(time)
                time += 60 / bpm
            }
        }
        if track.rmsEnvelope.isEmpty { track.measureRMS(sampleRate: sampleRate) }
        return track
    }

    /// The tempo the generator was told to use, where there is one.
    private var groundTruthBPM: Double? {
        switch self {
        case .edm128, .edm128KickOnly: return 128
        case .ballad72:                return 72
        // **87, not 174.** §2.3's `canonicalRange` is 85…170 and is normative:
        // the tracker folds 174 BPM by halving, and a half-time reading of a
        // breakbeat is the one a listener taps. M8 is a claim about the grid the
        // design commits to *publishing*; scoring it against a grid the design
        // says it will never report would be measuring the specification against
        // itself.
        case .dnb174:                  return 87
        case .buildDrop:               return 128
        default:                       return nil
        }
    }

    private func generate(sampleRate: Double, duration: Double) throws -> Track {
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
        case .click(let bpm): return synth.click(bpm: bpm)
        case .clickRamp:      return synth.clickRamp()
        case .clickGap:       return synth.click(bpm: 120, muting: 20..<28)
        case .buildDrop:      return synth.buildDrop(bpm: 128)
        case .roomTone:       return synth.musicThenRoom(bpm: 128, music: 20,
                                                         floorDB: -45)
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

    /// Music, then a room: the case the whole battery was missing.
    ///
    /// A microphone in a quiet room sits at −50…−40 dBFS, not at the −60 dBFS
    /// `near-silence` uses, and the difference is the whole question. The board
    /// must give up on a room the same way it gives up on digital silence.
    mutating func musicThenRoom(bpm: Double, music: Double, floorDB: Double) -> Track {
        var track = Track(samples: [], hasBeat: true)
        let beat = 60 / bpm
        var time = 0.0
        var step = 0
        while time < music {
            kick(at: time)
            track.events.append((time, .kick))
            if step % 4 == 1 || step % 4 == 3 {
                snare(at: time)
                track.events.append((time, .snare))
            }
            hat(at: time + beat / 2)
            track.events.append((time + beat / 2, .hat))
            time += beat
            step += 1
        }
        add(at: 0, length: music) { u in
            var value = 0.0
            for harmonic in 1...6 { value += sin(2 * .pi * 55 * Double(harmonic) * u) / Double(harmonic) }
            return 0.30 * value / 2
        }
        // The room. Stationary, uncorrelated, and *above* the level at which
        // the AGC's gain clamp alone can decide the question.
        let floor = pow(10, floorDB / 20)
        for position in index(music)..<count {
            buffer[position] += Float(floor * random.nextGaussian())
        }
        track.silenceWindows = [music...duration]
        track.samples = buffer
        return track
    }

    mutating func breakbeat(bpm: Double) -> Track {
        var track = Track(samples: [], hasBeat: true)
        let beat = 60 / bpm
        let bar = beat * 4
        var time = 0.0
        while time < duration {
            // Kick on 1 and 3, snare on 2 and 4, hats on every eighth.
            //
            // The kick on 3 is new in r2, and it is a correction rather than a
            // convenience. Without it the two kicks of a bar sit on beats 1 and
            // 3½, i.e. at phases 0 and 0.25 of the half-time grid the canonical
            // range folds 174 BPM into — so `TempoTracker.align` was pulled
            // alternately to two phases a quarter-beat apart and `σ_φ` measured
            // **0.42 beats**, four times §2.3.2's "do not anticipate" threshold.
            // The design then correctly refused to predict anything at all, and
            // the case silently stopped testing beat alignment while appearing
            // to. A break with a hit on every quarter is also the more ordinary
            // breakbeat; nothing else about the case changes.
            //
            // (r1 put the second kick on the "and" of 3 instead of on 3.)
            kick(at: time, amplitude: 0.85, decay: 0.12)
            track.events.append((time, .kick))
            snare(at: time + beat, amplitude: 0.55, decay: 0.10)
            track.events.append((time + beat, .snare))
            kick(at: time + beat * 2, amplitude: 0.75, decay: 0.12)
            track.events.append((time + beat * 2, .kick))
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

    // MARK: - The r2 cases

    /// One click: the doc's 2 kHz sine burst with an 8 ms exponential decay, on
    /// digital silence.
    ///
    /// The 1.5 ms raised-cosine attack is deliberate and it matters. A burst
    /// that starts with an infinite slope is not a 2 kHz sine burst at all — it
    /// is a broadband impulse with a 2 kHz emphasis, and its splatter is what
    /// the 20–120 Hz kick detector would be firing on. That is worth being
    /// precise about because the detector watches 20–120 Hz, 250 Hz–1 kHz and
    /// 6–16 kHz and nothing at 2 kHz: the case has to excite a watched band
    /// through a mechanism a real percussive click also has, which is a fast but
    /// finite attack, rather than through a discontinuity no physical source
    /// produces.
    mutating func clickBurst(at time: Double, amplitude: Double = 0.25) {
        add(at: time, length: 0.012) { u in
            let attack = u < 0.0020 ? 0.5 - 0.5 * cos(.pi * u / 0.0020) : 1
            return amplitude * attack * exp(-u / 0.008) * sin(2 * .pi * 2_000 * u)
        }
    }

    /// A bare click track at an exact tempo, optionally with a run of beats
    /// muted. `muting` is a **beat index** range, so `20..<28` is the doc's four
    /// second gap at 120 BPM.
    mutating func click(bpm: Double, muting: Range<Int>? = nil) -> Track {
        var track = Track(samples: [], hasBeat: true)
        let period = 60 / bpm
        var index = 0
        var time = 0.0
        while time < duration {
            // Every beat is ground truth whether or not it was sounded: the
            // point of the gap case is that the board must stop even though the
            // grid says a beat is due.
            track.beats.append(time)
            if muting.map({ !$0.contains(index) }) ?? true {
                clickBurst(at: time)
            }
            time += period
            index += 1
        }
        track.samples = buffer
        track.measureRMS(sampleRate: sampleRate)
        return track
    }

    /// 90 BPM for 10 s, ramping linearly to 100 over the next 10 s, then 100 for
    /// the rest. The ±2 %/beat tempo rate limit is exercised here, and
    /// prediction must not overshoot.
    mutating func clickRamp() -> Track {
        var track = Track(samples: [], hasBeat: true)
        var time = 0.0
        while time < duration {
            track.beats.append(time)
            clickBurst(at: time)
            let bpm: Double
            if time < 10 {
                bpm = 90
            } else if time < 20 {
                bpm = 90 + 10 * (time - 10) / 10
            } else {
                bpm = 100
            }
            time += 60 / bpm
        }
        track.samples = buffer
        track.measureRMS(sampleRate: sampleRate)
        return track
    }

    /// The case r1 has no answer to at all.
    ///
    /// 8 s filtered intro → 16 s build with the RMS rising about 18 dB
    /// monotonically → 1 s pre-drop silence → 12 s full-energy drop → 8 s
    /// breakdown. It is deliberately not a synthetic abstraction: it is the
    /// shape of the material the user was listening to when they used the word
    /// "cliff".
    mutating func buildDrop(bpm: Double) -> Track {
        var track = Track(samples: [], hasBeat: true)
        let beat = 60 / bpm
        let introEnd = 8.0, buildEnd = 24.0, dropStart = 25.0, dropEnd = 37.0
        var time = 0.0
        var index = 0
        while time < duration {
            track.beats.append(time)
            let section = time
            if section < introEnd {
                // A filtered intro: a soft kick on every other beat and a pad.
                if index % 2 == 0 {
                    kick(at: time, amplitude: 0.20, decay: 0.16)
                    track.events.append((time, .kick))
                }
            } else if section < buildEnd {
                // The build: level rising ~18 dB monotonically over sixteen
                // seconds, kick on every beat, hats subdividing faster as it
                // goes.
                let progress = (section - introEnd) / (buildEnd - introEnd)
                let amplitude = pow(10, (-18 + 18 * progress) / 20)
                kick(at: time, amplitude: 0.9 * amplitude + 0.1, decay: 0.14)
                track.events.append((time, .kick))
                if progress > 0.4 {
                    hat(at: time + beat / 2, amplitude: 0.25 * (0.3 + progress))
                    track.events.append((time + beat / 2, .hat))
                }
                if progress > 0.7, index % 2 == 1 {
                    snare(at: time, amplitude: 0.4 * progress)
                    track.events.append((time, .snare))
                }
            } else if section < dropStart {
                // One second of pre-drop silence. Nothing is synthesised.
            } else if section < dropEnd {
                kick(at: time, amplitude: 0.95)
                track.events.append((time, .kick))
                if index % 2 == 1 {
                    snare(at: time)
                    track.events.append((time, .snare))
                }
                hat(at: time + beat / 2, amplitude: 0.4)
                track.events.append((time + beat / 2, .hat))
            } else {
                // The breakdown: the drop's material gone, a pad left behind.
                if index % 4 == 0 {
                    kick(at: time, amplitude: 0.25, decay: 0.18)
                    track.events.append((time, .kick))
                }
            }
            time += beat
            index += 1
        }

        // The sustained layers, level-shaped to the same structure.
        let rate = sampleRate
        add(at: 0, length: duration) { u in
            let level: Double
            if u < introEnd {
                level = 0.05
            } else if u < buildEnd {
                let progress = (u - introEnd) / (buildEnd - introEnd)
                // A rising noise sweep is the other half of a build; here it is
                // a harmonic stack whose level rises with it.
                level = 0.05 + 0.35 * progress
            } else if u < dropStart {
                level = 0
            } else if u < dropEnd {
                level = 0.42
            } else {
                level = 0.07
            }
            guard level > 0 else { return 0 }
            var value = 0.0
            for harmonic in 1...6 {
                value += sin(2 * .pi * 55 * Double(harmonic) * u) / Double(harmonic)
            }
            _ = rate
            return level * value / 2
        }
        track.samples = buffer
        track.measureRMS(sampleRate: sampleRate)
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
