import Foundation
import GMMKProtocol
import GloriousVisualizer

/// Runs one case through the real engine with **decoupled audio and display
/// clocks**, which is the whole reason this harness was rewritten.
///
/// The old simulator fed exactly one frame's worth of audio and then rendered,
/// in lockstep, with a fixed frame interval. The aliasing class of bug — the
/// renderer latching whichever analysis state it happened to see, at an
/// arbitrary phase — **could not occur in the simulator at all**. That is why it
/// survived a tuning pass. Here audio is delivered on its own clock in small
/// chunks, the display wakes on a jittered clock, and frames are composed for
/// their *scheduled* time, so the interpolation path is genuinely exercised.
struct SimRun {

    var signal: Signal
    var mode: VisualizerMode
    var sampleRate: Double
    var frameRate: Double
    var duration: Double
    /// Standard deviation of Gaussian jitter on the display wake-up, seconds.
    var jitter: Double = 0
    /// A periodic transport stall: `(seconds, hertz)`.
    var stall: (length: Double, rate: Double)?
    var sensitivity: Double = 1
    var useThemeColour = false
    /// The display-side delay of the `/latency` arm (§10.1): the frame composed
    /// for `t` is recorded as *visible* at `t + L_out`.
    ///
    /// **M8 is only meaningful with this on.** A simulator that shows a frame the
    /// instant it is composed is measuring the model, not the pipeline, and
    /// would report a beat alignment the hardware cannot achieve.
    var outputLatency: Double = 0

    /// What one run produced, in the form every metric is computed from.
    struct Result {
        var frameTimes: [Double] = []
        /// Per displayed frame, the gamma-decoded lightness of every LED.
        var levels: [[Double]] = []
        /// Per displayed frame, the colours as sent, for the movie writer.
        var colors: [[RGB]] = []
        /// Intervals between the timestamps frames were **composed for**, for M7.
        ///
        /// Not the wake-to-wake intervals: the design's whole claim is that the
        /// render clock is fixed and that a late wake-up costs a *skipped* frame
        /// rather than a stretched one (P6). Measuring wake times would measure
        /// the injected jitter, which is the input to the experiment rather than
        /// its result.
        var tickIntervals: [Double] = []
        var droppedFrames = 0
        var staleFrames = 0
        var detectedOnsets: [OnsetEvent] = []
        var events: [(time: Double, kind: OnsetKind)] = []
        /// Mean AVERAGE_RELATIVE per band over the run after the warm-up, for M6.
        var bandAverageRelative = [Double](repeating: 0, count: AnalysisState.bandCount)
        var bandPresent = [Bool](repeating: false, count: AnalysisState.bandCount)
        var tempoConfidence: [Double] = []
        var bpm: [Double] = []
        var frameInterval: Double = 1.0 / 30
        /// The user sensitivity this run used, which the on-threshold follows.
        var sensitivity: Double = 1
        /// When each frame was actually *visible*: `t_scheduled + L_out`. M8
        /// measures against these, never against the composition times.
        var displayTimes: [Double] = []
        /// Exact beat times from the generator, for M8.
        var beats: [Double] = []
        /// The generator's own RMS envelope, for M9b and M9c.
        var rmsEnvelope: [(time: Double, rms: Double)] = []
        /// §7.2-R: colour packets per delivered frame, and how many frames fell
        /// back to a full repaint. Produced by running the real
        /// ``FramePackets/plan(for:lastSent:)`` over consecutive frames, which is
        /// the only place that budget can be checked without hardware.
        var packetCounts: [Int] = []
        var fullRepaints = 0
        /// `Φ`, `Σ` and `E` at the analysis rate, for the report.
        var phrase: [Double] = []
        var section: [Double] = []
        var energy: [Double] = []
        var phaseSigma: [Double] = []
        /// Every distinct beat the tracker published, so the grid's own offset
        /// against the ground truth can be measured separately from the
        /// scheduler's. Without it "off beat" cannot be attributed.
        var publishedBeats: [Double] = []
        /// What §2.3.4's credit rule did: launches, confirmations, misses.
        var beatLaunches = 0
        var beatConfirmations = 0
        var beatMisses = 0
    }

