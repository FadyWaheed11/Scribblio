// Generates Resources/paper.png, the sheet of writing paper the quill writes on.
// Off-white paper with fibres, grain, yellowing, a soft curl and torn (deckled) edges with alpha.
// The top-left corner is burnt away with a charred rim, and every edge is lightly scorched.
//   swiftc -O tools/note.swift -o /tmp/note && /tmp/note Resources/paper.png
import AppKit
import CoreGraphics

let W = 1000, H = 900

func hash(_ x: Int, _ y: Int, _ s: Int) -> Float {
    var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ s &* 2147483647)
    h = (h ^ (h >> 13)) &* 1274126177
    return Float(h ^ (h >> 16)) / Float(UInt32.max)
}

func noise(_ x: Float, _ y: Float, _ s: Int) -> Float {
    let xi = Int(floor(x)), yi = Int(floor(y))
    let fx = x - floor(x), fy = y - floor(y)
    let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
    let a = hash(xi, yi, s), b = hash(xi + 1, yi, s), c = hash(xi, yi + 1, s), d = hash(xi + 1, yi + 1, s)
    return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
}

func fbm(_ x: Float, _ y: Float, _ s: Int, _ oct: Int = 5) -> Float {
    var f: Float = 0, amp: Float = 0.5, fr: Float = 1
    for o in 0..<oct { f += amp * noise(x * fr, y * fr, s + o * 17); fr *= 2.03; amp *= 0.5 }
    return f
}

func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

var rng = SystemRandomNumberGenerator()
func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &rng) }

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 1. Paper pixel by pixel, torn-edge alpha kept separately
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
var edgeAlpha = [Float](repeating: 1, count: W * H)
var edgeDist = [Float](repeating: 1000, count: W * H)
var burnDist = [Float](repeating: 1000, count: W * H)
for row in 0..<H {
    let y = Float(H - 1 - row)        // y up, as in CG
    for x in 0..<W {
        let fx = Float(x)
        // cloudy paper pulp and fine grain
        let cloud = fbm(fx / 140, y / 140, 1)
        let grain = noise(fx / 1.3, y / 1.3, 5) - 0.5
        let fibre = noise(fx / 0.9, y / 7, 31) * noise(fx / 9, y / 1.1, 37)
        var r: Float = 0.965, g: Float = 0.945, b: Float = 0.885
        let k = 0.975 + 0.05 * (cloud - 0.5) + 0.025 * grain - 0.03 * fibre
        r *= k; g *= k; b *= k

        // torn edge: distance to the edge plus noise at two scales
        let e = min(min(fx, Float(W) - fx), min(y, Float(H) - y))
        let jag = 9 * fbm(fx / 22 + y / 22, y / 22 - fx / 22, 3, 4) + 4 * noise(fx / 2.5, y / 2.5, 9)
        let d = e - 6 - jag
        edgeAlpha[row * W + x] = smooth(-0.8, 1.2, d)
        edgeDist[row * W + x] = d
        // burnt top-left corner: distance to the corner with a ragged fiery edge
        let ragged = 60 * (fbm(fx / 70, y / 70, 41, 4) - 0.5) + 18 * (noise(fx / 14, y / 14, 43) - 0.5) + 5 * (noise(fx / 3, y / 3, 47) - 0.5)
        // the corner burns up to the margin but never into where the quill writes
        burnDist[row * W + x] = hypot(fx * 1.1, Float(H) - y) - 150 + ragged

        // yellowing at the edges and light aging
        let age = 1 - smooth(0, 90, d)
        r *= 1 - 0.03 * age; g *= 1 - 0.07 * age; b *= 1 - 0.17 * age
        b *= 1 - 0.05 * fbm(fx / 300, y / 300, 11)

        // light from the top left and a curl near the bottom-right corner
        let lx = fx / Float(W), ly = y / Float(H)
        var light = 1.02 - 0.05 * (lx * 0.6 + (1 - ly) * 0.4)
        let corner = hypot(Float(W) - fx, y) / 260
        if corner < 1 { light *= 1 - 0.07 * (1 - corner) * (1 - corner) + 0.03 * sin(corner * 3.14) }
        r *= light; g *= light; b *= light

        let i = (row * W + x) * 4
        px[i] = UInt8(max(0, min(255, r * 255)))
        px[i + 1] = UInt8(max(0, min(255, g * 255)))
        px[i + 2] = UInt8(max(0, min(255, b * 255)))
        px[i + 3] = 255
    }
}

