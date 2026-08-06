import XCTest
import GMMKProtocol
@testable import GloriousVisualizer

/// The r2 mechanisms had **no unit coverage at all**: nothing under `Tests/`
/// referenced `FramePackets`, `BeatSchedule`, `EnergyModel`, `ColourField` or
/// `Composition`, so every claim about them rested on the simulator's aggregate
/// numbers. These are the invariants those five files are supposed to hold, and
/// the two anti-vacuity proofs the battery cannot state.
final class CompositionTests: XCTestCase {

    // MARK: - §11.4 composition

    /// §11.4 property 1, and the reason it is a *board-mean* guarantee rather
    /// than a per-key floor: `B0` must stay **below** §6.3's rise threshold, or
    /// no key can ever go dark and M1 and M4 measure nothing.
    func testBedFloorCannotLightAKeyOnItsOwn() {
        XCTAssertLessThan(Composition.bedFloor, KeyHold.riseThreshold,
                          "a bed above the interlock's rise threshold is a per-key floor, "
                          + "which makes M1 and M4 vacuous")
        // The shallowest shape any mode uses, through the bed at rest.
        let shallowest = 0.75      // §12.4's pulse shape at the far edge
        XCTAssertLessThan(Composition.bedFloor * shallowest, KeyHold.riseThreshold)
    }

    func testCompositionMatchesTheStatedFormula() {
        let composition = Composition(phrase: 0.8, section: 0.5, silenceRamp: 0)
        XCTAssertEqual(composition.bed, Composition.bedFloor + Composition.bedScale * 0.5,
                       accuracy: 1e-12)
        XCTAssertEqual(composition.swell,
                       Composition.swellScale * (0.8 - Composition.swellReference * 0.5),
                       accuracy: 1e-12)
        XCTAssertEqual(composition.headroom, 1 - composition.bed - composition.swell,
                       accuracy: 1e-12)
    }

