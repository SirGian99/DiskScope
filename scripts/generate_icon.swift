#!/usr/bin/env swift
//
// Generates DiskScope's app icon at every size the .iconset needs, drawing the
// artwork with Core Graphics so it stays crisp at each pixel size (no scaling).
// Fully local — no assets or network. Run via `make icon`.
//
// The mark echoes the app itself: teal "size heat" bars (largest/brightest at
// the top) on the dark UI background, inside the standard macOS rounded tile.
//
import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

/// Draw the icon into a CG context whose coordinate space is `size` × `size`
/// (origin bottom-left, per AppKit).
func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let s = size

    // Standard macOS icon grid: rounded tile inset from the canvas edges.
    let inset = s * 0.092
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Background gradient (dark teal slate, matching the app window).
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [color(19, 58, 68), color(9, 24, 30)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.minY), options: [])

    // Soft teal sheen from the top-left corner.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [color(90, 200, 225, 0.32), color(90, 200, 225, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen,
                           startCenter: CGPoint(x: tile.minX + tile.width * 0.28, y: tile.maxY - tile.height * 0.2),
                           startRadius: 0,
                           endCenter: CGPoint(x: tile.minX + tile.width * 0.28, y: tile.maxY - tile.height * 0.2),
                           endRadius: tile.width * 0.75, options: [])

    // The "size heat" bars: largest & brightest on top, fading down.
    let pad = tile.width * 0.17
    let contentX = tile.minX + pad
    let contentW = tile.width - 2 * pad
    let contentTopY = tile.maxY - pad
    let contentH = tile.height - 2 * pad

    let count = 5
    let barH = contentH * 0.125
    let gap = (contentH - CGFloat(count) * barH) / CGFloat(count - 1)
    let widths: [CGFloat] = [1.0, 0.80, 0.60, 0.44, 0.30]
    let heat: [(CGFloat, CGFloat, CGFloat)] = [
        (111, 227, 247), (78, 196, 220), (60, 156, 180), (52, 118, 138), (46, 88, 104)
    ]

    for i in 0..<count {
        let y = contentTopY - barH - CGFloat(i) * (barH + gap)
        let w = contentW * widths[i]
        let rect = CGRect(x: contentX, y: y, width: w, height: barH)
        let path = CGPath(roundedRect: rect, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        let (r, g, b) = heat[i]

        ctx.saveGState()
        if i < 2 {   // glow on the brightest bars
            ctx.setShadow(offset: .zero, blur: s * 0.03, color: color(r, g, b, 0.65))
        }
        ctx.addPath(path)
        ctx.setFillColor(color(r, g, b))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.restoreGState()

    // Subtle top highlight around the tile for a glassy edge.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(255, 255, 255, 0.10))
    ctx.setLineWidth(max(1, s * 0.005))
    ctx.strokePath()
    ctx.restoreGState()
}

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    drawIcon(gctx.cgContext, size: CGFloat(pixels))
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// iconset filename -> pixel dimension
let targets: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var cache: [Int: Data] = [:]
for (name, px) in targets {
    let data: Data
    if let cached = cache[px] {
        data = cached
    } else {
        data = render(pixels: px).representation(using: .png, properties: [:])!
        cache[px] = data
    }
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
print("Wrote \(targets.count) images to \(outDir)")
