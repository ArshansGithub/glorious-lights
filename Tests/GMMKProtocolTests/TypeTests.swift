import XCTest
@testable import GMMKProtocol

final class TypeTests: XCTestCase {

    func testModeIDsMatchProtocolDoc() {
        XCTAssertEqual(LightingMode.horizontalWave.rawValue, 0x01)
        XCTAssertEqual(LightingMode.fixed.rawValue, 0x06)
        XCTAssertEqual(LightingMode.reactiveColor.rawValue, 0x11)
        XCTAssertEqual(LightingMode.off.rawValue, 0x13)
        XCTAssertEqual(LightingMode.custom.rawValue, 0x14)
        XCTAssertNil(LightingMode(rawValue: 0x00))   // 0x00 is invalid
        XCTAssertNil(LightingMode(rawValue: 0x15))
    }

    func testModeDisplayNamesAreUniqueAndNonEmpty() {
        let names = Set(LightingMode.allCases.map(\.displayName))
        XCTAssertEqual(names.count, LightingMode.allCases.count)
        XCTAssertFalse(names.contains(""))
        let slugs = Set(LightingMode.allCases.map(\.slug))
        XCTAssertEqual(slugs.count, LightingMode.allCases.count)
    }

    func testModeParsing() {
        XCTAssertEqual(LightingMode.parse("fixed"), .fixed)
        XCTAssertEqual(LightingMode.parse("Fixed"), .fixed)
        XCTAssertEqual(LightingMode.parse("normallyon"), .fixed)      // official label
        XCTAssertEqual(LightingMode.parse("Horizontal Wave"), .horizontalWave)
        XCTAssertEqual(LightingMode.parse("horizontalwave"), .horizontalWave)
        XCTAssertEqual(LightingMode.parse("wave1"), .horizontalWave)
        XCTAssertEqual(LightingMode.parse("6"), .fixed)               // decimal ID
        XCTAssertEqual(LightingMode.parse("0x14"), .custom)           // hex ID
        XCTAssertEqual(LightingMode.parse("20"), .custom)
        XCTAssertNil(LightingMode.parse("0"))
        XCTAssertNil(LightingMode.parse("21"))
        XCTAssertNil(LightingMode.parse("nonsense"))
    }

    func testDirectionPolarityFollowsCodeNotNotes() {
        // gmmkctl's gmmk_setDirLeft writes 0xFF; the notes file disagrees and is wrong.
        XCTAssertEqual(Direction.left.rawValue, 0xFF)
        XCTAssertEqual(Direction.right.rawValue, 0x00)
    }

    func testDirectionParsing() {
        XCTAssertEqual(Direction.parse("l"), .left)
        XCTAssertEqual(Direction.parse("LEFT"), .left)
        XCTAssertEqual(Direction.parse("up"), .left)
        XCTAssertEqual(Direction.parse("r"), .right)
        XCTAssertEqual(Direction.parse("right"), .right)
        XCTAssertNil(Direction.parse("sideways"))
    }

    func testRGBHexParsing() {
        XCTAssertEqual(RGB(hex: "ff8800"), RGB(red: 0xFF, green: 0x88, blue: 0x00))
        XCTAssertEqual(RGB(hex: "#FF8800"), RGB(red: 0xFF, green: 0x88, blue: 0x00))
        XCTAssertEqual(RGB(hex: "0xff8800"), RGB(red: 0xFF, green: 0x88, blue: 0x00))
        XCTAssertEqual(RGB(hex: "000000"), .black)
        XCTAssertNil(RGB(hex: "fff"))        // shorthand not supported
        XCTAssertNil(RGB(hex: "gggggg"))
        XCTAssertNil(RGB(hex: "ff88000"))
    }

    func testRGBHexString() {
        XCTAssertEqual(RGB(red: 0xFF, green: 0x88, blue: 0x00).hexString, "ff8800")
        XCTAssertEqual(RGB.black.hexString, "000000")
    }

    func testRangeConstants() {
        XCTAssertEqual(Brightness.max, 4)
        XCTAssertEqual(Delay.max, 3)
        XCTAssertEqual(GMMKPacket.maxKeysPerPacket, 18)
        XCTAssertEqual(GMMKPacket.maxCustomColorBytesPerPacket, 54)
    }
}
