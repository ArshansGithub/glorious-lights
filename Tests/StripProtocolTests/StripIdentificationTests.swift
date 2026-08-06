import XCTest
@testable import StripProtocol

/// Tests for the ranking that decides what tomorrow's strip is.
///
/// The scenarios are the real ambiguities the research turned up, not invented
/// ones: `LEDBLE-` living in two incompatible ecosystems, `FFE1` being claimed
/// by three families, and the ELK controllers advertising a service they do not
/// implement while hiding the one they do.
final class StripIdentificationTests: XCTestCase {

    /// Parses the UUIDs a test wrote as strings, failing the test rather than
    /// silently dropping one — a dropped UUID would quietly weaken the very
    /// evidence the test is checking.
    private func uuids(_ strings: [String],
                       file: StaticString = #filePath,
                       line: UInt = #line) -> [StripUUID] {
        strings.compactMap {
            let parsed = StripUUID($0)
            XCTAssertNotNil(parsed, "malformed UUID '\($0)' in test", file: file, line: line)
            return parsed
        }
    }

    private func profile(name: String? = nil,
                         advertised: [String] = [],
                         services: [String] = [],
                         characteristics: [String] = []) -> StripDeviceProfile {
        StripDeviceProfile(name: name,
                           advertisedServiceUUIDs: uuids(advertised),
                           serviceUUIDs: uuids(services),
                           characteristicUUIDs: uuids(characteristics))
    }

    // MARK: - The decisive cases

    /// `FF01` + `FF02` under service `FFFF` can only be LEDnetWF.
    func testLEDnetWFCharacteristicsAreConclusive() {
        let best = StripIdentifier.identify(
            profile(name: "LEDnetWF010097DAB37A",
                    services: ["FFFF"],
                    characteristics: ["FF01", "FF02"])).first
        XCTAssertEqual(best?.family, .lednetWF)
        XCTAssertEqual(best?.confidence, .confirmed)
    }

    /// A `D44BC439-…` characteristic means iDeal LED and nothing else — the
    /// single most valuable thing identification can report, because it is the
    /// family this project deliberately will not write to.
    func testIdealLEDIsIdentifiedEvenThoughItHasNoFrameBuilders() {
        let best = StripIdentifier.identify(
            profile(name: "ISP-",
                    characteristics: ["D44BC439-ABFD-45A2-B575-925416129600",
                                      "D44BC439-ABFD-45A2-B575-925416129601"])).first
        XCTAssertEqual(best?.family, .idealLED)
        XCTAssertEqual(best?.confidence, .confirmed)
        XCTAssertFalse(StripFamily.idealLED.framesAvailable)
    }

    /// `FFF3` is the ELK write characteristic and no one else's, so a GATT dump
    /// settles the family even when the name is unhelpful.
    func testELKCharacteristicOutranksAnUnhelpfulName() {
        let candidates = StripIdentifier.identify(
            profile(name: "LED LIGHT STRIP",
                    services: ["FFF0"],
                    characteristics: ["FFF3", "FFF4"]))
        XCTAssertTrue(candidates.first!.family.elkDialect != nil)
        XCTAssertEqual(candidates.first?.confidence, .confirmed)
    }

    // MARK: - The ambiguous cases

    /// `LEDBLE-` appears in both the ELK and Triones ecosystems with
    /// incompatible wire formats. With only a name to go on, the answer must be
    /// hedged, not confident.
    func testLEDBLENameAloneIsNotConfident() {
        let candidates = StripIdentifier.identify(profile(name: "LEDBLE-DE1254F9"))
        XCTAssertEqual(candidates.first?.family, .ledble)
        XCTAssertNotEqual(candidates.first?.confidence, .confirmed)
        // Triones must still be on the list — it is the other real possibility.
        XCTAssertTrue(candidates.contains { $0.family == .triones })
    }

    /// The same name, now with a Triones write characteristic discovered. The
    /// characteristic has to win.
    func testATrionesCharacteristicOverridesAnELKLeaningName() {
        let best = StripIdentifier.identify(
            profile(name: "LEDBLE-DE1254F9",
                    services: ["FFD5"],
                    characteristics: ["FFD9", "FFD4"])).first
        XCTAssertEqual(best?.family, .triones)
    }

    /// `FFE1` is claimed by LEDBLE, JACKYLED and SP alike, so finding it must
    /// not read as proof of any one of them.
    func testASharedCharacteristicDoesNotReadAsConfirmed() {
        let candidates = StripIdentifier.identify(
            profile(services: ["FFE0"], characteristics: ["FFE1"]))
        XCTAssertNotEqual(candidates.first?.confidence, .confirmed)
        let sharers = candidates.filter { $0.score > 0 }.map(\.family)
        XCTAssertTrue(sharers.contains(.ledble))
        XCTAssertTrue(sharers.contains(.jackyLED))
        XCTAssertTrue(sharers.contains(.spPixel))
    }

    /// …and a name breaks that tie.
    func testANameBreaksTheTieBetweenFamiliesSharingACharacteristic() {
        let best = StripIdentifier.identify(
            profile(name: "SP110E", services: ["FFE0"], characteristics: ["FFE1"])).first
        XCTAssertEqual(best?.family, .spPixel)
    }

    /// The ELK controllers advertise HID (`0x1812`), which they do not
    /// implement, and do not advertise `FFF0`, which they do. A scan therefore
    /// yields a name and nothing usable — which must still produce a ranked
    /// answer, just not a confident one.
    func testAScanOnlyProfileStillRanksButNeverConfirms() {
        let candidates = StripIdentifier.identify(
            profile(name: "ELK-BLEDOM", advertised: ["1812"]))
        XCTAssertEqual(candidates.first?.family, .elkBLEDOM)
        XCTAssertEqual(candidates.first?.confidence, .possible)
        XCTAssertFalse(candidates.first!.reasons.isEmpty)
    }

