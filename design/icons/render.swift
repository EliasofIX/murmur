import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Marks live in a 24×24 box, y-down. One weight throughout: 2.15.
// Drawn small in a white field so the icon stays mostly white.

let inkWidth: CGFloat = 2.15

struct Mark {
    let name: String
    let caption: String
    let file: String
    let draw: (CGContext) -> Void
    let svg: String
}

func bar(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: inkWidth, height: h)
}

let syllableSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#000">
  <rect x="6.275" y="7.55" width="2.15" height="8.9" rx="1.075"/>
  <rect x="10.925" y="4.7" width="2.15" height="14.6" rx="1.075"/>
  <rect x="15.575" y="7.55" width="2.15" height="8.9" rx="1.075"/>
</svg>
"""

// A raised cosine: flat line, one quiet lift, flat line. Zero slope where it joins.
func sentencePoints() -> [CGPoint] {
    let base: CGFloat = 13.85
    let amp: CGFloat = 4.35
    let x0: CGFloat = 4.7
    let x1: CGFloat = 19.3
    var pts = [CGPoint(x: 2.55, y: base), CGPoint(x: x0, y: base)]
    let steps = 64
    for i in 1..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = x0 + (x1 - x0) * t
        let y = base - amp * (1 - cos(2 * .pi * t)) / 2
        pts.append(CGPoint(x: x, y: y))
    }
    pts.append(CGPoint(x: x1, y: base))
    pts.append(CGPoint(x: 21.45, y: base))
    return pts
}

func sentencePath(_ c: CGContext) {
    let pts = sentencePoints()
    c.move(to: pts[0])
    for p in pts.dropFirst() { c.addLine(to: p) }
}

let sentenceSVG: String = {
    let d = sentencePoints().enumerated().map { i, p in
        String(format: "%@%.2f %.2f", i == 0 ? "M" : "L", p.x, p.y)
    }.joined(separator: " ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none">
      <path d="\(d)" stroke="#000" stroke-width="2.15" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
    """
}()

// Circular arc, opening to the right. Same stroke, similar height to the bars.
func asidePoints() -> [CGPoint] {
    let cx: CGFloat = 16.06
    let r: CGFloat = 6.7
    let a = 78 * CGFloat.pi / 180
    let steps = 48
    return (0...steps).map { i in
        let theta = -a + 2 * a * CGFloat(i) / CGFloat(steps)
        return CGPoint(x: cx - r * cos(theta), y: 12 + r * sin(theta))
    }
}

let asideSVG: String = {
    let d = asidePoints().enumerated().map { i, p in
        String(format: "%@%.2f %.2f", i == 0 ? "M" : "L", p.x, p.y)
    }.joined(separator: " ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none">
      <path d="\(d)" stroke="#000" stroke-width="2.15" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
    """
}()

let pauseSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#000">
  <circle cx="6.55" cy="12" r="1.28"/>
  <rect x="10.925" y="5.35" width="2.15" height="13.3" rx="1.075"/>
  <circle cx="17.45" cy="12" r="1.28"/>
</svg>
"""

func strokeCommon(_ c: CGContext) {
    c.setLineWidth(inkWidth)
    c.setLineCap(.round)
    c.setLineJoin(.round)
}

let marks: [Mark] = [
    Mark(name: "Syllable", caption: "The listening pill, reduced to three bars", file: "syllable", draw: { c in
        strokeCommon(c)
        c.addPath(CGPath(roundedRect: bar(6.275, 7.55, 8.9), cornerWidth: 1.075, cornerHeight: 1.075, transform: nil))
        c.addPath(CGPath(roundedRect: bar(10.925, 4.7, 14.6), cornerWidth: 1.075, cornerHeight: 1.075, transform: nil))
        c.addPath(CGPath(roundedRect: bar(15.575, 7.55, 8.9), cornerWidth: 1.075, cornerHeight: 1.075, transform: nil))
        c.fillPath()
    }, svg: syllableSVG),
    Mark(name: "Sentence", caption: "One spoken lift in a line of text", file: "sentence", draw: { c in
        strokeCommon(c)
        sentencePath(c)
        c.strokePath()
    }, svg: sentenceSVG),
    Mark(name: "Aside", caption: "Speech, set in parentheses", file: "aside", draw: { c in
        strokeCommon(c)
        let pts = asidePoints()
        c.move(to: pts[0])
        for p in pts.dropFirst() { c.addLine(to: p) }
        c.strokePath()
    }, svg: asideSVG),
    Mark(name: "Pause", caption: "A voice in the middle of a pause", file: "pause", draw: { c in
        strokeCommon(c)
        c.addEllipse(in: CGRect(x: 6.55 - 1.28, y: 12 - 1.28, width: 2.56, height: 2.56))
        c.addPath(CGPath(roundedRect: bar(10.925, 5.35, 13.3), cornerWidth: 1.075, cornerHeight: 1.075, transform: nil))
        c.addEllipse(in: CGRect(x: 17.45 - 1.28, y: 12 - 1.28, width: 2.56, height: 2.56))
        c.fillPath()
    }, svg: pauseSVG),
]

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func paint(_ mark: Mark, color cg: CGColor, in rect: CGRect, _ ctx: CGContext) {
    ctx.saveGState()
    ctx.setFillColor(cg)
    ctx.setStrokeColor(cg)
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.scaleBy(x: rect.width / 24, y: rect.height / 24)
    ctx.translateBy(x: -12, y: -12)
    mark.draw(ctx)
    ctx.restoreGState()
}

func drawText(_ string: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor, ctx: CGContext) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    ctx.saveGState()
    ctx.translateBy(x: x - width / 2, y: y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = CGPoint(x: 0, y: -ascent)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("png failed \(url)") }
}

let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let page = color(0xF5F5F3).cgColor
let band = color(0x0C0C0C).cgColor
let black = color(0x111111)
let white = color(0xFFFFFF)
let mute = color(0x8A8A86)

let W = 2160
let H = 1320
let ctx = makeContext(W, H)
ctx.setFillColor(page)
ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))

