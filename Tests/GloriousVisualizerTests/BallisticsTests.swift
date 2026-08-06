import XCTest
@testable import GloriousVisualizer

/// The ballistics, the adaptive levelling and the per-key interlock — the three
/// layers that between them make "the lights don't properly stay on" a
/// structural impossibility rather than a hope.
final class BallisticsTests: XCTestCase {

    // MARK: - AHR

    /// Attack is fast, the peak is *held*, and only then does it decay. Without
    /// the hold a 15 ms attack exists for one analysis hop and can fall between
    /// two display frames.
    func testAttackHoldRelease() {
        var envelope = AHR(attack: 0.015, hold: 0.100, release: 0.320)
        var now = 0.0
        envelope.update(target: 1, now: now, dt: 0.010)
        XCTAssertGreaterThan(envelope.value, 0.4)

        // Through the hold, with nothing arriving, the value does not fall.
        for _ in 0..<8 {
            now += 0.010
            envelope.update(target: 0, now: now, dt: 0.010)
        }
        let held = envelope.value
        XCTAssertGreaterThan(held, 0.4)

        // Past it, it decays on its own time constant.
        now += 0.320
        envelope.update(target: 0, now: now, dt: 0.320)
        XCTAssertLessThan(envelope.value, held * 0.5)
    }

    /// The clamps of §4.2, which are the flicker guarantee at the source: no
    /// envelope anywhere may fall faster than three display frames or 200 ms.
    func testReleaseIsClampedToTheFrameRate() {
        let fast = AHR.clamped(attack: 0.015, hold: 0.001, release: 0.010,
                               frameInterval: 1.0 / 30)
        XCTAssertGreaterThanOrEqual(fast.release, 0.200)
        XCTAssertGreaterThanOrEqual(fast.hold, 2.0 / 30)
        XCTAssertLessThanOrEqual(fast.attack, fast.release / 4)

        // At 15 fps the frame term binds rather than the absolute floor.
        let slow = AHR.clamped(attack: 0.015, hold: 0, release: 0.100,
                               frameInterval: 1.0 / 15)
        XCTAssertEqual(slow.release, 0.200, accuracy: 1e-9)
    }

    /// Wall-clock coefficients: the same elapsed time produces the same decay
    /// whether it arrives as one step or as ten (P2).
    func testDecayDependsOnElapsedTimeNotStepCount() {
        var coarse = AHR(attack: 0.001, hold: 0, release: 0.5)
        var fine = AHR(attack: 0.001, hold: 0, release: 0.5)
        coarse.update(target: 1, now: 0, dt: 0.01)
        fine.update(target: 1, now: 0, dt: 0.01)

        coarse.update(target: 0, now: 1, dt: 0.5)
        for step in 1...10 {
            fine.update(target: 0, now: 1 + Double(step) * 0.05, dt: 0.05)
        }
        XCTAssertEqual(coarse.value, fine.value, accuracy: 1e-6)
    }

    /// Peak markers snap up and fall at a constant rate — physical, not noisy.
    func testGravityPeakSnapsUpAndFallsLinearly() {
        var peak = GravityPeak(fallSeconds: 0.66)
        peak.update(target: 1, dt: 0.033)
        XCTAssertEqual(peak.value, 1, accuracy: 1e-9)
        peak.update(target: 0, dt: 0.33)
        XCTAssertEqual(peak.value, 0.5, accuracy: 0.01)
        peak.update(target: 0, dt: 10)
        XCTAssertEqual(peak.value, 0, accuracy: 1e-9)
    }

