import AppKit
import QuartzCore

// The magic quill: an acid-green vane, a carved nib, sparks while it writes.
final class QuillView: NSView {
    private let holder = CALayer()   // position of the quill tip
    private let wobble = CALayer()   // wobble
    private let body = CALayer()     // appearing
    private let sparks = CAEmitterLayer()
    private var shown = false
    private var lean: Double = -1     // -1 the quill leans right, +1 left (for right-to-left writing)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        holder.opacity = 0
        holder.addSublayer(wobble)
        wobble.addSublayer(body)
        buildQuill()
        sparks.emitterShape = .point
        sparks.renderMode = .additive
        sparks.birthRate = 0
        sparks.emitterCells = [spark(CGColor(srgbRed: 1, green: 0.85, blue: 0.35, alpha: 1)),
                               spark(CGColor(srgbRed: 0.45, green: 1, blue: 0.55, alpha: 1))]
        layer?.addSublayer(sparks)
        layer?.addSublayer(holder)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // tip is in view coordinates, nil hides the quill. writing turns on sparks and the quick wobble.
    func update(tip: CGPoint?, writing: Bool, time: Double, rtl: Bool = false) {
        guard let tip else {
            sparks.birthRate = 0
            if shown {
                shown = false
                holder.opacity = 0
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.4
                holder.add(fade, forKey: "out")
            }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        if sparks.contentsScale != scale { setScale(scale, layer!) }
        holder.position = tip
        sparks.emitterPosition = tip
        // when the direction changes, the quill smoothly leans over to the other side
        lean += ((rtl ? 1 : -1) - lean) * 0.12
        let a = writing ? 0.55 * lean + 0.07 * sin(time * 11) + 0.03 * sin(time * 23) : 0.6 * lean + 0.05 * sin(time * 1.7)
        wobble.transform = CATransform3DMakeRotation(CGFloat(a), 0, 0, 1)
        sparks.birthRate = writing ? 1 : 0
        CATransaction.commit()

        if !shown {
            shown = true
            holder.removeAllAnimations()
            holder.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.6
            holder.add(fade, forKey: "in")
            let pop = CASpringAnimation(keyPath: "transform")
            pop.fromValue = CATransform3DTranslate(CATransform3DMakeScale(0.3, 0.3, 1), 80, 220, 0)
            pop.toValue = CATransform3DIdentity
            pop.damping = 9
            pop.duration = pop.settlingDuration
            body.add(pop, forKey: "in")
        }
    }

    private func setScale(_ s: CGFloat, _ l: CALayer) {
        l.contentsScale = s
        l.sublayers?.forEach { setScale(s, $0) }
        l.mask.map { setScale(s, $0) }
    }

    private func spark(_ color: CGColor) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = QuillArt.star
        c.birthRate = 40
        c.lifetime = 0.9
        c.lifetimeRange = 0.4
        c.velocity = 35
        c.velocityRange = 30
        c.emissionRange = .pi * 2
        c.yAcceleration = -40
        c.scale = 0.22
        c.scaleRange = 0.12
        c.scaleSpeed = -0.2
        c.alphaSpeed = -1.1
        c.spin = 2
        c.spinRange = 4
        c.color = color
        return c
    }

    // The quill in its own coordinates: the tip at zero, the quill pointing up along y.
    private func buildQuill() {
        body.sublayerTransform = CATransform3DMakeScale(1.2, 1.2, 1)
        let frame = QuillArt.frame
        // a magic glow around the quill
        let glow = CALayer()
        glow.frame = frame
        glow.contents = QuillArt.feather
        glow.shadowColor = CGColor(srgbRed: 0.45, green: 1, blue: 0.4, alpha: 1)
        glow.shadowOpacity = 0.55
        glow.shadowRadius = 10
        glow.shadowOffset = .zero
        body.addSublayer(glow)
        // the quill itself and its shadow on the paper
        let quill = CALayer()
        quill.frame = frame
        quill.contents = QuillArt.feather
        quill.shadowColor = .black
        quill.shadowOpacity = 0.3
        quill.shadowRadius = 4
        quill.shadowOffset = CGSize(width: 9, height: -13)
        body.addSublayer(quill)
    }
}

