import Foundation

/// The analysis stage: samples in, ``AnalysisState`` and ``OnsetEvent`` out, at
/// a fixed ~94 Hz that has nothing to do with the display rate (P3).
///
/// This is where every adaptive decision in the visualizer lives. It runs one
/// pipeline per hop:
///
/// ```
/// ring → window(2048, Hann) → rFFT → |X[k]|
///      → per-bin adaptive whitening
///      → 8 log-spaced bands
///      → per band: relative followers, percentile norm, gate
///      → whitened flux → MAD peak-pick → arbiter → OnsetEvent
///      → tempo / phase
///      → AHR envelopes (accents, VU, body, master)
/// ```
///
/// The envelopes run *here*, at the analysis rate, rather than in the renderer.
/// That is what makes an attack shorter than one display frame meaningful: the
/// renderer samples a properly formed envelope instead of building one out of
/// point samples it took at an arbitrary phase.
public final class MusicAnalyzer {

    public let sampleRate: Double
    /// Analysis hop in samples, chosen to land the analysis rate near 94 Hz for
    /// whatever rate the capture device chose.
    public let hop: Int
    public var hopSeconds: Double { Double(hop) / sampleRate }
    public var analysisRate: Double { sampleRate / Double(hop) }

    /// Display frame interval, needed only so the AHR release clamps of §4.2 can
    /// be expressed in frames.
    public var frameInterval: Double

    private let analyzer: SpectrumAnalyzer
    private var whitening: AdaptiveWhitening
    private var followers: [RelativeFollower]
    private var normalisers: [PercentileNormaliser]
    private var gates: [BandGate]
    private var detectors: [OnsetKind: FluxOnsetDetector]
    private var arbiter = OnsetArbiter()
    private var tempoTracker: TempoTracker

    private var overallFollower = RelativeFollower()
    private var loudnessReference = QuantileTracker(percentile: 0.90,
                                                    window: PercentileNormaliser.window)
    private var centroidNormaliser = PercentileNormaliser()

    private var accents: [OnsetKind: AHR] = [:]
    private var vuEnvelope: AHR
    private var bodyEnvelope: AHR
    private var masterEnvelope: AHR
    private var registerLevels: [GravityPeak]
    private var registerPeaks: [GravityPeak]

    private var previousWhitened: [Double] = []
    private var fluxHistory: [Double] = []
    private var liveliness: [Double] = []

    private var pending: [Float] = []
    private var samplesConsumed = 0
    private var startTime: Double = 0
    private var hasStarted = false
    private var lastHopTime: Double = 0

    /// The AGC's gain is clamped to this ratio (§3.3). It is the one place the
    /// design's otherwise fully relative levelling meets an absolute, and it is
    /// deliberate: "a quiet room" and "music played very quietly" are
    /// indistinguishable to a purely relative system, so the gain a silent
    /// passage can ask for is bounded rather than argued about. Sixteen times
    /// is enough that any real programme material reaches full scale and little
    /// enough that a -60 dBFS noise bed reaches 0.016.
    public static let maximumGain: Double = 16
    public static let minimumGain: Double = 1.0 / 16

    /// A band whose long average is below this fraction of the spectrum's own
    /// long average is treated as empty: `1/100` is 40 dB down, which no band
    /// carrying anything audible ever is.
    public static let emptyBandFraction: Double = 0.01

    /// Below this normalised level the board is showing nothing, so the
    /// percentile histories are frozen — silence must not wind the gain up.
    public static let silenceLevel: Double = 0.02

    /// How far above its own median the broadband flux must have gone in the
    /// last second for *any* onset to be accepted. Measured separation: 1.17 on
    /// stationary noise, 1.57 on the quietest musical case in the battery.
    public static let livelinessRatio: Double = 1.5

    /// Registers fall at 110 ms per row; six rows is a 0.66 s full fall.
    public static let gravityPerRow: Double = 0.110

