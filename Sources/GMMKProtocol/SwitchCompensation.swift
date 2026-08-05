import Foundation

/// Colour correction for keyboards with mixed switch housings.
///
/// A clear switch housing shows the LED's colour as it is; a tinted one filters
/// it. Glorious Lynx housings are cyan: they absorb red and tint everything
/// green, so a board with clear and Lynx switches side by side looks two
/// different colours even though every LED is being sent the same bytes.
///
/// The correction is a per-channel pre-distortion applied only to the keys the
/// user has marked as Lynx: push red up towards full and pull green and blue
/// down, by a single strength factor `s`.
///
/// ```
/// r' = r + (255 - r) · s
/// g' = g · (1 - s)
/// b' = b · (1 - s)
/// ```
///
/// `s = 0` leaves the colour alone, `s = 1` produces pure red. There is no way
/// to derive the right `s` from first principles — it depends on the housing,
/// the LED and the eye — so the app has the user drag a slider until the board
/// looks uniform, and stores what they land on.
public enum SwitchCompensation {

    /// Starting point for the strength slider. Not measured, just a middle
    /// value that puts the user near the interesting part of the range.
    public static let defaultStrength: Double = 0.5

    /// Valid range for the strength factor.
    public static let strengthRange: ClosedRange<Double> = 0...1

    /// Applies the compensation to one colour. `strength` is clamped to
    /// ``strengthRange``.
    public static func compensate(_ color: RGB, strength: Double) -> RGB {
        let s = min(max(strength, strengthRange.lowerBound), strengthRange.upperBound)
        let red = Double(color.red)
        return RGB(red: channel(red + (255 - red) * s),
                   green: channel(Double(color.green) * (1 - s)),
                   blue: channel(Double(color.blue) * (1 - s)))
    }

    /// Rounds to the nearest integer and clamps into a byte.
    private static func channel(_ value: Double) -> UInt8 {
        UInt8(Swift.max(0, Swift.min(255, value.rounded())))
    }

    /// What one LED should be sent: the target colour, or its compensated form
    /// if that LED sits under a Lynx switch.
    public static func color(forLEDIndex ledIndex: UInt16,
                             target: RGB,
                             lynxLEDIndices: Set<UInt16>,
                             strength: Double) -> RGB {
        lynxLEDIndices.contains(ledIndex)
            ? compensate(target, strength: strength)
            : target
    }

    /// Colours for the whole of ``GMMKKeyMap/paintableLEDIndices``, in index
    /// order — i.e. the array to hand to
    /// ``GMMKTransaction/paintCompensated(target:lynxLEDIndices:strength:)``.
    public static func uniformColors(target: RGB,
                                     lynxLEDIndices: Set<UInt16>,
                                     strength: Double) -> [RGB] {
        let compensated = compensate(target, strength: strength)
        return GMMKKeyMap.paintableLEDIndices.map {
            lynxLEDIndices.contains($0) ? compensated : target
        }
    }
}
