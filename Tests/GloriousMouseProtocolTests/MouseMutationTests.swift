import XCTest
@testable import GloriousMouseProtocol

/// What each `gmmk-cli mouse` setter does to the blob, at byte level: synthetic
/// blob in, expected bytes out.
///
/// Every one of these commands is a read-modify-write of the whole 520-byte
/// report (`docs/mouse-protocol.md` §4), so "did the right byte change, and did
/// nothing else" is the only property that can be checked without hardware —
/// and it is the one that matters, because a stray byte in a blob write is a
/// setting the user did not ask for.
final class MouseMutationTests: XCTestCase {

    /// A synthetic but plausible blob: PMW3360, 1000 Hz, six DPI slots, all
    /// enabled, active ordinal 2, single-colour effect.
    private func makeBlob() -> MouseConfigBlob {
        var blob = MouseConfigBlob.empty(profile: .one)
        blob.setByte(0x06, at: MouseConfigBlob.Offset.sensor)
        blob.setByte(0x04, at: MouseConfigBlob.Offset.pollingAndFlags)    // flags 0, 1000 Hz
        blob.setByte(0x26, at: MouseConfigBlob.Offset.dpiCountAndActive)  // active 2, count 6
        blob.setByte(0x00, at: MouseConfigBlob.Offset.disabledDPIMask)
        for slot in 0..<8 {
            blob.setByte(UInt8(0x0B + slot * 4), at: MouseConfigBlob.Offset.dpiStages + slot)
        }
        blob.setByte(0x02, at: MouseConfigBlob.Offset.effect)             // single colour
        blob.setByte(0x43, at: MouseConfigBlob.Offset.singleMode)         // brightness 4, speed 3
        blob.setByte(0x01, at: MouseConfigBlob.Offset.liftOffDistance)
        blob.setByte(0xA1, at: MouseConfigBlob.Offset.unknown1)
        blob.setByte(0xA2, at: MouseConfigBlob.Offset.unknown2 + 2)
        blob.setByte(0xA3, at: MouseConfigBlob.Offset.unknown3 + 5)
        blob.setByte(0xA4, at: MouseConfigBlob.Offset.unknown4)
        return blob
    }

    /// Every offset whose byte differs between two blobs.
    private func changedOffsets(_ before: MouseConfigBlob,
                                _ after: MouseConfigBlob) -> [Int] {
        zip(before.bytes, after.bytes).enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .map(\.offset)
    }

    // MARK: - effect

