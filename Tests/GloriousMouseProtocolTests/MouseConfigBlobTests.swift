import XCTest
@testable import GloriousMouseProtocol

/// Blob layout, encodings and round-tripping, against `docs/mouse-protocol.md`
/// §4–§7.
///
/// The offsets asserted here are the sixteen OpenRGB writes as literals — the
/// doc's strongest cross-check is that they agree with libratbag's packed
/// struct, so a test that reproduces them catches any drift in this file.
final class MouseConfigBlobTests: XCTestCase {

    // MARK: - Helpers

    /// A synthetic but plausible blob: PMW3360, 1000 Hz, six DPI slots.
    private func makeBlob() -> MouseConfigBlob {
        var blob = MouseConfigBlob.empty(profile: .one)
        blob.setByte(0x06, at: MouseConfigBlob.Offset.sensor)
        blob.setByte(0x04, at: MouseConfigBlob.Offset.pollingAndFlags)   // flags 0, 1000 Hz
        blob.setByte(0x26, at: MouseConfigBlob.Offset.dpiCountAndActive) // active 2, count 6
        blob.setByte(0x00, at: MouseConfigBlob.Offset.disabledDPIMask)
        for slot in 0..<8 {
            blob.setByte(UInt8(0x0B + slot * 4), at: MouseConfigBlob.Offset.dpiStages + slot)
        }
        blob.setByte(0x02, at: MouseConfigBlob.Offset.effect)            // single colour
        blob.setByte(0x43, at: MouseConfigBlob.Offset.singleMode)        // brightness 4, speed 3
        blob.setByte(0xFF, at: MouseConfigBlob.Offset.singleColor)       // R
        blob.setByte(0x22, at: MouseConfigBlob.Offset.singleColor + 1)   // B
        blob.setByte(0x88, at: MouseConfigBlob.Offset.singleColor + 2)   // G
        blob.setByte(0x01, at: MouseConfigBlob.Offset.liftOffDistance)
        // A non-zero byte in each unknown region, so preservation is testable.
        blob.setByte(0xA1, at: MouseConfigBlob.Offset.unknown1)
        blob.setByte(0xA2, at: MouseConfigBlob.Offset.unknown2 + 2)
        blob.setByte(0xA3, at: MouseConfigBlob.Offset.unknown3 + 5)
        blob.setByte(0xA4, at: MouseConfigBlob.Offset.unknown4)
        return blob
    }

    // MARK: - Framing

    func testBlobRequiresTheFullReportLength() {
        XCTAssertThrowsError(try MouseConfigBlob(report: [UInt8](repeating: 0, count: 131)))
        XCTAssertThrowsError(try MouseConfigBlob(report: [UInt8](repeating: 0, count: 519)))
    }

    func testBlobRequiresReportIDFour() {
        var report = [UInt8](repeating: 0, count: 520)
        report[0] = 0x05
        XCTAssertThrowsError(try MouseConfigBlob(report: report))
        report[0] = 0x04
        XCTAssertNoThrow(try MouseConfigBlob(report: report))
    }

    /// Parse → serialise is the identity: nothing is normalised on the way in.
    func testRoundTripIsIdentity() throws {
        var report = [UInt8](repeating: 0, count: 520)
        report[0] = 0x04
        report[1] = 0x11
        for i in 2..<200 { report[i] = UInt8((i * 7 + 3) & 0xFF) }
        let blob = try MouseConfigBlob(report: report)
        XCTAssertEqual(blob.bytes, report)
        // And through a second parse.
        XCTAssertEqual(try MouseConfigBlob(report: blob.bytes).bytes, report)
    }

