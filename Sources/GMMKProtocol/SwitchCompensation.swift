import Foundation

/// Colour correction for keyboards with mixed switch housings.
///
/// A clear switch housing shows the LED's colour as it is; a tinted one filters
/// it. Glorious Lynx housings are cyan: they absorb red and tint everything
/// green, so a board with clear and Lynx switches side by side looks like two
/// different colours even though every LED is being sent the same bytes.
///
/// The fix is to pre-distort the colour sent to *some* of the keys — the ones
/// the user marks — so that what comes out of the housing matches the rest of
/// the board. Which type to mark is up to the user: it should be whichever they
/// have fewer of, because marking is done one key press at a time.
///
/// ``strengthRange`` is therefore **signed**, and the sign says which type was
/// marked:
///
/// | `s` | The marked keys are… | Applied to the marked keys |
/// |---|---|---|
/// | `> 0` | the tinted ones | undo the tint: push red up, pull green and blue down |
/// | `= 0` | — | nothing; every key gets the target colour |
/// | `< 0` | the clear ones | fake the tint: pull red down, push green up |
///
/// ```
/// s > 0:  r' = r + (255 - r)·s     g' = g·(1 - s)          b' = b·(1 - s)
/// s < 0:  r' = r·(1 - |s|)         g' = g + (255 - g)·|s|  b' = b
/// ```
///
/// The negative branch leaves blue alone. A cyan housing attenuates red hardest
/// and passes green and blue, so blue is the channel the two directions
/// disagree least about; ignoring it keeps the first pass simple, and the user
/// is tuning by eye against their own board anyway.
///
/// There is no way to derive the right `s` from first principles — it depends on
/// the housing, the LED and the eye — so the app has the user drag one slider
/// either way until the board looks uniform, and stores where they land.
public enum SwitchCompensation {

    /// Where the slider starts: no compensation at all, in either direction.
    public static let defaultStrength: Double = 0

    /// Valid range for the strength factor. Negative compensates in the
    /// opposite direction — see the type's discussion.
    public static let strengthRange: ClosedRange<Double> = -1...1

    /// Applies the compensation to one colour. `strength` is clamped to
    /// ``strengthRange``; a strength of 0 returns `color` unchanged.
    public static func compensate(_ color: RGB, strength: Double) -> RGB {
        let s = min(max(strength, strengthRange.lowerBound), strengthRange.upperBound)
        let red = Double(color.red)
        let green = Double(color.green)
        let blue = Double(color.blue)

        if s >= 0 {
            // The marked keys are the tinted ones: undo the tint.
            return RGB(red: channel(red + (255 - red) * s),
                       green: channel(green * (1 - s)),
                       blue: channel(blue * (1 - s)))
        }
        // The marked keys are the true-colour ones and the rest of the board is
        // tinted: tint these to match.
        let amount = -s
        return RGB(red: channel(red * (1 - amount)),
                   green: channel(green + (255 - green) * amount),
                   blue: color.blue)
    }

    /// Rounds to the nearest integer and clamps into a byte.
    private static func channel(_ value: Double) -> UInt8 {
        UInt8(Swift.max(0, Swift.min(255, value.rounded())))
    }

    /// What one LED should be sent: the target colour, or its compensated form
    /// if the user marked that key as the odd one out.
    public static func color(forLEDIndex ledIndex: UInt16,
                             target: RGB,
                             markedLEDIndices: Set<UInt16>,
                             strength: Double) -> RGB {
        markedLEDIndices.contains(ledIndex)
            ? compensate(target, strength: strength)
            : target
    }

    /// Colours for the whole of ``GMMKKeyMap/paintableLEDIndices``, in index
    /// order — i.e. the array to hand to
    /// ``GMMKTransaction/paintCompensated(target:markedLEDIndices:strength:)``.
    public static func uniformColors(target: RGB,
                                     markedLEDIndices: Set<UInt16>,
                                     strength: Double) -> [RGB] {
        let compensated = compensate(target, strength: strength)
        return GMMKKeyMap.paintableLEDIndices.map {
            markedLEDIndices.contains($0) ? compensated : target
        }
    }
}
