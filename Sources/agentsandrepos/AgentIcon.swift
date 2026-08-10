import AgentsAndReposCore
import AppKit

/// The app's own "agent" glyph — a small robot head drawn in code (no asset
/// catalog) — doubling as brand mark and state indicator:
///   idle      even eyes, nothing else
///   busy      uneven eyes (left half-height), echoing the tiles' activity bars
///   waiting   pause badge
///   error     dead × eyes — something is broken (fetch/status/CI)
/// All variants are template images so the menu bar recolors them.
@MainActor
enum AgentIcon {
    static let idle = make(.idle, description: AppInfo.displayName)
    static let busy = make(.busy, description: "Agents busy")
    static let waiting = make(.waiting, description: "Agents waiting")
    static let error = make(.error, description: "Repo or PR errors")

    private enum Variant { case idle, busy, waiting, error }

    // Canvas is 18×17pt; the badge circle sits over the bottom-right corner.
    private static let canvas = NSRect(x: 0, y: 0, width: 18, height: 17)
    private static let badgeCenter = NSPoint(x: 15.3, y: 2.7)
    private static let badgeRadius: CGFloat = 3.9

    private static func make(_ variant: Variant, description: String) -> NSImage {
        let image = NSImage(size: canvas.size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let hasBadge = variant == .waiting
            NSGraphicsContext.current?.saveGraphicsState()
            if hasBadge {
                // Clip the head drawing to everything *outside* the badge
                // circle, leaving a gap ring around the badge glyph. Clipping
                // (not destination-out) because the drawing handler renders
                // straight into the destination context.
                let clip = NSBezierPath(rect: canvas)
                clip.append(NSBezierPath(ovalIn: badgeRect(badgeRadius)))
                clip.windingRule = .evenOdd
                clip.addClip()
            }
            drawHead(variant)
            NSGraphicsContext.current?.restoreGraphicsState()

            if variant == .waiting {
                for x: CGFloat in [13.6, 15.6] {
                    NSBezierPath(
                        roundedRect: NSRect(x: x, y: 1.0, width: 1.3, height: 3.3),
                        xRadius: 0.65, yRadius: 0.65
                    ).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private static func drawHead(_ variant: Variant) {
        // Antenna
        NSBezierPath(ovalIn: NSRect(x: 7.9, y: 13.9, width: 2.2, height: 2.2)).fill()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 9, y: 14.0))
        stem.line(to: NSPoint(x: 9, y: 12.0))
        stem.lineWidth = 1.4
        stem.stroke()

        let outline = NSBezierPath(
            roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 10.8).insetBy(dx: 0.75, dy: 0.75),
            xRadius: 2.6, yRadius: 2.6)
        outline.lineWidth = 1.5
        outline.stroke()

        // Eyes sit above the head's vertical center, bottom-aligned so the
        // busy variant's short left eye reads like the tiles' activity bars.
        // The error variant swaps them for dead × eyes.
        let eyeCenters: [CGFloat] = [6.6, 11.4]
        if variant == .error {
            let cross = NSBezierPath()
            let r: CGFloat = 1.5
            for cx in eyeCenters {
                let c = NSPoint(x: cx, y: 7.2)
                cross.move(to: NSPoint(x: c.x - r, y: c.y - r))
                cross.line(to: NSPoint(x: c.x + r, y: c.y + r))
                cross.move(to: NSPoint(x: c.x - r, y: c.y + r))
                cross.line(to: NSPoint(x: c.x + r, y: c.y - r))
            }
            cross.lineWidth = 1.4
            cross.lineCapStyle = .round
            cross.stroke()
        } else {
            let leftHeight: CGFloat = variant == .busy ? 2.4 : 4.4
            for (cx, height) in zip(eyeCenters, [leftHeight, 4.4]) {
                NSBezierPath(
                    roundedRect: NSRect(x: cx - 1.1, y: 5.0, width: 2.2, height: height),
                    xRadius: 1.1, yRadius: 1.1
                ).fill()
            }
        }
    }

    private static func badgeRect(_ radius: CGFloat) -> NSRect {
        NSRect(
            x: badgeCenter.x - radius, y: badgeCenter.y - radius,
            width: radius * 2, height: radius * 2)
    }
}