    /// `mouse effect wave` touches byte 0x35 and nothing else: the effect's own
    /// parameter byte is left as the device had it unless a flag asks otherwise.
    func testSettingAnEffectTouchesOnlyTheEffectByte() {
        let before = makeBlob()
        var after = before
        after.effect = .wave

        XCTAssertEqual(changedOffsets(before, after), [MouseConfigBlob.Offset.effect])
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.effect], 0x09)
        XCTAssertEqual(after.effect, .wave)
    }

    /// `--speed`/`--brightness` write the packed byte belonging to *that*
    /// effect, at the offset the effect names — brightness high, speed low.
    func testEffectParametersWriteTheEffectsOwnByte() throws {
        let before = makeBlob()
        var after = before
        after.effect = .rave
        try after.setModeParameter(MouseModeParameter(speed: 2, brightness: 3), for: .rave)

        XCTAssertEqual(changedOffsets(before, after),
                       [MouseConfigBlob.Offset.effect, MouseConfigBlob.Offset.raveMode])
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.raveMode], 0x32)
        // The previously selected effect's parameter byte is untouched.
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.singleMode], 0x43)
    }

    /// Giving only one flag leaves the other nibble alone — the CLI composes the
    /// new parameter from the current one, so `--brightness 1` on a `speed 3`
    /// effect stays fast.
    func testOneFlagPreservesTheOtherNibble() throws {
        var blob = makeBlob()
        let current = try XCTUnwrap(blob.modeParameter(for: .single))
        XCTAssertEqual(current.speed, 3)
        XCTAssertEqual(current.brightness, 4)

        try blob.setModeParameter(MouseModeParameter(speed: current.speed, brightness: 1),
                                  for: .single)
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.singleMode], 0x13)
    }

    /// `off` has no parameter byte at all, so asking for one is refused rather
    /// than writing over byte 0x35 (which is where its `modeByteOffset` points).
    func testOffHasNoParameterByte() {
        var blob = makeBlob()
        XCTAssertFalse(MouseRGBEffect.off.hasModeByte)
        XCTAssertNil(blob.modeParameter(for: .off))
        XCTAssertThrowsError(try blob.setModeParameter(MouseModeParameter(speed: 1, brightness: 1),
                                                       for: .off))
    }

    /// Turning the LEDs off writes effect 0x00 and leaves the lift-off byte
    /// alone — the OpenRGB bug in doc §10 is writing 0x00 to 0x81 here.
    func testEffectOffDoesNotTouchLiftOffDistance() {
        let before = makeBlob()
        var after = before
        after.effect = .off

        XCTAssertEqual(changedOffsets(before, after), [MouseConfigBlob.Offset.effect])
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.liftOffDistance], 0x01)
    }

    // MARK: - color

    /// `mouse color` writes effect 0x02, the one-colour array in **R, B, G**
    /// order, and full brightness into the single-colour mode byte.
    func testSolidColorWritesRBGAndFullBrightness() throws {
        let before = makeBlob()
        var after = before
        after.effect = .single
        try after.setColors([MouseRGB(red: 0xFF, green: 0x88, blue: 0x22)], for: .single)
        let current = try XCTUnwrap(after.modeParameter(for: .single))
        try after.setModeParameter(MouseModeParameter(speed: current.speed, brightness: 4),
                                   for: .single)

        // Effect was already 0x02, brightness already 4: only the colour moves.
        XCTAssertEqual(changedOffsets(before, after),
                       [MouseConfigBlob.Offset.singleColor,
                        MouseConfigBlob.Offset.singleColor + 1,
                        MouseConfigBlob.Offset.singleColor + 2])
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.singleColor], 0xFF)      // R
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.singleColor + 1], 0x22)  // B
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.singleColor + 2], 0x88)  // G
    }

    // MARK: - polling

    /// The rate is the low nibble of 0x0A; the flag nibble above it is unknown
    /// territory and must survive.
    func testPollingRateWritesTheLowNibbleOnly() {
        var blob = makeBlob()
        blob.setByte(0x84, at: MouseConfigBlob.Offset.pollingAndFlags)  // XY flag + 1000 Hz
        let before = blob
        blob.pollingRate = .hz125

        XCTAssertEqual(changedOffsets(before, blob), [MouseConfigBlob.Offset.pollingAndFlags])
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.pollingAndFlags], 0x81)
        XCTAssertEqual(blob.pollingRate, .hz125)
        XCTAssertTrue(blob.hasIndependentXYDPI)
    }

    func testEveryPollingRateRoundTrips() {
        for rate in MousePollingRate.allCases {
            var blob = makeBlob()
            blob.pollingRate = rate
            XCTAssertEqual(blob.pollingRate, rate, "\(rate.hertz) Hz")
            XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.pollingAndFlags] & 0x0F,
                           rate.rawValue)
        }
    }

    // MARK: - dpi

    /// PMW3360 stores `DPI/100 − 1`, so 1600 is raw 0x0F — the off-by-100 the
    /// doc calls the easiest mistake in the protocol.
    func testSettingADPIStageWritesTheScaledRawByte() throws {
        let before = makeBlob()
        var after = before
        try after.setDPIStage(MouseDPIStage(dpi: 1600, isEnabled: true), at: 2)

        XCTAssertEqual(changedOffsets(before, after), [MouseConfigBlob.Offset.dpiStages + 2])
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.dpiStages + 2], 0x0F)
        XCTAssertEqual(after.dpiStages[2].x, 1600)
    }

    /// Changing a value must not change membership: the disabled mask is
    /// `dpi-enable`'s business, and a disabled slot stays disabled.
    func testSettingADPIStagePreservesTheDisabledBit() throws {
        var blob = makeBlob()
        try blob.setDPISlotEnabled(false, at: 3)
        let before = blob
        let existing = blob.dpiStages[3]
        try blob.setDPIStage(MouseDPIStage(dpi: 400, isEnabled: existing.isEnabled), at: 3)

        XCTAssertEqual(changedOffsets(before, blob), [MouseConfigBlob.Offset.dpiStages + 3])
        XCTAssertFalse(blob.isDPISlotEnabled(3))
        XCTAssertEqual(blob.dpiStages[3].x, 400)
    }

    /// Out-of-range values are refused, not clamped. Silently storing 12000 for
    /// a requested 20000 would be a setting the user never chose.
    func testOutOfRangeDPIIsRefused() {
        var blob = makeBlob()
        XCTAssertThrowsError(try blob.setDPIStage(MouseDPIStage(dpi: 20000), at: 0))
        XCTAssertThrowsError(try blob.setDPIStage(MouseDPIStage(dpi: 50), at: 0))
        XCTAssertThrowsError(try blob.setDPIStage(MouseDPIStage(dpi: 1250), at: 0))
        // Refused means unchanged.
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.dpiStages], 0x0B)
    }

    func testDPIRangeBoundsAreInclusive() throws {
        var blob = makeBlob()
        XCTAssertTrue(MouseSensor.pmw3360.isValidDPI(100))
        XCTAssertTrue(MouseSensor.pmw3360.isValidDPI(12000))
        XCTAssertFalse(MouseSensor.pmw3360.isValidDPI(12100))
        try blob.setDPIStage(MouseDPIStage(dpi: 12000), at: 0)
        XCTAssertEqual(blob.dpiStages[0].x, 12000)
    }

    // MARK: - dpi-enable

    /// Bit set = disabled (doc §6), and only the mask byte moves.
    func testDisablingASlotSetsItsBit() throws {
        let before = makeBlob()
        var after = before
        try after.setDPISlotEnabled(false, at: 2)

        XCTAssertEqual(changedOffsets(before, after), [MouseConfigBlob.Offset.disabledDPIMask])
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.disabledDPIMask], 0b0000_0100)
        XCTAssertFalse(after.isDPISlotEnabled(2))
        XCTAssertTrue(after.isDPISlotEnabled(1))
        XCTAssertEqual(after.enabledDPISlotCount, 5)
    }

    func testEnablingASlotClearsItsBit() throws {
        var blob = makeBlob()
        blob.setByte(0b0000_1010, at: MouseConfigBlob.Offset.disabledDPIMask)
        try blob.setDPISlotEnabled(true, at: 1)
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.disabledDPIMask], 0b0000_1000)
    }

    /// Disabling slots can strand the active ordinal past the end of the
    /// enabled list, so it is pulled back rather than left pointing at nothing.
    func testDisablingSlotsClampsTheActiveOrdinal() throws {
        var blob = makeBlob()
        try blob.setActiveDPIOrdinal(6)
        XCTAssertEqual(blob.activeDPIOrdinal, 6)

        try blob.setDPISlotEnabled(false, at: 5)
        XCTAssertEqual(blob.enabledDPISlotCount, 5)
        XCTAssertEqual(blob.activeDPIOrdinal, 5)

        try blob.setDPISlotEnabled(false, at: 4)
        XCTAssertEqual(blob.activeDPIOrdinal, 4)
    }

    /// An ordinal that is still in range is left exactly where it was.
    func testDisablingALaterSlotLeavesAnInRangeOrdinalAlone() throws {
        var blob = makeBlob()
        try blob.setActiveDPIOrdinal(2)
        try blob.setDPISlotEnabled(false, at: 5)
        XCTAssertEqual(blob.activeDPIOrdinal, 2)
    }

    func testSlotIndexIsBoundsChecked() {
        var blob = makeBlob()
        XCTAssertThrowsError(try blob.setDPISlotEnabled(false, at: 8))
        XCTAssertThrowsError(try blob.setDPISlotEnabled(false, at: -1))
    }

    // MARK: - dpi-active

    /// The ordinal is the high nibble of 0x0B; the slot count below it stays.
    func testActiveOrdinalWritesTheHighNibbleOnly() throws {
        let before = makeBlob()
        var after = before
        try after.setActiveDPIOrdinal(4)

        XCTAssertEqual(changedOffsets(before, after), [MouseConfigBlob.Offset.dpiCountAndActive])
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.dpiCountAndActive], 0x46)
        XCTAssertEqual(after.activeDPIOrdinal, 4)
        XCTAssertEqual(after.dpiSlotCount, 6)
    }

    /// **The semantics that are easy to get wrong** (doc §6): the ordinal counts
    /// enabled slots, so with slot 2 disabled, ordinal 4 is physical slot 5.
    func testOrdinalCountsEnabledSlotsOnly() throws {
        var blob = makeBlob()
        try blob.setDPISlotEnabled(false, at: 1)
        try blob.setActiveDPIOrdinal(4)

        XCTAssertEqual(blob.enabledDPISlotCount, 5)
        XCTAssertEqual(blob.activeDPISlot, 4)     // 0-based: slots 0,2,3,4 → the 4th is index 4
        XCTAssertEqual(blob.activeDPIOrdinal, 4)
    }

    /// Pointing the ordinal past the enabled count would select a stage that is
    /// switched off, so it is refused.
    func testOrdinalBeyondTheEnabledCountIsRefused() throws {
        var blob = makeBlob()
        XCTAssertThrowsError(try blob.setActiveDPIOrdinal(7))
        XCTAssertThrowsError(try blob.setActiveDPIOrdinal(0))

        try blob.setDPISlotEnabled(false, at: 0)
        XCTAssertThrowsError(try blob.setActiveDPIOrdinal(6))
        XCTAssertNoThrow(try blob.setActiveDPIOrdinal(5))
    }

    func testOrdinalIsRefusedWhenNothingIsEnabled() throws {
        var blob = makeBlob()
        for slot in 0..<8 { try blob.setDPISlotEnabled(false, at: slot) }
        XCTAssertEqual(blob.enabledDPISlotCount, 0)
        XCTAssertThrowsError(try blob.setActiveDPIOrdinal(1))
    }

    // MARK: - lift-off distance

    func testLiftOffDistanceWritesOneByte() throws {
        let before = makeBlob()
        var after = before
        try after.setLiftOffDistance(.mm3)

        XCTAssertEqual(changedOffsets(before, after), [MouseConfigBlob.Offset.liftOffDistance])
        XCTAssertEqual(after.bytes[MouseConfigBlob.Offset.liftOffDistance], 0x02)
        XCTAssertEqual(after.liftOffDistance, .mm3)
    }

    /// The 0xFF sentinel means the unit manages LOD through command 0x1b, and
    /// libratbag says explicitly not to overwrite it (doc §7).
    func testLiftOffSentinelIsRefused() {
        var blob = makeBlob()
        blob.setByte(0xFF, at: MouseConfigBlob.Offset.liftOffDistance)
        XCTAssertThrowsError(try blob.setLiftOffDistance(.mm2))
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.liftOffDistance], 0xFF)
    }

    // MARK: - debounce is not a blob field

    /// Debounce rides command 0x1a, so it must produce a report-5 frame and no
    /// blob change at all — which is also why `mouse dump` cannot back it up.
    func testDebounceIsACommandFrameNotABlobEdit() throws {
        let report = try MouseCommandReport.setDebounce(milliseconds: 8)
        XCTAssertEqual(report, [0x05, 0x1A, 0x04, 0x00, 0x00, 0x00])
        XCTAssertNil(MouseISPGuard.check(commandReport: report))
    }

    func testEveryDocumentedDebounceTimeEncodesAsHalfItself() throws {
        for ms in MouseCommandReport.debounceTimesMilliseconds {
            let report = try MouseCommandReport.setDebounce(milliseconds: ms)
            XCTAssertEqual(report[2], UInt8(ms / 2), "\(ms) ms")
        }
        XCTAssertThrowsError(try MouseCommandReport.setDebounce(milliseconds: 5))
        XCTAssertThrowsError(try MouseCommandReport.setDebounce(milliseconds: 18))
        XCTAssertThrowsError(try MouseCommandReport.setDebounce(milliseconds: 2))
    }

    // MARK: - The write as a whole

    /// A setter's blob still carries every unknown region verbatim, and the
    /// write marker is the observed size minus 8 — the byte that decides whether
    /// the device accepts any of it.
    func testAPreparedWriteKeepsUnknownsAndStampsTheMarker() throws {
        var blob = makeBlob()
        blob.effect = .wave
        try blob.setDPIStage(MouseDPIStage(dpi: 800, isEnabled: true), at: 0)
        blob.pollingRate = .hz500

        let prepared = blob.preparedForWrite(profile: .one, configSize: 131)
        XCTAssertEqual(prepared.bytes[MouseConfigBlob.Offset.configWrite], 0x7B)
        XCTAssertEqual(prepared.bytes[MouseConfigBlob.Offset.command], 0x11)
        XCTAssertEqual(prepared.bytes[MouseConfigBlob.Offset.reportID], 0x04)
        XCTAssertEqual(prepared.bytes[MouseConfigBlob.Offset.unknown1], 0xA1)
        XCTAssertEqual(prepared.bytes[MouseConfigBlob.Offset.unknown2 + 2], 0xA2)
        XCTAssertEqual(prepared.bytes[MouseConfigBlob.Offset.unknown3 + 5], 0xA3)
        XCTAssertEqual(prepared.bytes[MouseConfigBlob.Offset.unknown4], 0xA4)
        XCTAssertEqual(prepared.bytes[MouseConfigBlob.Offset.sensor], 0x06)
        XCTAssertTrue(prepared.isMarkedForWrite)
    }

    /// Nothing in any setter touches the sensor byte: the DPI encoding depends
    /// on it, so a wrong value there silently rescales every stage.
    func testNoSetterTouchesTheSensorByte() throws {
        var blob = makeBlob()
        blob.effect = .rainbow
        try blob.setModeParameter(MouseModeParameter(speed: 1, brightness: 2), for: .rainbow)
        blob.pollingRate = .hz250
        try blob.setDPIStage(MouseDPIStage(dpi: 3200), at: 7)
        try blob.setDPISlotEnabled(false, at: 7)
        try blob.setActiveDPIOrdinal(1)
        try blob.setLiftOffDistance(.mm2)
        blob.rainbowDirection = .up

        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.sensor], 0x06)
        XCTAssertEqual(blob.sensor, .pmw3360)
    }
}
