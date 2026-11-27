import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Round 2. Different silhouettes from the stroke-waveform set:
// a filled quotation mark, a letter m, a heavy open ring, the Option glyph.

let ink: CGFloat = 2.3

struct Mark {
    let name: String
    let caption: String
    let file: String
    let draw: (CGContext) -> Void
    let svg: String
}

func pts(_ pairs: [(CGFloat, CGFloat)]) -> [CGPoint] {
    pairs.map { CGPoint(x: $0.0, y: $0.1) }
}

func pathD(_ points: [CGPoint], closed: Bool = false) -> String {
    var d = points.enumerated().map { i, p in
        String(format: "%@%.2f %.2f", i == 0 ? "M" : "L", p.x, p.y)
    }.joined(separator: " ")
    if closed { d += " Z" }
    return d
}

func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, steps: Int) -> [CGPoint] {
    (0...steps).map { i in
        let t = CGFloat(i) / CGFloat(steps)
        let a = a0 + (a1 - a0) * t
        return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
    }
}

// Filled comma, one outline so the tail leaves the head without a neck.
// Drawn for a head near the top; `at` shifts it.
func commaOutline(at o: CGPoint) -> [CGPoint] {
    let raw: [(CGFloat, CGFloat)] = [
        (3.15, 1.55),
        (5.15, 1.70), (5.85, 3.15), (5.55, 4.85),
        (5.25, 6.35), (4.55, 7.15), (4.15, 8.55),
        (3.85, 9.85), (3.15, 11.05), (2.15, 11.15),
        (1.15, 11.25), (1.35, 9.85), (1.85, 8.45),
        (1.05, 7.55), (0.45, 6.15), (0.55, 4.35),
        (0.70, 2.55), (1.55, 1.35), (3.15, 1.55),
    ]
    // raw is move, then cubic triplets, then close on the first point.
    return raw.map { CGPoint(x: $0.0 + o.x, y: $0.1 + o.y) }
}

func addComma(_ c: CGContext, at o: CGPoint) {
    let p = commaOutline(at: o)
    c.move(to: p[0])
    var i = 1
    while i + 2 < p.count {
        c.addCurve(to: p[i + 2], control1: p[i], control2: p[i + 1])
        i += 3
    }
    c.closePath()
    c.fillPath()
}

func commaD(at o: CGPoint) -> String {
    let p = commaOutline(at: o)
    var d = String(format: "M%.2f %.2f", p[0].x, p[0].y)
    var i = 1
    while i + 2 < p.count {
        d += String(format: " C%.2f %.2f %.2f %.2f %.2f %.2f",
                    p[i].x, p[i].y, p[i + 1].x, p[i + 1].y, p[i + 2].x, p[i + 2].y)
        i += 3
    }
    return d + " Z"
}

func quotesSVG() -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#000">
      <path d="\(commaD(at: CGPoint(x: 4.9, y: 5.7)))"/>
      <path d="\(commaD(at: CGPoint(x: 12.8, y: 5.7)))"/>
    </svg>
    """
}

// Geometric grotesque m. Semicircular arches, three round feet.
func emPoints() -> [CGPoint] {
    let spring: CGFloat = 10.55
    let base: CGFloat = 16.15
    let r: CGFloat = 2.55
    let s: CGFloat = 6.9
    var p: [CGPoint] = [CGPoint(x: s, y: base), CGPoint(x: s, y: spring)]
    p += arc(s + r, spring, r, .pi, 2 * .pi, steps: 28)
    p += [CGPoint(x: s + 2 * r, y: base), CGPoint(x: s + 2 * r, y: spring)]
    p += arc(s + 3 * r, spring, r, .pi, 2 * .pi, steps: 28)
    p += [CGPoint(x: s + 4 * r, y: base)]
    return p
}

func emSVG() -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none">
      <path d="\(pathD(emPoints()))" stroke="#000" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
    """
}

