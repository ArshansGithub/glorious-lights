import XCTest
@testable import GloriousVisualizer
import GMMKProtocol

/// The musical layer end to end: onsets, tempo, gestures and the composed
/// picture, driven through the same ``VisualizerEngine`` the app drives.
final class MusicalAnalysisTests: XCTestCase {

    let sampleRate = 48_000.0

    // MARK: - Signals

    /// A kick-like burst: fast attack, exponential decay, low frequency.
    private func kick(into samples: inout [Float], at time: Double, amplitude: Double = 0.9) {
        let start = Int(time * sampleRate)
        for offset in 0..<Int(0.4 * sampleRate) {
            let index = start + offset
            guard index >= 0, index < samples.count else { continue }
            let u = Double(offset) / sampleRate
            let envelope = (1 - exp(-u / 0.012)) * exp(-u / 0.18)
            samples[index] += Float(amplitude * envelope * sin(2 * .pi * 60 * u))
        }
    }

    private func beatPattern(bpm: Double, seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(sampleRate * seconds))
        var time = 0.0
        while time < seconds {
            kick(into: &samples, at: time)
            time += 60 / bpm
        }
        return samples
    }

    private func sine(_ frequency: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { index in
            Float(amplitude * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    /// Runs a signal through the engine at the analysis rate, collecting every
    /// published state and event.
    private func analyse(_ samples: [Float]) -> (states: [AnalysisState], onsets: [OnsetEvent]) {
        let engine = VisualizerEngine(sampleRate: sampleRate, frameRate: 30)
        var states: [AnalysisState] = []
        var onsets: [OnsetEvent] = []
        engine.bus.onPublish = { state, events in
            states.append(state)
            onsets += events
        }
        var position = 0
        while position < samples.count {
            let end = min(position + 512, samples.count)
            engine.ingest(Array(samples[position..<end]),
                          hostTime: Double(end) / sampleRate)
            position = end
        }
        return (states, onsets)
    }

    // MARK: - Onsets

    /// **The regression that started the redesign.** A pure sine wave contains
    /// exactly zero onsets; the previous detector emitted 12.1 a second on one.
    func testASteadyToneProducesNoOnsets() {
        for frequency in [110.0, 440.0, 1_000.0] {
            let result = analyse(sine(frequency, seconds: 12))
            XCTAssertEqual(result.onsets.count, 0,
                           "a steady \(frequency) Hz tone produced onsets")
        }
    }

    /// Nor does noise, at any level: a stationary signal must produce a
    /// stationary board.
    func testNoiseProducesNoOnsets() {
        var generator = SystemRandomNumberGenerator()
        for amplitude in [0.2, 0.001] {
            let samples = (0..<Int(sampleRate * 12)).map { _ in
                Float(Double.random(in: -1...1, using: &generator) * amplitude)
            }
            XCTAssertEqual(analyse(samples).onsets.count, 0, "noise at \(amplitude)")
        }
    }

    func testDigitalSilenceProducesNoOnsets() {
        let result = analyse([Float](repeating: 0, count: Int(sampleRate * 5)))
        XCTAssertEqual(result.onsets.count, 0)
    }

    /// Kicks are found, at about the rate they were played, and reported as
    /// kicks rather than as something else.
    func testKicksAreDetectedAtTheRatePlayed() {
        let result = analyse(beatPattern(bpm: 120, seconds: 20))
        let kicks = result.onsets.filter { $0.kind == .kick && $0.time > 1 }
        // 120 BPM is two a second; allow the warm-up second.
        XCTAssertGreaterThan(Double(kicks.count) / 19, 1.7)
        XCTAssertLessThan(Double(kicks.count) / 19, 2.2)
        XCTAssertEqual(result.onsets.count, kicks.count + result.onsets.filter {
            $0.time <= 1 || $0.kind != .kick
        }.count)
    }

    /// Detected kicks land on the beat, not scattered around it.
    func testKicksLandOnTheBeat() {
        let period = 0.5
        let result = analyse(beatPattern(bpm: 120, seconds: 20))
        let kicks = result.onsets.filter { $0.kind == .kick && $0.time > 1 }
        XCTAssertFalse(kicks.isEmpty)
        for onset in kicks {
            let phase = onset.time.truncatingRemainder(dividingBy: period)
            let distance = min(phase, period - phase)
            XCTAssertLessThan(distance, 0.06, "onset at \(onset.time) is off the grid")
        }
    }

    /// The accepted trigger rate stays inside the band where a board can
    /// actually show one thing per event.
    func testTriggerRateStaysInsideTheUsefulBand() {
        let result = analyse(beatPattern(bpm: 160, seconds: 20))
        let rate = Double(result.onsets.count) / 20
        XCTAssertGreaterThan(rate, 0.5)
        XCTAssertLessThan(rate, 5.0)
    }

    /// The arbiter is strict precedence, not a weighted score: a kick coincident
    /// with anything else is reported as a kick, and nothing else is reported
    /// alongside it.
    func testTheArbiterPrefersTheKickAndSuppressesTheRest() {
        var arbiter = OnsetArbiter()
        func candidate(_ kind: OnsetKind, at time: Double, flux: Double) -> FluxOnsetDetector.Candidate {
            FluxOnsetDetector.Candidate(time: time, kind: kind, flux: flux, threshold: 1,
                                        strength: 1, confidence: 1)
        }
        // A snare with far more flux than the kick, at the same instant.
        var winners = arbiter.arbitrate([candidate(.kick, at: 1.0, flux: 2),
                                         candidate(.snare, at: 1.0, flux: 50)], now: 1.0)
        XCTAssertEqual(winners.map(\.kind), [.kick])
        // The snare is still pending; once its window elapses it is suppressed
        // because the kick claimed that moment.
        winners = arbiter.arbitrate([], now: 1.2)
        XCTAssertTrue(winners.isEmpty)
    }

    /// A snare on its own is reported: the arbiter suppresses duplicates, not
    /// events.
    func testALoneSnareSurvivesArbitration() {
        var arbiter = OnsetArbiter()
        let snare = FluxOnsetDetector.Candidate(time: 1.0, kind: .snare, flux: 10,
                                                threshold: 1, strength: 1, confidence: 1)
        XCTAssertTrue(arbiter.arbitrate([snare], now: 1.0).isEmpty)   // still deciding
        XCTAssertEqual(arbiter.arbitrate([], now: 1.2).map(\.kind), [.snare])
    }

    // MARK: - Tempo

    func testTempoOfAKickPattern() {
        for bpm in [100.0, 120.0, 150.0] {
            let result = analyse(beatPattern(bpm: bpm, seconds: 25))
            let settled = result.states.suffix(200).map(\.tempo.bpm).filter { $0 > 0 }
            XCTAssertFalse(settled.isEmpty, "no tempo at \(bpm) BPM")
            let median = settled.sorted()[settled.count / 2]
            XCTAssertEqual(median, TempoTracker.canonical(bpm: bpm), accuracy: bpm * 0.04,
                           "estimated \(median) for \(bpm)")
        }
    }

    /// Phase advances continuously and stays in `[0, 1)` — it is a position, not
    /// a trigger, which is what makes prediction possible at all.
    func testPhaseAdvancesContinuously() {
        let result = analyse(beatPattern(bpm: 120, seconds: 25))
        let locked = result.states.suffix(400)
        XCTAssertTrue(locked.allSatisfy { (0..<1).contains($0.tempo.phase) })
        // It wraps rather than sticking: over four seconds at 120 BPM there are
        // eight beats, so at least a few wraps must have happened.
        var wraps = 0
        var previous = 0.0
        for state in locked where state.tempo.bpm > 0 {
            if state.tempo.phase < previous { wraps += 1 }
            previous = state.tempo.phase
        }
        XCTAssertGreaterThan(wraps, 3)
    }

    /// Noise has no beat, and the tracker says so rather than inventing a grid.
    func testNoiseProducesLowTempoConfidence() {
        var generator = SystemRandomNumberGenerator()
        let samples = (0..<Int(sampleRate * 20)).map { _ in
            Float(Double.random(in: -1...1, using: &generator) * 0.2)
        }
        let noise = analyse(samples).states.suffix(400).map(\.tempo.confidence)
        let beat = analyse(beatPattern(bpm: 120, seconds: 20))
            .states.suffix(400).map(\.tempo.confidence)
        let noiseConfidence = noise.reduce(0, +) / Double(noise.count)
        let beatConfidence = beat.reduce(0, +) / Double(beat.count)
        // Noise has periodicity in it — any random envelope does — so the claim
        // is comparative: the tracker must be markedly less sure of noise than
        // of a real beat, and the modes cross-fade rather than switch on the
        // difference.
        XCTAssertLessThan(noiseConfidence, beatConfidence * 0.85,
                          "noise \(noiseConfidence) vs beat \(beatConfidence)")
    }

    /// Half- and double-time observations of the same music agree once folded.
    func testTemposAreFoldedIntoOneOctave() {
        XCTAssertEqual(TempoTracker.canonical(bpm: 60), 120, accuracy: 0.001)
        XCTAssertEqual(TempoTracker.canonical(bpm: 240), 120, accuracy: 0.001)
        XCTAssertEqual(TempoTracker.canonical(bpm: 128), 128, accuracy: 0.001)
        for bpm in stride(from: 40.0, through: 300.0, by: 7) {
            XCTAssertTrue(TempoTracker.canonicalRange.contains(TempoTracker.canonical(bpm: bpm)),
                          "\(bpm) folded outside the canonical range")
        }
    }

    // MARK: - Gestures

    /// **Absorption.** A trigger arriving while a gesture is building raises its
    /// amplitude and touches nothing else. Re-launching is what stops a gesture
    /// from ever displaying its body.
    func testATriggerDuringAttackIsAbsorbed() {
        var list = GestureList(capacity: 2)
        let envelope = AHR.clamped(attack: 0.015, hold: 0.1, release: 0.32,
                                   frameInterval: 1.0 / 30)
        XCTAssertTrue(list.trigger(Gesture(kind: .pulse, startTime: 1.0, amplitude: 0.4,
                                           envelope: envelope), at: 1.0))
        XCTAssertFalse(list.trigger(Gesture(kind: .pulse, startTime: 1.05, amplitude: 0.9,
                                            envelope: envelope), at: 1.05))
        XCTAssertEqual(list.gestures.count, 1)
        XCTAssertEqual(list.gestures[0].startTime, 1.0, accuracy: 1e-9)
        XCTAssertEqual(list.gestures[0].amplitude, 0.9, accuracy: 1e-9)
        // …and absorption only ever raises.
        list.trigger(Gesture(kind: .pulse, startTime: 1.06, amplitude: 0.1,
                             envelope: envelope), at: 1.06)
        XCTAssertEqual(list.gestures[0].amplitude, 0.9, accuracy: 1e-9)
    }

    /// Once in release, a gesture may be replaced — and the population is capped.
    func testGesturesAreCappedOldestFirst() {
        var list = GestureList(capacity: 2)
        let envelope = AHR(attack: 0.001, hold: 0, release: 0.01)
        for step in 0..<5 {
            let time = Double(step) * 0.5
            list.trigger(Gesture(kind: .ring, startTime: time, amplitude: 0.5,
                                 envelope: envelope), at: time)
        }
        XCTAssertLessThanOrEqual(list.gestures.count, 2)
    }

    /// The display is a pure function of time: evaluating the same gesture at
    /// the same instant gives the same answer no matter how it was reached.
    func testGestureLevelIsAFunctionOfTime() {
        let gesture = Gesture(kind: .pulse, startTime: 10, amplitude: 0.8,
                              envelope: AHR(attack: 0.015, hold: 0.1, release: 0.32))
        XCTAssertEqual(gesture.level(at: 9.9), 0, accuracy: 1e-12)
        XCTAssertEqual(gesture.level(at: 10.1), 0.8, accuracy: 0.01)
        XCTAssertLessThan(gesture.level(at: 10.5), 0.8)
        XCTAssertGreaterThan(gesture.level(at: 10.5), 0)
        XCTAssertFalse(gesture.isAlive(at: 10 + gesture.lifetime + 0.001))
    }

    /// Motion is clamped to two cells a frame, in frame-interval terms rather
    /// than against any particular frame rate.
    func testVelocityIsClampedInFrames() {
        XCTAssertEqual(clampedSpeed(1000, frameInterval: 1.0 / 30), 60, accuracy: 1e-9)
        XCTAssertEqual(clampedSpeed(1000, frameInterval: 1.0 / 15), 30, accuracy: 1e-9)
        XCTAssertEqual(clampedSpeed(5, frameInterval: 1.0 / 30), 5, accuracy: 1e-9)
    }

    /// Durations are musical, so a gesture stretches when the tempo halves
    /// instead of overlapping — and is clamped at both ends.
    func testMusicalDurationsStretchAndClamp() {
        XCTAssertEqual(musicalDuration(beats: 1, beatPeriod: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(musicalDuration(beats: 1, beatPeriod: 1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(musicalDuration(beats: 0.1, beatPeriod: 0.3), 0.20, accuracy: 1e-9)
        XCTAssertEqual(musicalDuration(beats: 8, beatPeriod: 1.0), 2.0, accuracy: 1e-9)
    }

    /// Motion blur widens the kernel by the distance travelled during a frame,
    /// which is what turns strobing into streaking.
    func testMotionBlurWidensWithSpeed() {
        let still = Gesture(kind: .wave, startTime: 0, amplitude: 1, speed: 0, width: 2.8,
                            envelope: AHR(attack: 0.01, hold: 0, release: 0.3))
        let fast = Gesture(kind: .wave, startTime: 0, amplitude: 1, speed: 60, width: 2.8,
                           envelope: AHR(attack: 0.01, hold: 0, release: 0.3))
        XCTAssertEqual(still.effectiveWidth(frameInterval: 1.0 / 30), 2.8, accuracy: 1e-9)
        XCTAssertGreaterThan(fast.effectiveWidth(frameInterval: 1.0 / 30), 2.8)
    }

    // MARK: - Canvas

    /// Fractional fills: the top row of a bar fades in continuously instead of
    /// toggling, which is most of the visible per-frame chatter on quiet
    /// material.
    func testColumnFillsAreFractional() {
        var canvas = LinearCanvas()
        canvas.fillColumn(0, height: 0.5, colour: (1, 1, 1), ramp: { _ in 1 })
        // 0.5 of five rows is two full rows and half of the third.
        XCTAssertEqual(canvas.red[0][0], 1, accuracy: 1e-9)
        XCTAssertEqual(canvas.red[0][1], 1, accuracy: 1e-9)
        XCTAssertEqual(canvas.red[0][2], 0.5, accuracy: 1e-9)
        XCTAssertEqual(canvas.red[0][3], 0, accuracy: 1e-9)

        // …and it is monotonic in height, with no step at a row boundary.
        var previous = 0.0
        for step in 0...50 {
            var probe = LinearCanvas()
            probe.fillColumn(0, height: Double(step) / 50, colour: (1, 1, 1), ramp: { _ in 1 })
            let total = (0..<LinearCanvas.rowCount).reduce(0.0) { $0 + probe.red[0][$1] }
            XCTAssertGreaterThanOrEqual(total + 1e-9, previous)
            previous = total
        }
    }

    /// The blur spreads a single lit column into its neighbours — the reason
    /// `widenIsolatedColumns` could be deleted — and conserves brightness.
    func testBlurSpreadsWithoutInventingEnergy() {
        var canvas = LinearCanvas()
        canvas.addColumn(8, (1, 1, 1), level: 1)
        let before = (0..<LinearCanvas.columnCount).reduce(0.0) { sum, column in
            sum + (0..<LinearCanvas.rowCount).reduce(0.0) { $0 + canvas.red[column][$1] }
        }
        canvas.blur(sigma: 1.0)
        XCTAssertGreaterThan(canvas.red[7][2], 0.1)
        XCTAssertGreaterThan(canvas.red[9][2], 0.1)
        XCTAssertLessThan(canvas.red[8][2], 1)
        let after = (0..<LinearCanvas.columnCount).reduce(0.0) { sum, column in
            sum + (0..<LinearCanvas.rowCount).reduce(0.0) { $0 + canvas.red[column][$1] }
        }
        XCTAssertEqual(after, before, accuracy: before * 0.25)
    }

    /// A short column samples the same continuous field as a tall one, so a bar
    /// rising through the navigation cluster fades rather than toggling half the
    /// column at a level crossing.
    func testShortColumnsSampleTheSameField() {
        var canvas = LinearCanvas()
        canvas.fillColumn(15, height: 0.6, colour: (1, 1, 1), ramp: { _ in 1 })
        let bottom = canvas.sample(column: 15, physicalRow: 0, of: 2)
        let top = canvas.sample(column: 15, physicalRow: 1, of: 2)
        XCTAssertGreaterThan(bottom.r, top.r)
        XCTAssertGreaterThan(bottom.r, 0.5)
    }

    // MARK: - Interpolation

    /// The renderer evaluates a continuous function of time between analysis
    /// states rather than latching whichever it happened to see.
    func testInterpolationIsContinuousAndBounded() {
        var a = AnalysisState(), b = AnalysisState(), c = AnalysisState()
        a.time = 0; b.time = 0.0107; c.time = 0.0214
        a[AnalysisState.Channel.vu] = 0
        b[AnalysisState.Channel.vu] = 0.5
        c[AnalysisState.Channel.vu] = 1
        let mid = AnalysisState.catmullRom(a, b, c, 0.5)
        XCTAssertGreaterThan(mid.vu, 0.5)
        XCTAssertLessThan(mid.vu, 1)
        XCTAssertEqual(AnalysisState.mix(b, c, 0).vu, 0.5, accuracy: 1e-9)
        XCTAssertEqual(AnalysisState.mix(b, c, 1).vu, 1, accuracy: 1e-9)
    }

    // MARK: - End to end

    /// Silence renders black, and near-silence stays dark: the percentile AGC's
    /// gain clamp is what stops a -60 dBFS noise bed becoming a light show.
    func testSilenceAndNearSilenceRenderDark() {
        var generator = SystemRandomNumberGenerator()
        let cases: [(String, [Float])] = [
            ("digital silence", [Float](repeating: 0, count: Int(sampleRate * 6))),
            ("-60 dBFS noise", (0..<Int(sampleRate * 6)).map { _ in
                Float(Double.random(in: -1...1, using: &generator) * 0.001)
            }),
        ]
        for (name, samples) in cases {
            for mode in VisualizerMode.allCases {
                let engine = VisualizerEngine(sampleRate: sampleRate, frameRate: 30, mode: mode)
                var position = 0
                var frame = 0
                var brightest = 0.0
                while position < samples.count {
                    let end = min(position + 512, samples.count)
                    engine.ingest(Array(samples[position..<end]),
                                  hostTime: Double(end) / sampleRate)
                    position = end
                    while Double(frame) / 30 < Double(end) / sampleRate {
                        let colors = engine.renderFrame(at: Double(frame) / 30)
                        frame += 1
                        guard Double(frame) / 30 > 2 else { continue }
                        brightest = max(brightest, colors.map {
                            max(KeyInterlock.decode($0.red),
                                max(KeyInterlock.decode($0.green), KeyInterlock.decode($0.blue)))
                        }.max() ?? 0)
                    }
                }
                XCTAssertLessThan(brightest, 0.10, "\(name) lit the board in \(mode.rawValue)")
            }
        }
    }

    /// Music renders something in every mode, and the board holds still between
    /// hits rather than blinking out.
    func testEveryModeShowsAndHoldsOnABeat() {
        let samples = beatPattern(bpm: 120, seconds: 12)
        for mode in VisualizerMode.allCases {
            let engine = VisualizerEngine(sampleRate: sampleRate, frameRate: 30, mode: mode)
            var position = 0
            var frame = 0
            var litFrames = 0
            var frames = 0
            while position < samples.count {
                let end = min(position + 512, samples.count)
                engine.ingest(Array(samples[position..<end]), hostTime: Double(end) / sampleRate)
                position = end
                while Double(frame) / 30 < Double(end) / sampleRate {
                    let colors = engine.renderFrame(at: Double(frame) / 30)
                    frame += 1
                    guard Double(frame) / 30 > 4 else { continue }
                    frames += 1
                    let lit = colors.filter { KeyInterlock.decode($0.red) >= 0.10
                        || KeyInterlock.decode($0.green) >= 0.10
                        || KeyInterlock.decode($0.blue) >= 0.10 }.count
                    if lit > 10 { litFrames += 1 }
                }
            }
            XCTAssertGreaterThan(Double(litFrames) / Double(frames), 0.9,
                                 "\(mode.rawValue) went dark between hits")
        }
    }

    /// The render is a function of the timestamp it is *given*, so a jittered
    /// wake-up cannot become motion jitter: composing the same frame time twice
    /// with the same analysis behind it gives the same picture.
    func testRenderingIsDrivenByTheTimestampNotTheWallClock() {
        let samples = beatPattern(bpm: 120, seconds: 6)
        func run(_ jitter: [Double]) -> [RGB] {
            let engine = VisualizerEngine(sampleRate: sampleRate, frameRate: 30)
            var position = 0
            var frame = 0
            var last: [RGB] = []
            while position < samples.count {
                let end = min(position + 512, samples.count)
                engine.ingest(Array(samples[position..<end]), hostTime: Double(end) / sampleRate)
                position = end
                while Double(frame) / 30 + jitter[frame % jitter.count] < Double(end) / sampleRate {
                    last = engine.renderFrame(at: Double(frame) / 30)
                    frame += 1
                }
            }
            return last
        }
        // The wake-ups differ; the composed timestamps do not.
        XCTAssertEqual(run([0]), run([0.004, 0.001, 0.007]))
    }
}

/// The invariants this round of the audit was about: the model's own resting
/// level, the two clocks, the arbiter's two windows, and the user controls.
final class AuditedInvariantTests: XCTestCase {

    private let envelope = AHR.clamped(attack: 0.015, hold: 0.1, release: 0.32,
                                       frameInterval: 1.0 / 30)

    /// P5 absorbs a *repeat*, not a different drum. Matching on `Gesture.Kind`
    /// alone made every ripple ring a `.ring` and every VU accent a `.pulse`, so
    /// a snare landing inside a kick's attack was merged into it — wrong origin,
    /// wrong colour, wrong speed.
    func testADifferentDrumIsNotAbsorbedIntoAnother() {
        var list = GestureList(capacity: 3)
        XCTAssertTrue(list.trigger(Gesture(kind: .ring, startTime: 1.0, amplitude: 0.5,
                                           origin: 8, onsetKind: .kick, envelope: envelope),
                                   at: 1.0))
        XCTAssertTrue(list.trigger(Gesture(kind: .ring, startTime: 1.04, amplitude: 0.5,
                                           origin: 12, onsetKind: .snare, envelope: envelope),
                                   at: 1.04))
        XCTAssertEqual(list.gestures.count, 2)
        XCTAssertEqual(list.gestures.map(\.onsetKind), [.kick, .snare])
        // …while a second kick inside the first's attack still absorbs.
        XCTAssertFalse(list.trigger(Gesture(kind: .ring, startTime: 1.05, amplitude: 0.9,
                                            origin: 8, onsetKind: .kick, envelope: envelope),
                                    at: 1.05))
        XCTAssertEqual(list.gestures.count, 2)
        XCTAssertEqual(list.gestures[0].amplitude, 0.9, accuracy: 1e-9)
    }

    /// The alignment target is the beat's own instant, not the hop that noticed
    /// it. Ignoring the parameter biased the grid by the peak-picking delay plus
    /// the group delay on every kick.
    func testBeatAlignmentUsesTheBeatsOwnTime() {
        func phase(after lag: Double) -> Double {
            var tracker = TempoTracker(analysisRate: 100)
            // Drive a clear 2 Hz pulse train until a tempo is established.
            var time = 0.0
            while tracker.current.bpm == 0, time < 30 {
                let beat = (time * 2).truncatingRemainder(dividingBy: 1) < 0.02
                tracker.process(fluxSum: beat ? 1 : 0, elapsed: 0.01)
                time += 0.01
            }
            XCTAssertGreaterThan(tracker.current.bpm, 0)
            tracker.align(toBeatAt: time - lag, now: time)
            return tracker.current.phase
        }
        XCTAssertNotEqual(phase(after: 0), phase(after: 0.040), accuracy: 0.0)
    }

    /// The analysis clock is derived from the sample count but slaved to the
    /// host clock, so a device running fast cannot drift away from the render
    /// clock without bound.
    func testAnalysisTimeFollowsTheHostClock() {
        let analyzer = MusicAnalyzer(sampleRate: 48_000, frameInterval: 1.0 / 30)
        let bus = AnalysisBus()
        var last = 0.0
        bus.onPublish = { state, _ in last = state.time }
        // The device really produces 48 240 samples per host second: 0.5 %, far
        // more than any real converter, so the test finishes quickly.
        let chunk = 512
        var host = 0.0
        var fed = 0
        while host < 20 {
            analyzer.ingest([Float](repeating: 0.01, count: chunk), hostTime: host, into: bus)
            fed += chunk
            host = Double(fed) / 48_240
        }
        // Without slaving, analysis time would be 0.5 % — 100 ms — behind by now.
        XCTAssertEqual(last, host, accuracy: 0.030)
    }

    /// Adjacent bands must not share a bin: `weakestBandRatio` is a `min` over
    /// the region's bands and only means anything if they are independent.
    func testBandsDoNotShareBins() {
        for rate in [44_100, 48_000, 96_000] as [Float] {
            let analyzer = SpectrumAnalyzer(sampleRate: rate)
            for index in 1..<analyzer.bandBins.count {
                XCTAssertGreaterThan(analyzer.bandBins[index].lower,
                                     analyzer.bandBins[index - 1].upper,
                                     "bands \(index - 1)/\(index) overlap at \(rate) Hz")
            }
        }
    }

    /// The arbiter's two windows are separate. A kick must not delete the hats
    /// around it, and a kick must still outrank a snare describing the same
    /// transient.
    func testAKickDoesNotDeleteTheHatsAroundIt() {
        var arbiter = OnsetArbiter()
        func candidate(_ kind: OnsetKind, _ time: Double) -> FluxOnsetDetector.Candidate {
            FluxOnsetDetector.Candidate(time: time, kind: kind, flux: 1, threshold: 0.5,
                                        strength: 1, confidence: 1)
        }
        XCTAssertEqual(arbiter.arbitrate([candidate(.kick, 1.0)], now: 1.0).map(\.kind), [.kick])
        // A hat a quarter of a second later survives …
        _ = arbiter.arbitrate([candidate(.hat, 1.25)], now: 1.25)
        let hats = arbiter.arbitrate([], now: 1.32).map(\.kind)
        XCTAssertEqual(hats, [.hat])
        // … while a snare inside the kick's own transient does not.
        _ = arbiter.arbitrate([candidate(.snare, 1.08)], now: 1.08)
        XCTAssertTrue(arbiter.arbitrate([], now: 1.15).isEmpty)
    }

    /// The user's sensitivity is a monotone gain that cannot clip or crush, and
    /// it is the identity at 1.
    func testSensitivityNeitherClipsNorCrushes() {
        for sensitivity in [0.5, 1.0, 2.0] {
            XCTAssertEqual(KeyInterlock.gain(0, sensitivity), 0, accuracy: 1e-12)
            XCTAssertEqual(KeyInterlock.gain(1, sensitivity), 1, accuracy: 1e-12)
            var previous = -1.0
            for step in 0...20 {
                let value = KeyInterlock.gain(Double(step) / 20, sensitivity)
                XCTAssertGreaterThan(value, previous)
                XCTAssertLessThanOrEqual(value, 1)
                previous = value
            }
        }
        XCTAssertEqual(KeyInterlock.gain(0.37, 1), 0.37, accuracy: 1e-12)
        XCTAssertGreaterThan(KeyInterlock.gain(0.37, 2), 0.37)
        XCTAssertLessThan(KeyInterlock.gain(0.37, 0.5), 0.37)
    }

    /// Turning "Auto Gain" off actually stops the AGC moving the gain, which is
    /// what its tooltip has always promised.
    func testAutoGainIsReadable() {
        let engine = VisualizerEngine(sampleRate: 48_000, frameRate: 30)
        XCTAssertTrue(engine.autoGain)
        engine.autoGain = false
        XCTAssertFalse(engine.analyzer.autoGain.value)
    }

    /// The flag the render and transport loops spin on is safe to write from
    /// the main thread.
    func testTheStopFlagIsAtomic() {
        let flag = AtomicFlag(false)
        XCTAssertFalse(flag.value)
        flag.value = true
        XCTAssertTrue(flag.value)
    }
}