    public init(sampleRate: Double, frameInterval: Double) {
        self.sampleRate = sampleRate
        self.frameInterval = frameInterval
        // 512 at 48 kHz, 448 at 44.1 kHz: both land within a few per cent of the
        // design's 93.75 Hz target, and both are a whole number of the ring's
        // granularity. A smaller hop buys latency and was tried — 256 halves the
        // peak-picking delay — but it also halves the independence between
        // consecutive analysis windows, and the stationary cases started
        // producing onsets again. The window overlap, not the frame rate, is
        // what the flux statistics rest on.
        let hopSize = max(128, Int((sampleRate / 93.75 / 64).rounded()) * 64)
        self.hop = hopSize
        self.analyzer = SpectrumAnalyzer(sampleRate: Float(sampleRate))
        self.whitening = AdaptiveWhitening(binCount: SpectrumAnalyzer.windowSize / 2)
        self.followers = Array(repeating: RelativeFollower(), count: AnalysisState.bandCount)
        self.normalisers = Array(repeating: PercentileNormaliser(), count: AnalysisState.bandCount)
        self.gates = Array(repeating: BandGate(), count: AnalysisState.bandCount)
        self.detectors = Dictionary(uniqueKeysWithValues:
            OnsetKind.allCases.map {
                ($0, FluxOnsetDetector(kind: $0, analysisRate: sampleRate / Double(hopSize)))
            })
        self.tempoTracker = TempoTracker(analysisRate: sampleRate / Double(hop))
        self.vuEnvelope = .clamped(attack: 0.150, hold: 0, release: 1.000,
                                   frameInterval: frameInterval)
        self.bodyEnvelope = .clamped(attack: 0.050, hold: 0, release: 0.500,
                                     frameInterval: frameInterval)
        self.masterEnvelope = .clamped(attack: 0.300, hold: 0, release: 1.200,
                                       frameInterval: frameInterval)
        self.registerLevels = Array(repeating: GravityPeak(fallSeconds: Self.gravityPerRow * 6,
                                                          hold: 0.100),
                                    count: AnalysisState.registerCount)
        self.registerPeaks = Array(repeating: GravityPeak(fallSeconds: Self.gravityPerRow * 6,
                                                          hold: 0.100),
                                   count: AnalysisState.registerCount)
        for kind in OnsetKind.allCases {
            accents[kind] = kind.accentEnvelope(frameInterval: frameInterval)
        }
    }

    /// Feeds captured samples and runs analysis on whole hops.
    ///
    /// - Parameter hostTime: when the *last* sample in `samples` was captured.
    ///   Analysis timestamps are derived from the sample count from there, so
    ///   they are exact even if the capture callback jitters.
    public func ingest(_ samples: [Float], hostTime: Double, into bus: AnalysisBus) {
        if !hasStarted {
            hasStarted = true
            startTime = hostTime - Double(samples.count) / sampleRate
            lastHopTime = startTime
        }
        pending += samples

        while pending.count >= SpectrumAnalyzer.windowSize {
            let window = Array(pending.prefix(SpectrumAnalyzer.windowSize))
            pending.removeFirst(hop)
            samplesConsumed += hop
            let time = startTime + Double(samplesConsumed + SpectrumAnalyzer.windowSize - hop)
                / sampleRate
            let (state, onsets) = analyse(window: window, at: time)
            bus.publish(state, onsets: onsets)
        }

        // A source delivering enormous buffers must not grow the backlog.
        if pending.count > SpectrumAnalyzer.windowSize * 8 {
            pending.removeFirst(pending.count - SpectrumAnalyzer.windowSize)
        }
    }

    /// How far behind the audio an event detected on the current hop actually
    /// happened: half a Hann window (its group delay) plus half a hop (the flux
    /// is a difference between two adjacent windows). Events are timestamped
    /// back by this, so a gesture starts at the moment the drum was hit rather
    /// than at the moment the maths noticed.
    public var groupDelay: Double {
        (Double(SpectrumAnalyzer.windowSize) / 2 + Double(hop) / 2) / sampleRate
    }

