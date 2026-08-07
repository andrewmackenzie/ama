#!/usr/bin/env swift
import AppKit

// Generates a macOS `.iconset` for Ama: an original mark — a cream serif "a"
// monogram on a deep ink-blue squircle with a gold writing-rule accent. The
// name nods to "amanuensis" (one who writes from dictation); the ink + gold
// evoke a scribe's page. Fully original (no third-party glyph), rendered with
// AppKit only. The Makefile turns the iconset into a `.icns` with `iconutil`.
//
// Usage: swift scripts/make-icon.swift <output.iconset dir>

func serifFont(size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .medium)
    if let d = base.fontDescriptor.withDesign(.serif),
       let f = NSFont(descriptor: d, size: size) {
        return f
    }
    return NSFont(name: "Times New Roman", size: size) ?? base
}

func renderIcon(size: Int) -> Data {
    let dim = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded-square tile (macOS icon grid inset).
    let inset = dim * 0.085
    let tile = NSRect(x: inset, y: inset, width: dim - inset * 2, height: dim - inset * 2)
    let radius = tile.width * 0.225
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    // Deep ink-blue gradient body.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.42, alpha: 1),   // slate ink
        NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.20, alpha: 1),   // deep ink
    ])!
    gradient.draw(in: tilePath, angle: -90)

    // Soft top highlight for depth.
    tilePath.setClip()
    let highlight = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.10),
        NSColor(white: 1, alpha: 0.0),
    ])!
    highlight.draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

    // Gold "writing rule" accent bar under the monogram.
    let barW = tile.width * 0.34
    let barH = max(1, tile.width * 0.045)
    let barRect = NSRect(x: tile.midX - barW / 2, y: tile.minY + tile.height * 0.225, width: barW, height: barH)
    let bar = NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2)
    NSColor(calibratedRed: 0.83, green: 0.64, blue: 0.29, alpha: 1).setFill()
    bar.fill()

    // Cream serif "a" monogram, centered above the rule.
    let cream = NSColor(calibratedRed: 0.95, green: 0.92, blue: 0.84, alpha: 1)
    let fontSize = tile.height * 0.66
    let attrs: [NSAttributedString.Key: Any] = [
        .font: serifFont(size: fontSize),
        .foregroundColor: cream,
    ]
    let glyph = NSAttributedString(string: "a", attributes: attrs)
    let gsize = glyph.size()
    let gx = tile.midX - gsize.width / 2
    let gy = tile.minY + tile.height * 0.30
    glyph.draw(at: NSPoint(x: gx, y: gy))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outPath = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset"
let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

let specs: [(name: String, pixels: Int)] = [
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

for spec in specs {
    try renderIcon(size: spec.pixels).write(to: outURL.appendingPathComponent(spec.name))
}

print("wrote \(specs.count) PNGs to \(outPath)")
