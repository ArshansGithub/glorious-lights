import Foundation

/// Where the six individually-addressable LEDs physically are.
///
/// Effect ``MouseRGBEffect/constant`` (`0x06`) drives all six independently from
/// the colour array at blob `0x56`–`0x67`. Nothing else does: Glorious's own
/// software does not expose the mode, and neither libratbag nor OpenRGB
/// implements it. The layout below is **hardware-verified** — established by
/// writing R, G, B, Y, M, C in index order and looking at the mouse — and is
/// recorded in `docs/mouse-protocol.md` §13.
///
/// ```
///        ┌─────────────┐
///   1 ───┤ ○  wheel    ├─── 1     front / cable end
///   2 ───┤             ├─── 2
///   3 ───┤             ├─── 3
///   4 ───┤             ├─── 4
///   5 ───┤             ├─── 5
///   6 ───┤             ├─── 6     back / palm end
///        └─────────────┘
/// ```
///
/// Three consequences worth stating plainly, because each one would otherwise
/// be discovered as a surprise:
///
/// * **Both side strips carry all six LEDs, mirrored.** There is no left/right
///   addressing — index 3 lights the same position on each side, and a gradient
///   runs identically down both flanks.
/// * **Index order is front to back**, front being the cable end.
/// * **The scroll wheel follows index 1.** It is not separately addressable, so
///   a UI that wants the wheel a particular colour is choosing LED 1's colour.
///
/// Intermediate hues visible between adjacent LEDs are the diffuser blending
/// two neighbours, not additional channels.
public enum MouseLED {

    /// Number of individually addressable LEDs — the same six the constant
    /// effect's colour array holds.
    public static let count = GloriousMouseDevice.ledCount

    /// Valid indices, 1-based as the UI and docs number them.
    public static let indices = 1...count

    /// Human label for a 1-based LED index, naming what else that position
    /// drives where it is not obvious.
    ///
    /// - Precondition: `index` is in ``indices``.
    public static func label(forIndex index: Int) -> String {
        precondition(indices.contains(index), "LED index \(index) is outside \(indices)")
        switch index {
        case 1:     return "LED 1 (front + wheel)"
        case count: return "LED \(count) (back)"
        default:    return "LED \(index)"
        }
    }

    /// All six labels, in index order.
    public static var labels: [String] { indices.map(label(forIndex:)) }

    /// Pads or trims a colour list to exactly ``count`` entries.
    ///
    /// Short lists repeat their last colour rather than going black: someone
    /// giving one colour means "this colour", not "this colour and five off".
    /// An empty list yields six blacks, which is the only sensible reading of
    /// no colours at all.
    public static func padded(_ colors: [MouseRGB]) -> [MouseRGB] {
        guard let last = colors.last else {
            return Array(repeating: .black, count: count)
        }
        if colors.count >= count { return Array(colors.prefix(count)) }
        return colors + Array(repeating: last, count: count - colors.count)
    }
}
