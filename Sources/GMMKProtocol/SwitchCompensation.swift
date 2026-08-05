import Foundation

/// Colour correction for keyboards with mixed switch housings.
///
/// A clear switch housing shows the LED's colour as it is; a tinted one filters
/// it. Glorious Lynx housings are cyan: they absorb red and over-transmit green
/// and blue, so a board with clear and Lynx switches side by side looks like two
/// different colours even though every LED is being sent the same bytes.
///
/// ## What gets corrected
///
/// The **tinted** keys are the ones that need correcting, and they are corrected
/// **towards the colour the user actually picked** — so the whole board
/// converges on the target rather than on the distortion.
///
/// The user marks the *minority* housing, because marking costs one key press
/// per key, and then says which kind they marked (``MarkedSwitches``). That
/// decides which side of the marked set gets the correction:
///
/// | ``MarkedSwitches`` | Marked keys | Unmarked keys |
/// |---|---|---|
/// | ``MarkedSwitches/trueColor`` | target colour, unchanged | corrected |
/// | ``MarkedSwitches/tinted`` | corrected | target colour, unchanged |
///
/// ## The correction
///
/// An inverse filter, with strength `s` in `0`…`1`:
///
/// ```
/// r' = r + (255 - r)·s        boost whatever red headroom exists
/// g' = g·(1 - s)              cut the over-transmitted green
/// b' = b·(1 - s·0.5)          cut blue too, half as hard
/// ```
///
/// Cutting green and blue is what does the work: the housing absorbs red, so on
/// a target that is already at `0xFF` red — the common case for warm colours —
/// there is no headroom to boost and the tint can only be cancelled by pulling
/// the other two channels down. Blue is cut at half rate because a cyan housing
/// passes green more freely than blue.
///
/// There is no way to derive the right `s` from first principles — it depends on
/// the housing, the LED and the eye — so the app has the user drag a slider
/// until the board looks uniform, and stores where they land.
public enum SwitchCompensation {

    /// Which kind of switch the user marked. The correction is applied to the
    /// tinted keys either way; this says which set those are.
    public enum MarkedSwitches: String, CaseIterable, Sendable {
        /// The marked keys are the clear ones that show the LED's true colour,
        /// so everything *else* is tinted and gets corrected. The common case:
        /// a mostly-Lynx board with a few clear switches.
        case trueColor
        /// The marked keys are the tinted ones and get corrected themselves.
        case tinted
    }

    /// Where the slider starts: no correction at all, so opening the tuner
    /// cannot change how the board looks until the user drags something.
    public static let defaultStrength: Double = 0

    /// Valid range for the strength factor.
    public static let strengthRange: ClosedRange<Double> = 0...1

    /// How much of `strength` is applied to the blue channel, relative to green.
    /// A cyan housing passes green more freely than blue, so blue is pulled down
    /// half as hard.
    public static let blueStrengthFactor: Double = 0.5

    /// Applies the inverse-filter correction to one colour. `strength` is
    /// clamped to ``strengthRange``; a strength of 0 returns `color` unchanged.
    public static func compensate(_ color: RGB, strength: Double) -> RGB {
        let s = min(max(strength, strengthRange.lowerBound), strengthRange.upperBound)
        let red = Double(color.red)
        return RGB(red: channel(red + (255 - red) * s),
                   green: channel(Double(color.green) * (1 - s)),
                   blue: channel(Double(color.blue) * (1 - s * blueStrengthFactor)))
    }

    /// Rounds to the nearest integer and clamps into a byte.
    private static func channel(_ value: Double) -> UInt8 {
        UInt8(Swift.max(0, Swift.min(255, value.rounded())))
    }

    /// Whether the LED at `ledIndex` is one of the tinted ones, i.e. the ones
    /// that need correcting.
    public static func needsCorrection(ledIndex: UInt16,
                                       markedLEDIndices: Set<UInt16>,
                                       markedSwitches: MarkedSwitches) -> Bool {
        let isMarked = markedLEDIndices.contains(ledIndex)
        return markedSwitches == .tinted ? isMarked : !isMarked
    }

    /// What one LED should be sent: the target colour for the true-colour keys,
    /// its corrected form for the tinted ones.
    public static func color(forLEDIndex ledIndex: UInt16,
                             target: RGB,
                             markedLEDIndices: Set<UInt16>,
                             markedSwitches: MarkedSwitches,
                             strength: Double) -> RGB {
        needsCorrection(ledIndex: ledIndex,
                        markedLEDIndices: markedLEDIndices,
                        markedSwitches: markedSwitches)
            ? compensate(target, strength: strength)
            : target
    }

    /// Colours for the whole of ``GMMKKeyMap/paintableLEDIndices``, in index
    /// order — i.e. the array to hand to
    /// ``GMMKTransaction/paintCompensated(target:markedLEDIndices:markedSwitches:strength:)``.
    public static func uniformColors(target: RGB,
                                     markedLEDIndices: Set<UInt16>,
                                     markedSwitches: MarkedSwitches,
                                     strength: Double) -> [RGB] {
        let corrected = compensate(target, strength: strength)
        return GMMKKeyMap.paintableLEDIndices.map {
            needsCorrection(ledIndex: $0,
                            markedLEDIndices: markedLEDIndices,
                            markedSwitches: markedSwitches) ? corrected : target
        }
    }
}