// 2. Fibres: short light and dark hairs
for _ in 0..<5000 {
    let x = rnd(0, CGFloat(W)), y = rnd(0, CGFloat(H))
    let a = rnd(0, .pi * 2), l = rnd(3, 16)
    let dark = Bool.random()
    ctx.setStrokeColor(dark ? CGColor(srgbRed: 0.55, green: 0.5, blue: 0.4, alpha: rnd(0.03, 0.09))
                            : CGColor(srgbRed: 1, green: 1, blue: 0.97, alpha: rnd(0.1, 0.25)))
    ctx.setLineWidth(rnd(0.4, 1.1))
    ctx.move(to: CGPoint(x: x, y: y))
    ctx.addQuadCurve(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l),
                     control: CGPoint(x: x + cos(a + 0.5) * l * 0.5, y: y + sin(a + 0.5) * l * 0.5))
    ctx.strokePath()
}

// 3. A few rusty age spots
for _ in 0..<28 {
    let r = rnd(0.6, 2.6)
    ctx.setFillColor(CGColor(srgbRed: 0.6, green: 0.42, blue: 0.2, alpha: rnd(0.08, 0.2)))
    ctx.fillEllipse(in: CGRect(x: rnd(40, CGFloat(W) - 40), y: rnd(40, CGFloat(H) - 40), width: r * 2, height: r * 2 * rnd(0.7, 1.2)))
}

// 4. Notepad rules, printed slightly unevenly
var ly: CGFloat = CGFloat(H) - 140
while ly > 90 {
    var x: CGFloat = 70
    while x < CGFloat(W) - 70 {
        let step = rnd(30, 70)
        ctx.setStrokeColor(CGColor(srgbRed: 0.42, green: 0.55, blue: 0.72, alpha: rnd(0.28, 0.38)))
        ctx.setLineWidth(1.4)
        ctx.move(to: CGPoint(x: x, y: ly)); ctx.addLine(to: CGPoint(x: min(x + step, CGFloat(W) - 70), y: ly + rnd(-0.25, 0.25)))
        ctx.strokePath()
        x += step
    }
    ly -= 62
}
ctx.setStrokeColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.3, alpha: 0.35))
ctx.setLineWidth(1.6)
ctx.move(to: CGPoint(x: 130, y: 50)); ctx.addLine(to: CGPoint(x: 130, y: CGFloat(H) - 50))
ctx.strokePath()

// 5. Fire: the corner is burnt away, charcoal at the rim, brown scorch beyond. The other edges are lightly singed.
for i in 0..<(W * H) {
    let bd = burnDist[i], ed = edgeDist[i]
    let a = edgeAlpha[i] * smooth(-1.2, 1.2, bd)
    if a <= 0 { for c in 0..<4 { px[i * 4 + c] = 0 }; continue }
    var r = Float(px[i * 4]) / 255, g = Float(px[i * 4 + 1]) / 255, b = Float(px[i * 4 + 2]) / 255
    let x = Float(i % W), y = Float(H - 1 - i / W)
    let flick = 0.75 + 0.5 * fbm(x / 25, y / 25, 53, 3)
    // brown scorch: wide at the burnt corner, narrow along the other edges
    let scorch = max((1 - smooth(0, 150, bd)) * flick, (1 - smooth(0, 38, ed)) * 0.55 * flick)
    r *= 1 - 0.5 * scorch; g *= 1 - 0.66 * scorch; b *= 1 - 0.85 * scorch
    // a charcoal rim with a smouldering orange band
    let char = max(1 - smooth(0, 13 * flick, bd), (1 - smooth(0, 4, ed)) * 0.7)
    let ember = exp(-pow((bd - 10) / 4, 2)) * 0.35
    r += (0.75 - r) * ember; g += (0.32 - g) * ember; b += (0.08 - b) * ember
    let k = pow(min(1, char), 0.7)
    r += (0.09 - r) * k; g += (0.06 - g) * k; b += (0.04 - b) * k
    px[i * 4] = UInt8(max(0, min(255, r * a * 255)))
    px[i * 4 + 1] = UInt8(max(0, min(255, g * a * 255)))
    px[i * 4 + 2] = UInt8(max(0, min(255, b * a * 255)))
    px[i * 4 + 3] = UInt8(a * 255)
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
