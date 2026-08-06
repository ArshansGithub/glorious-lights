import XCTest
@testable import StripProtocol

/// Golden bytes for the SP110E / SP107E pixel controllers.
///
/// From `mbullington`'s `sp110e.md` gist and `roslovets/SP110E`'s `driver.py`,
/// which agree on the frame shape and on every command byte asserted here.
final class SPPixelFrameTests: XCTestCase {

    /// "Each command consists of 4 bytes… the first 3 bytes contain data and
    /// the fourth is the command byte." The command last is what makes this
    /// family unmistakable on the wire.
    func testCommandByteComesLast() {
        XCTAssertEqual(SPPixelFrames.frame(0x2A, data: [0x80]),
                       [0x80, 0x00, 0x00, 0x2A])
        XCTAssertEqual(SPPixelFrames.frame(0xAA), [0x00, 0x00, 0x00, 0xAA])
    }

    func testEveryFrameIsFourBytes() {
        let frames = [SPPixelFrames.color(.white),
                      SPPixelFrames.power(on: true),
                      SPPixelFrames.power(on: false),
                      SPPixelFrames.brightness(0x80),
                      SPPixelFrames.mode(1),
                      SPPixelFrames.mode(0),
                      SPPixelFrames.speed(0x40),
                      SPPixelFrames.readParameters]
        for frame in frames { XCTAssertEqual(frame.count, 4) }
    }

    /// `mbullington`: "Set Color = RR GG BB 1e".
    func testColorGoldenBytes() {
        XCTAssertEqual(SPPixelFrames.color(StripRGB(red: 0xFF, green: 0, blue: 0)),
                       [0xFF, 0x00, 0x00, 0x1E])
        XCTAssertEqual(SPPixelFrames.color(StripRGB(red: 0x11, green: 0x22, blue: 0x33)),
                       [0x11, 0x22, 0x33, 0x1E])
    }

    /// `roslovets`: `0xAA` on, `0xAB` off, with the data bytes ignored.
    func testPowerGoldenBytes() {
        XCTAssertEqual(SPPixelFrames.power(on: true), [0x00, 0x00, 0x00, 0xAA])
        XCTAssertEqual(SPPixelFrames.power(on: false), [0x00, 0x00, 0x00, 0xAB])
    }

    /// The SP107E gist says off is `0xBB`, not `0xAB`. Both SP110E sources say
    /// `0xAB`. Kept as a separate constant so a strip that takes colour but
    /// will not switch off has somewhere to go.
    func testTheSP107EOffCommandIsCarriedSeparately() {
        XCTAssertEqual(SPPixelFrames.powerOffSP107E, [0x00, 0x00, 0x00, 0xBB])
        XCTAssertNotEqual(SPPixelFrames.powerOffSP107E, SPPixelFrames.power(on: false))
    }

    /// Brightness here really is a full byte, unlike ELK's and LEDnetWF's
    /// percentages.
    func testBrightnessIsAFullByte() {
        XCTAssertEqual(SPPixelFrames.brightness(0xFF), [0xFF, 0x00, 0x00, 0x2A])
        XCTAssertEqual(SPPixelFrames.brightness(0x00), [0x00, 0x00, 0x00, 0x2A])
    }

    /// `roslovets` special-cases mode 0 to the bare `0x06` command; modes
    /// 1…121 go through `0x2C`.
    func testModeZeroIsADifferentCommandEntirely() {
        XCTAssertEqual(SPPixelFrames.mode(0), [0x00, 0x00, 0x00, 0x06])
        XCTAssertEqual(SPPixelFrames.mode(1), [0x01, 0x00, 0x00, 0x2C])
        XCTAssertEqual(SPPixelFrames.mode(121), [0x79, 0x00, 0x00, 0x2C])
    }

    func testSpeedAndReadParametersGoldenBytes() {
        XCTAssertEqual(SPPixelFrames.speed(0x40), [0x40, 0x00, 0x00, 0x03])
        XCTAssertEqual(SPPixelFrames.readParameters, [0x00, 0x00, 0x00, 0x10])
    }

    /// The gist's connect-time write. Exposed but never sent automatically:
    /// `roslovets` omits it and works, and one unsourced write on connect is
    /// exactly what makes a bring-up session hard to reason about.
    func testTheOptionalInitWriteIsNotPartOfAnyCommand() {
        XCTAssertEqual(SPPixelFrames.optionalInitWrite, [0x01, 0xB7, 0xE3, 0xD5])
    }
}
