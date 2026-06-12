// Renders several background options for the Budgie app icon (same bird every
// time) and writes an icon-previews/index.html contact sheet to compare them.
// Run:  swift tools/make-icon-variants.swift  then open icon-previews/index.html
import AppKit
import Foundation

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
let charcoal = c(0.15, 0.14, 0.13)
let cream    = c(0.98, 0.96, 0.88)

struct Variant { let name: String; let label: String; let top: NSColor; let bottom: NSColor; let bird: NSColor }
let variants = [
    Variant(name: "yellow",       label: "Budgie yellow (charcoal bird)", top: c(1.00,0.97,0.86), bottom: c(0.98,0.86,0.48), bird: charcoal),
    Variant(name: "pink",         label: "Bubblegum pink (charcoal bird)", top: c(1.00,0.86,0.93), bottom: c(0.99,0.58,0.79), bird: charcoal),
    Variant(name: "pink-cream",   label: "Bubblegum pink (cream bird)", top: c(1.00,0.86,0.93), bottom: c(0.99,0.58,0.79), bird: cream),
    Variant(name: "fuchsia",      label: "Fuchsia (cream bird)", top: c(0.99,0.50,0.82), bottom: c(0.84,0.16,0.60), bird: cream),
    Variant(name: "lavender",     label: "Lavender / light purple (charcoal bird)", top: c(0.88,0.82,0.99), bottom: c(0.66,0.54,0.94), bird: charcoal),
    Variant(name: "lavender-cream", label: "Lavender / light purple (cream bird)", top: c(0.88,0.82,0.99), bottom: c(0.66,0.54,0.94), bird: cream),
    Variant(name: "purple",       label: "Purple (cream bird)", top: c(0.74,0.56,0.96), bottom: c(0.50,0.30,0.83), bird: cream),
]

func drawBird(scale s: CGFloat, tx: CGFloat, ty: CGFloat, color: NSColor) {
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x*s+tx, y: y*s+ty) }
    func tri(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> NSBezierPath {
        let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.line(to: c); p.close(); return p
    }
    func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x*s+tx, y: y*s+ty, width: w*s, height: h*s))
    }
    color.setFill()
    oval(5.3, 2.7, 8.8, 9.2).fill()
    oval(3.5, 8.5, 6.6, 6.6).fill()
    tri(P(4.3, 13.0), P(1.5, 11.0), P(4.3, 10.6)).fill()
    tri(P(11.0, 8.0), P(12.6, 4.0), P(17.2, 1.4)).fill()
}

func render(px: Int, v: Variant) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let size = CGFloat(px), margin = CGFloat(px) * 0.098, body = size - 2*margin
    let bg = NSRect(x: margin, y: margin, width: body, height: body)
    NSBezierPath(roundedRect: bg, xRadius: body*0.2237, yRadius: body*0.2237).addClip()
    NSGradient(starting: v.bottom, ending: v.top)!.draw(in: bg, angle: 90)
    let minX: CGFloat = 1.5, minY: CGFloat = 1.4, maxX: CGFloat = 17.2, maxY: CGFloat = 15.1
    let scale = 0.60 * body / max(maxX-minX, maxY-minY)
    drawBird(scale: scale, tx: size/2 - (minX+maxX)/2*scale, ty: size/2 - (minY+maxY)/2*scale, color: v.bird)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = "icon-previews"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for v in variants {
    for px in [512, 128, 64, 32] {
        try! render(px: px, v: v).write(to: URL(fileURLWithPath: "\(out)/\(v.name)-\(px).png"))
    }
}

var cards = ""
for v in variants {
    cards += """
    <section class="card">
      <h2>\(v.label)</h2>
      <div class="rows">
        <div class="panel light"><img src="\(v.name)-512.png" width="180" height="180"></div>
        <div class="panel dark"><img src="\(v.name)-512.png" width="180" height="180"></div>
        <div class="panel sizes">
          <img src="\(v.name)-128.png" width="128" height="128">
          <img src="\(v.name)-64.png" width="64" height="64">
          <img src="\(v.name)-32.png" width="32" height="32">
        </div>
      </div>
    </section>\n
    """
}
let html = """
<!doctype html><meta charset="utf-8"><title>Budgie icon options</title>
<style>
  body{font:15px -apple-system,system-ui,sans-serif;margin:32px;background:#fafafa;color:#222}
  h1{font-size:22px} h2{font-size:15px;font-weight:600;margin:0 0 12px}
  .card{background:#fff;border:1px solid #e3e3e3;border-radius:14px;padding:20px;margin:16px 0;max-width:760px}
  .rows{display:flex;gap:16px;align-items:center;flex-wrap:wrap}
  .panel{border-radius:12px;padding:18px;display:flex;gap:14px;align-items:flex-end}
  .light{background:#f2f2f2} .dark{background:#1d1d1f}
  .sizes{background:#f2f2f2}
  img{display:block}
</style>
<h1>Budgie app icon — background options</h1>
<p>Same bird every time. Left = light Finder/Dock, middle = dark mode, right = small sizes (128 / 64 / 32 px).</p>
\(cards)
"""
try! html.write(to: URL(fileURLWithPath: "\(out)/index.html"), atomically: true, encoding: .utf8)
print("Wrote \(variants.count) variants + index.html to \(out)/")