// Heavy circle, a gap on the right. Sampled the long way around.
func gapPoints() -> [CGPoint] {
    let a0 = 18 * CGFloat.pi / 180
    let a1 = 342 * CGFloat.pi / 180
    return arc(12.35, 12, 6.7, a0, a1, steps: 80)
}

func gapSVG() -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none">
      <path d="\(pathD(gapPoints()))" stroke="#000" stroke-width="3.05" stroke-linecap="round"/>
    </svg>
    """
}

// ⌥  stem, branch, arm.
func optionPoints() -> [CGPoint] {
    [
        CGPoint(x: 6.7, y: 17.15),
        CGPoint(x: 6.7, y: 10.35),
        CGPoint(x: 11.15, y: 6.55),
        CGPoint(x: 17.7, y: 6.55),
    ]
}

func optionSVG() -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none">
      <path d="\(pathD(optionPoints()))" stroke="#000" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
    """
}

let marks: [Mark] = [
    Mark(name: "Quotes", caption: "Speech, as type", file: "quotes", draw: { c in
        addComma(c, at: CGPoint(x: 4.9, y: 5.7))
        addComma(c, at: CGPoint(x: 12.8, y: 5.7))
    }, svg: quotesSVG()),
    Mark(name: "Em", caption: "The name, as a letter", file: "em", draw: { c in
        c.setLineWidth(2.3)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        let p = emPoints()
        c.move(to: p[0])
        for q in p.dropFirst() { c.addLine(to: q) }
        c.strokePath()
    }, svg: emSVG()),
    Mark(name: "Gap", caption: "A circle, just open", file: "gap", draw: { c in
        c.setLineWidth(3.05)
        c.setLineCap(.round)
        let p = gapPoints()
        c.move(to: p[0])
        for q in p.dropFirst() { c.addLine(to: q) }
        c.strokePath()
    }, svg: gapSVG()),
    Mark(name: "Option", caption: "The key you hold", file: "option", draw: { c in
        c.setLineWidth(2.3)
        c.setLineCap(.round)
        c.setLineJoin(.miter)
        c.setMiterLimit(2.2)
        let p = optionPoints()
        c.move(to: p[0])
        for q in p.dropFirst() { c.addLine(to: q) }
        c.strokePath()
    }, svg: optionSVG()),
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
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
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
    ctx.saveGState()
    ctx.translateBy(x: x - width / 2, y: y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = CGPoint(x: 0, y: -ascent)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
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
    guard CGImageDestinationFinalize(dest) else { fatalError("png \(url)") }
}

let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let page = color(0xF5F5F3).cgColor
let band = color(0x0C0C0C).cgColor
let black = color(0x111111)
let white = color(0xFFFFFF)
let mute = color(0x8A8A86)

let W = 2160, H = 1320
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
    paint(mark, color: black.cgColor, in: CGRect(x: cx - 160, y: 130, width: 320, height: 320), ctx)
    drawText(mark.name, x: cx, y: 520, font: nameFont, color: black, ctx: ctx)
    drawText(mark.caption, x: cx, y: 568, font: captionFont, color: mute, ctx: ctx)
    paint(mark, color: white.cgColor, in: CGRect(x: cx - 92, y: bandY + 70, width: 184, height: 184), ctx)
}
drawTextLeft("BLACK ON WHITE", x: 72, y: 64, font: kickerFont, color: mute, ctx: ctx)
drawTextLeft("WHITE ON BLACK", x: 72, y: bandY + 36, font: kickerFont, color: mute, ctx: ctx)
writePNG(ctx.makeImage()!, to: out.appendingPathComponent("sheet-2.png"))

for mark in marks {
    let tile = makeContext(1200, 1200)
    tile.setFillColor(white.cgColor)
    tile.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
    paint(mark, color: black.cgColor, in: CGRect(x: 280, y: 280, width: 640, height: 640), tile)
    writePNG(tile.makeImage()!, to: out.appendingPathComponent("\(mark.file).png"))
    try mark.svg.write(to: out.appendingPathComponent("\(mark.file).svg"), atomically: true, encoding: .utf8)
}
print("ok")
