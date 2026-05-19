import AppKit

/// Renders the menu bar icon. Unlike a static glyph, the icon is a small live
/// instrument: it shows mic level while recording and animates while working,
/// so the app communicates state without the user opening the popover.
enum MenuBarIcon {
    private static let size = NSSize(width: 18, height: 18)

    /// Idle: the hand-drawn perched budgie at menu-bar size.
    static func idle() -> NSImage { budgie(size: size) }

    /// The budgie silhouette, drawn at an arbitrary size. SF Symbols ships only
    /// one generic songbird glyph, which reads as mush — so the bird is composed
    /// from a few overlapping solid shapes (round head, hooked beak, plump body,
    /// long swept tail) that the system tints as a template. Used for the menu
    /// bar, the popover header and the About panel, so the app shows one bird.
    static func budgie(size: NSSize) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            let s = rect.width / 18.0          // design canvas is 18 units
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: x * s, y: y * s)
            }
            func triangle(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> NSBezierPath {
                let p = NSBezierPath()
                p.move(to: a); p.line(to: b); p.line(to: c); p.close()
                return p
            }
            NSColor.black.setFill()

            // Plump body and round head — overlapping ovals merge into one mass.
            NSBezierPath(ovalIn: NSRect(x: 5.3 * s, y: 2.7 * s,
                                        width: 8.8 * s, height: 9.2 * s)).fill()
            NSBezierPath(ovalIn: NSRect(x: 3.5 * s, y: 8.5 * s,
                                        width: 6.6 * s, height: 6.6 * s)).fill()
            // Short hooked beak, pointing left off the head.
            triangle(pt(4.3, 13.0), pt(1.5, 11.0), pt(4.3, 10.6)).fill()
            // Long tail sweeping down to the lower-right — the budgie giveaway.
            triangle(pt(11.0, 8.0), pt(12.6, 4.0), pt(17.2, 1.4)).fill()

            return true
        }
        img.isTemplate = true
        return img
    }

    /// Error: a warning triangle (the caller tints it orange).
    static func error() -> NSImage { symbol("exclamationmark.triangle.fill") }

    /// Recording: five rounded bars whose heights track the live input level.
    static func recording(level: Float) -> NSImage {
        let lvl = CGFloat(max(0.06, min(1, level)))
        let weights: [CGFloat] = [0.45, 0.78, 1.0, 0.78, 0.45]
        let img = NSImage(size: size, flipped: false) { rect in
            let barW: CGFloat = 2.3
            let count = weights.count
            let gap = (rect.width - CGFloat(count) * barW) / CGFloat(count - 1)
            NSColor.black.setFill()
            for i in 0..<count {
                let h = 3 + (rect.height - 3) * lvl * weights[i]
                let x = CGFloat(i) * (barW + gap)
                let y = (rect.height - h) / 2
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: barW, height: h),
                    xRadius: barW / 2, yRadius: barW / 2)
                bar.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Transcribing: three dots, one enlarged per `phase` to read as motion.
    static func transcribing(phase: Int) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            let count = 3
            let base: CGFloat = 3.6
            let gap = (rect.width - CGFloat(count) * base) / CGFloat(count - 1)
            NSColor.black.setFill()
            for i in 0..<count {
                let d = (phase % count == i) ? base : base * 0.55
                let x = CGFloat(i) * (base + gap) + (base - d) / 2
                let y = (rect.height - d) / 2
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Budgie")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }
}
