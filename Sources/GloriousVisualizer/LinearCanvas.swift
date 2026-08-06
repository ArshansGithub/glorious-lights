import Foundation
import GMMKProtocol

/// The board as a 17 × 6 grid of float RGB, which is what modes paint into.
///
/// Composition happens entirely in float lightness, 0…1, additively — light adds
/// (P8). There is exactly one gamma encode, in ``KeyInterlock/encode(_:)``, at
/// the very end of the pipeline.
///
/// The grid is *normalised*: five level rows plus one peak row, regardless of
/// how many physical rows a given column has. Columns with fewer rows (the
/// three-key navigation cluster has two) sample the same continuous field, so a
/// bar rising through them fades in exactly as it does on the main block instead
/// of toggling half the column at a level crossing.
public struct LinearCanvas: Sendable {

    public static var columnCount: Int { VisualizerLayout.columns.count }
    /// Five level rows.
    public static let rowCount = 5
    /// Row index of the function-row peak markers.
    public static let peakRow = rowCount

    /// `[column][row]`, row 0 at the bottom, row 5 the peak marker.
    public private(set) var red: [[Double]]
    public private(set) var green: [[Double]]
    public private(set) var blue: [[Double]]

    public init() {
        let empty = [[Double]](repeating: [Double](repeating: 0, count: Self.rowCount + 1),
                               count: Self.columnCount)
        red = empty
        green = empty
        blue = empty
    }

    public mutating func add(column: Int, row: Int, _ colour: (r: Double, g: Double, b: Double),
                             level: Double) {
        guard column >= 0, column < Self.columnCount,
              row >= 0, row <= Self.peakRow, level > 0 else { return }
        red[column][row] += colour.r * level
        green[column][row] += colour.g * level
        blue[column][row] += colour.b * level
    }

    /// Paints a whole column, level rows and optionally the peak marker.
    public mutating func addColumn(_ column: Int, _ colour: (r: Double, g: Double, b: Double),
                                   level: Double, peak: Double = 0) {
        for row in 0..<Self.rowCount { add(column: column, row: row, colour, level: level) }
        if peak > 0 { add(column: column, row: Self.peakRow, colour, level: peak) }
    }

    /// Fills a column from the bottom to a fractional height (§6.5).
    ///
    /// The top row's coverage is `h − r` clamped to `0…1`, so a rising bar fades
    /// its top row in continuously. The old integer row count made the top row of
    /// every bar a pure on/off, which on a two-row column meant a level crossing
    /// 0.5 toggled half the column — a large fraction of the visible per-frame
    /// toggling on quiet material.
    public mutating func fillColumn(_ column: Int, height: Double,
                                    colour: (r: Double, g: Double, b: Double),
                                    ramp: (Int) -> Double = { row in
                                        0.35 + 0.65 * Double(row) / Double(LinearCanvas.rowCount - 1)
                                    }) {
        let h = clamp(height, 0, 1) * Double(Self.rowCount)
        for row in 0..<Self.rowCount {
            let coverage = clamp(h - Double(row), 0, 1)
            guard coverage > 0 else { break }
            add(column: column, row: row, colour, level: coverage * ramp(row))
        }
    }

    /// Separable Gaussian blur across the grid, σ = 1.0 cell (§6.2).
    ///
    /// This is what makes single-column gestures readable, and it replaces
    /// `widenIsolatedColumns` — a frame-relative threshold with no temporal state
    /// applied at the very end of the pipeline, where whether a column counted as
    /// "lit" could flip between consecutive frames purely because the frame's own
    /// brightest key changed.
    public mutating func blur(sigma: Double = 1.0) {
        guard sigma > 0 else { return }
        let radius = max(1, Int((sigma * 2.5).rounded()))
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        for index in kernel.indices { kernel[index] /= total }

        func blurChannel(_ channel: [[Double]]) -> [[Double]] {
            var horizontal = channel
            for column in 0..<Self.columnCount {
                for row in 0...Self.peakRow {
                    var sum: Double = 0
                    for (offset, weight) in kernel.enumerated() {
                        let source = min(max(column + offset - radius, 0), Self.columnCount - 1)
                        sum += channel[source][row] * weight
                    }
                    horizontal[column][row] = sum
                }
            }
            var vertical = horizontal
            for column in 0..<Self.columnCount {
                // The peak row is a separate display element, not the top of the
                // bar, so vertical blur stops below it.
                for row in 0..<Self.rowCount {
                    var sum: Double = 0
                    for (offset, weight) in kernel.enumerated() {
                        let source = min(max(row + offset - radius, 0), Self.rowCount - 1)
                        sum += horizontal[column][source] * weight
                    }
                    vertical[column][row] = sum
                }
            }
            return vertical
        }

        red = blurChannel(red)
        green = blurChannel(green)
        blue = blurChannel(blue)
    }

    /// Samples the normalised grid at a physical column/row, interpolating so a
    /// short column reads the same continuous field as a tall one.
    public func sample(column: Int, physicalRow: Int, of rowCount: Int)
        -> (r: Double, g: Double, b: Double) {
        guard rowCount > 0 else { return (0, 0, 0) }
        let position = rowCount == 1
            ? 0.0
            : Double(physicalRow) * Double(Self.rowCount - 1) / Double(rowCount - 1)
        let lower = min(max(Int(position), 0), Self.rowCount - 1)
        let upper = min(lower + 1, Self.rowCount - 1)
        let t = position - Double(lower)
        func mix(_ channel: [[Double]]) -> Double {
            channel[column][lower] * (1 - t) + channel[column][upper] * t
        }
        return (mix(red), mix(green), mix(blue))
    }