    /// The swell is the PHRASE energy *above* the section floor, so a phrase at
    /// or below `k·Σ` contributes nothing and the board sits on its bed.
    func testSwellIsZeroBelowTheSectionFloor() {
        let composition = Composition(phrase: 0.3, section: 0.9, silenceRamp: 0)
        XCTAssertEqual(composition.swell, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(composition.resting, Composition.bedFloor)
    }

    /// "A hit can only add light, never remove it": the accent is added into
    /// whatever is left, so the level is monotone in the accent and never
    /// exceeds one.
    func testAccentOnlyAddsAndNeverClips() {
        let composition = Composition(phrase: 1, section: 1, silenceRamp: 0)
        var previous = -1.0
        for step in 0...20 {
            let level = composition.level(shape: 1, accent: Double(step) / 20)
            XCTAssertGreaterThanOrEqual(level, previous)
            XCTAssertLessThanOrEqual(level, 1)
            previous = level
        }
    }

    func testSilenceRampScalesTheWholeComposition() {
        let lit = Composition(phrase: 0.6, section: 0.6, silenceRamp: 0)
        let half = Composition(phrase: 0.6, section: 0.6, silenceRamp: 0.5)
        XCTAssertEqual(half.level(shape: 1, accent: 0.4),
                       lit.level(shape: 1, accent: 0.4) * 0.5, accuracy: 1e-12)
        let dark = Composition(phrase: 0.6, section: 0.6, silenceRamp: 1)
        XCTAssertEqual(dark.level(shape: 1, accent: 1), 0, accuracy: 1e-12)
    }

    // MARK: - §6.3 the interlock

    /// "The interlock is a filter, not a source: it cannot create light that the
    /// model did not ask for." Snapping a held key's output up to the rise
    /// threshold did exactly that — and, because the threshold sits above M1 and
    /// M4's 0.10 on-level, it also made both metrics unfailable.
    func testInterlockNeverShowsMoreThanTheModelAskedFor() {
        var key = KeyHold()
        var now = 0.0
        let dt = 1.0 / 30
        // Light it, then drop the model to a level between the fall threshold
        // and the metric's on-level.
        for _ in 0..<10 {
            XCTAssertLessThanOrEqual(key.update(0.5, now: now, dt: dt), 0.5)
            now += dt
        }
        for _ in 0..<30 {
            let shown = key.update(0.08, now: now, dt: dt)
            XCTAssertLessThanOrEqual(shown, 0.5)
            now += dt
        }
        XCTAssertTrue(key.isLit, "0.08 is above the fall threshold, so the key stays lit")
        XCTAssertEqual(key.level, 0.08, accuracy: 1e-9,
                       "a held key shows what the model composed, not the rise threshold")
    }

    func testInterlockHoldsTheMinimumOnTime() {
        var key = KeyHold()
        let dt = 1.0 / 30
        var now = 0.0
        _ = key.update(0.5, now: now, dt: dt)
        XCTAssertTrue(key.isLit)
        now += dt
        while now < KeyHold.minimumOn {
            _ = key.update(0, now: now, dt: dt)
            XCTAssertTrue(key.isLit, "a key must stay lit for the minimum on-time")
            now += dt
        }
        _ = key.update(0, now: now + dt, dt: dt)
        XCTAssertFalse(key.isLit)
    }

    // MARK: - §7.2-R packet budget

    /// `max ≤ 7` is an **invariant of the builder**, not a measurement: the
    /// simulator reports it because it cannot fail there. This is the proof, over
    /// random change sets including the pathological strides §7.2-R names.
    func testFramePacketsNeverCostMoreThanARepaint() {
        let count = GMMKKeyMap.paintableLEDIndices.count
        let repaint = Int(ceil(Double(count) / Double(GMMKPacket.maxKeysPerPacket)))
        var random = SystemRandomNumberGenerator()
        let last = [RGB](repeating: RGB(red: 1, green: 2, blue: 3), count: count)

        func check(_ frame: [RGB], _ label: String) {
            let plan = FramePackets.plan(for: frame, lastSent: last)
            XCTAssertLessThanOrEqual(plan.colourPackets, repaint, label)
        }
        // Every stride, which is the family that produces the worst run plans.
        for stride in 1...12 {
            var frame = last
            for index in Swift.stride(from: 0, to: count, by: stride) {
                frame[index] = RGB(red: 9, green: 9, blue: 9)
            }
            check(frame, "stride \(stride)")
        }
        // …and random sets.
        for _ in 0..<2_000 {
            var frame = last
            for index in 0..<count where Bool.random(using: &random) {
                frame[index] = RGB(red: 9, green: 9, blue: 9)
            }
            check(frame, "random set")
        }
    }

    func testAnUnchangedFrameSendsNothing() {
        let frame = [RGB](repeating: RGB(red: 4, green: 5, blue: 6), count: 24)
        let plan = FramePackets.plan(for: frame, lastSent: frame)
        XCTAssertEqual(plan.colourPackets, 0)
        XCTAssertEqual(plan.changedKeys, 0)
        XCTAssertFalse(plan.fullRepaint)
    }

    func testACoherentRegionCostsOnePacket() {
        var frame = [RGB](repeating: .black, count: 126)
        let last = frame
        for index in 40..<52 { frame[index] = RGB(red: 7, green: 7, blue: 7) }
        let plan = FramePackets.plan(for: frame, lastSent: last)
        XCTAssertEqual(plan.colourPackets, 1)
    }

    // MARK: - §2.3.4 prediction credit

    /// Two consecutive misses stop prediction, two consecutive confirmations
    /// restart it — and **an abandoned grid counts its launched predictions as
    /// misses**, which is what makes `click-120-gap` a test of the credit rule
    /// rather than of the grid-grounding timeout.
    func testCreditStopsPredictionAfterTwoMisses() {
        var schedule = BeatSchedule()
        var state = AnalysisState()
        state.tempo = TempoEstimate(bpm: 120, confidence: 1, phase: 0,
                                    nextBeatTime: 1.0, phaseSigma: 0)
        let envelope = AHR(attack: 0.035, hold: 0.1, release: 0.3)

        // Two confirmations take credit from 0 to 2, which is where prediction
        // is permitted.
        for beat in 0..<2 {
            let time = Double(beat) * 0.5
            state.tempo.nextBeatTime = time + 0.5
            _ = schedule.advance(state: state, latency: 0.01, envelope: envelope,
                                 frameInterval: 1.0 / 30, carry: 0,
                                 previousFrame: time - 1.0 / 30, now: time)
            _ = schedule.offer(onset: OnsetEvent(time: time + 0.5, kind: .kick,
                                                 strength: 1, confidence: 1, band: 0),
                               amplitude: 0.8)
        }
        XCTAssertTrue(schedule.isPredicting)
        let before = schedule.predictionCredit

        // Two beats go by with no onset at all.
        var now = 1.5
        while now < 3.0 {
            state.tempo.nextBeatTime = (now / 0.5).rounded(.up) * 0.5
            _ = schedule.advance(state: state, latency: 0.01, envelope: envelope,
                                 frameInterval: 1.0 / 30, carry: 0,
                                 previousFrame: now - 1.0 / 30, now: now)
            now += 1.0 / 30
        }
        XCTAssertLessThan(schedule.predictionCredit, before)
        XCTAssertFalse(schedule.isPredicting, "two misses must stop prediction")
        XCTAssertGreaterThanOrEqual(schedule.misses, 2)
    }

    func testAbandonedGridCountsItsPendingPredictionsAsMisses() {
        var schedule = BeatSchedule()
        var state = AnalysisState()
        state.tempo = TempoEstimate(bpm: 120, confidence: 1, phase: 0,
                                    nextBeatTime: 0.5, phaseSigma: 0)
        let envelope = AHR(attack: 0.035, hold: 0.1, release: 0.3)
        for beat in 0..<3 {
            let time = Double(beat) * 0.5
            state.tempo.nextBeatTime = time + 0.5
            _ = schedule.advance(state: state, latency: 0.01, envelope: envelope,
                                 frameInterval: 1.0 / 30, carry: 0,
                                 previousFrame: time - 1.0 / 30, now: time)
            _ = schedule.offer(onset: OnsetEvent(time: time + 0.5, kind: .kick,
                                                 strength: 1, confidence: 1, band: 0),
                               amplitude: 0.8)
        }
        XCTAssertTrue(schedule.isPredicting)
        // A beat is published, its time passes with no onset, and then the
        // analyser abandons the grid before the confirmation window closes.
        state.tempo.nextBeatTime = 2.0
        _ = schedule.advance(state: state, latency: 0.01, envelope: envelope,
                             frameInterval: 1.0 / 30, carry: 0,
                             previousFrame: 1.9, now: 1.95)
        let missesBefore = schedule.misses
        state.tempo.confidence = 0
        state.tempo.bpm = 0
        _ = schedule.advance(state: state, latency: 0.01, envelope: envelope,
                             frameInterval: 1.0 / 30, carry: 0,
                             previousFrame: 1.98, now: 2.02)
        XCTAssertGreaterThan(schedule.misses, missesBefore,
                             "an abandoned prediction is still an unconfirmed prediction")
        XCTAssertFalse(schedule.isPredicting)
    }

    // MARK: - §12 the colour field

    /// §12.1: the hue field's **shape** must come from the music. With the
    /// centroid and the spread held still, only the palette rotates — which is
    /// exactly the open-loop board that passes M10a and M10b and is why
    /// `viz-sim` gained `μ_h`.
    func testStaticMusicRotatesThePaletteButNotItsShape() {
        var field = ColourField()
        var now = 0.0
        let dt = 1.0 / 30
        func profile() -> [Double] {
            let hues = (0..<field.columnCount).map { field.hue(column: $0) }
            let mean = hues.reduce(0, +) / Double(hues.count)
            return hues.map { $0 - mean }
        }
        for _ in 0..<60 {
            field.advance(brightness: 0.5, spread: 0.7, phrase: 0.5, section: 0.5,
                          structureChanged: false, now: now, dt: dt)
            now += dt
        }
        let first = profile()
        let firstHue = field.hue(column: 0)
        for _ in 0..<300 {
            field.advance(brightness: 0.5, spread: 0.7, phrase: 0.5, section: 0.5,
                          structureChanged: false, now: now, dt: dt)
            now += dt
        }
        let later = profile()
        for column in 0..<field.columnCount {
            XCTAssertEqual(first[column], later[column], accuracy: 1e-6,
                           "a static spectrum must not change the shape of the field")
        }
        XCTAssertNotEqual(firstHue, field.hue(column: 0), accuracy: 1e-9,
                          "…while the base hue still drifts with Σ")
    }

    /// …and the shape *does* move when the spectrum does. This is the property
    /// `μ_h` measures: §12.1 ties the fan width `A` to the spectral spread, so a
    /// bass-only passage collapses the board toward one hue and a full-band one
    /// fans it out. (The boundary position `x_c` cancels out of the *profile* —
    /// `A·(x − x_c)/16` minus its own mean over `x` is `A·(x − 8)/16` — which is
    /// why `μ_h` is a statement about the fan and the trail, not about `x_c`.)
    func testTheHueFanFollowsTheSpectralSpread() {
        var field = ColourField()
        var now = 0.0
        let dt = 1.0 / 30
        func fan() -> Double { field.hue(column: 16) - field.hue(column: 0) }
        for _ in 0..<120 {
            field.advance(brightness: 0.5, spread: 0.05, phrase: 0.5, section: 0.5,
                          structureChanged: false, now: now, dt: dt)
            now += dt
        }
        let narrow = abs(fan())
        for _ in 0..<120 {
            field.advance(brightness: 0.5, spread: 1.0, phrase: 0.5, section: 0.5,
                          structureChanged: false, now: now, dt: dt)
            now += dt
        }
        let wide = abs(fan())
        XCTAssertLessThan(narrow, 0.05, "a bass-only passage collapses toward one hue")
        XCTAssertGreaterThan(wide, 0.2, "a full-band passage fans across the wheel")
    }

    /// §12.4: no band maps to the centre column. That one line is the largest
    /// single contributor to "the colour is concentrated in the centre".
    func testNoGestureOriginLandsOnTheCentreColumn() {
        let centre = Double(LinearCanvas.columnCount - 1) / 2
        for band in 0..<AnalysisState.bandCount {
            XCTAssertNotEqual(ColourField.originColumn(band: band), centre,
                              "band \(band) maps to the centre column")
        }
    }

    // MARK: - §11 the energy model

    /// §11.3's downward asymmetry is normative: `Σ` may accelerate its rise on
    /// any novelty but its fall only on sustained genuine quiet, and it is
    /// rate-limited to 0.25 per second at all times.
    func testSectionCannotFallFasterThanTheRateLimit() {
        var model = EnergyModel()
        let dt = 1.0 / 93.75
        var now = 0.0
        // Programme material, i.e. a level with dynamics: a steady sine has no
        // range for `E` to normalise against and correctly reads as flat.
        func music(_ time: Double) -> Double {
            0.2 * (0.15 + 0.85 * max(0, sin(2 * .pi * 2 * time)))
        }
        while now < 40 {
            model.update(rms: music(now), gateOpen: true, now: now, dt: dt)
            now += dt
        }
        let peak = model.section
        XCTAssertGreaterThan(peak, 0.2)
        // A hard stop. Even the accelerated path takes ≥ 4 s from full to zero.
        var elapsed = 0.0
        while elapsed < 2.0 {
            model.update(rms: 0, gateOpen: false, now: now, dt: dt)
            now += dt
            elapsed += dt
        }
        XCTAssertGreaterThanOrEqual(model.section,
                                    peak - EnergyModel.sectionFallRateLimit * 2.0 - 1e-6)
    }

    /// A session that begins in silence does not light the board.
    func testEnergyStaysAtZeroUntilTheGateHasOpened() {
        var model = EnergyModel()
        let dt = 1.0 / 93.75
        var now = 0.0
        for _ in 0..<200 {
            model.update(rms: 1e-7, gateOpen: false, now: now, dt: dt)
            now += dt
        }
        XCTAssertEqual(model.energy, 0, accuracy: 1e-12)
        XCTAssertEqual(model.section, 0, accuracy: 1e-12)
    }

    /// §11.3 as amended in r2.1: a room-tone floor the master gate calls "music"
    /// still ramps the board out, because it has no section.
    func testRoomToneRampsOutEvenWithTheGateOpen() {
        var model = EnergyModel()
        let dt = 1.0 / 93.75
        var now = 0.0
        // Music, loudly, long enough to establish a section.
        while now < 40 {
            model.update(rms: 0.2 * (0.15 + 0.85 * max(0, sin(2 * .pi * 2 * now))),
                         gateOpen: true, now: now, dt: dt)
            now += dt
        }
        XCTAssertGreaterThan(model.section, 0.3)
        // Then a stationary floor, with the gate still reporting "playing".
        while now < 160 {
            model.update(rms: 0.0056, gateOpen: true, now: now, dt: dt)
            now += dt
        }
        XCTAssertLessThan(model.section, EnergyModel.quietLevel)
        XCTAssertEqual(model.silenceRamp, 1, accuracy: 1e-9,
                       "a board must give up on a room the way it gives up on silence")
    }

    /// The reference window is a span of **seconds**, not a count of loud hops.
    ///
    /// Sparse material — a click track is the extreme, but any percussive track
    /// with real gaps is the same shape — clears the seeding guard on a few per
    /// cent of its hops. While the guard applied to every update rather than to
    /// seeding alone, those few per cent were the tracker's whole diet: on
    /// `click-112`, 116 hops of 2 806, so a 60 s window became an effective 24
    /// minutes and `p05` and `p95` were still 0.01 dB apart after thirty
    /// seconds. `E` was then decided by whichever hop happened to seed it, and
    /// the board went black for twenty seconds of a thirty second run.
    ///
    /// The invariant that catches it: two burst periods that differ only in
    /// tempo must not produce qualitatively different energy.
    func testSparseMaterialStillSeparatesTheEnergyReference() {
        let dt = 1.0 / 93.75
        /// Peak `E` over the last ten seconds of a burst train at this period.
        func peakEnergy(burstPeriod: Double) -> Double {
            var model = EnergyModel()
            var now = 0.0
            var peak = 0.0
            while now < 30 {
                // A 12 ms burst on digital silence, exactly like the click cases.
                let phase = now.truncatingRemainder(dividingBy: burstPeriod)
                let rms = phase < 0.012 ? 0.08 : 0.0
                model.update(rms: rms, gateOpen: true, now: now, dt: dt)
                if now >= 20 { peak = max(peak, model.energy) }
                now += dt
            }
            return peak
        }
        // 120 BPM and 112 BPM — the two the battery runs, and the pair that
        // differed by 13 dB of reference purely through where the seed landed.
        let fast = peakEnergy(burstPeriod: 0.500)
        let slow = peakEnergy(burstPeriod: 60.0 / 112)
        XCTAssertGreaterThan(fast, 0.2, "a burst must lift E above the reference floor")
        XCTAssertGreaterThan(slow, 0.2,
                             "a 7 % change of tempo must not blank the board: E was "
                             + "pinned at its seed and never cleared 0.05")
        XCTAssertEqual(fast, slow, accuracy: 0.25,
                       "two tempos of the same material must not land on different "
                       + "energy references")
    }
}
