import Foundation

/// Colour correction for keyboards with mixed switch housings.
///
/// A clear switch housing shows the LED's colour as it is; a tinted one filters
/// it. Glorious Lynx housings are cyan: they absorb red and over-transmit green
/// and blue, so a board with clear and Lynx switches side by side looks like two
/// different colours even though every LED is being sent the same bytes.
///
/// ## Which keys get corrected
///
/// The user marks the *minority* housing, because marking costs one key press
/// per key, and then says which kind they marked (``MarkedSwitches``). That
/// decides which side of the marked set is the tinted one:
///
/// | ``MarkedSwitches`` | Marked keys | Unmarked keys |
/// |---|---|---|
/// | ``MarkedSwitches/trueColor`` | true colour | tinted |
/// | ``MarkedSwitches/tinted`` | tinted | true colour |
///
/// ## The two corrections
///
/// A ``Profile`` composes both, in this order, per key:
///
/// 1. **Hue** — an inverse filter on the *tinted* keys only, pulling them back
///    towards the colour the user picked, with strength `s` in `0`…`1`:
///    ```
///    r' = r + (255 - r)·s        boost whatever red headroom exists
///    g' = g·(1 - s)              cut the over-transmitted green
///    b' = b·(1 - s·0.5)          cut blue too, half as hard
///    ```
///    Cutting green and blue is what does the work: the housing absorbs red, so
///    on a target already at `0xFF` red there is no headroom to boost and the
///    tint can only be cancelled from the other two channels. Blue is cut at
///    half rate because a cyan housing passes green more freely than blue.
///
/// 2. **Intensity** — a flat scale on *one whole set*, marked or unmarked,
///    chosen by the sign of ``Profile/balance``. Hue-matching does not imply
///    brightness-matching: on green- and blue-dominant colours the cyan plastic
///    acts as an efficient diffuser and those keys glow visibly *hotter* than
///    the clear ones, while on red-dominant colours the same housing makes them
///    dimmer. Which set is too bright therefore flips with hue, so the control
///    is bidirectional and the user drags towards uniform either way rather than
///    being asked which physical effect they are looking at.
///
/// Neither correction can be derived from first principles — both depend on the
/// housing, the LED and the eye — so the app has the user drag sliders until the
/// board looks uniform and stores where they land.
public enum SwitchCompensation {

    /// Which kind of switch the user marked. The hue correction is applied to
    /// the tinted keys either way; this says which set those are.
    public enum MarkedSwitches: String, CaseIterable, Sendable {
        /// The marked keys are the clear ones that show the LED's true colour,
        /// so everything *else* is tinted. The common case: a mostly-Lynx board
        /// with a few clear switches.
        case trueColor
        /// The marked keys are the tinted ones.
        case tinted
    }

    // MARK: - Ranges

    /// Where the hue slider starts: no correction at all, so opening the tuner
    /// cannot change how the board looks until the user drags something.
    public static let defaultStrength: Double = 0

    /// Valid range for the hue-correction strength.
    public static let strengthRange: ClosedRange<Double> = 0...1

    /// How much of `strength` is applied to the blue channel, relative to green.
    /// A cyan housing passes green more freely than blue, so blue is pulled down
    /// half as hard.
    public static let blueStrengthFactor: Double = 0.5

    /// Where the balance slider starts: both sets at full intensity.
    public static let defaultBalance: Double = 0

    /// Valid range for the intensity balance. **Signed**: positive dims the
    /// unmarked set, negative dims the marked set.
    public static let balanceRange: ClosedRange<Double> = -1...1

    /// How far a full-scale balance can dim a set — 70%, i.e. down to 30% drive.
    /// Short of blacking the set out, which would read as broken rather than as
    /// balanced.
    public static let maxDim: Double = 0.7

    // MARK: - The hue correction

    /// Applies the inverse-filter hue correction to one colour. `strength` is
    /// clamped to ``strengthRange``; a strength of 0 returns `color` unchanged.
    public static func compensate(_ color: RGB, strength: Double) -> RGB {
        let s = min(max(strength, strengthRange.lowerBound), strengthRange.upperBound)
        let red = Double(color.red)
        return RGB(red: channel(red + (255 - red) * s),
                   green: channel(Double(color.green) * (1 - s)),
                   blue: channel(Double(color.blue) * (1 - s * blueStrengthFactor)))
    }

    // MARK: - The intensity correction

    /// Multiplies every channel by `factor`, rounding and clamping.
    public static func scale(_ color: RGB, by factor: Double) -> RGB {
        RGB(red: channel(Double(color.red) * factor),
            green: channel(Double(color.green) * factor),
            blue: channel(Double(color.blue) * factor))
    }

    /// The intensity multiplier a balance of this magnitude applies to the set
    /// it dims: `1` at 0, `1 - maxDim` at full scale. The other set is left at 1.
    public static func dimFactor(forBalance balance: Double) -> Double {
        let magnitude = min(abs(balance), balanceRange.upperBound)
        return 1 - maxDim * magnitude
    }

