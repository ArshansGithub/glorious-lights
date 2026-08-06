import Foundation

/// Colours that look about the same through a clear housing and a tinted one.
///
/// Correcting for a cyan housing has a hard limit: the filter is *subtractive*,
/// so the only way to add back the red it absorbs is to drive red harder — and
/// on any warm colour red is already at `0xFF` with nowhere to go. See
/// ``SwitchCompensation``, which does what can be done and cannot do more.
///
/// Working with the bias instead of against it has no such limit. A cyan
/// housing barely touches green and blue, so a colour whose drive is mostly
/// green and blue comes out nearly the same through either housing and the
/// board reads as uniform with no per-key correction at all. These are ordinary
/// global solid colours — the plain `fixed` mode — not per-key paints.
///
/// Every entry keeps ``SwitchCompensation/redFraction(_:)`` at or below
/// ``maxRedFraction``, which is what makes it switch-friendly; a test enforces
/// that, so a new swatch cannot quietly break the guarantee.
public enum SwitchFriendlyPalette {

    /// A named swatch.
    public struct Swatch: Equatable, Sendable {
        public let name: String
        public let color: RGB

        public init(_ name: String, _ hex: String) {
            self.name = name
            // The hex strings are literals in this file, so a typo is a
            // programmer error rather than something to surface at runtime.
            guard let color = RGB(hex: hex) else {
                preconditionFailure("\(name) has a malformed hex colour: \(hex)")
            }
            self.color = color
        }
    }

    /// Ceiling on a swatch's red share of total drive. Comfortably under
    /// ``SwitchCompensation/redHeavyThreshold``, which is where a colour starts
    /// showing the switch mix badly.
    public static let maxRedFraction: Double = 0.35

    /// The palette, ordered warm-ish to cool so the menu reads as a gradient.
    public static let swatches: [Swatch] = [
        Swatch("Lime",    "99ff33"),
        Swatch("Mint",    "66ffaa"),
        Swatch("Seafoam", "44ffcc"),
        Swatch("Teal",    "00ccaa"),
        Swatch("Cyan",    "00e5ff"),
        Swatch("Ice",     "99e6ff"),
        Swatch("Sky",     "3399ff"),
        Swatch("Indigo",  "5533ff"),
    ]
}