    func run() throws -> Result {
        let track = try signal.track(sampleRate: sampleRate, duration: duration)
        let engine = VisualizerEngine(sampleRate: sampleRate, frameRate: frameRate,
                                      mode: mode, useThemeColor: useThemeColour)
        engine.sensitivity = sensitivity

        var result = Result()
        result.events = track.events
        result.beats = track.beats
        result.rmsEnvelope = track.rmsEnvelope
        result.frameInterval = engine.frameInterval
        result.sensitivity = sensitivity

        // M6 and M5 are measured on the control signals at the analysis rate,
        // not on the pixels: "does this need a per-genre constant" is a question
        // about the normalisation layer, and the pixels cannot answer it.
        var bandSums = [Double](repeating: 0, count: AnalysisState.bandCount)
        var bandNormSums = [Double](repeating: 0, count: AnalysisState.bandCount)
        var bandCounts = [Double](repeating: 0, count: AnalysisState.bandCount)
        var detected: [OnsetEvent] = []
        var confidences: [Double] = []
        var bpms: [Double] = []
        var phrases: [Double] = []
        var sections: [Double] = []
        var energies: [Double] = []
        var sigmas: [Double] = []
        var published: [Double] = []
        engine.bus.onPublish = { state, onsets in
            detected += onsets
            // The first five seconds are the warm-up the design explicitly
            // allows for; M6 is a claim about steady state.
            if state.time >= 5 {
                for band in 0..<AnalysisState.bandCount {
                    // Averaged over *every* hop, not only the loud ones:
                    // conditioning on the band being above its own floor selects
                    // the peaks and would report a ratio above 1 for any
                    // percussive band no matter how good the normalisation is.
                    bandSums[band] += state.averageRelative(band)
                    bandNormSums[band] += state.share(band)
                    bandCounts[band] += 1
                }
                confidences.append(state.tempo.confidence)
                if state.tempo.bpm > 0 { bpms.append(state.tempo.bpm) }
                phrases.append(state.phrase)
                sections.append(state.section)
                energies.append(state.energy)
                sigmas.append(state.tempo.phaseSigma)
                let beat = state.tempo.nextBeatTime
                if beat > 0, published.last.map({ abs($0 - beat) > 0.2 }) ?? true {
                    published.append(beat)
                }
            }
        }

        let dt = engine.frameInterval
        let chunk = 256                       // the mic buffer the design asks for
        var audioPosition = 0
        var random = SeededRandom(seed: 991)
        var scheduled = 0.0
        var lastComposed = 0.0
        var lastColors: [RGB]?
        var lastPacked: [RGB]?

        let totalFrames = Int(duration / dt)
        var frame = 0
        while frame < totalFrames {
            scheduled = Double(frame) * dt
            var wake = scheduled
            if jitter > 0 { wake += abs(random.nextGaussian()) * jitter }
            // A transport stall is **not** a render-clock stall (P6). The frame
            // is still composed on its own grid slot and at its own timestamp;
            // what a stalled transport costs is *delivery* — the board goes on
            // showing the last frame that made it out. Adding the stall to the
            // display wake-up instead modelled the render thread blocking on
            // USB, which is precisely the architecture the redesign removed, and
            // it made the M7 tick bound report the injected stall as a clock
            // failure.
            var stalled = false
            if let stall, stall.rate > 0 {
                let period = 1 / stall.rate
                let phase = scheduled.truncatingRemainder(dividingBy: period)
                stalled = phase < stall.length
            }

            // Audio arrives on its own clock, in small buffers, up to the moment
            // the display actually wakes.
            let target = min(Int(wake * sampleRate), track.samples.count)
            while audioPosition < target {
                let end = min(audioPosition + chunk, target)
                engine.ingest(Array(track.samples[audioPosition..<end]),
                              hostTime: Double(end) / sampleRate)
                audioPosition = end
            }

            // The transport's contribution to `L̂`, reported before the frame
            // that will use it is composed. On hardware this comes from the
            // echoed `END`; here it is the arm's own injected delay, which is
            // the same quantity measured the same way (§8.2-R).
            engine.reportDelivery(lag: outputLatency)
            let colors = engine.renderFrame(at: scheduled)
            result.tickIntervals.append(scheduled - lastComposed)
            lastComposed = scheduled
            // What the *board* shows: the newly composed frame, or the last one
            // that was delivered if the transport is mid-stall.
            let shown = stalled ? (lastColors ?? colors) : colors
            if stalled { result.droppedFrames += 1 } else { lastColors = colors }
            if !stalled {
                let plan = FramePackets.plan(for: colors, lastSent: lastPacked)
                lastPacked = colors
                result.packetCounts.append(plan.colourPackets)
                if plan.fullRepaint { result.fullRepaints += 1 }
            }
            result.frameTimes.append(scheduled)
            result.displayTimes.append(scheduled + outputLatency)
            result.levels.append(shown.map { colour in
                max(KeyInterlock.decode(colour.red),
                    max(KeyInterlock.decode(colour.green), KeyInterlock.decode(colour.blue)))
            })
            result.colors.append(shown)

            // Catch up by whole intervals: a late wake-up skips the frames whose
            // slots have already passed rather than sliding the clock.
            var next = frame + 1
            while Double(next) * dt < wake - 1e-9 {
                next += 1
                result.droppedFrames += 1
                // The board keeps showing the last frame that was delivered.
                if let lastColors {
                    result.frameTimes.append(Double(next - 1) * dt)
                    result.displayTimes.append(Double(next - 1) * dt + outputLatency)
                    result.levels.append(result.levels[result.levels.count - 1])
                    result.colors.append(lastColors)
                }
            }
            frame = next
        }

        result.detectedOnsets = detected
        result.staleFrames = engine.telemetry.stale
        result.tempoConfidence = confidences
        result.bpm = bpms
        result.phrase = phrases
        result.section = sections
        result.energy = energies
        result.phaseSigma = sigmas
        result.publishedBeats = published
        let beat = engine.renderer.beatTelemetry
        result.beatLaunches = beat.launches
        result.beatConfirmations = beat.confirmations
        result.beatMisses = beat.misses
        for band in 0..<AnalysisState.bandCount where bandCounts[band] > 0 {
            result.bandAverageRelative[band] = bandSums[band] / bandCounts[band]
            // "Present" means the band carried a real share of the spectrum,
            // which is the analyser's own test for a band being empty. A
            // percentile-normalised level cannot answer this: normalisation
            // stretches an empty band's leakage across the full range too.
            result.bandPresent[band] =
                bandNormSums[band] / bandCounts[band] > MusicAnalyzer.emptyBandFraction * 5
        }
        return result
    }
}
