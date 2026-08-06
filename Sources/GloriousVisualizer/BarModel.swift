import Foundation
import GMMKProtocol

/// How a column's level moves over time: **instant attack, slow release**.
///
/// A meter that tracked the signal exactly would flicker at frame rate and read
/// as noise. Rising immediately and falling on an exponential tail is what makes
/// a bar graph legible: transients are visible the frame they happen, and the
/// eye is given something continuous to follow between them.
public struct LevelSmoother: Equatable, Sendable {

    /// Time for a bar to fall to about a third of its height with no new input.
    public static let defaultReleaseTime: Double = 0.200

    /// Seconds for the exponential release.
    public var releaseTime: Double
    private(set) var levels: [Float]

    public init(bandCount: Int, releaseTime: Double = LevelSmoother.defaultReleaseTime) {
        self.releaseTime = releaseTime
        self.levels = [Float](repeating: 0, count: bandCount)
    }

    /// Folds a new set of levels in, given how long since the last frame.
    ///
    /// The decay is computed from elapsed time rather than applied per frame, so
    /// a frame the transport delayed does not leave the bars hanging: the fall
    /// looks the same whether the display managed 15 fps or 9.
    public mutating func update(with input: [Float], elapsed: Double) -> [Float] {
        let decay = releaseTime > 0 ? Float(exp(-max(elapsed, 0) / releaseTime)) : 0
        for index in levels.indices {
            let incoming = index < input.count ? input[index] : 0
            // Attack is instantaneous; only the fall is smoothed.
            levels[index] = incoming >= levels[index] ? incoming : levels[index] * decay
        }
        return levels
    }

    /// The current levels without advancing time.
    public var current: [Float] { levels }
}

/// Slowly normalises to the loudest thing heard recently, so quiet recordings
/// and loud ones both fill the board.
///
/// Deliberately sluggish. A fast normaliser pumps — it turns a quiet passage up
/// until the next drum hit slams everything back down — so the reference peak
/// rises quickly to a new maximum and decays over many seconds.
public struct AutoGain: Equatable, Sendable {

    /// How long the reference peak takes to fall to about a third with nothing
    /// louder arriving.
    public static let defaultDecayTime: Double = 4.0

    /// The quietest reference peak allowed. Without a floor, silence drives the
    /// gain to infinity and the first faint sound blinds the display.
    public static let minimumPeak: Float = 0.005

    public var decayTime: Double
    private(set) var peak: Float

    public init(decayTime: Double = AutoGain.defaultDecayTime) {
        self.decayTime = decayTime
        self.peak = AutoGain.minimumPeak
    }

    /// Updates the reference peak and returns the multiplier to apply.
    public mutating func update(observedPeak: Float, elapsed: Double) -> Float {
        let decay = decayTime > 0 ? Float(exp(-max(elapsed, 0) / decayTime)) : 0
        peak = max(observedPeak, max(peak * decay, Self.minimumPeak))
        return 1 / peak
    }
}

/// Which colours the bars are painted in.
public enum VisualizerStyle: String, CaseIterable, Sendable {
    /// Bars in the desk look's own colour, graded from dim at the bottom to
    /// full at the top, so the board keeps whatever colour the user chose.
    case theme
    /// Green at the bottom through yellow to red at the top — the colours a
    /// level meter has used since long before keyboards had LEDs, and readable
    /// without knowing what the display is.
    case heat

    public var displayName: String {
        switch self {
        case .theme: return "Theme Colour"
        case .heat:  return "Heat"
        }
    }
}

/// Turns per-column levels into one colour per LED.
///
/// Pure: it takes numbers and returns a paint, so the whole visual result is
/// testable without audio or hardware.
public struct BarRenderer: Sendable {

    /// A column lights its peak key when it reaches this fraction of full.
    public static let peakThreshold: Float = 0.85

    public var style: VisualizerStyle
    /// The colour ``VisualizerStyle/theme`` paints in.
    public var themeColor: RGB
    /// What unlit keys show. Black rather than dark grey: a spectrum analyser
    /// wants contrast, and the board's own glow is the background.
    public var background: RGB

    public init(style: VisualizerStyle, themeColor: RGB, background: RGB = .black) {
        self.style = style
        self.themeColor = themeColor
        self.background = background
    }

    /// How many of `rowCount` rows a level of `0…1` lights.
    ///
    /// Rounds up rather than to nearest, so any audible signal lights the bottom
    /// row: a bar that reads zero for everything below half a row makes the
    /// display look broken during quiet passages.
    public static func rowsLit(level: Float, rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        guard level > 0 else { return 0 }
        let clamped = min(max(level, 0), 1)
        return min(rowCount, max(1, Int((clamped * Float(rowCount)).rounded(.up))))
    }

    /// The colour for row `row` of `rowCount`, `row` counting from the bottom.
    public func color(forRow row: Int, of rowCount: Int) -> RGB {
        let position = rowCount > 1 ? Double(row) / Double(rowCount - 1) : 1
        switch style {
        case .theme:
            // Dim at the bottom to full at the top, never fully dark or the
            // bottom row would be invisible.
            let scale = 0.35 + 0.65 * position
            return RGB(red: channel(Double(themeColor.red) * scale),
                       green: channel(Double(themeColor.green) * scale),
                       blue: channel(Double(themeColor.blue) * scale))
        case .heat:
            // Green → yellow over the lower half, yellow → red over the upper.
            if position <= 0.5 {
                let t = position * 2
                return RGB(red: channel(255 * t), green: 255, blue: 0)
            }
            let t = (position - 0.5) * 2
            return RGB(red: 255, green: channel(255 * (1 - t)), blue: 0)
        }
    }

    private func channel(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }

    /// Renders one frame: a colour for every LED index the layout can light,
    /// plus `background` for the rest of the addressable range.
    ///
    /// - Parameter levels: one per column, `0…1`. Extra entries are ignored and
    ///   missing ones read as silent.
    public func frame(levels: [Float]) -> [RGB] {
        var colors = [RGB](repeating: background,
                           count: GMMKKeyMap.paintableLEDIndices.count)
        func paint(_ ledIndex: UInt16, _ color: RGB) {
            let offset = Int(ledIndex) - Int(GMMKKeyMap.minLEDIndex)
            guard colors.indices.contains(offset) else { return }
            colors[offset] = color
        }

        for (index, column) in VisualizerLayout.columns.enumerated() {
            let level = index < levels.count ? levels[index] : 0
            let lit = Self.rowsLit(level: level, rowCount: column.rowCount)
            for row in 0..<lit {
                let color = self.color(forRow: row, of: column.rowCount)
                for led in column.levelRows[row] { paint(led, color) }
            }
            if level >= Self.peakThreshold {
                // The peak row is a transient marker, so it is painted at full
                // rather than graded — it is either happening or it is not.
                let peakColor = style == .heat
                    ? RGB(red: 255, green: 255, blue: 255)
                    : themeColor
                for led in column.peakKeys { paint(led, peakColor) }
            }
        }
        return colors
    }
}
