import XCTest
@testable import GMMKProtocol

/// Shape tests for the ANSI TKL key table. These cannot check that a given key
/// lights the LED the table claims — only hardware can — but they can check the
/// table is a well-formed bijection over a plausible index space, which is where
/// a transcription slip from `docs/protocol.md` §4 would show up.
final class KeyMapTests: XCTestCase {

    func testCoversEveryANSITKLKey() {
        XCTAssertEqual(GMMKKeyMap.ansiTKL.count, GMMKKeyMap.ansiTKLKeyCount)
        XCTAssertEqual(GMMKKeyMap.ansiTKLKeyCount, 87)
    }

    func testLEDIndicesAreUnique() {
        let indices = GMMKKeyMap.ansiTKL.map(\.ledIndex)
        XCTAssertEqual(Set(indices).count, indices.count,
                       "two keys claim the same LED index")
    }

    func testKeyCodesAreUnique() {
        let codes = GMMKKeyMap.ansiTKL.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count,
                       "two keys claim the same virtual key code")
    }

    func testLEDIndicesAreInRange() {
        for key in GMMKKeyMap.ansiTKL {
            XCTAssertGreaterThanOrEqual(key.ledIndex, GMMKKeyMap.minLEDIndex, key.label)
            XCTAssertLessThanOrEqual(key.ledIndex, GMMKKeyMap.maxLEDIndex, key.label)
        }
        XCTAssertEqual(GMMKKeyMap.minLEDIndex, 1)
        XCTAssertEqual(GMMKKeyMap.maxLEDIndex, 126)
        XCTAssertEqual(GMMKKeyMap.paintableLEDIndices.count, 126)
    }

    func testLabelsAreUniqueAndNonEmpty() {
        let labels = GMMKKeyMap.ansiTKL.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertFalse(labels.contains(""))
    }

    /// Indices lifted straight out of `docs/protocol.md` §4. The two that matter
    /// most are the ones the doc independently cross-validates against
    /// `rgb_keyboard`'s address table: Backspace 98 (0x0126) and PrtSc 106
    /// (0x013E).
    func testSpotChecksAgainstTheFullSizeMap() {
        let expected: [(String, UInt16)] = [
            ("Esc", 1), ("F1", 2), ("F12", 13),
            ("`", 18), ("=", 30), ("Backspace", 98),
            ("Tab", 35), ("\\", 64),
            ("Caps Lock", 52), ("Enter", 81),
            ("Left Shift", 69), ("Right Shift", 80),
            ("Space", 89), ("Right Ctrl", 93),
            ("PrtSc", 106), ("ScrLk", 107), ("Pause", 108),
            ("Insert", 110), ("PgDn", 115),
            ("Up", 96), ("Left", 94), ("Down", 95), ("Right", 97),
        ]
        for (label, ledIndex) in expected {
            let key = GMMKKeyMap.ansiTKL.first { $0.label == label }
            XCTAssertEqual(key?.ledIndex, ledIndex, label)
        }
    }

    /// The numpad indices belong to the full-size board only, so none of them
    /// may appear here.
    func testNoNumpadIndices() {
        let numpad: Set<UInt16> = [31, 32, 33, 48, 49, 50, 65, 66, 67,
                                   82, 83, 84, 99, 100, 101, 116, 117]
        for key in GMMKKeyMap.ansiTKL {
            XCTAssertFalse(numpad.contains(key.ledIndex),
                           "\(key.label) uses numpad index \(key.ledIndex)")
        }
    }

    func testLookupsRoundTrip() {
        for key in GMMKKeyMap.ansiTKL {
            XCTAssertEqual(GMMKKeyMap.ledIndex(forKeyCode: key.keyCode), key.ledIndex, key.label)
            XCTAssertEqual(GMMKKeyMap.key(forKeyCode: key.keyCode), key, key.label)
            XCTAssertEqual(GMMKKeyMap.key(forLEDIndex: key.ledIndex), key, key.label)
        }
        XCTAssertEqual(GMMKKeyMap.ledIndexByKeyCode.count, GMMKKeyMap.ansiTKLKeyCount)
    }

    /// A key this board does not have — 0x53 is numpad 1 — must not resolve.
    func testUnknownKeyCodeResolvesToNil() {
        XCTAssertNil(GMMKKeyMap.ledIndex(forKeyCode: 0x53))
        XCTAssertNil(GMMKKeyMap.key(forKeyCode: 0xFFFF))
    }

    /// Gaps in the index space (14–17, 34, 51, 68, …) have no key.
    func testUnpopulatedIndicesResolveToNil() {
        for index: UInt16 in [14, 15, 16, 17, 34, 51, 68, 109] {
            XCTAssertNil(GMMKKeyMap.key(forLEDIndex: index), "index \(index)")
        }
    }

    /// Modifiers are the keys most likely to be mis-transcribed, and macOS
    /// delivers them as `flagsChanged` rather than `keyDown`, so pin the codes.
    func testModifierKeyCodes() {
        let expected: [(String, UInt16)] = [
            ("Left Shift", 0x38), ("Right Shift", 0x3C),
            ("Left Ctrl", 0x3B), ("Right Ctrl", 0x3E),
            ("Left Opt", 0x3A), ("Right Opt", 0x3D),
            ("Left Cmd", 0x37), ("Right Cmd", 0x36),
            ("Caps Lock", 0x39),
        ]
        for (label, keyCode) in expected {
            XCTAssertEqual(GMMKKeyMap.ansiTKL.first { $0.label == label }?.keyCode,
                           keyCode, label)
        }
    }
}
