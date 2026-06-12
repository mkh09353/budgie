// Generates Budgie.icns from the SAME budgie silhouette drawn in the menu bar
// (see Sources/Budgie/MenuBarIcon.swift), so the app shows one bird everywhere.
// The bird is vector, so every icon size is rendered natively (crisp at 16px and
// 1024px alike). Run:  swift tools/make-icon.swift  then  iconutil -c icns ...
import AppKit
import Foundation

// --- Look (tweak these three to restyle) -----------------------------------
let bgTop    = NSColor(srgbRed: 1.00, green: 0.97, blue: 0.86, alpha: 1) // warm cream
let bgBottom = NSColor(srgbRed: 0.98, green: 0.86, blue: 0.48, alpha: 1) // soft budgie yellow
let birdCol  = NSColor(srgbRed: 0.15, green: 0.14, blue: 0.13, alpha: 1) // charcoal silhouette

// The budgie silhouette, identical geometry to MenuBarIcon.budgie, mapped from
// its 18-unit design canvas onto the icon via p' = p*scale + (tx,ty).
func drawBird(scale s: CGFloat, tx: CGFloat, ty: CGFloat) {
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x*s+tx, y: y*s+ty) }
    func tri(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> NSBezierPath {
        let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.line(to: c); p.close(); return p
    }
    func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x*s+tx, y: y*s+ty, width: w*s, height: h*s))
    }
    birdCol.setFill()
    oval(5.3, 2.7, 8.8, 9.2).fill()   // plump body
    oval(3.5, 8.5, 6.6, 6.6).fill()   // round head
    tri(P(4.3, 13.0), P(1.5, 11.0), P(4.3, 10.6)).fill()  // hooked beak
    tri(P(11.0, 8.0), P(12.6, 4.0), P(17.2, 1.4)).fill()  // long swept tail
}

func renderIcon(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

    let size = CGFloat(px)
    let margin = size * 0.098                 // Big Sur icon-grid margin
    let body = size - 2 * margin
    let bgRect = NSRect(x: margin, y: margin, width: body, height: body)
    NSBezierPath(roundedRect: bgRect, xRadius: body * 0.2237, yRadius: body * 0.2237).addClip()
    NSGradient(starting: bgBottom, ending: bgTop)!.draw(in: bgRect, angle: 90)

    // Center the bird's bounding box (in 18-unit space) inside the body.
    let minX: CGFloat = 1.5, minY: CGFloat = 1.4, maxX: CGFloat = 17.2, maxY: CGFloat = 15.1
    let scale = 0.60 * body / max(maxX - minX, maxY - minY)
    drawBird(scale: scale,
             tx: size/2 - (minX + maxX)/2 * scale,
             ty: size/2 - (minY + maxY)/2 * scale)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let outDir = "Budgie.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, px) in sizes {
    let data = renderIcon(px: px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("Wrote \(sizes.count) PNGs to \(outDir)/")
