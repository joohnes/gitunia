#!/usr/bin/env swift
// Renders the Gitunia app icon: the menu bar's branching arrows (SF Symbol `arrow.triangle.branch`)
// in the brand orange, semibold, on a dark graphite rounded square.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

do {
    let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Theme.brand's dark-appearance variant: the lifted orange reads better on graphite than the
    // light-mode one.
    let orange = NSColor(srgbRed: 1.00, green: 0.54, blue: 0.24, alpha: 1)

    func render(_ px: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep)
        else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }

        let s = CGFloat(px)
        // macOS icon grid: the body fills ~80% of the canvas with continuous-looking corners.
        let inset = s * 0.1
        let square = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let body = NSBezierPath(roundedRect: square, xRadius: square.width * 0.225, yRadius: square.width * 0.225)

        // Graphite, a touch lighter at the top so it doesn't read as flat black.
        NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1),
                   ending: NSColor(srgbRed: 0.13, green: 0.135, blue: 0.15, alpha: 1))?
            .draw(in: body, angle: -90)
        // Hairline rim so the icon holds its edge on a dark Dock.
        NSColor(white: 1, alpha: 0.08).setStroke()
        body.lineWidth = max(1, s * 0.004)
        body.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [orange]))
        guard let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { throw CocoaError(.fileReadNoSuchFile) }
        let size = symbol.size
        symbol.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))

        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    let entries: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in entries {
        try render(px).write(to: outDir.appendingPathComponent("\(name).png"))
    }
    print("iconset written to \(outDir.path)")
} catch {
    print(error)
    exit(1)
}
