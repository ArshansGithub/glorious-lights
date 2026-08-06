import XCTest
@testable import StripProtocol

/// Tests for the UUID value type.
///
/// The whole point of this type is that `"FFD9"` and
/// `"0000ffd9-0000-1000-8000-00805f9b34fb"` are the same UUID. CoreBluetooth
/// reports whichever form the peripheral advertised, so comparing the strings
/// as they arrive silently fails to match — and a silent non-match during
/// identification looks exactly like an unknown device.
final class StripUUIDTests: XCTestCase {

    func testShortAndLongFormsAreTheSameValue() {
        let short = StripUUID("FFD9")
        let long = StripUUID("0000ffd9-0000-1000-8000-00805f9b34fb")
        let undashed = StripUUID("0000ffd90000100080000080" + "5f9b34fb")
        XCTAssertEqual(short, long)
        XCTAssertEqual(short, StripUUID(short: 0xFFD9))
        XCTAssertNotNil(undashed)
    }

    func testParsingIsCaseInsensitiveAndToleratesA0xPrefix() {
        XCTAssertEqual(StripUUID("ffd9"), StripUUID("FFD9"))
        XCTAssertEqual(StripUUID("0xFFD9"), StripUUID("FFD9"))
        XCTAssertEqual(StripUUID(" FFD9 "), StripUUID("FFD9"))
    }

    func testVendorUUIDsSurviveIntact() {
        let ideal = StripUUID("d44bc439-abfd-45a2-b575-925416129600")
        XCTAssertEqual(ideal?.uuidString, "D44BC439-ABFD-45A2-B575-925416129600")
        XCTAssertNil(ideal?.shortValue)
        XCTAssertEqual(ideal?.shortDescription, "D44BC439-ABFD-45A2-B575-925416129600")
    }

    func testShortValueOnlyAppliesInsideTheBluetoothBaseRange() {
        XCTAssertEqual(StripUUID("FFD9")?.shortValue, 0xFFD9)
        XCTAssertEqual(StripUUID("FFF3")?.shortDescription, "FFF3")
        XCTAssertNil(StripUUID("0001FFD9-0000-1000-8000-00805F9B34FB")?.shortValue)
    }

    /// Malformed input yields `nil`, never a UUID that would quietly fail to
    /// match anything for the rest of the session.
    func testMalformedInputIsRejected() {
        XCTAssertNil(StripUUID(""))
        XCTAssertNil(StripUUID("FFD"))
        XCTAssertNil(StripUUID("GGGG"))
        XCTAssertNil(StripUUID("0000ffd9-0000-1000-8000"))
        XCTAssertNil(StripUUID("0000ffd9_0000_1000_8000_00805f9b34fb"))
        XCTAssertNil(StripUUID("zzzzzzzz-0000-1000-8000-00805f9b34fb"))
    }

    /// Every UUID hardcoded in the family table has to parse — the literal
    /// initialiser traps on a typo, so this is really a test that the tables
    /// are well formed.
    func testEveryFamilySignatureParses() {
        for family in StripFamily.allCases {
            let gatt = family.gatt
            XCTAssertFalse(gatt.writeCharacteristics.isEmpty, family.displayName)
            XCTAssertFalse(gatt.notifyCharacteristics.isEmpty, family.displayName)
            for uuid in gatt.services + gatt.writeCharacteristics + gatt.notifyCharacteristics {
                XCTAssertEqual(StripUUID(uuid.uuidString), uuid)
            }
        }
    }

    // MARK: - Colour parsing

    func testColorHexParsingAcceptsTheUsualSpellings() {
        let expected = StripRGB(red: 0x11, green: 0x22, blue: 0x33)
        XCTAssertEqual(StripRGB(hex: "112233"), expected)
        XCTAssertEqual(StripRGB(hex: "#112233"), expected)
        XCTAssertEqual(StripRGB(hex: "0x112233"), expected)
        XCTAssertEqual(StripRGB(hex: "112233")?.hexString, "112233")
    }

    func testColorHexParsingRejectsTheWrongLength() {
        XCTAssertNil(StripRGB(hex: "1122"))
        XCTAssertNil(StripRGB(hex: "11223344"))
        XCTAssertNil(StripRGB(hex: "gggggg"))
        XCTAssertNil(StripRGB(hex: ""))
    }

    /// The transposed byte order the JACKYLED dialect needs.
    func testWireByteOrders() {
        let rgb = StripRGB(red: 1, green: 2, blue: 3)
        XCTAssertEqual(rgb.rgbBytes, [1, 2, 3])
        XCTAssertEqual(rgb.rbgBytes, [1, 3, 2])
    }
}