    func testProfileKnowsWhetherTheStrongEvidenceWasAvailable() {
        XCTAssertFalse(profile(name: "ELK-BLEDOM").isPostDiscovery)
        XCTAssertTrue(profile(characteristics: ["FFF3"]).isPostDiscovery)
    }

    // MARK: - Shape of the ranking

    /// Every family is always returned, so `strip scan` and `strip try-all`
    /// work from one list. Nothing is filtered out for scoring zero.
    func testIdentifyAlwaysReturnsEveryFamilyBestFirst() {
        let candidates = StripIdentifier.identify(profile(name: "Some Random Device"))
        XCTAssertEqual(candidates.count, StripFamily.allCases.count)
        XCTAssertEqual(Set(candidates.map(\.family)), Set(StripFamily.allCases))
        XCTAssertEqual(candidates.map(\.score), candidates.map(\.score).sorted(by: >))
    }

    /// A device that matches nothing yields no best guess at all, rather than
    /// whichever family happened to sort first.
    func testBestGuessIsNilWhenNothingMatched() {
        XCTAssertNil(StripIdentifier.bestGuess(profile(name: "Some Random Device")))
        XCTAssertNil(StripIdentifier.bestGuess(profile(name: nil)))
        XCTAssertEqual(StripIdentifier.bestGuess(profile(name: "TRIONES-A1B2"))?.family,
                       .triones)
    }

    /// Ties break toward the commonest hardware, so an unidentifiable device
    /// still gets tried in a sensible order.
    func testTiesBreakTowardTheTryAllOrder() {
        let candidates = StripIdentifier.identify(profile(name: "Some Random Device"))
        XCTAssertEqual(candidates.first?.family, StripFamily.tryAllOrder.first)
    }

    /// `try-all` must cover every family that can actually build a colour
    /// frame, and no family that cannot.
    func testTryAllCoversExactlyTheFamiliesWithFrameBuilders() {
        let buildable = StripFamily.allCases.filter { $0.colorFrame(.white) != nil }
        XCTAssertEqual(Set(StripFamily.tryAllOrder), Set(buildable))
        XCTAssertFalse(StripFamily.tryAllOrder.contains(.idealLED))
        XCTAssertEqual(StripFamily.tryAllOrder.count, 9)
    }

    // MARK: - The façade

    func testEveryTryAllFamilyBuildsColourAndPowerFrames() {
        for family in StripFamily.tryAllOrder {
            XCTAssertNotNil(family.colorFrame(.white), family.displayName)
            XCTAssertNotNil(family.powerFrame(on: true), family.displayName)
            XCTAssertNotNil(family.powerFrame(on: false), family.displayName)
            XCTAssertNotNil(family.statusQueryFrame, family.displayName)
        }
    }

    /// Triones has no RGB brightness command at all — its only intensity
    /// command drives the separate white channel. That is a fact about the
    /// protocol, so the façade says `nil` and flags the workaround rather than
    /// inventing a frame.
    func testTrionesReportsNoBrightnessFrameAndFlagsTheWorkaround() {
        XCTAssertNil(StripFamily.triones.brightnessFrame(percent: 50))
        XCTAssertTrue(StripFamily.triones.scalesBrightnessByColor)
        for family in StripFamily.tryAllOrder where family != .triones {
            XCTAssertNotNil(family.brightnessFrame(percent: 50), family.displayName)
            XCTAssertFalse(family.scalesBrightnessByColor, family.displayName)
        }
    }

    /// The façade must dispatch to the same builders the golden tests pin,
    /// not to a second copy of the frame layout.
    func testFacadeDispatchesToTheSameBuildersTheGoldenTestsPin() {
        let rgb = StripRGB(red: 0x11, green: 0x22, blue: 0x33)
        XCTAssertEqual(StripFamily.elkBLEDOM.colorFrame(rgb),
                       ELKFrames.color(rgb, dialect: .bledom))
        XCTAssertEqual(StripFamily.triones.colorFrame(rgb), TrionesFrames.color(rgb))
        XCTAssertEqual(StripFamily.lednetWF.colorFrame(rgb, sequence: 7),
                       LEDnetWFFrames.color(rgb, sequence: 7))
        XCTAssertEqual(StripFamily.spPixel.colorFrame(rgb), SPPixelFrames.color(rgb))
    }

    /// Only LEDnetWF varies with the sequence counter; passing one to any other
    /// family must be a no-op rather than a silently different frame.
    func testOnlyLEDnetWFVariesWithTheSequenceCounter() {
        for family in StripFamily.tryAllOrder where family != .lednetWF {
            XCTAssertEqual(family.colorFrame(.white, sequence: 0),
                           family.colorFrame(.white, sequence: 200),
                           family.displayName)
        }
        XCTAssertNotEqual(StripFamily.lednetWF.colorFrame(.white, sequence: 0),
                          StripFamily.lednetWF.colorFrame(.white, sequence: 200))
    }

    /// LEDnetWF is the only family documented as refusing commands until
    /// notifications are on, and MELK the only one needing a login.
    func testConnectTimeRequirementsAreFamilySpecific() {
        XCTAssertTrue(StripFamily.lednetWF.requiresNotifications)
        for family in StripFamily.allCases where family != .lednetWF {
            XCTAssertFalse(family.requiresNotifications, family.displayName)
        }
    }
}
