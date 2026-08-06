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
    }

    func run() throws -> Result {
        let track = try signal.track(sampleRate: sampleRate, duration: duration)
        let engine = VisualizerEngine(sampleRate: sampleRate, frameRate: frameRate,
                                      mode: mode, useThemeColor: useThemeColour)
        engine.sensitivity = sensitivity

        var result = Result()
        result.events = track.events
        result.frameInterval = engine.frameInterval

        // M6 and M5 are measured on the control signals at the analysis rate,
        // not on the pixels: "does this need a per-genre constant" is a question
        // about the normalisation layer, and the pixels cannot answer it.
        var bandSums = [Double](repeating: 0, count: AnalysisState.bandCount)
        var bandNormSums = [Double](repeating: 0, count: AnalysisState.bandCount)
        var bandCounts = [Double](repeating: 0, count: AnalysisState.bandCount)
        var detected: [OnsetEvent] = []
        var confidences: [Double] = []
        var bpms: [Double] = []
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
            }
        }

        let dt = engine.frameInterval
        let chunk = 256                       // the mic buffer the design asks for
        var audioPosition = 0
        var random = SeededRandom(seed: 991)
        var scheduled = 0.0
        var lastComposed = 0.0
        var lastColors: [RGB]?

        let totalFrames = Int(duration / dt)
        var frame = 0
        while frame < totalFrames {
            scheduled = Double(frame) * dt
            var wake = scheduled
            if jitter > 0 { wake += abs(random.nextGaussian()) * jitter }
            if let stall, stall.rate > 0 {
                let period = 1 / stall.rate
                if (scheduled + dt).truncatingRemainder(dividingBy: period) < dt {
                    wake += stall.length
                }
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

            let colors = engine.renderFrame(at: scheduled)
            result.frameTimes.append(scheduled)
            result.levels.append(colors.map { colour in
                max(KeyInterlock.decode(colour.red),
                    max(KeyInterlock.decode(colour.green), KeyInterlock.decode(colour.blue)))
            })
            result.colors.append(colors)
            result.tickIntervals.append(scheduled - lastComposed)
            lastComposed = scheduled
            lastColors = colors

            // Catch up by whole intervals: a late wake-up skips the frames whose
            // slots have already passed rather than sliding the clock.
            var next = frame + 1
            while Double(next) * dt < wake - 1e-9 {
                next += 1
                result.droppedFrames += 1
                // The board keeps showing the last frame that was delivered.
                if let lastColors {
                    result.frameTimes.append(Double(next - 1) * dt)
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
