import AppKit
import CoreText
import Metal
import QuartzCore

// The sheet the quill writes on as you type.
// It is a small text editor: a caret, arrow keys, inserting and deleting anywhere,
// and long text scrolls smoothly along the rules. The quill writes new letters where they are inserted.
// The page is drawn into a CGContext in sheet pixels (y up) and uploaded into the cloth texture.
final class Page {
    static let W = 1000, H = 900
    // rules on the sheet, see tools/note.swift
    let firstLine = CGFloat(H - 140), lineStep: CGFloat = 62
    let left: CGFloat = 150, right: CGFloat = 910
    var maxLines: Int { Int((firstLine - 90) / lineStep) + 1 }

    enum Move { case left, right, up, down }

    private struct Glyph {
        var index: Int        // index in the text (UTF-16)
        var path: CGPath      // in unscrolled coordinates
        var box: CGRect
        var seed: Double
        var line: Int
        var rtl: Bool         // an Arabic or Hebrew letter: the quill draws it from right to left
    }

    private struct Ghost {    // an erased letter melting in green light
        var path: CGPath
        var born: Double
    }

    private struct Line {     // the caret on a line stands at positions start...last
        var start: Int
        var last: Int
        var rtl = false
    }

    private let baseCtx, settledCtx, frameCtx: CGContext
    // where there is paper and where it burnt away: ink and clicks only on paper
    private let paperAlpha: [UInt8]
    private let paperMask: CGImage
    private let font: CTFont
    private(set) var text = ""
    var fullText: String { text }
    private(set) var selected = false
    private(set) var caret = 0
    private var desiredX: CGFloat?        // the column the up and down arrows aim for
    private var units: Int { (text as NSString).length }
    private var doneAt: [Double] = []     // when the quill finished each letter, .infinity if not yet
    private var glyphs: [Glyph] = []
    private var byIndex: [Int: [Int]] = [:]
    private var lines: [Line] = []
    private var anchorX: [CGFloat] = []   // caret x for every position
    private var anchorLine: [Int] = []
    private var ghosts: [Ghost] = []
    private var settled = Set<Int>()
    private var settledScroll: CGFloat = -1
    private var penT: Double = 0
    private var now: Double = 0
    private let glow = 1.1
    private let inkWeight: CGFloat = 1.1   // extra ink thickness in sheet pixels
    private var scroll: CGFloat = 0       // first visible line, smoothed
    private var scrollTarget = 0
    private var nibPos: CGPoint
    private(set) var dirty = true

    // Edit history. A run of typing becomes one step, like in ordinary editors.
    private enum EditKind { case typing, deleting, other }
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    private var lastKind: EditKind?
    private var lastEditAt: Double = -10
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var pending: Int? { doneAt.firstIndex(of: .infinity) }
    var writing: Bool { pending != nil }
    var busy: Bool { writing || !ghosts.isEmpty || doneAt.contains { now - $0 < glow } || abs(scroll - CGFloat(scrollTarget)) > 0.001 }
    var nib: CGPoint { nibPos }