    /// Every typed setter, applied and then reverted, must leave the buffer
    /// byte-identical — including the unknown regions the doc says to preserve.
    func testMutationRoundTripsBackToTheOriginalBytes() throws {
        let original = makeBlob()
        var blob = original

        blob.pollingRate = .hz125
        blob.effect = .rave
        try blob.setModeParameter(MouseModeParameter(speed: 1, brightness: 2), for: .single)
        try blob.setColors([MouseRGB(red: 1, green: 2, blue: 3)], for: .single)
        try blob.setDPIStage(MouseDPIStage(dpi: 800, isEnabled: false), at: 0)
        try blob.setLiftOffDistance(.mm3)
        XCTAssertNotEqual(blob.bytes, original.bytes)

        blob.pollingRate = .hz1000
        blob.effect = .single
        try blob.setModeParameter(MouseModeParameter(speed: 3, brightness: 4), for: .single)
        try blob.setColors([MouseRGB(red: 0xFF, green: 0x88, blue: 0x22)], for: .single)
        try blob.setDPIStage(MouseDPIStage(dpi: 1200, isEnabled: true), at: 0)
        try blob.setLiftOffDistance(.mm2)
        XCTAssertEqual(blob.bytes, original.bytes)
    }

    func testUnknownRegionsSurviveEveryTypedSetter() throws {
        var blob = makeBlob()
        blob.pollingRate = .hz500
        blob.effect = .wave
        try blob.setModeParameter(MouseModeParameter(speed: 2, brightness: 1), for: .wave)
        try blob.setDPIStage(MouseDPIStage(dpi: 3200), at: 4)

        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.unknown1], 0xA1)
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.unknown2 + 2], 0xA2)
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.unknown3 + 5], 0xA3)
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.unknown4], 0xA4)
    }

    // MARK: - Write marker

    /// Doc §4: `buf[3] = configSize − 8`. OpenRGB hardcodes `0x7B` for this
    /// device, which is 131 − 8.
    func testWriteMarkerMatchesOpenRGBsLiteralForA131ByteConfig() {
        let prepared = makeBlob().preparedForWrite(profile: .one, configSize: 131)
        XCTAssertEqual(prepared.writeMarker, 0x7B)
        XCTAssertEqual(prepared.bytes[0x03], 0x7B)
        XCTAssertEqual(prepared.bytes[0x01], 0x11)
        XCTAssertTrue(prepared.isMarkedForWrite)
    }

    func testWriteMarkerFollowsTheObservedSizeWhenItIs167() {
        let prepared = makeBlob().preparedForWrite(profile: .two, configSize: 167)
        XCTAssertEqual(prepared.writeMarker, 167 - 8)
        XCTAssertEqual(prepared.bytes[0x01], 0x21)
    }

    /// A blob straight off the device carries the read marker, so a "verbatim"
    /// write would be a silent no-op. This is the trap `mouse restore` avoids.
    func testABlobAsReadIsNotMarkedForWrite() {
        XCTAssertFalse(makeBlob().isMarkedForWrite)
    }

    /// OpenRGB zeroes `unknown2[2]` (offset 0x06) with no explanation; doc §11
    /// item 6 says preserve it instead.
    func testPreparingForWritePreservesOffsetSix() {
        var blob = makeBlob()
        blob.setByte(0x5A, at: 0x06)
        XCTAssertEqual(blob.preparedForWrite(profile: .one, configSize: 131).bytes[0x06], 0x5A)
    }

    func testInferredConfigSizeIsClampedIntoTheDocumentedWindow() {
        // An all-but-empty blob still infers at least the documented minimum.
        XCTAssertEqual(MouseConfigBlob.empty().inferredConfigSize,
                       GloriousMouseDevice.configSizeMin)
        var blob = MouseConfigBlob.empty()
        blob.setByte(0x01, at: 0x80)
        XCTAssertEqual(blob.inferredConfigSize, 0x81)
        // Trailing junk beyond the documented maximum cannot inflate it.
        blob.setByte(0x01, at: 400)
        XCTAssertEqual(blob.inferredConfigSize, GloriousMouseDevice.configSizeMax)
    }

    func testObservedReadLengthWinsOverInference() throws {
        var report = MouseConfigBlob.empty().bytes
        report[0x80] = 0x01
        let blob = try MouseConfigBlob(report: report, observedReadLength: 131)
        XCTAssertEqual(blob.inferredConfigSize, 0x81)
        XCTAssertEqual(blob.effectiveConfigSize, 131)
    }

    // MARK: - Offsets

    /// The sixteen literal offsets OpenRGB uses (doc §5). If this test fails,
    /// the layout table in this file has drifted from the doc.
    func testOffsetsMatchOpenRGBsLiterals() {
        XCTAssertEqual(MouseConfigBlob.Offset.configWrite, 0x03)
        XCTAssertEqual(MouseConfigBlob.Offset.effect, 0x35)
        XCTAssertEqual(MouseConfigBlob.Offset.rainbowMode, 0x36)
        XCTAssertEqual(MouseConfigBlob.Offset.rainbowDirection, 0x37)
        XCTAssertEqual(MouseConfigBlob.Offset.singleMode, 0x38)
        XCTAssertEqual(MouseConfigBlob.Offset.singleColor, 0x39)
        XCTAssertEqual(MouseConfigBlob.Offset.breathing7Mode, 0x3C)
        XCTAssertEqual(MouseConfigBlob.Offset.breathing7ColorCount, 0x3D)
        XCTAssertEqual(MouseConfigBlob.Offset.breathing7Colors, 0x3E)
        XCTAssertEqual(MouseConfigBlob.Offset.tailMode, 0x53)
        XCTAssertEqual(MouseConfigBlob.Offset.spectrumBreathingMode, 0x54)
        XCTAssertEqual(MouseConfigBlob.Offset.raveMode, 0x74)
        XCTAssertEqual(MouseConfigBlob.Offset.raveColors, 0x75)
        XCTAssertEqual(MouseConfigBlob.Offset.waveMode, 0x7C)
        XCTAssertEqual(MouseConfigBlob.Offset.breathing1Mode, 0x7D)
        XCTAssertEqual(MouseConfigBlob.Offset.liftOffDistance, 0x81)
    }

    /// Each effect's parameter byte and colour array must sit where §5.1 says.
    func testEffectParameterOffsets() {
        XCTAssertEqual(MouseRGBEffect.rainbow.modeByteOffset, 0x36)
        XCTAssertEqual(MouseRGBEffect.single.modeByteOffset, 0x38)
        XCTAssertEqual(MouseRGBEffect.breathing7.modeByteOffset, 0x3C)
        XCTAssertEqual(MouseRGBEffect.tail.modeByteOffset, 0x53)
        XCTAssertEqual(MouseRGBEffect.spectrumBreathing.modeByteOffset, 0x54)
        XCTAssertEqual(MouseRGBEffect.constant.modeByteOffset, 0x55)
        XCTAssertEqual(MouseRGBEffect.rave.modeByteOffset, 0x74)
        XCTAssertEqual(MouseRGBEffect.random.modeByteOffset, 0x7B)
        XCTAssertEqual(MouseRGBEffect.wave.modeByteOffset, 0x7C)
        XCTAssertEqual(MouseRGBEffect.breathing1.modeByteOffset, 0x7D)
        XCTAssertFalse(MouseRGBEffect.off.hasModeByte)

        XCTAssertEqual(MouseRGBEffect.single.colorArray?.offset, 0x39)
        XCTAssertEqual(MouseRGBEffect.single.colorArray?.count, 1)
        XCTAssertEqual(MouseRGBEffect.breathing7.colorArray?.count, 7)
        // The only mode addressing all six LEDs individually (doc §11 item 5).
        XCTAssertEqual(MouseRGBEffect.constant.colorArray?.offset, 0x56)
        XCTAssertEqual(MouseRGBEffect.constant.colorArray?.count, 6)
        XCTAssertEqual(MouseRGBEffect.rave.colorArray?.offset, 0x75)
        XCTAssertEqual(MouseRGBEffect.rave.colorArray?.count, 2)
        XCTAssertEqual(MouseRGBEffect.breathing1.colorArray?.offset, 0x7E)
        XCTAssertNil(MouseRGBEffect.wave.colorArray)
    }

    /// The colour arrays must not overlap the fields that follow them.
    func testColorArraysFitBetweenTheirNeighbours() {
        XCTAssertEqual(MouseConfigBlob.Offset.breathing7Colors + 7 * 3,
                       MouseConfigBlob.Offset.tailMode)
        XCTAssertEqual(MouseConfigBlob.Offset.constantColors + 6 * 3,
                       MouseConfigBlob.Offset.unknown3)
        XCTAssertEqual(MouseConfigBlob.Offset.raveColors + 2 * 3,
                       MouseConfigBlob.Offset.randomMode)
        XCTAssertEqual(MouseConfigBlob.Offset.breathing1Color + 3,
                       MouseConfigBlob.Offset.liftOffDistance)
        XCTAssertEqual(MouseConfigBlob.Offset.dpiStages + 16,
                       MouseConfigBlob.Offset.dpiStageColors)
        XCTAssertEqual(MouseConfigBlob.Offset.dpiStageColors + 8 * 3,
                       MouseConfigBlob.Offset.effect)
    }

    // MARK: - Colour order

    /// Doc §5.2: the wire order is R, **B**, G. Get this wrong and red looks
    /// fine while green and blue swap.
    func testColorsAreStoredInRBGOrder() throws {
        var blob = MouseConfigBlob.empty()
        try blob.setColors([MouseRGB(red: 0x11, green: 0x22, blue: 0x33)], for: .single)
        XCTAssertEqual(blob.bytes[0x39], 0x11)  // R
        XCTAssertEqual(blob.bytes[0x3A], 0x33)  // B
        XCTAssertEqual(blob.bytes[0x3B], 0x22)  // G
        XCTAssertEqual(blob.colors(for: .single)?.first,
                       MouseRGB(red: 0x11, green: 0x22, blue: 0x33))
    }

    func testRBGDecodingIsNotAccidentallySymmetric() {
        let color = MouseRGB(rbgBytes: [0x01, 0x02, 0x03])
        XCTAssertEqual(color.red, 0x01)
        XCTAssertEqual(color.blue, 0x02)
        XCTAssertEqual(color.green, 0x03)
        XCTAssertEqual(color.rbgBytes, [0x01, 0x02, 0x03])
    }

    func testSixConstantColorsRoundTripIndependently() throws {
        var blob = MouseConfigBlob.empty()
        let colors: [MouseRGB] = (0..<6).map { (i: Int) -> MouseRGB in
            let base = UInt8(i * 3)
            return MouseRGB(red: base + 1, green: base + 2, blue: base + 3)
        }
        try blob.setColors(colors, for: .constant)
        XCTAssertEqual(blob.colors(for: .constant), colors)
    }

    func testTooManyColorsIsRefusedRatherThanTruncated() {
        var blob = MouseConfigBlob.empty()
        let eight = (0..<8).map { _ in MouseRGB.black }
        XCTAssertThrowsError(try blob.setColors(eight, for: .breathing7))
        XCTAssertThrowsError(try blob.setColors([.black], for: .wave))
    }

    // MARK: - Speed / brightness

    /// Doc §5.3: `((brightness & 0xF) << 4) | (speed & 0xF)`.
    func testModeParameterNibblePacking() {
        XCTAssertEqual(MouseModeParameter(speed: 3, brightness: 4).packed, 0x43)
        XCTAssertEqual(MouseModeParameter(speed: 0, brightness: 0).packed, 0x00)
        XCTAssertEqual(MouseModeParameter(packed: 0x43).speed, 3)
        XCTAssertEqual(MouseModeParameter(packed: 0x43).brightness, 4)
        // Speed is the LOW nibble; a swap would make these equal.
        XCTAssertNotEqual(MouseModeParameter(speed: 1, brightness: 2).packed,
                          MouseModeParameter(speed: 2, brightness: 1).packed)
    }

    func testModeParameterReadsTheEffectsOwnByte() throws {
        let blob = makeBlob()
        let parameter = try XCTUnwrap(blob.modeParameter(for: .single))
        XCTAssertEqual(parameter.speed, 3)
        XCTAssertEqual(parameter.brightness, 4)
        XCTAssertNil(blob.modeParameter(for: .off))
        XCTAssertThrowsError(try {
            var copy = blob
            try copy.setModeParameter(MouseModeParameter(speed: 1, brightness: 1), for: .off)
        }())
    }

    // MARK: - Effect byte

    func testEffectIDsMatchTheDocumentedTable() {
        XCTAssertEqual(MouseRGBEffect.off.rawValue, 0x00)
        XCTAssertEqual(MouseRGBEffect.rainbow.rawValue, 0x01)
        XCTAssertEqual(MouseRGBEffect.single.rawValue, 0x02)
        XCTAssertEqual(MouseRGBEffect.breathing7.rawValue, 0x03)
        XCTAssertEqual(MouseRGBEffect.tail.rawValue, 0x04)
        XCTAssertEqual(MouseRGBEffect.spectrumBreathing.rawValue, 0x05)
        XCTAssertEqual(MouseRGBEffect.constant.rawValue, 0x06)
        XCTAssertEqual(MouseRGBEffect.rave.rawValue, 0x07)
        XCTAssertEqual(MouseRGBEffect.random.rawValue, 0x08)
        XCTAssertEqual(MouseRGBEffect.wave.rawValue, 0x09)
        XCTAssertEqual(MouseRGBEffect.breathing1.rawValue, 0x0A)
    }

    /// `0xFF` is `RGB_NOT_SUPPORTED` — what mice with no LEDs report. It must
    /// not be a selectable effect, and it must not decode as one.
    func testNotSupportedSentinelIsNotAnEffect() {
        XCTAssertNil(MouseRGBEffect(rawValue: MouseRGBEffect.notSupportedRawValue))
        var blob = MouseConfigBlob.empty()
        blob.setByte(0xFF, at: MouseConfigBlob.Offset.effect)
        XCTAssertNil(blob.effect)
        XCTAssertEqual(blob.effectRawValue, 0xFF)
    }

    func testEffectParsingAcceptsSlugsAndIDs() {
        XCTAssertEqual(MouseRGBEffect.parse("rave"), .rave)
        XCTAssertEqual(MouseRGBEffect.parse("0x06"), .constant)
        XCTAssertEqual(MouseRGBEffect.parse("2"), .single)
        XCTAssertNil(MouseRGBEffect.parse("unicorn"))
    }

    // MARK: - Polling rate and flags

    /// Doc §7: low nibble `1`/`2`/`3`/`4` → 125/250/500/1000 Hz.
    func testPollingRateNibbleMap() {
        XCTAssertEqual(MousePollingRate(rawValue: 1)?.hertz, 125)
        XCTAssertEqual(MousePollingRate(rawValue: 2)?.hertz, 250)
        XCTAssertEqual(MousePollingRate(rawValue: 3)?.hertz, 500)
        XCTAssertEqual(MousePollingRate(rawValue: 4)?.hertz, 1000)
        // 0 is libratbag's error sentinel, not a rate.
        XCTAssertNil(MousePollingRate(rawValue: 0))
    }

    /// Setting the rate must not disturb the unknown high-nibble flags.
    func testSettingPollingRatePreservesTheFlagNibble() {
        var blob = MouseConfigBlob.empty()
        blob.setByte(0xB4, at: MouseConfigBlob.Offset.pollingAndFlags)  // flags 0xB, 1000 Hz
        XCTAssertEqual(blob.pollingRate, .hz1000)
        XCTAssertEqual(blob.configFlags, 0xB)
        blob.pollingRate = .hz250
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.pollingAndFlags], 0xB2)
        XCTAssertEqual(blob.configFlags, 0xB)
    }

    func testXYIndependentFlagIsBitThreeOfTheHighNibble() {
        var blob = MouseConfigBlob.empty()
        blob.setByte(0x84, at: MouseConfigBlob.Offset.pollingAndFlags)
        XCTAssertTrue(blob.hasIndependentXYDPI)
        blob.setByte(0x74, at: MouseConfigBlob.Offset.pollingAndFlags)
        XCTAssertFalse(blob.hasIndependentXYDPI)
    }

    // MARK: - DPI

    /// Doc §6: on the PMW3360 `raw = DPI/100 − 1`, so `0x0B` is **1200** DPI,
    /// not 1100. This is the easiest thing in the protocol to get wrong.
    func testPMW3360DPIScalingIsOffByOneHundredFromTheNaiveReading() {
        XCTAssertEqual(MouseSensor.pmw3360.dpi(raw: 0x0B), 1200)
        XCTAssertEqual(MouseSensor.pmw3360.dpi(raw: 0x00), 100)
        XCTAssertEqual(MouseSensor.pmw3360.raw(dpi: 1200), 0x0B)
        XCTAssertEqual(MouseSensor.pmw3360.raw(dpi: 400), 0x03)
        // The PMW3389 does not have the −1.
        XCTAssertEqual(MouseSensor.pmw3389.dpi(raw: 0x0B), 1100)
        XCTAssertEqual(MouseSensor.pmw3389.raw(dpi: 1100), 0x0B)
    }

    func testDPIEncodingRoundTripsAcrossTheWholeRange() {
        for dpi in stride(from: 100, through: 12000, by: 100) {
            XCTAssertEqual(MouseSensor.pmw3360.dpi(raw: MouseSensor.pmw3360.raw(dpi: dpi)), dpi)
        }
    }

    func testDPIIsClampedAndSnappedToTheSensorsRange() {
        XCTAssertEqual(MouseSensor.pmw3360.dpi(raw: MouseSensor.pmw3360.raw(dpi: 50)), 100)
        XCTAssertEqual(MouseSensor.pmw3360.dpi(raw: MouseSensor.pmw3360.raw(dpi: 99_000)), 12000)
        XCTAssertEqual(MouseSensor.pmw3360.dpi(raw: MouseSensor.pmw3360.raw(dpi: 1250)), 1200)
    }

    func testDPIStagesDecodeWithTheSensorsScaling() {
        let blob = makeBlob()
        XCTAssertEqual(blob.sensor, .pmw3360)
        XCTAssertEqual(blob.dpiSlotCount, 6)
        XCTAssertEqual(blob.activeDPIOrdinal, 2)
        XCTAssertEqual(blob.dpiStages[0].x, 1200)   // raw 0x0B
        XCTAssertEqual(blob.dpiStages[1].x, 1600)   // raw 0x0F
        XCTAssertTrue(blob.dpiStages.allSatisfy(\.isSymmetric))
    }

    /// Doc §6: `0x0C` is a **disabled** mask — bit set means the slot is off.
    func testDisabledMaskPolarityIsInverted() throws {
        var blob = makeBlob()
        XCTAssertTrue(blob.isDPISlotEnabled(1))
        try blob.setDPIStage(MouseDPIStage(dpi: 800, isEnabled: false), at: 1)
        XCTAssertEqual(blob.disabledDPIMask & 0b10, 0b10)
        XCTAssertFalse(blob.isDPISlotEnabled(1))
        XCTAssertTrue(blob.isDPISlotEnabled(0))
        XCTAssertFalse(blob.dpiStages[1].isEnabled)
    }

    /// With the flag set the 16 bytes are 8 `{x, y}` pairs, not 8 values.
    func testIndependentXYUsesPairedBytes() throws {
        var blob = MouseConfigBlob.empty()
        blob.setByte(0x06, at: MouseConfigBlob.Offset.sensor)
        blob.setByte(0x84, at: MouseConfigBlob.Offset.pollingAndFlags)
        try blob.setDPIStage(MouseDPIStage(x: 800, y: 1600, isEnabled: true), at: 1)
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.dpiStages + 2], 0x07)  // 800
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.dpiStages + 3], 0x0F)  // 1600
        XCTAssertEqual(blob.dpiStages[1], MouseDPIStage(x: 800, y: 1600, isEnabled: true))
    }

    /// Writing an asymmetric stage without the flag would silently drop Y and
    /// misalign the array, so it is refused.
    func testAsymmetricDPIWithoutTheFlagIsRefused() {
        var blob = makeBlob()
        XCTAssertThrowsError(try blob.setDPIStage(MouseDPIStage(x: 800, y: 1600, isEnabled: true),
                                                  at: 0))
    }

    func testDPISlotIndexIsBoundsChecked() {
        var blob = makeBlob()
        XCTAssertThrowsError(try blob.setDPIStage(MouseDPIStage(dpi: 800), at: 8))
        XCTAssertThrowsError(try blob.setDPIStage(MouseDPIStage(dpi: 800), at: -1))
        XCTAssertFalse(blob.isDPISlotEnabled(9))
    }

    // MARK: - Lift-off distance

    func testLiftOffDistanceValues() {
        var blob = MouseConfigBlob.empty()
        blob.setByte(0x01, at: MouseConfigBlob.Offset.liftOffDistance)
        XCTAssertEqual(blob.liftOffDistance, .mm2)
        blob.setByte(0x02, at: MouseConfigBlob.Offset.liftOffDistance)
        XCTAssertEqual(blob.liftOffDistance, .mm3)
        blob.setByte(0xFF, at: MouseConfigBlob.Offset.liftOffDistance)
        XCTAssertEqual(blob.liftOffDistance, .commandManaged)
    }

    /// Doc §7 and §10: `0xFF` means the unit sets LOD via command `0x1b`, and
    /// libratbag says never to overwrite it. OpenRGB destroys it through a
    /// missing `break`; this must not.
    func testWritingOverTheCommandManagedSentinelIsRefused() {
        var blob = MouseConfigBlob.empty()
        blob.setByte(0xFF, at: MouseConfigBlob.Offset.liftOffDistance)
        XCTAssertThrowsError(try blob.setLiftOffDistance(.mm2))
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.liftOffDistance], 0xFF)
    }

    /// The specific OpenRGB bug: selecting "off" (or breathing, which falls
    /// through into it) writes 0x00 into 0x81. Setting the effect here must
    /// leave that byte alone.
    func testSettingTheOffEffectDoesNotTouchTheLiftOffByte() {
        var blob = makeBlob()
        blob.effect = .off
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.effect], 0x00)
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.liftOffDistance], 0x01)
        blob.effect = .breathing1
        XCTAssertEqual(blob.bytes[MouseConfigBlob.Offset.liftOffDistance], 0x01)
    }

    func testUndocumentedLiftOffValuesAreRefused() {
        var blob = MouseConfigBlob.empty()
        blob.setByte(0x01, at: MouseConfigBlob.Offset.liftOffDistance)
        XCTAssertThrowsError(try blob.setLiftOffDistance(.other(0x03)))
        XCTAssertThrowsError(try blob.setLiftOffDistance(.commandManaged))
    }

    // MARK: - Breathing-7 colour count

    /// Doc §10: byte `0x3D` is the colour count, not a "bank change". Dropping
    /// it to 6 silently loses the last colour.
    func testBreathing7ColorCountIsClampedToOneThroughSeven() {
        var blob = MouseConfigBlob.empty()
        blob.breathing7ColorCount = 7
        XCTAssertEqual(blob.bytes[0x3D], 7)
        blob.breathing7ColorCount = 0
        XCTAssertEqual(blob.bytes[0x3D], 1)
        blob.breathing7ColorCount = 9
        XCTAssertEqual(blob.bytes[0x3D], 7)
    }

    // MARK: - Summary

    func testSummaryDecodesTheSyntheticBlob() {
        let text = makeBlob().summaryLines().joined(separator: "\n")
        XCTAssertTrue(text.contains("PMW3360"))
        XCTAssertTrue(text.contains("1000 Hz"))
        XCTAssertTrue(text.contains("Single Colour"))
        XCTAssertTrue(text.contains("#ff8822"))
        XCTAssertTrue(text.contains("1200"))
        XCTAssertTrue(text.contains("2 mm"))
    }

    func testHexDumpIsSixteenBytesPerRow() {
        let lines = makeBlob().hexDumpLines(upTo: 32)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("0000  04 11"))
        XCTAssertTrue(lines[1].hasPrefix("0010  "))
    }
}

// MARK: - Test-only byte poking

extension MouseConfigBlob {
    /// Sets one raw byte. Test-only: production code goes through the typed
    /// accessors so unknown regions cannot be clobbered by accident.
    mutating func setByte(_ value: UInt8, at offset: Int) {
        var report = bytes
        report[offset] = value
        self = try! MouseConfigBlob(report: report, observedReadLength: observedReadLength)
    }
}