    /// A descending smoothstep is a ramp, not an inverted step. Every soft edge
    /// in the render is written that way round.
    func testSmoothstepRunsBothDirections() {
        XCTAssertEqual(smoothstep(0, 1, 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(smoothstep(1, 0, 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(smoothstep(1, 0, 0), 1, accuracy: 1e-9)
        XCTAssertEqual(smoothstep(1, 0, 1), 0, accuracy: 1e-9)
        // Monotonic and bounded in both directions.
        var previous = 1.0
        for step in 0...10 {
            let value = smoothstep(2, 0, Double(step) / 5)
            XCTAssertLessThanOrEqual(value, previous + 1e-12)
            XCTAssertTrue((0...1).contains(value))
            previous = value
        }
    }

    // MARK: - Adaptive levelling

    /// The percentile tracker settles where the fraction it was asked for lies
    /// beneath, whatever the absolute scale — the property that lets one set of
    /// constants serve a -60 dBFS bed and a full-scale mix.
    func testQuantileTrackerIsScaleFree() {
        for scale in [1.0, 0.001, 1000.0] {
            var low = QuantileTracker(percentile: 0.10, window: 1)
            var high = QuantileTracker(percentile: 0.90, window: 1)
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<4000 {
                let sample = Double.random(in: 0...1, using: &generator) * scale
                low.update(sample, dt: 0.01)
                high.update(sample, dt: 0.01)
            }
            XCTAssertEqual(low.value / scale, 0.1, accuracy: 0.09, "scale \(scale)")
            XCTAssertEqual(high.value / scale, 0.9, accuracy: 0.15, "scale \(scale)")
            XCTAssertLessThan(low.value, high.value)
        }
    }

    /// A single outlier cannot move a percentile — the failure the old
    /// peak-driven loudness reference had by construction.
    func testASingleClickCannotMoveTheReference() {
        var high = QuantileTracker(percentile: 0.90, window: 10)
        for _ in 0..<2000 { high.update(0.1, dt: 0.01) }
        let settled = high.value
        high.update(100, dt: 0.01)
        XCTAssertEqual(high.value / settled, 1, accuracy: 0.05)
    }

    /// **Both relative values revolve around 1.0 for a stationary signal, at any
    /// level.** This is the whole threshold vocabulary; if it drifts, every
    /// trigger and gate in the system means something different per track.
    func testStationarySignalsSitAtOne() {
        for level in [0.001, 0.5, 5.0] {
            var follower = RelativeFollower()
            var result = (current: 0.0, average: 0.0)
            for _ in 0..<2000 { result = follower.update(level, dt: 0.0107) }
            XCTAssertEqual(result.current, 1, accuracy: 0.02, "level \(level)")
            XCTAssertEqual(result.average, 1, accuracy: 0.02, "level \(level)")
        }
    }

    /// A band holding nothing must not report a huge ratio on its own leakage:
    /// the floor is a fraction of the whole spectrum's level.
    func testAnEmptyBandDoesNotReportAHugeRatio() {
        var follower = RelativeFollower()
        var result = (current: 0.0, average: 0.0)
        for _ in 0..<2000 { result = follower.update(1e-9, dt: 0.0107, floor: 1e-3) }
        XCTAssertLessThan(result.current, 0.01)
        XCTAssertLessThan(result.average, 0.01)
    }

    /// A hit raises the instantaneous ratio far more than the attenuated one —
    /// which is why triggers use one and motion the other.
    func testAHitRaisesCurrentMoreThanAverage() {
        var follower = RelativeFollower()
        for _ in 0..<2000 { follower.update(0.1, dt: 0.0107) }
        let hit = follower.update(1.0, dt: 0.0107)
        XCTAssertGreaterThan(hit.current, 5)
        XCTAssertGreaterThan(hit.current, hit.average)
    }

    /// The gate has hysteresis, a hold-open minimum and a ramp — the three
    /// anti-chatter terms. It never snaps to zero.
    func testGateHoldsOpenAndRampsOut() {
        var gate = BandGate()
        var now = 0.0
        XCTAssertEqual(gate.update(currentRelative: 1.5, averageRelative: 1.5,
                                   norm: 0.5, now: now, dt: 0.0107), 1, accuracy: 1e-9)
        // Immediately quiet: the hold keeps it open.
        now += 0.05
        XCTAssertEqual(gate.update(currentRelative: 0.2, averageRelative: 0.2,
                                   norm: 0.0, now: now, dt: 0.05), 1, accuracy: 1e-9)
        // Past the hold it closes — but ramps rather than snapping.
        now += 0.100
        let closing = gate.update(currentRelative: 0.2, averageRelative: 0.2,
                                  norm: 0.0, now: now, dt: 0.100)
        XCTAssertLessThan(closing, 1)
        XCTAssertGreaterThan(closing, 0)
        now += 2
        XCTAssertLessThan(gate.update(currentRelative: 0.2, averageRelative: 0.2,
                                      norm: 0.0, now: now, dt: 2), 0.01)
    }

    // MARK: - Per-key interlock

    /// Minimum on-time: once lit, a key stays lit even if the model asks for
    /// black on the very next frame.
    func testKeyStaysLitForTheMinimumOnTime() {
        var key = KeyHold()
        var now = 0.0
        XCTAssertGreaterThan(key.update(0.8, now: now, dt: 1.0 / 30), 0)
        XCTAssertTrue(key.isLit)
        for _ in 0..<4 {
            now += 1.0 / 30
            key.update(0, now: now, dt: 1.0 / 30)
            XCTAssertTrue(key.isLit, "went dark after \(now * 1000) ms")
        }
        // …and beyond it, it is allowed to go out.
        now += 0.2
        key.update(0, now: now, dt: 0.2)
        XCTAssertFalse(key.isLit)
        XCTAssertEqual(key.level, 0, accuracy: 1e-9)
    }

    /// Minimum off-time bounds the toggle rate by construction: one full
    /// on→off→on cycle cannot happen faster than 250 ms.
    func testAKeyCannotToggleFasterThanFourHertz() {
        var key = KeyHold()
        var now = 0.0
        var transitions = 0
        var wasLit = false
        // Ask for a full-scale square wave at 15 Hz — far faster than the
        // interlock may follow.
        for step in 0..<600 {
            now += 1.0 / 300
            key.update(step % 10 < 5 ? 1.0 : 0.0, now: now, dt: 1.0 / 300)
            if key.isLit != wasLit {
                transitions += 1
                wasLit = key.isLit
            }
        }
        // One cycle needs at least 150 + 100 ms, so 2 s allows at most eight of
        // them — sixteen transitions — against the sixty the signal asked for.
        XCTAssertLessThanOrEqual(transitions, 16, "\(transitions) transitions in 2 s")
        XCTAssertLessThanOrEqual(Double(transitions) / 2 / 2, 4.0)
    }

    /// Rising is instant, falling is rate limited: an attack must stay an
    /// attack, and nothing may fall from full to black faster than 200 ms.
    func testRiseIsInstantAndFallIsSlewLimited() {
        var key = KeyHold()
        XCTAssertEqual(key.update(1, now: 0, dt: 1.0 / 30), 1, accuracy: 1e-9)
        // Hold it at full past the minimum on-time…
        var now = 0.0
        while now < 0.2 {
            now += 1.0 / 30
            key.update(1, now: now, dt: 1.0 / 30)
        }
        // …then ask for black. One frame is 1/6 of the 200 ms slew.
        now += 1.0 / 30
        let afterOneFrame = key.update(0, now: now, dt: 1.0 / 30)
        XCTAssertGreaterThan(afterOneFrame, 0.7)
        XCTAssertLessThan(afterOneFrame, 1)
        // Six frames is the whole of it.
        for _ in 0..<6 {
            now += 1.0 / 30
            key.update(0, now: now, dt: 1.0 / 30)
        }
        XCTAssertEqual(key.level, 0, accuracy: 1e-9)
    }

    /// The interlock is a filter, not a source: it can delay darkness, never
    /// invent light.
    func testTheInterlockNeverCreatesLight() {
        var key = KeyHold()
        for step in 0..<200 {
            let level = key.update(0, now: Double(step) / 30, dt: 1.0 / 30)
            XCTAssertEqual(level, 0, accuracy: 1e-12)
        }
    }

    /// Exactly one gamma encode, and it round-trips.
    func testGammaRoundTrips() {
        // From 0.15: below that the encode legitimately quantises to zero,
        // which is the bottom of the board's own resolution.
        for lightness in stride(from: 0.15, through: 1.0, by: 0.05) {
            let byte = KeyInterlock.gamma(lightness)
            XCTAssertEqual(KeyInterlock.decode(byte), lightness, accuracy: 0.02,
                           "lightness \(lightness)")
        }
        XCTAssertEqual(KeyInterlock.gamma(0), 0)
        XCTAssertEqual(KeyInterlock.gamma(1), 255)
        XCTAssertEqual(KeyInterlock.gamma(2), 255)
        XCTAssertEqual(KeyInterlock.gamma(-1), 0)
    }

    /// Gamma spends its resolution where the eye is sensitive: half lightness is
    /// far below half PWM, which is what makes a four-frame fade look like one.
    func testGammaIsPerceptualNotLinear() {
        XCTAssertLessThan(KeyInterlock.gamma(0.5), 80)
        XCTAssertGreaterThan(KeyInterlock.gamma(0.5), 40)
    }
}
