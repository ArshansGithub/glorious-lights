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

    /// Whether the percentile AGC of §3.3 may move the gain at all.
    ///
    /// The menu has always offered this and nothing read it: the normalisation
    /// ran regardless, so "Auto Gain" was a tick that changed nothing while its
    /// tooltip promised to "normalise to the loudest sound heard recently".
    /// With it off the gain is pinned at unity and the board simply shows how
    /// loud the material actually is. Written from the render thread, read here
    /// on the analysis thread, hence the flag rather than a `Bool`.
    public let autoGain = AtomicFlag(true)

    private let analyzer: SpectrumAnalyzer
    private var whitening: AdaptiveWhitening
    private var followers: [RelativeFollower]
    private var normalisers: [PercentileNormaliser]
    private var gates: [BandGate]
    private var detectors: [OnsetKind: FluxOnsetDetector]
    private var arbiter = OnsetArbiter()
    private var tempoTracker: TempoTracker

    /// A fast-attack, slow-release envelope on the time-domain RMS, so "is
    /// anything playing" is not a statement about duty cycle. See the master
    /// brightness below.
    private var rmsPeak = AHR(attack: 0.005, hold: 0.150, release: 0.600)

    private var overallFollower = RelativeFollower()
    private var loudnessReference = QuantileTracker(percentile: 0.90,
                                                    window: PercentileNormaliser.window)
    private var centroidNormaliser = PercentileNormaliser()

    /// §11's three timescales. The one part of the pipeline whose reference
    /// window is deliberately *longer* than the structure it shows (P9).
    private var energy = EnergyModel()

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
    /// Every sample handed in, including the ones still waiting for a whole hop.
    private var samplesReceived = 0
    private var startTime: Double = 0
    private var hasStarted = false
    private var lastHopTime: Double = 0
    private var lastOnsetTime: Double = -.infinity
    /// Monotonic count of §11.3 novelty events, which §12.1's structure kick
    /// consumes. A counter rather than a flag: the renderer samples states at
    /// its own rate and may miss the hop an event fired on.
    private var structureChanges = 0

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
    /// last second before any onset is accepted at all, and how far above it
    /// before onsets are accepted at full confidence.
    ///
    /// Measured separation: 1.12–1.17 on stationary noise, 1.57 on the quietest
    /// musical case in the battery. A single hard threshold at 1.5 sat at 96 %
    /// of the quietest passing case and was an all-or-nothing switch on the
    /// entire onset path, so material 4 % less lively than a synthetic ballad
    /// produced *zero* onsets rather than dimmer ones — which is the failure
    /// §2.2 names when it says the transition from "hit" to "no hit" must be
    /// continuous. The floor is now placed on the stationary side of the gap
    /// instead, with 11 % of headroom above the noisiest stationary case and
    /// 21 % below the quietest musical one, and everything between the floor
    /// and full simply drives dimmer gestures.
    public static let livelinessFloor: Double = 1.30
    public static let livelinessFull: Double = 1.55

    /// Fraction of the sample-count-versus-host-clock error corrected per
    /// buffer. Slow enough that callback jitter is averaged away, fast enough
    /// that a real rate offset never accumulates: 2 % of a 256-sample buffer is
    /// a time constant of about a quarter of a second.
    public static let clockSlew: Double = 0.02
    /// An error this large is not drift — it is a dropout or a device change —
    /// and is corrected in one step. Also, being smaller than the shortest
    /// buffer's own advance divided by ``clockSlew``, it keeps analysis
    /// timestamps monotonic under the slow correction.
    public static let resyncThreshold: Double = 0.250

    /// How long the beat grid keeps full confidence after the last accepted
    /// onset, and how long before it is abandoned entirely. A tempo is a claim
    /// about recurring events; four seconds without one is two bars at any
    /// tempo the tracker will report.
    public static let gridGroundedSeconds: Double = 2.0
    public static let gridAbandonSeconds: Double = 4.0

    /// Registers fall under gravity at this rate per row. §6.4 gives the window
    /// — "faster than ~60 ms/row and the marker becomes flicker; slower than
    /// ~150 ms/row and it looks stuck" — and the slow end of it is where the
    /// bars belong. A bar's rows are thresholds it crosses, so the fall rate
    /// *is* the rate at which its top row can toggle: at 110 ms/row a busy
    /// polyrhythm produced 1.97 on→off→on cycles per key-second against M1's
    /// ceiling of 1.5, and there is nothing else in a pure envelope mode to slow
    /// it down.
    public static let gravityPerRow: Double = 0.150

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
        // The peak-hold is the §6.3 minimum visible on-time, which P1 allows as
        // a perceptual constant. A bar's rows are thresholds the bar crosses, so
        // a register that falls back the moment it stops rising turns a busy
        // passage into a row toggling at the hit rate — measured on
        // `polyrhythm`, 1.97 on→off→on cycles per key-second against a ceiling
        // of 1.5, with nothing else in the mode to slow it down.
        self.registerLevels = Array(repeating: GravityPeak(fallSeconds: Self.gravityPerRow * 6,
                                                          hold: KeyHold.minimumOn),
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
            samplesReceived = 0
        }
        samplesReceived += samples.count
        // **The analysis clock is slaved to the host clock, slowly.**
        //
        // Timestamps are derived from the sample count so they are exact even
        // when the capture callback jitters — but they are derived against the
        // device's *nominal* rate. A device producing 48 000 ± 50 ppm advances
        // analysis time at 1 ± 50 ppm host-seconds per host-second, which is
        // linear, unbounded drift against the render clock: after about seven
        // minutes the 20 ms extrapolation limit is exceeded and either every
        // frame is counted stale or the interpolator runs off the end of its
        // history. A dropout or a device change adds a permanent step with no
        // resync path at all.
        //
        // So the sample count still sets the *fine* structure — that is what
        // makes it immune to callback jitter — and the host clock sets the
        // slow term. A small error is corrected at 2 % per buffer, far slower
        // than any callback jitter and far faster than any real clock drift; a
        // large one is a dropout or a device change and is resynced outright.
        let expectedEnd = startTime + Double(samplesReceived) / sampleRate
        let error = hostTime - expectedEnd
        if abs(error) > Self.resyncThreshold {
            startTime += error
            lastHopTime += error
        } else {
            startTime += error * Self.clockSlew
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
    /// Measured, r2: the residual is **material-dependent** and no constant
    /// removes it. An impulsive transient is timestamped about 17 ms earlier
    /// relative to its true onset than a 50 Hz kick with a 12 ms attack is,
    /// because §3.1's whitening peak-follower rises instantaneously — a
    /// broadband transient saturates its bins on the first hop whose window
    /// touches it, while a low-frequency onset has to build for two or three
    /// cycles before its bins move at all. Against ground truth the published
    /// beat grid sits at −16 ms on the click cases and +3 ms on `edm-128` with
    /// this constant, which straddles zero; §8.3's user offset is what dials out
    /// whatever a given machine and a given genre leave over.
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
        let gain = autoGain.value
            ? clamp(1 / max(loudnessReference.value, QuantileTracker.floor),
                    Self.minimumGain, Self.maximumGain)
            : 1
        // Master brightness answers "is there material playing", not "how loud
        // is it this instant". The dynamics are already carried by the relative
        // values every mode composes from, so making the master a level as well
        // multiplies them twice — and, worse, drags the whole board across the
        // per-key on/off threshold once per beat, which is flicker manufactured
        // by the brightness control itself. A smoothstep over the bottom quarter
        // of the normalised range gives full brightness to anything genuinely
        // playing and ramps to black only for genuine silence.
        // …measured on a **peak-holding** envelope of the RMS, not on the hop's
        // own RMS. "Is anything playing" is a question about the material, and a
        // hop-by-hop RMS answers a question about duty cycle instead: a click
        // track is 2 % sound and 98 % digital silence, so its mean RMS is 17 dB
        // below its peak and the master envelope — whose 300 ms attack cannot
        // follow a 10 ms burst — settled at 0.1 and left the board almost dark
        // on a signal that is unambiguously playing. Sparse acoustic material
        // has the same shape in a milder form. The peak envelope's own
        // ballistics are §4.1's accent numbers, and it changes nothing on
        // continuous material, where peak and mean coincide.
        rmsPeak.update(target: rms, now: time, dt: dt)
        // **The ramp is 0.02…0.06, not 0.02…0.25 (§11.5).** The wide ramp made
        // the master a *level* spanning 22 dB, and §11.5 deletes exactly that:
        // "master keeps its 'is anything playing' role only; dynamics come from
        // `bed + swell`". As a level it was also the largest single cause of the
        // board dying on quiet material — measured, 31 % of the frames of
        // `cut-transitions` in which the ground truth says music is playing had
        // a board mean under 0.06, because a −34 dBFS piano following a loud
        // section reads 0.05 through an AGC whose reference is still set by the
        // loud section. The lower edge stays where it is: with the AGC gain
        // clamped to 16, a −60 dBFS noise bed reaches **exactly** 0.016 and must
        // stay dark, and the lower edge is placed just above it.
        //
        // The upper edge is 0.030, not 0.25 and not 0.06. Anything wider is
        // still a level, and a level is what §11.5 deletes: the AGC's reference
        // is a 10 s p90, so during a quiet passage that follows a loud one the
        // gain has not yet caught up and a −34 dBFS piano reads 0.048 — which a
        // 0.02…0.25 ramp turns into 0.16 and a 0.02…0.06 ramp into 0.78, in both
        // cases dimming genuinely audible music by the one multiplier that sits
        // downstream of everything §11 does. Measured, the wider ramps left
        // `cut-transitions` completely black for five seconds of each half.
        // Between 0.016 (a −60 dBFS bed at maximum gain) and 0.030 there is
        // nothing but the gain clamp itself, which is where the question "is
        // anything playing" is actually decided.
        let masterTarget = smoothstep(0.018, 0.030, clamp(rmsPeak.value * gain, 0, 1))
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
            ? smoothstep(Self.livelinessFloor, Self.livelinessFull, liveliness.max() ?? 0)
            : 0

        // Onsets: candidates per kind, then winner-take-all across kinds.
        var candidates: [FluxOnsetDetector.Candidate] = []
        for kind in OnsetKind.allCases where lively > 0 {
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
            // Liveliness scales the gesture rather than gating it, so material
            // sitting near the stationary boundary fades in instead of
            // appearing all at once.
            // Which band inside the region actually fired, for §12.4's origin
            // map. A relative comparison between two bands of the same region,
            // so it stays dimensionless (P1).
            let firing = winner.kind.bands.max { bandCurrent[$0] < bandCurrent[$1] }
                ?? winner.kind.bands.lowerBound
            events.append(OnsetEvent(time: winner.time - groupDelay,
                                     kind: winner.kind,
                                     strength: winner.strength,
                                     confidence: winner.confidence * lively,
                                     band: firing))
            if winner.kind == .kick {
                // The transient, not the hop that noticed it.
                tempoTracker.align(toBeatAt: winner.time - groupDelay, now: time)
            }
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
        // §2.3.1 — publish the beat, not just the phase. Computed here, where
        // the phase actually lives, and never recomputed downstream.
        if state.tempo.bpm > 0 {
            state.tempo.nextBeatTime =
                time + (1 - state.tempo.phase) * state.tempo.beatPeriod
        }
        // The grid is only as believable as the signal is lively. Autocorrelating
        // the residual of a *stationary* signal still finds a peak — a 110 Hz
        // sine reported 114.8 BPM at confidence 0.46, comfortably over
        // `usableConfidence`, so wave launched a sweep every beat of a tempo that
        // does not exist and a stationary signal produced a moving board. The
        // same liveliness measure that decides whether an onset is real decides
        // how much of the grid to believe, and for exactly the same reason.
        // …and only as believable as the events under it. A grid with nothing
        // beating on it has been fitted to noise.
        if !events.isEmpty { lastOnsetTime = time }
        let grounded = smoothstep(Self.gridAbandonSeconds, Self.gridGroundedSeconds,
                                  time - lastOnsetTime)
        state.tempo.confidence *= lively * grounded

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

        // §11 — the two slower references. Driven from the same RMS the AGC
        // uses, but referenced against sixty seconds of its own history rather
        // than four, which is the whole difference between a board with a memory
        // and a board that returns to a constant after every hit (P9).
        energy.update(rms: rms, gateOpen: !frozen, now: time, dt: dt)
        state[AnalysisState.Channel.energy] = energy.energy
        state[AnalysisState.Channel.phrase] = energy.phrase
        state[AnalysisState.Channel.section] = energy.section
        state[AnalysisState.Channel.silenceRamp] = energy.silenceRamp
        if energy.noveltyFired { structureChanges += 1 }
        state.structureChanges = structureChanges
        state[AnalysisState.Channel.spread] = Self.spread(of: bandValues)

        return (state, events)
    }

    /// Normalised spectral entropy over the band set (§12.1).
    ///
    /// `spread = −Σ s_b·ln s_b / ln 8` with `s_b = band_b / Σ band`. A bass-only
    /// passage occupies one band and reads near zero; a full-band passage reads
    /// near one. It is what decides how far the hue field fans, so the board
    /// collapses toward one colour exactly when the music does.
    static func spread(of bands: [Double]) -> Double {
        let total = bands.reduce(0, +)
        guard total > QuantileTracker.floor, bands.count > 1 else { return 0 }
        var entropy = 0.0
        for value in bands {
            let share = max(value, 0) / total
            if share > 1e-12 { entropy -= share * log(share) }
        }
        return clamp(entropy / log(Double(bands.count)), 0, 1)
    }

    public func reset() {
        whitening.reset()
        energy.reset()
        rmsPeak.reset()
        structureChanges = 0
        for index in followers.indices { followers[index].reset() }
        for index in normalisers.indices { normalisers[index].reset() }
        for index in gates.indices { gates[index].reset() }
        for kind in OnsetKind.allCases {
            detectors[kind]?.reset()
            accents[kind]?.reset()
        }
        arbiter.reset()
        lastOnsetTime = -.infinity
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
        samplesReceived = 0
        hasStarted = false
    }
}
