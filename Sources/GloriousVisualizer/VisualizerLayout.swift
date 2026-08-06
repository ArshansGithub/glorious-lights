import Foundation
import GMMKProtocol

/// The keyboard seen as a bar-graph display: vertical columns of keys, each of
/// which can be lit from the bottom up.
///
/// The physical grid is not rectangular — every row of a staggered keyboard has
/// a different key count, and the wide keys (space, shift, enter) straddle
/// several columns — so the mapping is written out by key rather than computed
/// from geometry the map does not carry. That makes it reviewable against the
/// board in front of you, and patchable one line at a time if a key looks wrong.
///
/// ## Why 17 columns
///
/// The main block's natural width is **14**: the number row and the QWERTY row
/// both have exactly fourteen keys, so those two rows define the grid and every
/// other row is fitted to it. The navigation cluster adds **3** more on the
/// right, giving 17 in total. Wide keys occupy every column they physically
/// cover, so a bar rising through the space bar lights it once for whichever of
/// its columns is loud.
///
/// ## Rows
///
/// Each column is a stack of rows, **bottom first**, matching how a level meter
/// fills. The five level rows are the bottom row, `ZXCV`, `ASDF`, `QWERTY` and
/// the number row. The function row is deliberately *not* one of them: it is the
/// peak indicator, lit separately when a column's level spikes, so the top of
/// the board reads as transient rather than as "very loud".
public enum VisualizerLayout {

    /// One column of the display.
    public struct Column: Equatable, Sendable {
        /// LED indices per row, **bottom row first**. A row usually holds one
        /// key; it holds several where a wide key spans this column or where
        /// two keys share the position.
        public let levelRows: [[UInt16]]
        /// The function-row key that flashes when this column peaks. Empty only
        /// if a column has no peak key.
        public let peakKeys: [UInt16]

        public init(levelRows: [[UInt16]], peakKeys: [UInt16]) {
            self.levelRows = levelRows
            self.peakKeys = peakKeys
        }

        /// How many rows this column can light — the resolution of its bar.
        public var rowCount: Int { levelRows.count }
    }

    /// Number of level rows in the main block: bottom, ZXCV, ASDF, QWERTY,
    /// number.
    public static let levelRowCount = 5

    /// Looks a key up by label, trapping on a typo rather than silently
    /// producing a column with a missing key.
    private static func led(_ label: String) -> UInt16 {
        guard let key = GMMKKeyMap.ansiTKL.first(where: { $0.label == label }) else {
            preconditionFailure("no key labelled '\(label)' in GMMKKeyMap.ansiTKL")
        }
        return key.ledIndex
    }

    private static func leds(_ labels: [String]) -> [UInt16] { labels.map(led) }

    /// The main block's five rows, each written left to right, fitted onto the
    /// 14-column grid the number and QWERTY rows define.
    ///
    /// Each entry is the list of labels occupying that column in that row. The
    /// wide keys repeat across the columns they cover: `Space` spans the middle
    /// of the bottom row, `Enter` and `Right Shift` the right edge of theirs.
    private static let mainBlockRows: [[[String]]] = [
        // Bottom row — three modifiers, a seven-column space bar, four more.
        [["Left Ctrl"], ["Left Cmd"], ["Left Opt"],
         ["Space"], ["Space"], ["Space"], ["Space"], ["Space"], ["Space"], ["Space"],
         ["Right Opt"], ["Right Cmd / Fn"], ["Menu"], ["Right Ctrl"]],
        // ZXCV row — Left Shift is wide on the left, Right Shift on the right.
        [["Left Shift"], ["Z"], ["X"], ["C"], ["V"], ["B"], ["N"], ["M"],
         [","], ["."], ["/"], ["Right Shift"], ["Right Shift"], ["Right Shift"]],
        // ASDF row — Caps on the left, Enter wide on the right.
        [["Caps Lock"], ["A"], ["S"], ["D"], ["F"], ["G"], ["H"], ["J"], ["K"], ["L"],
         [";"], ["'"], ["Enter"], ["Enter"]],
        // QWERTY row — exactly fourteen keys, one per column.
        [["Tab"], ["Q"], ["W"], ["E"], ["R"], ["T"], ["Y"], ["U"], ["I"], ["O"],
         ["P"], ["["], ["]"], ["\\"]],
        // Number row — also exactly fourteen.
        [["`"], ["1"], ["2"], ["3"], ["4"], ["5"], ["6"], ["7"], ["8"], ["9"],
         ["0"], ["-"], ["="], ["Backspace"]],
    ]

    /// The navigation cluster, as three more columns of two rows each. Bottom
    /// first, so `Delete` sits under `Insert` as it does physically.
    private static let navigationColumns: [[[String]]] = [
        [["Delete"], ["Insert"]],
        [["End"], ["Home"]],
        [["PgDn"], ["PgUp"]],
    ]

    /// The function row, left to right, used as peak indicators.
    private static let functionRow = ["Esc", "F1", "F2", "F3", "F4", "F5", "F6",
                                      "F7", "F8", "F9", "F10", "F11", "F12",
                                      "PrtSc", "ScrLk", "Pause"]

    /// Number of columns in the main block.
    public static let mainBlockColumnCount = 14

    /// Every column, left to right: fourteen in the main block, then the three
    /// of the navigation cluster.
    public static let columns: [Column] = {
        var result: [Column] = []

        for index in 0..<mainBlockColumnCount {
            let rows = mainBlockRows.map { leds($0[index]) }
            result.append(Column(levelRows: rows, peakKeys: []))
        }
        for column in navigationColumns {
            // The cluster is only two rows tall, so its bars are coarser than
            // the main block's. Padding it to five with empty rows would make a
            // quiet column look lit; leaving it short means its two rows simply
            // mean more each.
            result.append(Column(levelRows: column.map(leds), peakKeys: []))
        }

        // Peak keys are spread proportionally: sixteen function-row keys across
        // seventeen columns, so every column has one and adjacent columns share
        // where they must.
        return result.enumerated().map { index, column in
            let position = result.count > 1
                ? Double(index) * Double(functionRow.count - 1) / Double(result.count - 1)
                : 0
            let key = functionRow[Int(position.rounded())]
            return Column(levelRows: column.levelRows, peakKeys: [led(key)])
        }
    }()

    /// Every LED the display can light, level rows and peak keys together.
    /// Anything not in here is painted the background colour each frame.
    public static let litLEDIndices: Set<UInt16> = {
        var indices = Set<UInt16>()
        for column in columns {
            for row in column.levelRows { indices.formUnion(row) }
            indices.formUnion(column.peakKeys)
        }
        return indices
    }()
}