    /// Rounds to the nearest integer and clamps into a byte.
    private static func channel(_ value: Double) -> UInt8 {
        UInt8(Swift.max(0, Swift.min(255, value.rounded())))
    }

    // MARK: - Profile

    /// Everything the user tuned: which keys are marked, what they are, and how
    /// hard to correct hue and intensity.
    ///
    /// This is the whole input to the per-key render, and ``isActive`` is what
    /// decides whether a colour change is sent as a per-key paint at all — see
    /// ``GMMKTransaction/applyColor(_:compensation:)``.
    public struct Profile: Equatable, Sendable {

        /// LED indices of the minority housing the user marked.
        public var markedLEDIndices: Set<UInt16>
        /// Which kind of switch those marks identify.
        public var markedSwitches: MarkedSwitches
        /// Hue-correction strength, `0`…`1`, applied to the tinted keys.
        public var strength: Double
        /// Intensity balance, `-1`…`1`. Positive dims the unmarked set,
        /// negative dims the marked set.
        public var balance: Double

        public init(markedLEDIndices: Set<UInt16> = [],
                    markedSwitches: MarkedSwitches = .trueColor,
                    strength: Double = SwitchCompensation.defaultStrength,
                    balance: Double = SwitchCompensation.defaultBalance) {
            self.markedLEDIndices = markedLEDIndices
            self.markedSwitches = markedSwitches
            self.strength = strength
            self.balance = balance
        }

        /// Nothing marked, nothing corrected.
        public static let neutral = Profile()

        /// Whether this profile would change any LED.
        ///
        /// Both halves matter: with nothing marked there are no two sets to tell
        /// apart, and with both sliders at zero there is nothing to apply — so
        /// either way the board is better served by a plain global colour write
        /// than by 12 per-key packets.
        public var isActive: Bool {
            !markedLEDIndices.isEmpty && (strength != 0 || balance != 0)
        }

        /// Whether this LED sits under a tinted housing and gets the hue
        /// correction.
        public func needsHueCorrection(ledIndex: UInt16) -> Bool {
            let isMarked = markedLEDIndices.contains(ledIndex)
            return markedSwitches == .tinted ? isMarked : !isMarked
        }

        /// Whether this LED is in the set the balance slider dims.
        public func isDimmed(ledIndex: UInt16) -> Bool {
            let isMarked = markedLEDIndices.contains(ledIndex)
            if balance > 0 { return !isMarked }
            if balance < 0 { return isMarked }
            return false
        }

        /// The intensity multiplier applied to the dimmed set.
        public var dimFactor: Double { SwitchCompensation.dimFactor(forBalance: balance) }

        /// What one LED should be sent: the target, hue-corrected if that key is
        /// tinted, then scaled if that key is in the dimmed set.
        public func color(forLEDIndex ledIndex: UInt16, target: RGB) -> RGB {
            var color = target
            if needsHueCorrection(ledIndex: ledIndex) {
                color = SwitchCompensation.compensate(color, strength: strength)
            }
            if isDimmed(ledIndex: ledIndex) {
                color = SwitchCompensation.scale(color, by: dimFactor)
            }
            return color
        }

        /// Colours for the whole of ``GMMKKeyMap/paintableLEDIndices``, in index
        /// order — i.e. the array to hand to
        /// ``GMMKTransaction/paintCompensated(target:profile:)``.
        ///
        /// Only four distinct colours are possible, so they are computed once
        /// rather than per LED.
        public func uniformColors(target: RGB) -> [RGB] {
            let corrected = SwitchCompensation.compensate(target, strength: strength)
            let factor = dimFactor
            let plainDimmed = SwitchCompensation.scale(target, by: factor)
            let correctedDimmed = SwitchCompensation.scale(corrected, by: factor)

            return GMMKKeyMap.paintableLEDIndices.map { index in
                let tinted = needsHueCorrection(ledIndex: index)
                let dimmed = isDimmed(ledIndex: index)
                switch (tinted, dimmed) {
                case (true, true):   return correctedDimmed
                case (true, false):  return corrected
                case (false, true):  return plainDimmed
                case (false, false): return target
                }
            }
        }
    }

    // MARK: - How badly a colour will show the switch mix

    /// How much of a colour's total drive is red, `0`…`1`.
    ///
    /// Red is the channel a cyan housing absorbs, so it is the one that makes a
    /// mixed-switch board look like two boards. Black has no drive at all and
    /// scores 0.
    public static func redFraction(_ color: RGB) -> Double {
        let total = Double(Int(color.red) + Int(color.green) + Int(color.blue))
        return Double(color.red) / Swift.max(1, total)
    }

    /// Above this share of red, the difference between housings is obvious
    /// enough to be worth warning about.
    public static let redHeavyThreshold: Double = 0.45

    /// Whether a colour is red-dominant enough that a mixed-switch board will
    /// visibly show the mix. Advisory only — nothing refuses to send it.
    public static func isRedHeavy(_ color: RGB) -> Bool {
        redFraction(color) > redHeavyThreshold
    }
}