    public func peak(column: Int) -> (r: Double, g: Double, b: Double) {
        (red[column][Self.peakRow], green[column][Self.peakRow], blue[column][Self.peakRow])
    }
}

/// The per-key state machine that turns "probably won't flicker" into "cannot
/// flicker", independent of what any mode did (§6.3).
///
/// A Schmitt trigger with a 2.3:1 hysteresis ratio, a minimum on-time, a minimum
/// off-time and a down-slew limit. Together the on- and off-time minima put a
/// hard ceiling of four on→off→on transitions per key-second on the display, by
/// construction — one full cycle needs at least 150 + 100 ms.
///
/// It is a filter, not a source: it can only delay a key going dark and delay it
/// relighting. It cannot create light the model did not ask for.
public struct KeyHold: Equatable, Sendable {

    public static let riseThreshold: Double = 0.14
    public static let fallThreshold: Double = 0.06
    public static let minimumOn: Double = 0.150
    public static let minimumOff: Double = 0.100
    /// A key cannot fall from full to black faster than this.
    public static let downSlewSeconds: Double = 0.200

    private var lit = false
    private var litSince: Double = -.infinity
    private var darkSince: Double = -.infinity
    private var displayed: Double = 0

    public init() {}

    @discardableResult
    public mutating func update(_ x: Double, now: Double, dt: Double) -> Double {
        if lit {
            if x < Self.fallThreshold, now - litSince >= Self.minimumOn {
                lit = false
                darkSince = now
            }
        } else if x > Self.riseThreshold, now - darkSince >= Self.minimumOff {
            lit = true
            litSince = now
        }

        // Rising is unbounded — attacks must stay instant. Falling is rate
        // limited, and while the key is held on it cannot fall below the level
        // at which the model said it was lit.
        let desired = lit ? max(x, Self.riseThreshold) : 0
        if desired >= displayed {
            displayed = desired
        } else {
            displayed = max(desired, displayed - dt / Self.downSlewSeconds)
        }
        return displayed
    }

    public var isLit: Bool { lit }
    public var level: Double { displayed }
}

/// The per-LED interlock bank plus the single gamma encode.
public struct KeyInterlock: Sendable {

    private var keys: [KeyHold]

    public init() {
        keys = [KeyHold](repeating: KeyHold(), count: GMMKKeyMap.paintableLEDIndices.count)
    }

    /// Runs the interlock over one frame of linear-lightness colours and encodes
    /// the result.
    ///
    /// - Parameters:
    ///   - levels: per-LED `(r, g, b)` in lightness units, 0…1.
    ///   - sensitivity: the user's gain, applied **after** the hold decision so
    ///     that turning it down cannot make the interlock let go of a key.
    public mutating func encode(_ levels: [(r: Double, g: Double, b: Double)],
                                sensitivity: Double,
                                now: Double, dt: Double) -> [RGB] {
        var out = [RGB](repeating: .black, count: keys.count)
        for index in keys.indices {
            let colour: (r: Double, g: Double, b: Double) =
                index < levels.count ? levels[index] : (0, 0, 0)
            // The interlock decides on the key's overall lightness, so a key
            // never changes hue as a side effect of being held on.
            let lightness = max(colour.r, max(colour.g, colour.b))
            let held = keys[index].update(min(lightness, 1), now: now, dt: dt)
            guard held > 0, lightness > 0 else { continue }
            let scale = held / lightness
            out[index] = RGB(red: Self.gamma(Self.gain(colour.r * scale, sensitivity)),
                             green: Self.gamma(Self.gain(colour.g * scale, sensitivity)),
                             blue: Self.gamma(Self.gain(colour.b * scale, sensitivity)))
        }
        return out
    }

    /// The user's sensitivity, as a gain that cannot clip and cannot crush.
    ///
    /// `1 − (1 − x)^s` is monotone in both arguments, fixes 0 and 1, and is the
    /// identity at `s = 1`. A plain multiply is neither: at the top of the
    /// shipped range it drove most of the board to full scale, where a kick has
    /// nowhere left to go — the frame-to-frame difference collapsed below M2's
    /// *lower* bound and nearly half the events produced no measurable response
    /// at all, which is the design's "other way to fail the user's complaint".
    /// This keeps the ordering and the dynamics of what the model composed and
    /// only changes how much of the range they occupy.
    public static func gain(_ lightness: Double, _ sensitivity: Double) -> Double {
        let x = clamp(lightness, 0, 1)
        guard sensitivity != 1, sensitivity > 0 else { return x }
        return 1 - pow(1 - x, sensitivity)
    }

    /// The one gamma encode in the system (§6.5).
    ///
    /// Perceived brightness is roughly a power law, so a linear PWM ramp spends
    /// most of its visible change in the bottom fifth of the range and reads as
    /// an abrupt jump at the top. Encoding once, at the end, is what makes a fade
    /// over four frames look like a fade rather than four steps — and it is what
    /// makes low-level detail visible instead of collapsing into the bottom few
    /// code values.
    public static func gamma(_ lightness: Double) -> UInt8 {
        UInt8(clamp((255 * pow(clamp(lightness, 0, 1), 2.2)).rounded(), 0, 255))
    }

    /// The inverse, for tools that measure what was displayed.
    public static func decode(_ byte: UInt8) -> Double {
        pow(Double(byte) / 255, 1 / 2.2)
    }

    public mutating func reset() {
        keys = [KeyHold](repeating: KeyHold(), count: keys.count)
    }
}
