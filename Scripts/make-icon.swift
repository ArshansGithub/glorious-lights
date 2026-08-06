#!/usr/bin/env swift
//
// Renders the app icon as a set of PNGs for `iconutil`.
//
//   swift Scripts/make-icon.swift <output.iconset directory>
//
// The glyph is drawn from primitives rather than using an SF Symbol on purpose:
// Apple's SF Symbols licence does not permit their use in application icons.
// This is a keyboard drawn in that general style, which is a different thing
// from the symbol itself.
//
// Everything below is resolution-independent — the drawing is done in a 1024pt
// space and scaled — so the 16pt icon is the same artwork, not a separate one.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry, in the 1024pt reference square

private let reference: CGFloat = 1024

/// macOS icons are not drawn edge to edge: the artwork sits inside a margin so
/// that it optically matches the system's own icons in the Dock and Finder.
private let bleed: CGFloat = 100

/// Corner radius of the rounded square, as macOS draws it (roughly 2/9 of the
/// body width on Big Sur and later).
private let cornerRadiusRatio: CGFloat = 2.0 / 9.0

// MARK: - Palette

/// The gradient reads as RGB lighting without being a literal rainbow: a deep
/// indigo base lifting through magenta into cyan, which is also where the app's
/// switch-friendly palette lives.
private let gradientStops: [(CGFloat, NSColor)] = [
    (0.00, NSColor(srgbRed: 0.16, green: 0.11, blue: 0.42, alpha: 1)),
    (0.45, NSColor(srgbRed: 0.55, green: 0.13, blue: 0.68, alpha: 1)),
    (0.78, NSColor(srgbRed: 0.20, green: 0.52, blue: 0.92, alpha: 1)),
    (1.00, NSColor(srgbRed: 0.14, green: 0.85, blue: 0.85, alpha: 1)),
]

// MARK: - Drawing

private func drawIcon(in context: CGContext, size: CGFloat) {
    let scale = size / reference
    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    let body = CGRect(x: bleed, y: bleed,
                      width: reference - bleed * 2,
                      height: reference - bleed * 2)
    let radius = body.width * cornerRadiusRatio
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

    // Background gradient, corner to corner so the hue travels diagonally.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let colors = gradientStops.map { $0.1.usingColorSpace(.sRGB)!.cgColor } as CFArray
    let locations = gradientStops.map { $0.0 }
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: locations) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: body.minX, y: body.maxY),
                                   end: CGPoint(x: body.maxX, y: body.minY),
                                   options: [])
    }

    // A soft highlight across the top edge, so the face is not flat.
    let highlight = CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2)
    context.saveGState()
    context.clip(to: highlight)
    if let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 1, alpha: 0.22).cgColor,
                                       NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(sheen,
                                   start: CGPoint(x: body.midX, y: body.maxY),
                                   end: CGPoint(x: body.midX, y: body.midY),
                                   options: [])
    }
    context.restoreGState()
    context.restoreGState()

    drawKeyboard(in: context, within: body)

    context.restoreGState()
}

/// A keyboard: a rounded outline with three rows of keys and a spacebar.
private func drawKeyboard(in context: CGContext, within body: CGRect) {
    let width = body.width * 0.66
    let height = width * 0.62
    let frame = CGRect(x: body.midX - width / 2,
                       y: body.midY - height / 2,
                       width: width, height: height)

    let stroke = width * 0.045
    let outerRadius = width * 0.09
    context.setStrokeColor(NSColor(white: 1, alpha: 0.96).cgColor)
    context.setLineWidth(stroke)
    context.addPath(CGPath(roundedRect: frame.insetBy(dx: stroke / 2, dy: stroke / 2),
                           cornerWidth: outerRadius, cornerHeight: outerRadius,
                           transform: nil))
    context.strokePath()

    // Key grid. Three rows of five, then a spacebar — enough to read as a
    // keyboard at 32pt without turning to mush at 16pt.
    let inset = stroke * 2.6
    let field = frame.insetBy(dx: inset, dy: inset)
    let columns = 5
    let rows = 3
    let gap = field.width * 0.045
    let keyWidth = (field.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
    // The bottom quarter of the field belongs to the spacebar.
    let keyAreaHeight = field.height * 0.70
    let keyHeight = (keyAreaHeight - gap * CGFloat(rows - 1)) / CGFloat(rows)
    let keyRadius = keyWidth * 0.22

    context.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor)
    for row in 0..<rows {
        for column in 0..<columns {
            let x = field.minX + CGFloat(column) * (keyWidth + gap)
            let y = field.maxY - keyHeight - CGFloat(row) * (keyHeight + gap)
            context.addPath(CGPath(roundedRect: CGRect(x: x, y: y,
                                                       width: keyWidth, height: keyHeight),
                                   cornerWidth: keyRadius, cornerHeight: keyRadius,
                                   transform: nil))
        }
    }
    context.fillPath()

    let spacebarHeight = keyHeight
    let spacebar = CGRect(x: field.minX + keyWidth * 0.6,
                          y: field.minY,
                          width: field.width - keyWidth * 1.2,
                          height: spacebarHeight)
    context.addPath(CGPath(roundedRect: spacebar,
                           cornerWidth: keyRadius, cornerHeight: keyRadius, transform: nil))
    context.fillPath()
}

// MARK: - Output

private func writePNG(size: Int, to url: URL) throws {
    let pixels = size
    guard let context = CGContext(data: nil,
                                  width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError.contextFailed(size)
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    drawIcon(in: context, size: CGFloat(pixels))

    guard let image = context.makeImage() else { throw IconError.imageFailed(size) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw IconError.encodeFailed(size)
    }
    try data.write(to: url)
}

enum IconError: Error, CustomStringConvertible {
    case usage
    case contextFailed(Int)
    case imageFailed(Int)
    case encodeFailed(Int)

    var description: String {
        switch self {
        case .usage:
            return "usage: swift Scripts/make-icon.swift <output.iconset directory>"
        case .contextFailed(let size): return "could not create a \(size)px bitmap context"
        case .imageFailed(let size):   return "could not render the \(size)px image"
        case .encodeFailed(let size):  return "could not encode the \(size)px PNG"
        }
    }
}

/// The names `iconutil` expects inside an `.iconset` directory.
private let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else { throw IconError.usage }
    let directory = URL(fileURLWithPath: arguments[1])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for variant in variants {
        try writePNG(size: variant.pixels, to: directory.appendingPathComponent(variant.name))
    }
    print("wrote \(variants.count) PNGs to \(directory.path)")
} catch {
    FileHandle.standardError.write("make-icon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
