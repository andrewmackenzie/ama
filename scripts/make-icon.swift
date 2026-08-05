#!/usr/bin/env swift
import AppKit

// Generates a macOS `.iconset` directory of PNGs for Parrot: a white Lucide
// bird on a rounded blue gradient tile. The Makefile turns the iconset into a
// `.icns` with `iconutil`. Uses only AppKit — no third-party rasterizer.
//
// Usage: swift scripts/make-icon.swift <output.iconset dir>

let birdSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" \
stroke-linecap="round" stroke-linejoin="round">\
<path d="M16 7h.01"/>\
<path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
<path d="m20 7 2 .5-2 .5"/>\
<path d="M10 18v3"/>\
<path d="M14 17.75V21"/>\
<path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
</svg>
"""

func birdImage() -> NSImage {
    let data = birdSVG.data(using: .utf8)!
    let image = NSImage(data: data)!
    image.isTemplate = true
    return image
}

/// Draw the bird tinted `color`, fit into `rect`.
func drawBird(_ base: NSImage, in rect: NSRect, color: NSColor) {
    let tinted = NSImage(size: rect.size)
    tinted.lockFocus()
    let full = NSRect(origin: .zero, size: rect.size)
    base.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    full.fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
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

    // Rounded-rect tile with a small inset (macOS icon grid convention).
    let inset = dim * 0.08
    let tile = NSRect(x: inset, y: inset, width: dim - inset * 2, height: dim - inset * 2)
    let radius = tile.width * 0.225
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.29, green: 0.56, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.35, blue: 0.86, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    let bird = birdImage()
    let birdDim = tile.width * 0.60
    let birdRect = NSRect(
        x: tile.midX - birdDim / 2,
        y: tile.midY - birdDim / 2,
        width: birdDim, height: birdDim
    )
    drawBird(bird, in: birdRect, color: .white)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Emit iconset

let outPath = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset"
let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

// (base point size, scale) -> Apple iconset filename.
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
    let data = renderIcon(size: spec.pixels)
    try data.write(to: outURL.appendingPathComponent(spec.name))
}

print("wrote \(specs.count) PNGs to \(outPath)")