    private func analyse(window: [Float], at time: Double) -> (AnalysisState, [OnsetEvent]) {
        let dt = max(time - lastHopTime, 1e-6)
        lastHopTime = time

        let magnitudes = analyzer.magnitudes(from: window)
        // Whitening feeds the **flux** path only.
        //
        // §3.1 adopts per-bin whitening to fix spectral tilt so that the highs
        // light up without a per-song EQ, and for onset detection it is exactly
        // right: flux on whitened bins is what makes a hat and a kick comparable.
        // For the *level* path it is the wrong tool, and running both compounds
        // their failure modes: whitening divides every bin by its own recent
        // peak, so a band that is nearly empty between hits has its leakage
        // amplified to full scale, and a lowpassed snare read as full-scale in
        // all eight bands at once — the whole board rising and falling together
        // on every backbeat, which is the opposite of showing musical shape.
        // Percentile normalisation (§3.3) already fixes tilt band by band, from
        // that band's own observed range, and cannot amplify an empty band
        // because its p90 collapses with it.
        let whitened = whitening.process(magnitudes, dt: dt)

        // Time-domain RMS is the only quantity in the pipeline that carries an
        // absolute level, and it exists solely to feed the clamped AGC below.
        var sumOfSquares: Double = 0
        for sample in window.suffix(hop) { sumOfSquares += Double(sample) * Double(sample) }
        let rms = (sumOfSquares / Double(max(hop, 1))).squareRoot()

        var state = AnalysisState()
        state.time = time

        // Per-band followers, normalisation and gates.
        // A band 40 dB below the spectrum's own average level is empty, and its
        // ratios must say so. Relative to the board rather than to full scale,
        // so it stays a dimensionless comparison.
        let bandFloor = overallFollower.long * Self.emptyBandFraction
        var bandValues = [Double](repeating: 0, count: AnalysisState.bandCount)
        var bandCurrent = [Double](repeating: 1, count: AnalysisState.bandCount)
        var bandAverage = [Double](repeating: 1, count: AnalysisState.bandCount)
        var bandGate = [Double](repeating: 0, count: AnalysisState.bandCount)
        let frozen = masterEnvelope.value < Self.silenceLevel && rms < loudnessReference.value
        for band in 0..<AnalysisState.bandCount {
            let range = analyzer.bandBins[band]
            var sum: Double = 0
            for bin in range.lower...range.upper { sum += Double(magnitudes[bin]) }
            let value = sum / Double(range.upper - range.lower + 1)
            bandValues[band] = value

            let relative = followers[band].update(value, dt: dt, floor: bandFloor)
            bandCurrent[band] = relative.current
            bandAverage[band] = relative.average
            // Normalise the **short envelope**, not the instantaneous value.
            // A bar is something that moves continuously, and §3.2's rule is
            // that continuous motion is driven by the attenuated value. Feeding
            // the raw value makes `x_norm` sit at zero between transients — a
            // spectrum display that shows only spikes, with nothing to read a
            // level from.
            let norm = normalisers[band].update(followers[band].short, dt: dt, frozen: frozen)
            let gate = gates[band].update(currentRelative: relative.current,
                                          averageRelative: relative.average,
                                          norm: norm, now: time, dt: dt)
            bandGate[band] = gate
            state[AnalysisState.Channel.bandCurrent(band)] = relative.current
            state[AnalysisState.Channel.bandAverage(band)] = relative.average
            state[AnalysisState.Channel.bandNorm(band)] = norm
            state[AnalysisState.Channel.bandGate(band)] = gate
            state[AnalysisState.Channel.bandShare(band)] = overallFollower.long > 0
                ? followers[band].long / overallFollower.long : 0
        }

        let overall = bandValues.reduce(0, +) / Double(bandValues.count)
        let overallRelative = overallFollower.update(overall, dt: dt)
        state[AnalysisState.Channel.overallCurrent] = overallRelative.current
        state[AnalysisState.Channel.overallAverage] = overallRelative.average

        // Percentile AGC with the gain clamp of §3.3.
        if !frozen { loudnessReference.update(rms, dt: dt) }
        let gain = clamp(1 / max(loudnessReference.value, QuantileTracker.floor),
                         Self.minimumGain, Self.maximumGain)
        // Master brightness answers "is there material playing", not "how loud
        // is it this instant". The dynamics are already carried by the relative
        // values every mode composes from, so making the master a level as well
        // multiplies them twice — and, worse, drags the whole board across the
        // per-key on/off threshold once per beat, which is flicker manufactured
        // by the brightness control itself. A smoothstep over the bottom quarter
        // of the normalised range gives full brightness to anything genuinely
        // playing and ramps to black only for genuine silence.
        let masterTarget = smoothstep(0.02, 0.25, clamp(rms * gain, 0, 1))
        masterEnvelope.update(target: masterTarget, now: time, dt: dt)
        state[AnalysisState.Channel.master] = masterEnvelope.value

        // Broadband flux, computed before the detectors because they use it as
        // corroboration, and rectified against its own running median so the
        // tempo autocorrelation sees rhythm rather than texture.
        var totalFlux: Double = 0
        if previousWhitened.count == whitened.count {
            for index in whitened.indices {
                let rise = whitened[index] - previousWhitened[index]
                if rise > 0 { totalFlux += rise }
            }
        }
        previousWhitened = whitened
        fluxHistory.append(totalFlux)
        if fluxHistory.count > Int(analysisRate) {
            fluxHistory.removeFirst(fluxHistory.count - Int(analysisRate))
        }
        let sortedFlux = fluxHistory.sorted()
        let medianFlux = sortedFlux[sortedFlux.count / 2]
        let broadband = min(totalFlux / max(medianFlux, QuantileTracker.floor), 100)
        liveliness.append(broadband)
        if liveliness.count > Int(analysisRate) {
            liveliness.removeFirst(liveliness.count - Int(analysisRate))
        }
        // **The spectral liveliness gate.** Onsets are permitted only when the
        // spectrum as a whole has done something in the last second.
        //
        // This is the test that finally makes "zero onsets on stationary
        // material" structural rather than statistical. Every per-band test is a
        // threshold on a random variable, so on a stationary signal it fires at
        // whatever its false-alarm rate is — 3 per second on pink noise for a
        // five-bin kick region, which is precisely the class of bug this
        // redesign exists to remove. Broadband flux over a thousand bins is a
        // different kind of statistic: on stationary material it sits within a
        // few per cent of its own median indefinitely (measured: 1.12–1.17 for
        // pink, white and a -60 dBFS bed), while every musical case in the
        // battery reaches at least 1.57. It asks "is this signal stationary?",
        // which is a question about the signal rather than about a threshold.
        // …and it needs its own window before it can answer. Until a full
        // second of flux history exists the median it is measured against is
        // built from a handful of samples, and every level in the pipeline is
        // still converging — which is exactly when a spurious "event" is most
        // likely and least meaningful.
        let lively = liveliness.count >= Int(analysisRate)
            && (liveliness.max() ?? 0) > Self.livelinessRatio

        // Onsets: candidates per kind, then winner-take-all across kinds.
        var candidates: [FluxOnsetDetector.Candidate] = []
        for kind in OnsetKind.allCases where lively {
            guard var detector = detectors[kind] else { continue }
            let lower = analyzer.bandBins[kind.bands.lowerBound].lower
            let upper = analyzer.bandBins[kind.bands.upperBound].upper
            let relative = kind.bands.map { bandCurrent[$0] }.reduce(0, +)
                / Double(kind.bands.count)
            // The weakest band of the region gets its own, gentler floor. The
            // SNR test then asks whether the whole region rose rather than just
            // one edge of it: a voice's fundamental sits at 85–180 Hz, right on
            // the upper band of the kick region, so on the region's *mean* every
            // voiced syllable reads as a kick.
            let relativeFloor = kind.bands.map { bandCurrent[$0] }.min() ?? 0
            let gate = kind.bands.map { bandGate[$0] }.max() ?? 0
            if let candidate = detector.process(whitened: whitened[lower...upper],
                                                time: time,
                                                currentRelative: relative,
                                                weakestBand: relativeFloor,
                                                gate: gate) {
                candidates.append(candidate)
            }
            detectors[kind] = detector
        }
        var events: [OnsetEvent] = []
        for winner in arbiter.arbitrate(candidates, now: time) {
            detectors[winner.kind]?.accept(at: winner.time)
            events.append(OnsetEvent(time: winner.time - groupDelay,
                                     kind: winner.kind,
                                     strength: winner.strength,
                                     confidence: winner.confidence))
            if winner.kind == .kick { tempoTracker.align(toBeatAt: winner.time) }
        }

        // Accent envelopes, driven at the analysis rate so a 15 ms attack means
        // something even though frames are 33 ms apart.
        for kind in OnsetKind.allCases {
            let fired = events.first { $0.kind == kind }
            // Confidence scales amplitude rather than gating it: the transition
            // from "hit" to "no hit" has to be continuous or the board chatters
            // at the detection boundary.
            let target = fired.map { clamp(0.4 + 0.6 * $0.confidence, 0, 1) * (0.5 + 0.5 * $0.strength) } ?? 0
            accents[kind]?.update(target: target, now: time, dt: dt)
            state[AnalysisState.Channel.accent(kind)] = accents[kind]?.value ?? 0
        }

        state.tempo = tempoTracker.process(fluxSum: Float(max(0, totalFlux - medianFlux)),
                                           elapsed: dt)

        // Registers: instant rise, gravity fall, and a separate peak marker.
        for index in 0..<AnalysisState.registerCount {
            let bands = SpectrumAnalyzer.registerBands[index]
            var level: Double = 0
            for band in bands {
                level = max(level, state.norm(band) * state.gate(band))
            }
            // Smoothstep over the bottom of the range rather than a cliff, and a
            // floor so a register shows its shape in quiet passages instead of
            // blinking out.
            let shaped = 0.05 + 0.95 * smoothstep(0, 1, level)
            registerLevels[index].update(target: shaped, dt: dt)
            registerPeaks[index].update(target: registerLevels[index].value, dt: dt)
            state[AnalysisState.Channel.register(index)] = registerLevels[index].value
            state[AnalysisState.Channel.registerPeak(index)] = registerPeaks[index].value
        }

        // VU and body: the slow layers. Both are driven from AVERAGE_RELATIVE,
        // never from the instantaneous value.
        let vuTarget = clamp((overallRelative.average - 0.5) / 1.2, 0, 1)
        vuEnvelope.update(target: vuTarget, now: time, dt: dt)
        state[AnalysisState.Channel.vu] = vuEnvelope.value

        let bodyTarget = clamp((state.midAverageRelative - 0.5) / 1.2, 0, 1)
        bodyEnvelope.update(target: bodyTarget, now: time, dt: dt)
        state[AnalysisState.Channel.body] = bodyEnvelope.value

        let centroid = analyzer.centroid(of: whitened)
        let logCentroid = log(max(centroid, 20))
        state[AnalysisState.Channel.brightness] =
            centroidNormaliser.update(logCentroid, dt: dt, frozen: frozen)

        return (state, events)
    }

    public func reset() {
        whitening.reset()
        for index in followers.indices { followers[index].reset() }
        for index in normalisers.indices { normalisers[index].reset() }
        for index in gates.indices { gates[index].reset() }
        for kind in OnsetKind.allCases {
            detectors[kind]?.reset()
            accents[kind]?.reset()
        }
        arbiter.reset()
        tempoTracker = TempoTracker(analysisRate: analysisRate)
        overallFollower.reset()
        loudnessReference.reset()
        centroidNormaliser.reset()
        vuEnvelope.reset()
        bodyEnvelope.reset()
        masterEnvelope.reset()
        for index in registerLevels.indices {
            registerLevels[index].reset()
            registerPeaks[index].reset()
        }
        previousWhitened.removeAll()
        fluxHistory.removeAll()
        liveliness.removeAll()
        pending.removeAll()
        samplesConsumed = 0
        hasStarted = false
    }
}
