// Draws the disk image window: a dusty floor with one freshly vacuumed lane. Regenerate with:
//   swift scripts/make-dmg-background.swift Resources
import AppKit

let W: CGFloat = 660, H: CGFloat = 420
let appC = CGPoint(x: 170, y: 214), appsC = CGPoint(x: 490, y: 214)   // keep in sync with release.sh

struct RNG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

func draw(scale: CGFloat, to path: String, preview: Bool = false) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: gc.cgContext, flipped: true)
    let c = gc.cgContext
    c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)   // top-left origin, like Finder's icon positions
    var rng = RNG(s: 0x9E3779B97F4A7C15)
    func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &rng) }

    // Oak planks: light enough for Finder's black icon labels.
    let plankH: CGFloat = 60
    var y: CGFloat = -8, row = 0
    while y < H {
        var x: CGFloat = row % 2 == 0 ? -r(40, 120) : -r(150, 260)
        while x < W {
            let w = r(210, 340), t = r(-0.018, 0.018)
            let rect = CGRect(x: x, y: y, width: w, height: plankH)
            color(0.895 + t, 0.775 + t, 0.60 + t).setFill(); rect.fill()
            for _ in 0..<7 {   // grain
                let gy = y + r(4, plankH - 4)
                c.setStrokeColor(color(0.55, 0.38, 0.2, r(0.025, 0.07)).cgColor); c.setLineWidth(r(0.5, 1.1))
                c.move(to: CGPoint(x: x, y: gy))
                c.addCurve(to: CGPoint(x: x + w, y: gy + r(-3, 3)), control1: CGPoint(x: x + w * 0.3, y: gy + r(-4, 4)), control2: CGPoint(x: x + w * 0.7, y: gy + r(-4, 4)))
                c.strokePath()
            }
            c.setFillColor(color(0.42, 0.28, 0.15, 0.32).cgColor); c.fill(CGRect(x: x + w - 0.7, y: y, width: 0.7, height: plankH))
            x += w
        }
        c.setFillColor(color(0.42, 0.28, 0.15, 0.32).cgColor); c.fill(CGRect(x: 0, y: y + plankH - 0.7, width: W, height: 0.7))
        y += plankH; row += 1
    }

    // Keep the mess out of the lane, the icons, their labels and the text.
    let laneTop = appC.y - 62, laneBottom = appC.y + 62
    func busy(_ x: CGFloat, _ y: CGFloat) -> Bool {
        if y < 112 { return true }
        if y > laneTop - 6 && y < laneBottom + 6 && x > appC.x - 20 && x < appsC.x + 20 { return true }
        for ic in [appC, appsC] where abs(x - ic.x) < 94 && y > ic.y - 86 && y < ic.y + 112 { return true }
        return false
    }

    // Fine dust everywhere else.
    for _ in 0..<520 {
        let x = r(0, W), y = r(0, H), d = r(0.7, 2.6)
        if busy(x, y) { continue }
        c.setFillColor(color(0.36, 0.32, 0.28, r(0.16, 0.42)).cgColor)
        c.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d))
    }

    // Stray desktop junk, the kind the robot is here to eat.
    func paper(_ p: CGPoint, _ s: CGFloat, _ a: CGFloat) {
        c.saveGState(); c.translateBy(x: p.x, y: p.y); c.rotate(by: a)
        c.setShadow(offset: CGSize(width: 1, height: 2), blur: 3, color: NSColor(white: 0, alpha: 0.28).cgColor)
        c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: -s * 0.4, y: -s * 0.5, width: s * 0.8, height: s))
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(NSColor(white: 0.74, alpha: 1).cgColor)
        for i in 0..<4 { c.fill(CGRect(x: -s * 0.28, y: -s * 0.32 + CGFloat(i) * s * 0.18, width: s * (i == 3 ? 0.3 : 0.56), height: s * 0.055)) }
        c.restoreGState()
    }
    func folder(_ p: CGPoint, _ s: CGFloat, _ a: CGFloat) {
        c.saveGState(); c.translateBy(x: p.x, y: p.y); c.rotate(by: a)
        c.setShadow(offset: CGSize(width: 1, height: 2), blur: 3, color: NSColor(white: 0, alpha: 0.28).cgColor)
        c.setFillColor(color(0.36, 0.68, 0.96).cgColor)
        c.addPath(CGPath(roundedRect: CGRect(x: -s * 0.5, y: -s * 0.38, width: s * 0.45, height: s * 0.3), cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)); c.fillPath()
        c.addPath(CGPath(roundedRect: CGRect(x: -s * 0.5, y: -s * 0.28, width: s, height: s * 0.66), cornerWidth: s * 0.07, cornerHeight: s * 0.07, transform: nil)); c.fillPath()
        c.restoreGState()
    }
    func photo(_ p: CGPoint, _ s: CGFloat, _ a: CGFloat, _ tint: NSColor) {
        c.saveGState(); c.translateBy(x: p.x, y: p.y); c.rotate(by: a)
        c.setShadow(offset: CGSize(width: 1, height: 2), blur: 3, color: NSColor(white: 0, alpha: 0.28).cgColor)
        c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: -s * 0.55, y: -s * 0.42, width: s * 1.1, height: s * 0.84))
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(tint.cgColor); c.fill(CGRect(x: -s * 0.47, y: -s * 0.34, width: s * 0.94, height: s * 0.68))
        c.restoreGState()
    }
    paper(CGPoint(x: 42, y: 150), 34, -0.32)
    photo(CGPoint(x: 48, y: 358), 36, 0.2, color(0.95, 0.58, 0.45))
    folder(CGPoint(x: 330, y: 352), 34, -0.13)
    paper(CGPoint(x: 268, y: 378), 30, 0.28)
    photo(CGPoint(x: 400, y: 374), 32, -0.24, color(0.48, 0.78, 0.68))
    paper(CGPoint(x: 618, y: 138), 32, 0.26)
    folder(CGPoint(x: 616, y: 372), 32, 0.2)

    // The vacuumed lane: alternating nap, soft edges, tiny crumbs pushed up along its sides.
    c.saveGState()
    let lane = CGRect(x: appC.x, y: laneTop, width: appsC.x - appC.x, height: laneBottom - laneTop)
    c.addPath(CGPath(roundedRect: lane, cornerWidth: 26, cornerHeight: 26, transform: nil)); c.clip()
    color(1, 0.96, 0.87, 0.5).setFill(); lane.fill()
    let stripes = 6, sh = lane.height / CGFloat(stripes)
    for i in 0..<stripes where i % 2 == 0 {
        c.setFillColor(NSColor(white: 1, alpha: 0.2).cgColor)
        c.fill(CGRect(x: lane.minX, y: lane.minY + CGFloat(i) * sh, width: lane.width, height: sh))
    }
    c.restoreGState()
    for x in stride(from: appC.x + 66, to: appsC.x - 66, by: 3.4) {
        for edge in [laneTop - 3, laneBottom + 3] {
            c.setFillColor(color(0.34, 0.3, 0.26, r(0.25, 0.55)).cgColor)
            let d = r(0.8, 2.3)
            c.fillEllipse(in: CGRect(x: x + r(-1.5, 1.5), y: edge + r(-3.5, 3.5), width: d, height: d))
        }
    }

    // Chevrons, getting stronger towards the dock.
    let accent = color(0.03, 0.47, 0.70)
    for (i, x) in [CGFloat(292), 326, 360].enumerated() {
        c.setStrokeColor(accent.withAlphaComponent(0.42 + CGFloat(i) * 0.27).cgColor)
        c.setLineWidth(7); c.setLineCap(.round); c.setLineJoin(.round)
        c.move(to: CGPoint(x: x - 8, y: appC.y - 18)); c.addLine(to: CGPoint(x: x + 8, y: appC.y)); c.addLine(to: CGPoint(x: x - 8, y: appC.y + 18))
        c.strokePath()
    }

    // The landing spot: a charging pad under the Applications folder.
    let pad = CGRect(x: appsC.x - 72, y: appsC.y - 74, width: 144, height: 136)
    c.setFillColor(color(1, 1, 1, 0.42).cgColor)
    c.addPath(CGPath(roundedRect: pad, cornerWidth: 28, cornerHeight: 28, transform: nil)); c.fillPath()
    c.setStrokeColor(accent.cgColor); c.setLineWidth(2.5); c.setLineDash(phase: 0, lengths: [9, 7])
    c.addPath(CGPath(roundedRect: pad, cornerWidth: 28, cornerHeight: 28, transform: nil)); c.strokePath()
    c.setLineDash(phase: 0, lengths: [])

    // Words.
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let ink = color(0.2, 0.13, 0.07)
    NSAttributedString(string: "Drag me to Applications", attributes: [.font: NSFont.systemFont(ofSize: 29, weight: .bold), .foregroundColor: ink, .paragraphStyle: para])
        .draw(in: CGRect(x: 0, y: 38, width: W, height: 40))
    NSAttributedString(string: "Then I'll get to work on your desktop.", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: ink.withAlphaComponent(0.72), .paragraphStyle: para])
        .draw(in: CGRect(x: 0, y: 76, width: W, height: 24))

    if preview {
        // Only for reviewing the art: approximates what Finder will place on top.
        func icon(_ img: NSImage, _ p: CGPoint, _ label: String) {
            img.draw(in: CGRect(x: p.x - 64, y: p.y - 64, width: 128, height: 128), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black, .paragraphStyle: para])
                .draw(in: CGRect(x: p.x - 70, y: p.y + 70, width: 140, height: 20))
        }
        icon(NSImage(contentsOfFile: CommandLine.arguments[2])!, appC, "RoboDust")
        icon(NSWorkspace.shared.icon(forFile: "/Applications"), appsC, "Applications")
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
draw(scale: 1, to: out + "/dmg-background.png")
draw(scale: 2, to: out + "/dmg-background@2x.png")
if CommandLine.arguments.count > 2 { draw(scale: 2, to: out + "/dmg-preview.png", preview: true) }
