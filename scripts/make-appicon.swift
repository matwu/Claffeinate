// Generates macOS AppIcon PNGs from a square source image.
// Applies the standard macOS rounded-rect mask (~80.5% content with margin,
// corner radius ~22.37% of the content) so the icon reads as native in Finder.
//
//   swift scripts/make-appicon.swift <source.png> <AppIcon.appiconset dir>
//
// Note: this uses a circular-corner rounded rect (close to, but not exactly,
// Apple's continuous "squircle"). For a pixel-perfect squircle + light/dark/
// tinted variants, route the artwork through Icon Composer instead.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make-appicon.swift <source.png> <out dir>\n".data(using: .utf8)!)
    exit(2)
}
let srcPath = args[1]
let outDir = args[2]

guard let src = NSImage(contentsOfFile: srcPath) else {
    FileHandle.standardError.write("error: cannot load \(srcPath)\n".data(using: .utf8)!)
    exit(1)
}

// (filename, pixel size) — covers every entry in the appiconset Contents.json.
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let contentRatio: CGFloat = 0.8047   // macOS Big Sur+ icon grid
let cornerRatio: CGFloat = 0.2237    // corner radius / content side

for (name, side) in specs {
    let s = CGFloat(side)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { continue }
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.interpolationQuality = .high

    let content = s * contentRatio
    let offset = (s - content) / 2
    let radius = content * cornerRatio
    let rect = NSRect(x: offset, y: offset, width: content, height: content)
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    src.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! data.write(to: url)
    print("wrote \(name) (\(side)px)")
}
