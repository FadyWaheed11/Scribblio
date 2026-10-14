// Generates the app icon: the magic quill writing glowing ink on a scrap of burnt paper.
// Uses the same quill art as the app (Sources/Quill.swift) and the paper texture (Resources/paper.png).
//   swiftc -O tools/icon.swift Sources/Quill.swift -o /tmp/icon && /tmp/icon
// Writes Resources/icon_1024.png and Resources/AppIcon.icns.
import AppKit

let N = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

let c = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// the macOS icon tile: an 824 by 824 rounded square with a 100 margin
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
let nib = CGPoint(x: 492, y: 318)

c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0, 0, 0, 0.45))
c.addPath(shape)
c.setFillColor(rgb(0.03, 0.07, 0.08))
c.fillPath()
c.restoreGState()

c.saveGState()
c.addPath(shape)
c.clip()

// a night emerald background glowing around the quill
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.16, 0.42, 0.26), rgb(0.06, 0.18, 0.15), rgb(0.02, 0.05, 0.07)] as CFArray,
                    locations: [0, 0.45, 1])!
c.drawRadialGradient(bg, startCenter: CGPoint(x: nib.x + 60, y: nib.y + 120), startRadius: 0,
                     endCenter: CGPoint(x: 512, y: 512), endRadius: 720, options: [.drawsAfterEndLocation])

// small stars
var rng = SystemRandomNumberGenerator()
func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &rng) }
for _ in 0..<70 {
    let p = CGPoint(x: r(110, 914), y: r(420, 914)), s = r(1, 3.2)
    c.setFillColor(rgb(0.85, 1, 0.85, r(0.15, 0.55)))
    c.fillEllipse(in: CGRect(x: p.x, y: p.y, width: s, height: s))
}

// a scrap of burnt paper
if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: "Resources/paper.png") as CFURL, nil),
   let paper = CGImageSourceCreateImageAtIndex(src, 0, nil) {
    c.saveGState()
    c.translateBy(x: 400, y: 330)
    c.rotate(by: 0.13)
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: rgb(0, 0, 0, 0.55))
    c.draw(paper, in: CGRect(x: -300, y: -265, width: 600, height: 540))
    c.restoreGState()
}

// a glowing ink flourish coming out of the quill
let ink = CGMutablePath()
ink.move(to: CGPoint(x: 205, y: 300))
ink.addCurve(to: CGPoint(x: 300, y: 372), control1: CGPoint(x: 220, y: 360), control2: CGPoint(x: 268, y: 392))
ink.addCurve(to: CGPoint(x: 318, y: 282), control1: CGPoint(x: 340, y: 348), control2: CGPoint(x: 352, y: 268))
ink.addCurve(to: CGPoint(x: 395, y: 352), control1: CGPoint(x: 280, y: 300), control2: CGPoint(x: 340, y: 380))
ink.addCurve(to: nib, control1: CGPoint(x: 440, y: 330), control2: CGPoint(x: 455, y: 300))
c.saveGState()
c.setLineCap(.round)
c.setLineJoin(.round)
c.setShadow(offset: .zero, blur: 26, color: rgb(0.35, 1, 0.45, 1))
c.setStrokeColor(rgb(0.25, 0.85, 0.4, 0.95))
c.setLineWidth(11)
c.addPath(ink)
c.strokePath()
c.setShadow(offset: .zero, blur: 0, color: nil)
c.setStrokeColor(rgb(0.85, 1, 0.8, 0.9))
c.setLineWidth(3.5)
c.addPath(ink)
c.strokePath()
c.restoreGState()

// the quill itself: a shadow on the paper and a soft glow
let k: CGFloat = 2.35
let quill = QuillArt.render(scale: 3 * k)
func drawQuill(offset: CGSize, shadow: CGColor?, blur: CGFloat) {
    c.saveGState()
    if let shadow { c.setShadow(offset: offset, blur: blur, color: shadow) }
    c.translateBy(x: nib.x, y: nib.y)
    c.rotate(by: -0.6)
    c.scaleBy(x: k, y: k)
    c.draw(quill, in: QuillArt.frame)
    c.restoreGState()
}
drawQuill(offset: .zero, shadow: rgb(0.45, 1, 0.4, 0.9), blur: 40)
drawQuill(offset: CGSize(width: 26, height: -34), shadow: rgb(0, 0, 0, 0.45), blur: 14)

// sparkles around the tip
func sparkle(_ p: CGPoint, _ s: CGFloat, _ col: CGColor) {
    let star = CGMutablePath()
    star.move(to: CGPoint(x: p.x, y: p.y + s))
    star.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: p)
    star.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: p)
    star.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: p)
    star.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: p)
    c.saveGState()
    c.setShadow(offset: .zero, blur: s * 0.9, color: col)
    c.addPath(star)
    c.setFillColor(rgb(1, 1, 0.92))
    c.fillPath()
    c.restoreGState()
}
let gold = rgb(1, 0.82, 0.3), green = rgb(0.45, 1, 0.5)
sparkle(CGPoint(x: nib.x - 6, y: nib.y + 2), 30, green)
sparkle(CGPoint(x: 560, y: 268), 16, gold)
sparkle(CGPoint(x: 438, y: 410), 13, gold)
sparkle(CGPoint(x: 600, y: 360), 10, green)
sparkle(CGPoint(x: 250, y: 420), 12, gold)
sparkle(CGPoint(x: 700, y: 760), 18, gold)
sparkle(CGPoint(x: 290, y: 780), 14, green)
sparkle(CGPoint(x: 830, y: 520), 11, gold)
for _ in 0..<26 {
    let a = r(0, .pi * 2), d = r(20, 150)
    let p = CGPoint(x: nib.x + cos(a) * d * 1.3, y: nib.y + sin(a) * d * 0.8 + 20)
    c.setShadow(offset: .zero, blur: 6, color: Bool.random() ? gold : green)
    c.setFillColor(rgb(1, 1, 0.9, r(0.5, 0.95)))
    let s = r(2, 5)
    c.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
}
c.restoreGState()

// a thin highlight along the tile edge
c.saveGState()
c.addPath(shape)
c.setStrokeColor(rgb(1, 1, 1, 0.12))
c.setLineWidth(2)
c.strokePath()
c.restoreGState()

let master = c.makeImage()!
func png(_ img: CGImage, _ size: Int, _ path: String) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}
png(master, 1024, "Resources/icon_1024.png")

let set = FileManager.default.temporaryDirectory.appendingPathComponent("Quill.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    png(master, s, set.appendingPathComponent("icon_\(s)x\(s).png").path)
    png(master, s * 2, set.appendingPathComponent("icon_\(s)x\(s)@2x.png").path)
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "ok" : "iconutil failed")
