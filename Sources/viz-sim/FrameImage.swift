import CoreGraphics
import Foundation
import GMMKProtocol
import GloriousVisualizer
import ImageIO
import UniformTypeIdentifiers

/// Draws a rendered frame as a TKL-shaped grid of rounded rects.
///
/// The geometry is derived from ``VisualizerLayout`` rather than from a keycap
/// map, so what is drawn is exactly the structure the renderer addresses:
/// columns left to right, rows bottom to top, the function row as a separate
/// strip. Colours are looked up per LED index out of the frame the keyboard
/// would actually have been sent — there is no second colour path here.
enum FrameImage {

    static let keySize: CGFloat = 40
    static let gap: CGFloat = 6
    static let margin: CGFloat = 24
    /// Space between the function-row strip and the main block.
    static let functionRowGap: CGFloat = 18

    private static let columnCount = VisualizerLayout.columns.count
    private static let mainRowCount = VisualizerLayout.levelRowCount

    static var imageSize: CGSize {
        let width = margin * 2 + CGFloat(columnCount) * keySize + CGFloat(columnCount - 1) * gap
        let height = margin * 2 + CGFloat(mainRowCount + 1) * keySize
            + CGFloat(mainRowCount - 1) * gap + functionRowGap
        return CGSize(width: width, height: height)
    }

    /// Renders one frame to an image. `colors` is indexed as the renderer
    /// produces it: offset `n` is LED index `n + GMMKKeyMap.minLEDIndex`.
    static func image(colors: [RGB]) throws -> CGImage {
        try draw(colors: colors)
    }

    /// Writes one PNG.
    static func write(colors: [RGB], to url: URL) throws {
        let image = try draw(colors: colors)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SimError.imageFailed(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SimError.imageFailed(url.path)
        }
    }

    private static func draw(colors: [RGB]) throws -> CGImage {
        let size = imageSize
        guard let context = CGContext(data: nil,
                                      width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SimError.imageFailed("bitmap context")
        }

        // Dark background: the board is unlit plastic, and a white page would
        // make a dim bar look brighter than it is.
        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        func color(forLED led: UInt16) -> CGColor {
            let offset = Int(led) - Int(GMMKKeyMap.minLEDIndex)
            let rgb = colors.indices.contains(offset) ? colors[offset] : .black
            // Unlit keys are drawn as faint outlines rather than pure black, so
            // the board's shape stays readable in a dark frame.
            if rgb == .black {
                return CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1)
            }
            return CGColor(red: CGFloat(rgb.red) / 255,
                           green: CGFloat(rgb.green) / 255,
                           blue: CGFloat(rgb.blue) / 255,
                           alpha: 1)
        }

        func draw(_ rect: CGRect, _ cgColor: CGColor) {
            let path = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                              cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.setFillColor(cgColor)
            context.addPath(path)
            context.fillPath()
        }

        for (columnIndex, column) in VisualizerLayout.columns.enumerated() {
            let x = margin + CGFloat(columnIndex) * (keySize + gap)

            for rowIndex in 0..<column.rowCount {
                // Row 0 is the bottom row, and CoreGraphics' origin is bottom
                // left, so the row index is the y index directly.
                let y = margin + CGFloat(rowIndex) * (keySize + gap)
                let led = column.levelRows[rowIndex].first ?? 0
                draw(CGRect(x: x, y: y, width: keySize, height: keySize), color(forLED: led))
            }

            // The function row sits above the tallest main column, whatever
            // this column's own height is.
            let topY = margin + CGFloat(mainRowCount) * (keySize + gap) + functionRowGap
            if let peak = column.peakKeys.first {
                draw(CGRect(x: x, y: topY, width: keySize, height: keySize),
                     color(forLED: peak))
            }
        }

        guard let image = context.makeImage() else {
            throw SimError.imageFailed("makeImage")
        }
        return image
    }
}