enum QuillArt {
    // where the quill image sits relative to the tip, in points
    static let frame = CGRect(x: -58, y: -4, width: 112, height: 282)

    // The quill is drawn once: hundreds of vane barbs, down at the base, the shaft,
    // the translucent barrel and the cut nib dipped in ink.
    static let feather = render(scale: 3)

    // scale is pixels per point; the app icon needs it bigger
    static func render(scale k: CGFloat) -> CGImage {
        let c = CGContext(data: nil, width: Int(frame.width * k), height: Int(frame.height * k), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x: k, y: k)
        c.translateBy(x: -frame.minX, y: -frame.minY)
        c.setLineCap(.round)
        var g = SystemRandomNumberGenerator()
        func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &g) }
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

        let top: CGFloat = 274, vane0: CGFloat = 64
        // the shaft axis is slightly curved
        func axis(_ y: CGFloat) -> CGPoint { let t = (y - 18) / (top - 18); return CGPoint(x: -9 * t * t, y: y) }
        func tangent(_ y: CGFloat) -> CGVector {
            let t = (y - 18) / (top - 18), dx = -18 * t / (top - 18)
            let l = sqrt(dx * dx + 1)
            return CGVector(dx: dx / l, dy: 1 / l)
        }
        func rot(_ v: CGVector, _ a: CGFloat) -> CGVector {
            CGVector(dx: v.dx * cos(a) - v.dy * sin(a), dy: v.dx * sin(a) + v.dy * cos(a))
        }
        // vane width: grows fast, holds long, rounds off at the end
        func width(_ t: CGFloat) -> CGFloat { 44 * pow(sin(.pi * pow(max(0, min(1, t)), 0.62)), 0.75) * (1 - 0.18 * t) }

        // down at the base
        for _ in 0..<160 {
            let y = r(46, 104), side: CGFloat = Bool.random() ? 1 : -1
            let s = axis(y)
            let a = side * r(0.5, 1.9)
            let l = r(10, 30)
            let d = rot(tangent(y), a)
            c.setStrokeColor(rgb(0.78, 0.97, 0.55, r(0.18, 0.4)))
            c.setLineWidth(r(0.25, 0.5))
            c.move(to: s)
            c.addCurve(to: CGPoint(x: s.x + d.dx * l + r(-6, 6), y: s.y + d.dy * l + r(-8, 4)),
                       control1: CGPoint(x: s.x + d.dx * l * 0.3 + r(-5, 5), y: s.y + d.dy * l * 0.3 + r(-5, 5)),
                       control2: CGPoint(x: s.x + d.dx * l * 0.7 + r(-7, 7), y: s.y + d.dy * l * 0.7 + r(-7, 7)))
            c.strokePath()
        }

        // vane barbs, with splits and clumped strands like a real feather
        for side: CGFloat in [1, -1] {
            var y = vane0, group: CGFloat = 0, gap = 0
            while y < top - 2 {
                let t = (y - vane0) / (top - vane0)
                if Double.random(in: 0..<1) < 0.045 { group = r(-0.12, 0.12) }
                if gap == 0 && Double.random(in: 0..<1) < 0.012 && t > 0.08 { gap = Int.random(in: 2...6) }
                let theta = (0.95 - 0.25 * t) + group
                let wv = width(t) * (side > 0 ? 1 : 0.58)
                var len = wv / max(0.3, sin(theta)) * r(0.9, 1.02)
                if gap > 0 { len *= r(0.25, 0.6); gap -= 1 }
                let s = axis(y)
                let d = rot(tangent(y), side * theta)
                let up = rot(d, side * 0.9)
                let e = CGPoint(x: s.x + d.dx * len, y: s.y + d.dy * len)
                let m = CGPoint(x: s.x + d.dx * len * 0.55 + up.dx * len * 0.1, y: s.y + d.dy * len * 0.55 + up.dy * len * 0.1)
                let b = r(0.88, 1.08)
                c.setStrokeColor(rgb(0.36 * b + 0.2 * t, 0.86 * b, 0.12 * b, r(0.75, 0.95)))
                c.setLineWidth(r(0.45, 0.65))
                c.move(to: s)
                c.addQuadCurve(to: e, control: m)
                c.strokePath()
                // light barb tips
                let q = CGPoint(x: (m.x + e.x) / 2, y: (m.y + e.y) / 2)
                c.setStrokeColor(rgb(0.62 * b, 0.98, 0.3 * b, r(0.35, 0.6)))
                c.setLineWidth(r(0.35, 0.5))
                c.move(to: q)
                c.addLine(to: e)
                c.strokePath()
                y += r(0.38, 0.55)
            }
        }

        // shading and highlights only on top of the barbs already drawn
        c.saveGState()
        c.setBlendMode(.sourceAtop)
        let spine = CGMutablePath()
        spine.move(to: axis(vane0 - 10))
        for y in stride(from: vane0, through: top, by: 4) { spine.addLine(to: axis(y)) }
        c.setShadow(offset: .zero, blur: 22, color: rgb(0.03, 0.22, 0.03, 0.7))
        c.setStrokeColor(rgb(0.05, 0.3, 0.05, 0.22))
        c.setLineWidth(4)
        c.addPath(spine)
        c.strokePath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               colors: [rgb(1, 1, 0.8, 0.28), rgb(1, 1, 0.8, 0), rgb(0, 0.1, 0, 0.25)] as CFArray,
                               locations: [0, 0.45, 1])!
        c.drawLinearGradient(sheen, start: CGPoint(x: -40, y: top), end: CGPoint(x: 30, y: vane0), options: [])
        c.restoreGState()

        // the shaft: pale, tapering toward the end
        let rachis = CGMutablePath()
        let ys = Array(stride(from: CGFloat(56), through: top, by: 3))
        func half(_ y: CGFloat) -> CGFloat { 1.7 * (1 - (y - 56) / (top - 56)) + 0.25 }
        rachis.move(to: CGPoint(x: axis(ys[0]).x - half(ys[0]), y: ys[0]))
        for y in ys { rachis.addLine(to: CGPoint(x: axis(y).x - half(y), y: y)) }
        for y in ys.reversed() { rachis.addLine(to: CGPoint(x: axis(y).x + half(y), y: y)) }
        rachis.closeSubpath()
        c.addPath(rachis)
        c.setFillColor(rgb(0.93, 0.96, 0.8))
        c.fillPath()
        c.addPath(rachis)
        c.setStrokeColor(rgb(0.45, 0.55, 0.3, 0.6))
        c.setLineWidth(0.35)
        c.strokePath()

        // the barrel: a translucent horn tube
        let tube = CGMutablePath()
        tube.move(to: CGPoint(x: -2.6, y: 18))
        tube.addCurve(to: CGPoint(x: -2.1, y: 60), control1: CGPoint(x: -3.1, y: 32), control2: CGPoint(x: -2.8, y: 48))
        tube.addLine(to: CGPoint(x: 1.9, y: 60))
        tube.addCurve(to: CGPoint(x: 2.6, y: 18), control1: CGPoint(x: 2.6, y: 48), control2: CGPoint(x: 3.1, y: 32))
        tube.closeSubpath()
        c.saveGState()
        c.addPath(tube)
        c.clip()
        let horn = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(0.62, 0.58, 0.44, 0.95), rgb(0.97, 0.95, 0.86, 0.9), rgb(0.86, 0.82, 0.68, 0.85), rgb(0.55, 0.5, 0.38, 0.95)] as CFArray,
                              locations: [0, 0.32, 0.6, 1])!
        c.drawLinearGradient(horn, start: CGPoint(x: -3.2, y: 0), end: CGPoint(x: 3.2, y: 0), options: [])
        c.setStrokeColor(rgb(0.7, 0.66, 0.52, 0.5))
        c.setLineWidth(0.3)
        for y in [26, 31, 39, 44, 52] as [CGFloat] { c.move(to: CGPoint(x: -3, y: y)); c.addLine(to: CGPoint(x: 3, y: y + 0.6)); c.strokePath() }
        c.setStrokeColor(rgb(1, 1, 1, 0.75))
        c.setLineWidth(0.5)
        c.move(to: CGPoint(x: -1.2, y: 20)); c.addLine(to: CGPoint(x: -0.9, y: 58)); c.strokePath()
        c.restoreGState()

        // the cut nib: the bevel, the slit, the ink
        let nib = CGMutablePath()
        nib.move(to: .zero)
        nib.addCurve(to: CGPoint(x: -2.6, y: 19), control1: CGPoint(x: -0.6, y: 6), control2: CGPoint(x: -2.4, y: 12))
        nib.addLine(to: CGPoint(x: 2.6, y: 19))
        nib.addCurve(to: .zero, control1: CGPoint(x: 2.2, y: 11), control2: CGPoint(x: 0.5, y: 5))
        nib.closeSubpath()
        c.saveGState()
        c.addPath(nib)
        c.clip()
        c.drawLinearGradient(horn, start: CGPoint(x: -3, y: 0), end: CGPoint(x: 3, y: 0), options: [])
        // the inside of the cut is darker
        let scoop = CGMutablePath()
        scoop.move(to: CGPoint(x: -0.2, y: 3))
        scoop.addCurve(to: CGPoint(x: 2.6, y: 19), control1: CGPoint(x: 0.4, y: 10), control2: CGPoint(x: 0.6, y: 17))
        scoop.addLine(to: CGPoint(x: 2.6, y: 3))
        scoop.closeSubpath()
        c.addPath(scoop)
        c.setFillColor(rgb(0.48, 0.42, 0.3, 0.55))
        c.fillPath()
        let ink = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: [rgb(0.03, 0.06, 0.05, 1), rgb(0.05, 0.12, 0.08, 0.85), rgb(0.1, 0.2, 0.1, 0)] as CFArray,
                             locations: [0, 0.45, 1])!
        c.drawLinearGradient(ink, start: .zero, end: CGPoint(x: 0, y: 13), options: [])
        c.restoreGState()
        c.setStrokeColor(rgb(0.02, 0.04, 0.03, 0.9))
        c.setLineWidth(0.35)
        c.move(to: CGPoint(x: 0.05, y: 0.6)); c.addLine(to: CGPoint(x: 0.2, y: 8.5)); c.strokePath()
        // a drop of fresh ink shines on the tip
        c.setFillColor(rgb(1, 1, 1, 0.55))
        c.fillEllipse(in: CGRect(x: -0.9, y: 2.2, width: 0.8, height: 1.4))
        return c.makeImage()!
    }

    // a soft four-pointed sparkle for the particles
    static let star: CGImage = {
        let n = 48
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let m = CGFloat(n) / 2
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: m, y: m), startRadius: 0, endCenter: CGPoint(x: m, y: m), endRadius: m * 0.45, options: [])
        c.setFillColor(CGColor(gray: 1, alpha: 0.9))
        for r in [CGRect(x: m - 1.2, y: 2, width: 2.4, height: CGFloat(n) - 4), CGRect(x: 2, y: m - 1.2, width: CGFloat(n) - 4, height: 2.4)] {
            c.fillEllipse(in: r)
        }
        return c.makeImage()!
    }()
}