    init?(paper url: URL) {
        let W = Page.W, H = Page.H
        func make() -> CGContext? {
            CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let b = make(), let s = make(), let f = make() else { return nil }
        b.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        // sheet alpha, rows top to bottom (BGRA in memory, alpha is the fourth byte)
        let bytes = b.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
        var alpha = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) { alpha[i] = bytes[i * 4 + 3] }
        guard let mc = CGContext(data: &alpha, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let mask = mc.makeImage() else { return nil }
        paperAlpha = alpha
        paperMask = mask
        baseCtx = b
        settledCtx = s
        frameCtx = f
        font = Page.cursive(52)
        nibPos = CGPoint(x: left + 40, y: firstLine + 20)
        relayout()
    }

    // Whether there is paper at a point of the sheet (texture uv, v from the top).
    func isPaper(u: Float, v: Float) -> Bool {
        let x = Int(u * Float(Page.W)), y = Int(v * Float(Page.H))
        guard x >= 0, y >= 0, x < Page.W, y < Page.H else { return false }
        return paperAlpha[y * Page.W + x] > 127
    }

    // Handwriting font. Arabic letters come from a handwritten Naskh, everything else from the system fallbacks.
    static func cursive(_ size: CGFloat) -> CTFont {
        var name = "Georgia-Italic"
        for n in ["SnellRoundhand", "Apple-Chancery"] where CTFontCopyPostScriptName(CTFontCreateWithName(n as CFString, size, nil)) as String == n {
            name = n
            break
        }
        let cascade = ["DecoTypeNaskh", "GeezaPro"].map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, size) }
        let d = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: name,
            kCTFontCascadeListAttribute: cascade,
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(d, size, nil)
    }

    // Paragraph direction from the first strong letter, like ordinary editors. nil if there are no strong letters.
    static func isRTL(_ s: String) -> Bool? {
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x370...0x52F: return false
            default: continue
            }
        }
        return nil
    }

    // Direction for empty lines and lines without letters: from the keyboard language.
    // Switch the keyboard to Arabic and the quill moves to the right edge.
    var preferRTL = false {
        didSet {
            guard preferRTL != oldValue else { return }
            relayout()
            revealCaret()
        }
    }

    // The line under the quill runs right to left, so the quill leans the other way.
    var nibRTL: Bool { lines[anchorLine[pending ?? caret]].rtl }

    // MARK: editing

    func type(_ s: String) {
        let n = (s as NSString).length
        guard n > 0 else { return }
        // typing over a selection replaces all the text, as one undo step
        record(selected || n > 1 ? .other : .typing)
        if selected { erase() }
        text = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: s)
        doneAt.insert(contentsOf: Array(repeating: .infinity, count: n), at: caret)
        caret += n
        desiredX = nil
        // a new line closes the undo step
        if s.contains("\n") { lastKind = nil }
        relayout()
        revealCaret()
    }

    // An opened note: the quill rewrites the first page, the rest appears at once.
    func load(_ s: String) {
        undoStack = []
        redoStack = []
        lastKind = nil
        text = s
        doneAt = Array(repeating: .infinity, count: units)
        ghosts = []
        penT = 0
        caret = 0
        desiredX = nil
        selected = false
        scroll = 0
        scrollTarget = 0
        relayout()
    }

    func backspace() {
        if selected { clear(); return }
        guard caret > 0 else { return }
        record(.deleting)
        let r = (text as NSString).rangeOfComposedCharacterSequence(at: caret - 1)
        caret = r.location
        remove(r)
    }

    func deleteForward() {
        if selected { clear(); return }
        guard caret < units else { return }
        record(.deleting)
        remove((text as NSString).rangeOfComposedCharacterSequence(at: caret))
    }

    func clear() {
        guard !text.isEmpty else { return }
        record(.other)
        erase()
    }

    private func erase() {
        vanish { _ in true }
        text = ""
        doneAt = []
        caret = 0
        selected = false
        scrollTarget = 0
        relayout()
    }

    // MARK: undo

    private func record(_ kind: EditKind) {
        if kind != .other && kind == lastKind && now - lastEditAt < 2 {
            lastEditAt = now
            return
        }
        undoStack.append(text)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack = []
        lastKind = kind
        lastEditAt = now
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(text)
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(text)
        restore(s)
    }

    // Switch to another text: what goes away melts in green light, what comes back is written again by the quill.
    private func restore(_ s: String) {
        let old = Array(text.utf16), new = Array(s.utf16)
        var p = 0
        while p < min(old.count, new.count) && old[p] == new[p] { p += 1 }
        var q = 0
        while q < min(old.count, new.count) - p && old[old.count - 1 - q] == new[new.count - 1 - q] { q += 1 }
        vanish { $0 >= p && $0 < old.count - q }
        doneAt = Array(doneAt[0..<p]) + Array(repeating: .infinity, count: new.count - p - q) + Array(doneAt[(old.count - q)...])
        text = s
        caret = new.count - q
        selected = false
        desiredX = nil
        lastKind = nil
        relayout()
        revealCaret()
    }

    func selectAll() {
        guard !text.isEmpty else { return }
        selected = true
        dirty = true
    }

    func deselect() {
        guard selected else { return }
        selected = false
        dirty = true
    }

    // Arrow keys. by: .word with Option, .edge with Command (end of the line or of the whole text).
    enum Step { case char, word, edge }

    func move(_ m: Move, by step: Step = .char) {
        deselect()
        lastKind = nil
        let ns = text as NSString
        // in a right-to-left line the arrows follow the screen, which is logically reversed
        var m = m
        if lines[anchorLine[caret]].rtl {
            if m == .left { m = .right } else if m == .right { m = .left }
        }
        switch (m, step) {
        case (.left, .char):
            if caret > 0 { caret = ns.rangeOfComposedCharacterSequence(at: caret - 1).location }
            desiredX = nil
        case (.right, .char):
            if caret < units { caret = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: caret)) }
            desiredX = nil
        case (.left, .word):
            var i = caret
            while i > 0 && isSpace(ns.character(at: i - 1)) { i -= 1 }
            while i > 0 && !isSpace(ns.character(at: i - 1)) { i -= 1 }
            caret = i
            desiredX = nil
        case (.right, .word):
            var i = caret
            while i < units && isSpace(ns.character(at: i)) { i += 1 }
            while i < units && !isSpace(ns.character(at: i)) { i += 1 }
            caret = i
            desiredX = nil
        case (.left, .edge):
            caret = lines[anchorLine[caret]].start
            desiredX = nil
        case (.right, .edge):
            caret = lines[anchorLine[caret]].last
            desiredX = nil
        case (.up, .edge):
            caret = 0
            desiredX = nil
        case (.down, .edge):
            caret = units
            desiredX = nil
        case (.up, _), (.down, _):
            let x = desiredX ?? anchorX[caret]
            let l = anchorLine[caret] + (m == .up ? -1 : 1)
            if l < 0 { caret = 0 } else if l >= lines.count { caret = units } else { caret = nearest(x, on: l) }
            desiredX = x
        }
        dirty = true
        revealCaret()
    }

    // A click on the sheet puts the caret at the nearest letter. pt is in sheet pixels.
    func placeCaret(at pt: CGPoint) {
        deselect()
        lastKind = nil
        let l = Int(floor((firstLine + 44 - pt.y) / lineStep + scroll))
        caret = nearest(pt.x, on: max(0, min(lines.count - 1, l)))
        desiredX = nil
        dirty = true
        revealCaret()
    }

    private func isSpace(_ c: unichar) -> Bool { c == 32 || c == 10 || c == 9 }

    private func nearest(_ x: CGFloat, on l: Int) -> Int {
        let ln = lines[l]
        var best = ln.start
        for i in ln.start...ln.last where abs(anchorX[i] - x) < abs(anchorX[best] - x) { best = i }
        return best
    }

    // Erased written letters melt in green light where they can be seen.
    private func vanish(_ which: (Int) -> Bool) {
        let shift = CGAffineTransform(translationX: 0, y: scroll * lineStep)
        for g in glyphs where which(g.index) && doneAt[g.index].isFinite && visible(g.line, scroll) {
            if let p = g.path.copy(using: [shift]) { ghosts.append(Ghost(path: p, born: now)) }
        }
    }

    private func remove(_ r: NSRange) {
        vanish { $0 >= r.location && $0 < NSMaxRange(r) }
        text = (text as NSString).replacingCharacters(in: r, with: "")
        doneAt.removeSubrange(r.location..<NSMaxRange(r))
        desiredX = nil
        relayout()
        revealCaret()
    }

    // Scroll so the caret line is on the sheet.
    private func revealCaret() {
        let l = anchorLine[caret]
        if l < scrollTarget { scrollTarget = l }
        if l >= scrollTarget + maxLines { scrollTarget = l - maxLines + 1 }
        scrollTarget = max(0, min(scrollTarget, max(0, lines.count - maxLines)))
        dirty = true
    }

    private func visible(_ line: Int, _ s: CGFloat) -> Bool {
        let p = CGFloat(line) - s
        return p > -0.98 && p < CGFloat(maxLines) - 0.02
    }

    // lines near the top and bottom fade while scrolling
    private func alpha(_ line: Int) -> Double {
        let p = Double(CGFloat(line) - scroll), m = Double(maxLines - 1)
        return max(0, min(1, p + 1)) * max(0, min(1, m + 1 - p))
    }

    private func baseline(_ line: Int) -> CGFloat { firstLine - (CGFloat(line) - scroll) * lineStep }

    // MARK: layout

    private func relayout() {
        glyphs = []
        byIndex = [:]
        lines = []
        anchorX = Array(repeating: left, count: units + 1)
        anchorLine = Array(repeating: 0, count: units + 1)
        settledScroll = -1
        dirty = true

        var line = 0
        var paraStart = 0
        let paras = text.components(separatedBy: "\n")
        for (pi, p) in paras.enumerated() {
            let plen = (p as NSString).length
            if plen == 0 {
                // an empty line
                lines.append(Line(start: paraStart, last: paraStart, rtl: preferRTL))
                anchorX[paraStart] = preferRTL ? right : left
                anchorLine[paraStart] = line
                line += 1
                paraStart += pi < paras.count - 1 ? 1 : 0
                continue
            }
            let rtl = Page.isRTL(p) ?? preferRTL
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
            let ts = CTTypesetterCreateWithAttributedString(NSAttributedString(string: p, attributes: [.font: font, .paragraphStyle: style]))
            var start = 0
            repeat {
                let y = firstLine - CGFloat(line) * lineStep
                let count = max(1, CTTypesetterSuggestLineBreak(ts, start, Double(right - left)))
                let l = CTTypesetterCreateLine(ts, CFRange(location: start, length: count))
                let end = start + count
                // Arabic lines sit against the right edge
                let x0 = left + (rtl ? CGFloat(CTLineGetPenOffsetForFlush(l, 1, Double(right - left))) : 0)
                lines.append(Line(start: paraStart + start, last: paraStart + (end >= plen ? plen : end - 1), rtl: rtl))
                for i in start...end where paraStart + i <= units {
                    anchorX[paraStart + i] = x0 + CTLineGetOffsetForStringIndex(l, i, nil)
                    anchorLine[paraStart + i] = line
                }
                for run in CTLineGetGlyphRuns(l) as! [CTRun] {
                    let n = CTRunGetGlyphCount(run)
                    let rf = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                    var gs = [CGGlyph](repeating: 0, count: n)
                    var ps = [CGPoint](repeating: .zero, count: n)
                    var idx = [CFIndex](repeating: 0, count: n)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: n), &gs)
                    CTRunGetPositions(run, CFRange(location: 0, length: n), &ps)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
                    let runRTL = CTRunGetStatus(run).contains(.rightToLeft)
                    for i in 0..<n {
                        var m = CGAffineTransform(translationX: x0 + ps[i].x, y: y + ps[i].y)
                        guard let path = CTFontCreatePathForGlyph(rf, gs[i], &m), !path.boundingBox.isEmpty else { continue }
                        let k = paraStart + idx[i]
                        byIndex[k, default: []].append(glyphs.count)
                        glyphs.append(Glyph(index: k, path: path, box: path.boundingBox, seed: Double(k % 7) * 0.9, line: line, rtl: runRTL))
                    }
                }
                start = end
                line += 1
            } while start < plen
            paraStart += plen + (pi < paras.count - 1 ? 1 : 0)
        }
    }

    // MARK: frame

    // Returns true if the page was redrawn.
    @discardableResult
    func tick(dt: Double) -> Bool {
        now += dt
        // the quill does not rewrite invisible lines (for example the tail of an opened note)
        while let p = pending, !visible(anchorLine[p], CGFloat(scrollTarget)) { doneAt[p] = now - glow - 1 }
        if let p = pending {
            // the further ahead you type, the faster the quill writes
            let backlog = doneAt.reduce(0) { $0 + ($1 == .infinity ? 1 : 0) }
            let speed = min(30, 1 + Double(backlog) * 0.35)
            let w = (byIndex[p] ?? []).map { glyphs[$0].box.width }.max() ?? 0
            let dur = (w > 0 ? max(0.05, Double(w) / 650) : 0.06) / speed
            penT += dt / dur
            while penT >= 1, let q = pending {
                doneAt[q] = now
                penT -= 1
            }
            if pending == nil { penT = 0 }
        }
        let st = CGFloat(scrollTarget)
        if abs(scroll - st) > 0.001 {
            scroll += (st - scroll) * CGFloat(1 - exp(-dt * 9))
            if abs(scroll - st) < 0.002 { scroll = st }
            dirty = true
        }
        ghosts.removeAll { now - $0.born > 0.7 }
        moveNib(dt)
        guard busy || dirty else { return false }
        render()
        return true
    }

    private func moveNib(_ dt: Double) {
        let lift = scroll * lineStep
        var target: CGPoint
        if let p = pending, let gi = byIndex[p]?.first {
            let g = glyphs[gi]
            let t = max(0, min(1, penT))
            let y = g.box.minY + g.box.height * CGFloat(0.5 + 0.42 * sin(t * .pi * 3 + g.seed))
            let x = g.rtl ? g.box.maxX - g.box.width * CGFloat(t) : g.box.minX + g.box.width * CGFloat(t)
            target = CGPoint(x: x, y: y + lift)
        } else {
            // a space, a line break or waiting: the quill hovers over the caret
            let i = pending ?? caret
            target = CGPoint(x: anchorX[i] + 2, y: baseline(anchorLine[i]) + 14)
        }
        let k = CGFloat(1 - exp(-dt * 30))
        nibPos.x += (target.x - nibPos.x) * k
        nibPos.y += (target.y - nibPos.y) * k
    }

    private func render() {
        dirty = false
        let shift = CGAffineTransform(translationX: 0, y: scroll * lineStep)
        if settledScroll != scroll {
            copy(baseCtx, to: settledCtx)
            settled = []
            settledScroll = scroll
        }
        let full = CGRect(x: 0, y: 0, width: Page.W, height: Page.H)
        settledCtx.saveGState()
        settledCtx.clip(to: full, mask: paperMask)
        for g in glyphs where !settled.contains(g.index) && visible(g.line, scroll) && now - doneAt[g.index] > glow {
            draw(g, shift, in: settledCtx, ink: inkColor(age: glow, alpha: alpha(g.line)), glow: 0)
        }
        settledCtx.restoreGState()
        for g in glyphs where visible(g.line, scroll) && now - doneAt[g.index] > glow { settled.insert(g.index) }

        copy(settledCtx, to: frameCtx)
        // everything drawn from here lands only on paper, not in the burnt hole
        frameCtx.saveGState()
        frameCtx.clip(to: full, mask: paperMask)
        defer { frameCtx.restoreGState() }
        if selected { highlight() }
        let p = pending
        for g in glyphs where !settled.contains(g.index) && visible(g.line, scroll) {
            if g.index == p {
                frameCtx.saveGState()
                frameCtx.concatenate(shift)
                // a slanted edge, like a pen moving along cursive; Arabic letters appear from right to left
                let t = CGFloat(min(1, penT)), b = g.box
                frameCtx.beginPath()
                if g.rtl {
                    let x = b.maxX + 2 - (b.width + 4) * t
                    frameCtx.move(to: CGPoint(x: b.maxX + 40, y: b.minY - 10))
                    frameCtx.addLine(to: CGPoint(x: x + 3, y: b.minY - 10))
                    frameCtx.addLine(to: CGPoint(x: x - 0.3 * (b.height + 10), y: b.maxY + 10))
                    frameCtx.addLine(to: CGPoint(x: b.maxX + 40, y: b.maxY + 10))
                } else {
                    let x = b.minX - 2 + (b.width + 4) * t
                    frameCtx.move(to: CGPoint(x: b.minX - 40, y: b.minY - 10))
                    frameCtx.addLine(to: CGPoint(x: x - 3, y: b.minY - 10))
                    frameCtx.addLine(to: CGPoint(x: x + 0.3 * (b.height + 10), y: b.maxY + 10))
                    frameCtx.addLine(to: CGPoint(x: b.minX - 40, y: b.maxY + 10))
                }
                frameCtx.closePath()
                frameCtx.clip()
                fill(g.path, in: frameCtx, ink: inkColor(age: 0, alpha: alpha(g.line)), glow: 1)
                frameCtx.restoreGState()
            } else if doneAt[g.index].isFinite {
                let age = now - doneAt[g.index]
                draw(g, shift, in: frameCtx, ink: inkColor(age: age, alpha: alpha(g.line)), glow: 1 - age / glow)
            }
        }
        for gh in ghosts {
            let a = 1 - (now - gh.born) / 0.7
            fill(gh.path, in: frameCtx, ink: inkColor(age: 0, alpha: a), glow: a)
        }
    }

    private func draw(_ g: Glyph, _ shift: CGAffineTransform, in c: CGContext, ink: CGColor, glow: Double) {
        c.saveGState()
        c.concatenate(shift)
        fill(g.path, in: c, ink: ink, glow: glow)
        c.restoreGState()
    }

    // Selection is a magic highlighter band under each line; the ink stays dark.
    private func highlight() {
        var rows: [Int: CGRect] = [:]
        for g in glyphs where visible(g.line, scroll) { rows[g.line] = rows[g.line].map { $0.union(g.box) } ?? g.box }
        frameCtx.saveGState()
        frameCtx.setBlendMode(.multiply)
        frameCtx.setFillColor(CGColor(srgbRed: 0.8, green: 0.97, blue: 0.64, alpha: 1))
        for (l, r) in rows {
            let y = baseline(l)
            frameCtx.addPath(CGPath(roundedRect: CGRect(x: r.minX - 8, y: y - 16, width: r.width + 16, height: 56),
                                    cornerWidth: 10, cornerHeight: 10, transform: nil))
        }
        frameCtx.fillPath()
        frameCtx.restoreGState()
    }

    var image: CGImage? { frameCtx.makeImage() }

    func upload(to t: MTLTexture) {
        t.replace(region: MTLRegionMake2D(0, 0, Page.W, Page.H), mipmapLevel: 0,
                  withBytes: frameCtx.data!, bytesPerRow: frameCtx.bytesPerRow)
    }

    private func inkColor(age: Double, alpha: Double = 1) -> CGColor {
        // fresh ink glows acid green and then darkens
        let t = max(0, min(1, age / glow))
        let k = t * t * (3 - 2 * t)
        let fresh = (0.42, 1.0, 0.5), ink = (0.07, 0.15, 0.09)
        return CGColor(srgbRed: fresh.0 + (ink.0 - fresh.0) * k, green: fresh.1 + (ink.1 - fresh.1) * k,
                       blue: fresh.2 + (ink.2 - fresh.2) * k, alpha: max(0, alpha))
    }

    private func fill(_ path: CGPath, in c: CGContext, ink: CGColor, glow: Double) {
        c.saveGState()
        if glow > 0.01 {
            c.setShadow(offset: .zero, blur: 14, color: CGColor(srgbRed: 0.35, green: 1, blue: 0.45, alpha: CGFloat(min(1, glow)) * 0.9))
        }
        // a thin outline of the same ink around each letter makes the handwriting bolder and easier to read
        c.setFillColor(ink)
        c.setStrokeColor(ink)
        c.setLineWidth(inkWeight)
        c.setLineJoin(.round)
        c.addPath(path)
        c.drawPath(using: .fillStroke)
        c.restoreGState()
    }

    private func copy(_ a: CGContext, to b: CGContext) {
        memcpy(b.data!, a.data!, a.bytesPerRow * a.height)
    }
}