let bandY: CGFloat = 900
ctx.setFillColor(band)
ctx.fill(CGRect(x: 0, y: bandY, width: CGFloat(W), height: CGFloat(H) - bandY))

let nameFont = NSFont.systemFont(ofSize: 28, weight: .medium)
let captionFont = NSFont.systemFont(ofSize: 18, weight: .regular)
let kickerFont = NSFont.systemFont(ofSize: 15, weight: .medium)

let colW = CGFloat(W) / 4
for (i, mark) in marks.enumerated() {
    let cx = colW * (CGFloat(i) + 0.5)
    paint(mark, color: black.cgColor, in: CGRect(x: cx - 150, y: 150, width: 300, height: 300), ctx)
    drawText(mark.name, x: cx, y: 520, font: nameFont, color: black, ctx: ctx)
    drawText(mark.caption, x: cx, y: 568, font: captionFont, color: mute, ctx: ctx)
    paint(mark, color: white.cgColor, in: CGRect(x: cx - 92, y: bandY + 70, width: 184, height: 184), ctx)
}

func drawTextLeft(_ string: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor, ctx: CGContext) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
    var ascent: CGFloat = 0
    CTLineGetTypographicBounds(line, &ascent, nil, nil)
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = CGPoint(x: 0, y: -ascent)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

drawTextLeft("BLACK ON WHITE", x: 72, y: 64, font: kickerFont, color: mute, ctx: ctx)
drawTextLeft("WHITE ON BLACK", x: 72, y: bandY + 36, font: kickerFont, color: color(0x8A8A86), ctx: ctx)

writePNG(ctx.makeImage()!, to: out.appendingPathComponent("sheet.png"))

// Individual tiles: mostly white, mark centered. Plus the reversed tile.
for mark in marks {
    let tile = makeContext(1200, 1200)
    tile.setFillColor(white.cgColor)
    tile.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
    paint(mark, color: black.cgColor, in: CGRect(x: 300, y: 300, width: 600, height: 600), tile)
    writePNG(tile.makeImage()!, to: out.appendingPathComponent("\(mark.file).png"))

    let rev = makeContext(1200, 1200)
    rev.setFillColor(band)
    rev.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
    paint(mark, color: white.cgColor, in: CGRect(x: 300, y: 300, width: 600, height: 600), rev)
    writePNG(rev.makeImage()!, to: out.appendingPathComponent("\(mark.file)-white.png"))

    try mark.svg.write(to: out.appendingPathComponent("\(mark.file).svg"), atomically: true, encoding: .utf8)
}

// Menu-bar proof: 18pt template blown up 12× with a 1px grid, so the small size is honest.
let proof = makeContext(1400, 420)
proof.setFillColor(white.cgColor)
proof.fill(CGRect(x: 0, y: 0, width: 1400, height: 420))
for (i, mark) in marks.enumerated() {
    let origin = CGPoint(x: 70 + CGFloat(i) * 340, y: 80)
    let cell: CGFloat = 18 * 12
    proof.setFillColor(color(0xF3F3F1).cgColor)
    proof.fill(CGRect(x: origin.x, y: origin.y, width: cell, height: cell))
    // pixel grid
    proof.setStrokeColor(color(0xE4E4E0).cgColor)
    proof.setLineWidth(1)
    for g in 0...18 {
        let p = origin.x + CGFloat(g) * 12
        proof.move(to: CGPoint(x: p, y: origin.y))
        proof.addLine(to: CGPoint(x: p, y: origin.y + cell))
        let q = origin.y + CGFloat(g) * 12
        proof.move(to: CGPoint(x: origin.x, y: q))
        proof.addLine(to: CGPoint(x: origin.x + cell, y: q))
    }
    proof.strokePath()
    paint(mark, color: black.cgColor, in: CGRect(x: origin.x, y: origin.y, width: cell, height: cell), proof)
}
writePNG(proof.makeImage()!, to: out.appendingPathComponent("menubar-proof.png"))

print("wrote \(out.path)")
