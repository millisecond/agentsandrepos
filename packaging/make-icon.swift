#!/usr/bin/swift
// Renders AppIcon.icns for the release bundle — the same code-drawn robot
// head the menu bar uses (Sources/agentsandrepos/AgentIcon.swift, idle
// variant), white on an indigo gradient squircle. Generated at build time by
// make-app.sh so no binary asset lives in the repo.
//
//   swift packaging/make-icon.swift <output.icns>
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

// MARK: - Drawing (all coordinates in a 1024×1024 y-up space)

func draw1024() {
    // Apple's icon grid: the squircle occupies 824pt of the 1024 canvas
    // with ~185pt corner radius; the rest is transparent margin.
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
    NSGradient(
        starting: NSColor(srgbRed: 0.243, green: 0.231, blue: 0.663, alpha: 1),  // indigo-800
        ending: NSColor(srgbRed: 0.451, green: 0.451, blue: 0.941, alpha: 1)  // indigo-500
    )!.draw(in: squircle, angle: 90)

    // Robot head, scaled up from AgentIcon's 18×17 canvas and centered on
    // the plate (nudged down half a grid unit: the antenna makes the art
    // top-heavy, and true centering reads as floating too high).
    let s: CGFloat = 31.0
    let art = NSSize(width: 18 * s, height: 17 * s)
    let transform = NSAffineTransform()
    transform.translateX(
        by: (1024 - art.width) / 2, yBy: (1024 - art.height) / 2 - s * 0.5)
    transform.scale(by: s)
    NSGraphicsContext.current?.saveGraphicsState()
    transform.concat()

    NSColor.white.setFill()
    NSColor.white.setStroke()

    // Antenna
    NSBezierPath(ovalIn: NSRect(x: 7.9, y: 13.9, width: 2.2, height: 2.2)).fill()
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 9, y: 14.0))
    stem.line(to: NSPoint(x: 9, y: 12.0))
    stem.lineWidth = 1.4
    stem.stroke()

    // Head outline
    let outline = NSBezierPath(
        roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 10.8).insetBy(dx: 0.75, dy: 0.75),
        xRadius: 2.6, yRadius: 2.6)
    outline.lineWidth = 1.5
    outline.stroke()

    // Idle eyes: two even pills
    for cx: CGFloat in [6.6, 11.4] {
        NSBezierPath(
            roundedRect: NSRect(x: cx - 1.1, y: 5.0, width: 2.2, height: 4.4),
            xRadius: 1.1, yRadius: 1.1
        ).fill()
    }

    NSGraphicsContext.current?.restoreGraphicsState()
}

// MARK: - Rasterize each iconset size

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    draw1024()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(pixels: Int, name: String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("agentsandrepos-\(ProcessInfo.processInfo.globallyUniqueString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for (pixels, name) in sizes {
    try renderPNG(pixels: pixels).write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
