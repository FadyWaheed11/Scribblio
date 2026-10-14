import AppKit
import Carbon
import MetalKit
import UniformTypeIdentifiers
import simd

// A full-screen window above the desktop icons but below all other windows.
// The mouse passes through everywhere except the sheets. The window takes the keyboard.
final class DeskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class DeskView: MTKView {
    weak var desk: Desk?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func pt(_ e: NSEvent) -> SIMD2<Float> {
        let p = convert(e.locationInWindow, from: nil)
        return SIMD2(Float(p.x), Float(p.y))
    }

    override func mouseDown(with e: NSEvent) { desk?.mouseDown(pt(e)) }
    override func mouseDragged(with e: NSEvent) { desk?.mouseDragged(pt(e)) }
    override func mouseUp(with e: NSEvent) { desk?.mouseUp() }
    override func scrollWheel(with e: NSEvent) { desk?.scroll(e, at: pt(e)) }
    override func rightMouseDown(with e: NSEvent) { desk?.contextMenu(e, at: pt(e)) }
    override func keyDown(with e: NSEvent) { if desk?.key(e) != true { super.keyDown(with: e) } }
}

// The note file: JSON text inside, but to the system it is its own document type rather than JSON,
// otherwise Finder opens it in TextEdit.
struct NoteFile: Codable {
    var text: String
    var version = 1
    var width: Double?      // sheet width as a fraction of the screen width; missing in older files

    static let type = UTType(exportedAs: "com.fadywaheed.scribblio.note", conformingTo: .data)
    static let ext = "scribblio"
}

// One note on the desktop: the cloth sheet, the page of text, its own textures and file.
final class Note {
    let page: Page
    private(set) var cloth: Cloth
    private(set) var mesh: SheetMesh
    private let device: MTLDevice
    private var textures: [MTLTexture] = []
    private var ti = 0
    var url: URL?
    var savedText = ""

    var texture: MTLTexture { textures[ti] }
    var unsaved: Bool { page.fullText != savedText }
    var title: String {
        if let url { return url.deletingPathExtension().lastPathComponent }
        let words = page.fullText.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
        return words.isEmpty ? L("Untitled Note") : words
    }

    init?(device: MTLDevice, paper: URL, width: Float) {
        guard let page = Page(paper: paper) else { return nil }
        self.page = page
        self.device = device
        cloth = Cloth(width: width, height: width * Float(Page.H) / Float(Page.W), params: .paper)
        mesh = SheetMesh(device: device, cloth: cloth)
        // a texture per frame in flight, so we never write into the one the GPU is reading
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Page.W, height: Page.H, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .managed
        for _ in 0..<3 {
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            textures.append(t)
        }
        page.tick(dt: 0)
        upload()
    }

    func upload() {
        ti = (ti + 1) % textures.count
        page.upload(to: textures[ti])
    }

    // Sheet corners: vertex index and side (x: -1 left, +1 right; y: -1 bottom, +1 top).
    var corners: [(idx: Int, side: SIMD2<Float>)] {
        let c = cloth
        return [(c.idx(0, 0), SIMD2(-1, -1)), (c.idx(c.nx - 1, 0), SIMD2(1, -1)),
                (c.idx(0, c.ny - 1), SIMD2(-1, 1)), (c.idx(c.nx - 1, c.ny - 1), SIMD2(1, 1))]
    }

    // New size: the sheet is rebuilt with the same shape and lies flat, the writing scales with it.
    // anchor is the corner that stays put, side says which corner is being dragged.
    func resize(width: Float, anchor: SIMD2<Float>, side: SIMD2<Float>, angle: Float, camera: Camera) {
        let c = Cloth(width: width, height: width * Float(Page.H) / Float(Page.W), params: .paper)
        c.floorZ = cloth.floorZ
        // the cloth height is rounded to whole rows, so the center uses the real one
        let half = SIMD2(side.x * c.width / 2, side.y * c.height / 2)
        let center = anchor + SIMD2(half.x * cos(angle) - half.y * sin(angle), half.x * sin(angle) + half.y * cos(angle))
        c.layout(center: center, angle: angle, drop: 0)
        c.updateDerived(camera)
        cloth = c
        mesh = SheetMesh(device: device, cloth: c)
    }
}

final class Desk: NSObject, MTKViewDelegate, NSMenuDelegate {
    let window: DeskWindow
    let view: DeskView
    private let quill: QuillView
    private let renderer: Renderer
    private let paperURL: URL
    private var camera: Camera
    // the array order is the stack: the last note is on top and the quill writes in it
    private(set) var notes: [Note] = []
    private var hoverTimer: Timer?
    private var dragging: Note?
    // dragging a corner: the opposite corner stays put, the sheet grows or shrinks
    private struct Resize { let note: Note; let anchor: SIMD2<Float>; let side: SIMD2<Float>; let angle: Float }
    private var resizing: Resize?
    private var cursorIsResize = false
    static var defaultWidth: Float {
        get { let v = UserDefaults.standard.float(forKey: "quill.noteWidth"); return v > 0 ? v : 0.36 }
        set { UserDefaults.standard.set(newValue, forKey: "quill.noteWidth") }
    }
    // a press without movement is a click; the sheet lifts only when dragged
    private var press: (vertex: Int, z: Float, at: SIMD2<Float>)?
    private var calmFrames = 0
    private var clock: Double = 0
    private var quillTip: CGPoint?
    private var quillGlide: Double = 0
    private let liftHeight: Float = 90
    private let layerGap: Float = 0.8

    var active: Note? { notes.last }

    private var awake = true {
        didSet { if awake != oldValue { view.isPaused = !awake } }
    }

    init?(screen: NSScreen, paper url: URL) {
        let frame = screen.frame
        camera = Camera(size: SIMD2(Float(frame.width), Float(frame.height)))
        paperURL = url

        window = DeskWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        view = DeskView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.layer?.isOpaque = false
        quill = QuillView(frame: NSRect(origin: .zero, size: frame.size))
        do {
            renderer = try Renderer(device: device, colorFormat: view.colorPixelFormat,
                                    depthFormat: view.depthStencilPixelFormat, sampleCount: view.sampleCount)
        } catch {
            NSLog("Scribblio: renderer error \(error)")
            return nil
        }
        super.init()

        view.desk = self
        view.delegate = self
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        quill.autoresizingMask = [.width, .height]
        root.addSubview(view)
        root.addSubview(quill)
        window.contentView = root
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        hoverTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.idle() }
        RunLoop.main.add(hoverTimer!, forMode: .common)

        // keyboard layout change: the quill moves to the edge that language is written from
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(keyboardChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
    }

    // Whether the current keyboard language is written right to left (Arabic, Hebrew, Persian, Urdu…).
    static var keyboardRTL: Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
              let lang = langs.first else { return false }
        return ["ar", "he", "fa", "ur", "yi", "ps", "sd", "ug", "dv", "ckb"].contains { lang == $0 || lang.hasPrefix($0 + "-") }
    }

    @objc private func keyboardChanged() {
        DispatchQueue.main.async { [self] in
            let rtl = Desk.keyboardRTL
            for n in notes { n.page.preferRTL = rtl }
            wake()
        }
    }

    private func wake() {
        calmFrames = 0
        awake = true
    }

    // MARK: notes

    @discardableResult
    func newNote(text: String? = nil, url: URL? = nil, width: Float? = nil) -> Note? {
        let w = camera.size.x * max(0.12, min(0.9, width ?? Desk.defaultWidth))
        guard let n = Note(device: renderer.device, paper: paperURL, width: w) else { return nil }
        n.page.preferRTL = Desk.keyboardRTL
        if let text {
            n.page.load(text)
            n.savedText = text
        }
        n.url = url
        // a new sheet falls near the center, each next one a bit to the side
        let k = Float(notes.count)
        let off = notes.isEmpty ? SIMD2<Float>(0, 0) : SIMD2(Float.random(in: -1...1), Float.random(in: -1...1)) * 110 + SIMD2(30, -20) * min(k, 4)
        let c = simd_clamp(camera.center + off, SIMD2(n.cloth.width, n.cloth.height) * 0.5, camera.size - SIMD2(n.cloth.width, n.cloth.height) * 0.5)
        active?.page.deselect()
        notes.append(n)
        restack()
        n.cloth.layout(center: c, angle: Float.random(in: -0.12...0.12), drop: 260)
        n.cloth.updateDerived(camera)
        quillGlide = 0.45
        wake()
        return n
    }

    // Stack heights in order: the top sheet lies on the others.
    private func restack() {
        for (i, n) in notes.enumerated() { n.cloth.floorZ = Float(i) * layerGap }
    }

    private func bringToFront(_ n: Note) {
        guard let i = notes.firstIndex(where: { $0 === n }), i != notes.count - 1 else { return }
        active?.page.deselect()
        notes.remove(at: i)
        notes.append(n)
        restack()
        quillGlide = 0.45
        wake()
    }

    func close(_ n: Note) {
        if n.unsaved && !n.page.fullText.isEmpty {
            let a = NSAlert()
            a.messageText = L("Save changes to “%@”?", n.title)
            a.informativeText = L("Your changes will be lost if you don’t save them.")
            a.addButton(withTitle: L("Save"))
            a.addButton(withTitle: L("Cancel"))
            a.addButton(withTitle: L("Don’t Save"))
            NSApp.activate(ignoringOtherApps: true)
            switch a.runModal() {
            case .alertFirstButtonReturn: if !save(n, as: false) { return }
            case .alertSecondButtonReturn: return
            default: break
            }
        }
        notes.removeAll { $0 === n }
        restack()
        quillGlide = 0.45
        wake()
    }

    var unsavedCount: Int { notes.filter { $0.unsaved && !$0.page.fullText.isEmpty }.count }

    // MARK: files

    // The folder the save and open dialogs start in. The app never looks into folders by itself:
    // only those dialogs grant access to files, so macOS never asks for Documents permission.
    static var notesFolder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "quill.notesFolder") { return URL(fileURLWithPath: p) }
            if let last = recent.first { return last.deletingLastPathComponent() }
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "quill.notesFolder") }
    }

    // Recent notes without touching the disk; a missing file leaves the list when you try to open it.
    static var recent: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "quill.recent") ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.prefix(12).map(\.path), forKey: "quill.recent") }
    }

    private func remember(_ u: URL) {
        Desk.recent = [u] + Desk.recent.filter { $0.standardizedFileURL != u.standardizedFileURL }
        Desk.notesFolder = u.deletingLastPathComponent()
    }

    @discardableResult
    func save(_ n: Note, as saveAs: Bool) -> Bool {
        var target = n.url
        if target == nil || saveAs {
            let p = NSSavePanel()
            p.allowedContentTypes = [NoteFile.type]
            p.directoryURL = n.url?.deletingLastPathComponent() ?? Desk.notesFolder
            p.nameFieldStringValue = n.title.replacingOccurrences(of: "/", with: "-")
            p.message = L("Save the note so you can open it again later")
            NSApp.activate(ignoringOtherApps: true)
            guard p.runModal() == .OK, let u = p.url else { return false }
            target = u
        }
        guard let target else { return false }
        do {
            let text = n.page.fullText
            try JSONEncoder().encode(NoteFile(text: text, width: Double(n.cloth.width / camera.size.x))).write(to: target, options: .atomic)
            n.url = target
            n.savedText = text
            remember(target)
            return true
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
            return false
        }
    }

    func open(_ u: URL) {
        if let n = notes.first(where: { $0.url?.standardizedFileURL == u.standardizedFileURL }) {
            bringToFront(n)
            return
        }
        do {
            let f = try JSONDecoder().decode(NoteFile.self, from: Data(contentsOf: u))
            newNote(text: f.text, url: u, width: f.width.map(Float.init))
            remember(u)
        } catch {
            Desk.recent = Desk.recent.filter { $0.standardizedFileURL != u.standardizedFileURL }
            let a = NSAlert()
            a.messageText = L("“%@” can’t be opened", u.lastPathComponent)
            a.informativeText = L("It isn’t a Scribblio note or it is damaged.")
            a.runModal()
        }
    }

    // MARK: menu commands

    @objc func newNoteAction(_ sender: Any?) { newNote() }

    @objc func openAction(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [NoteFile.type]
        p.allowsMultipleSelection = true
        p.directoryURL = Desk.notesFolder
        p.message = L("Choose one or more notes to open")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        p.urls.forEach(open)
    }

    @objc func openRecentAction(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { open(u) }
    }

    @objc func clearRecentAction(_ sender: Any?) { Desk.recent = [] }

    @objc func saveAction(_ sender: Any?) { if let n = active { save(n, as: false) } }
    @objc func saveAsAction(_ sender: Any?) { if let n = active { save(n, as: true) } }
    @objc func closeAction(_ sender: Any?) { if let n = active { close(n) } }

    @objc func selectAllAction(_ sender: Any?) { active?.page.selectAll(); wake() }
    @objc func undoAction(_ sender: Any?) { active?.page.undo(); wake() }
    @objc func redoAction(_ sender: Any?) { active?.page.redo(); wake() }

    @objc func copyAction(_ sender: Any?) {
        guard let p = active?.page, p.selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p.fullText, forType: .string)
    }

    @objc func cutAction(_ sender: Any?) {
        guard let p = active?.page, p.selected else { return }
        copyAction(sender)
        p.clear()
        wake()
    }

    @objc func pasteAction(_ sender: Any?) {
        guard let p = active?.page, var s = NSPasteboard.general.string(forType: .string) else { return }
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        s.unicodeScalars.removeAll { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
        guard !s.isEmpty else { return }
        p.type(s)
        wake()
    }

    @objc func clearPageAction(_ sender: Any?) { active?.page.clear(); wake() }

    @objc func redropAction(_ sender: Any?) {
        guard let c = active?.cloth else { return }
        let p = c.pose()
        c.layout(center: p.center, angle: p.angle, drop: 200)
        wake()
    }

    @objc func centerAction(_ sender: Any?) {
        active?.cloth.layout(center: camera.center, angle: 0, drop: 120)
        wake()
    }

    func validate(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveAction), #selector(saveAsAction), #selector(closeAction), #selector(selectAllAction),
             #selector(pasteAction), #selector(clearPageAction), #selector(redropAction), #selector(centerAction):
            return active != nil
        case #selector(copyAction), #selector(cutAction):
            return active?.page.selected == true
        case #selector(undoAction):
            return active?.page.canUndo == true
        case #selector(redoAction):
            return active?.page.canRedo == true
        default:
            return true
        }
    }

    // The Open Recent menu is rebuilt every time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for u in Desk.recent {
            let it = NSMenuItem(title: u.deletingPathExtension().lastPathComponent, action: #selector(openRecentAction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = u
            menu.addItem(it)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: L("No Saved Notes Yet"), action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(.separator())
            let c = NSMenuItem(title: L("Clear Menu"), action: #selector(clearRecentAction(_:)), keyEquivalent: "")
            c.target = self
            menu.addItem(c)
        }
    }

    // MARK: frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let dt: Float = 1.0 / Float(max(30, view.preferredFramesPerSecond))
        clock += Double(dt)
        var moving = false
        for n in notes {
            if n.page.tick(dt: Double(dt)) { n.upload() }
            n.cloth.step(dt: dt)
            n.cloth.updateDerived(camera)
            if n.page.busy || n.cloth.isGrabbing || n.cloth.maxSpeed >= 3 { moving = true }
        }
        updateQuill(dt: Double(dt))
        renderer.draw(sheets: notes.map { Sheet(cloth: $0.cloth, mesh: $0.mesh, texture: $0.texture) }, camera: camera, in: view)

        calmFrames = moving || quillGlide > 0 ? 0 : calmFrames + 1
        if calmFrames > 45 { awake = false }
    }

    // The quill tip from the sheet to the screen, bilinear over the cloth grid. The quill always sits on the top note.
    private func updateQuill(dt: Double) {
        guard let n = active else {
            quill.update(tip: nil, writing: false, time: clock)
            quillTip = nil
            return
        }
        let page = n.page, cloth = n.cloth
        var tip = page.nib
        // when not writing, the quill hovers above the paper
        if !page.writing { tip.y += CGFloat(16 + 9 * sin(clock * 2.2)) }
        let fi = Float(tip.x) / Float(Page.W) * Float(cloth.nx - 1)
        let fj = Float(tip.y) / Float(Page.H) * Float(cloth.ny - 1)
        let i = max(0, min(cloth.nx - 2, Int(fi))), j = max(0, min(cloth.ny - 2, Int(fj)))
        let u = max(0, min(1, fi - Float(i))), v = max(0, min(1, fj - Float(j)))
        func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        let p = lerp(lerp(cloth.pos[cloth.idx(i, j)], cloth.pos[cloth.idx(i + 1, j)], u),
                     lerp(cloth.pos[cloth.idx(i, j + 1)], cloth.pos[cloth.idx(i + 1, j + 1)], u), v)
        let nrm = cloth.nrm[cloth.idx(i, j)]
        // the sheet is face down here, so the quill is hidden
        guard nrm.z > 0.15 else {
            quill.update(tip: nil, writing: false, time: clock)
            quillTip = nil
            return
        }
        let s = camera.project(p + nrm * 2)
        var target = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
        // when the note changes, the quill flies over to it instead of jumping
        if quillGlide > 0, let from = quillTip {
            quillGlide -= dt
            let k = CGFloat(1 - exp(-dt * 12))
            target = CGPoint(x: from.x + (target.x - from.x) * k, y: from.y + (target.y - from.y) * k)
        }
        quillTip = target
        quill.update(tip: target, writing: page.writing, time: clock, rtl: page.nibRTL)
    }

    // While the simulation sleeps, a timer lets the mouse through empty space and keeps the quill bobbing.
    private func idle() {
        if !awake {
            clock += 1.0 / 30
            updateQuill(dt: 1.0 / 30)
        }
        if resizing != nil { return }
        if dragging != nil { return }
        let m = NSEvent.mouseLocation
        let s = SIMD2(Float(m.x - window.frame.minX), Float(m.y - window.frame.minY))
        // during someone else's drag (a file from Finder) the sheets let the mouse through
        let busy = NSEvent.pressedMouseButtons != 0 && window.ignoresMouseEvents
        let corner = busy ? nil : cornerHit(s)
        let sheet = busy || corner != nil ? nil : pick(s, needVertex: false)
        let hit = corner != nil || sheet != nil
        if window.ignoresMouseEvents == hit { window.ignoresMouseEvents = !hit }
        setResizeCursor(corner.map { corners -> SIMD2<Float> in corners.note.corners[corners.corner].side })
    }

    // Over a sheet corner the cursor turns into resize arrows; there are no other marks.
    private func setResizeCursor(_ side: SIMD2<Float>?) {
        guard let side else {
            if cursorIsResize { NSCursor.arrow.set(); cursorIsResize = false }
            return
        }
        cursorIsResize = true
        if #available(macOS 15.0, *) {
            let pos: NSCursor.FrameResizePosition = side.y > 0 ? (side.x > 0 ? .topRight : .topLeft) : (side.x > 0 ? .bottomRight : .bottomLeft)
            NSCursor.frameResize(position: pos, directions: .all).set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // The sheet corner under a screen point, dragged to resize. A corner covered by another sheet on top does not count.
    private func cornerHit(_ s: SIMD2<Float>) -> (note: Note, corner: Int)? {
        for n in notes.reversed() {
            if let k = n.corners.firstIndex(where: { simd_distance(n.cloth.proj[$0.idx], s) < 20 }) { return (n, k) }
            if n.cloth.pick(s, needVertex: false) != nil, let uv = n.cloth.pickUV(s), n.page.isPaper(u: uv.x, v: uv.y) { return nil }
        }
        return nil
    }

    private func rot(_ v: SIMD2<Float>, _ a: Float) -> SIMD2<Float> {
        SIMD2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a))
    }

    // The topmost sheet under a screen point.
    private func pick(_ s: SIMD2<Float>, needVertex: Bool) -> (note: Note, vertex: Int, z: Float)? {
        var best: (Note, Int, Float)?
        for n in notes.reversed() {
            // the mouse passes through the burnt corner of a sheet
            guard let (v, z) = n.cloth.pick(s, needVertex: needVertex), z > (best?.2 ?? -.greatestFiniteMagnitude),
                  let uv = n.cloth.pickUV(s), n.page.isPaper(u: uv.x, v: uv.y) else { continue }
            best = (n, v, z)
        }
        return best.map { (note: $0.0, vertex: $0.1, z: $0.2) }
    }

    // MARK: mouse

    func mouseDown(_ s: SIMD2<Float>) {
        // a click on a sheet gives it the keyboard and brings it to the top
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeFirstResponder(view)
        if let c = cornerHit(s) {
            let n = c.note
            bringToFront(n)
            let side = n.corners[c.corner].side
            let opp = n.corners.first { $0.side == -side }!
            let p = n.cloth.pos[opp.idx]
            resizing = Resize(note: n, anchor: SIMD2(p.x, p.y), side: side, angle: n.cloth.pose().angle)
            wake()
            return
        }
        guard let hit = pick(s, needVertex: true) else { return }
        bringToFront(hit.note)
        hit.note.page.deselect()
        dragging = hit.note
        press = (hit.vertex, hit.z, s)
        wake()
    }

    func mouseDragged(_ s: SIMD2<Float>) {
        if let r = resizing {
            // size from the mouse projected onto the sheet diagonal, keeping the sheet's shape
            let n = r.note
            let w0 = camera.unproject(s, z: n.cloth.floorZ)
            let local = rot(SIMD2(w0.x, w0.y) - r.anchor, -r.angle)
            let aspect = Float(Page.H) / Float(Page.W)
            let dir = SIMD2(r.side.x, r.side.y * aspect)
            let maxW = min(camera.size.x * 0.9, camera.size.y * 0.95 / aspect)
            let w = max(camera.size.x * 0.12, min(maxW, simd_dot(local, dir) / simd_dot(dir, dir)))
            n.resize(width: w, anchor: r.anchor, side: r.side, angle: r.angle, camera: camera)
            wake()
            return
        }
        guard let n = dragging else { return }
        if let p = press {
            if simd_distance(s, p.at) < 4 { return }
            press = nil
            n.cloth.beginGrab(vertex: p.vertex, target: camera.unproject(p.at, z: max(p.z, 0) + liftHeight))
        }
        n.cloth.grabTarget = camera.unproject(s, z: n.cloth.grabTarget.z)
        wake()
    }

    func mouseUp() {
        if let r = resizing {
            resizing = nil
            // new notes will have the same size
            Desk.defaultWidth = r.note.cloth.width / camera.size.x
            wake()
            return
        }
        guard let n = dragging else { return }
        dragging = nil
        if let p = press {
            press = nil
            // a click without dragging puts the quill at the letter under the mouse
            if let uv = n.cloth.pickUV(p.at) {
                n.page.placeCaret(at: CGPoint(x: CGFloat(uv.x) * CGFloat(Page.W), y: (1 - CGFloat(uv.y)) * CGFloat(Page.H)))
                wake()
            }
            return
        }
        n.cloth.endGrab()
        wake()
    }

    func scroll(_ e: NSEvent, at s: SIMD2<Float>) {
        let d = Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.05)
        guard d != 0, let hit = pick(s, needVertex: false) else { return }
        hit.note.cloth.rotate(by: d)
        wake()
    }

    func contextMenu(_ e: NSEvent, at s: SIMD2<Float>) {
        if let hit = pick(s, needVertex: false) { bringToFront(hit.note) }
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector) {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = self
            m.addItem(it)
        }
        add(L("New Note"), #selector(newNoteAction(_:)))
        add(L("Open Note…"), #selector(openAction(_:)))
        let recent = NSMenu()
        recent.delegate = self
        let ri = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: "")
        ri.submenu = recent
        m.addItem(ri)
        m.addItem(.separator())
        add(L("Save"), #selector(saveAction(_:)))
        add(L("Save As…"), #selector(saveAsAction(_:)))
        add(L("Select All"), #selector(selectAllAction(_:)))
        add(L("Clear the Page"), #selector(clearPageAction(_:)))
        m.addItem(.separator())
        add(L("Drop Again"), #selector(redropAction(_:)))
        add(L("Center"), #selector(centerAction(_:)))
        add(L("Close Note"), #selector(closeAction(_:)))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: L("Quit Scribblio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        NSMenu.popUpContextMenu(m, with: e, for: view)
    }

    // MARK: keyboard

    func key(_ e: NSEvent) -> Bool {
        guard let page = active?.page else { return false }
        let cmd = e.modifierFlags.contains(.command), opt = e.modifierFlags.contains(.option)
        let step: Page.Step = cmd ? .edge : opt ? .word : .char
        // arrows move the quill through the text, with Option by word, with Command to the end of the line or text
        switch e.keyCode {
        case 123: page.move(.left, by: step); wake(); return true
        case 124: page.move(.right, by: step); wake(); return true
        case 126: page.move(.up, by: step); wake(); return true
        case 125: page.move(.down, by: step); wake(); return true
        case 115: page.move(.left, by: .edge); wake(); return true    // home
        case 119: page.move(.right, by: .edge); wake(); return true   // end
        default: break
        }
        if cmd { return false }
        switch e.keyCode {
        case 51: page.backspace()                      // delete
        case 117: page.deleteForward()                 // forward delete
        case 53: page.deselect()                       // esc
        case 36, 76: page.type("\n")                   // return, enter
        case 48: page.type("    ")                     // tab
        default:
            guard let s = e.characters, !s.isEmpty,
                  s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
            else { return false }
            page.type(s)
        }
        wake()
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var desk: Desk?
    private var pendingOpen: [URL] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateSettings()
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = Bundle.main.url(forResource: "paper", withExtension: "png"),
              let d = Desk(screen: screen, paper: url) else {
            NSLog("Scribblio: could not start")
            NSApp.terminate(nil)
            return
        }
        desk = d
        setupMainMenu()
        // notes open in Scribblio on double-click, even if another editor is chosen for JSON
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: NoteFile.type) { err in
            if let err { NSLog("Scribblio: could not become the default app for notes: \(err)") }
        }
        if pendingOpen.isEmpty { d.newNote() } else { pendingOpen.forEach(d.open) }
        pendingOpen = []
        NSApp.activate(ignoringOtherApps: true)
    }

    // Settings from before the app had its own identifier: recent notes, the notes folder and the note size.
    private func migrateSettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "scribblio.migrated") else { return }
        d.set(true, forKey: "scribblio.migrated")
        guard let old = UserDefaults(suiteName: "com.srtnk.quill") else { return }
        for k in ["quill.recent", "quill.notesFolder", "quill.noteWidth"] where d.object(forKey: k) == nil {
            if let v = old.object(forKey: k) { d.set(v, forKey: k) }
        }
    }

    // double-clicking a note file in Finder
    func application(_ sender: NSApplication, open urls: [URL]) {
        if let desk { urls.forEach(desk.open) } else { pendingOpen += urls }
    }

    // reopening from the Dock: if there are no sheets, drop a new one
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if desk?.notes.isEmpty == true { desk?.newNote() }
        desk?.window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let n = desk?.unsavedCount, n > 0 else { return .terminateNow }
        let a = NSAlert()
        a.messageText = n == 1 ? L("You have an unsaved note.") : L("You have %d unsaved notes.", n)
        a.informativeText = L("If you quit now, the unsaved writing will be lost.")
        a.addButton(withTitle: L("Cancel"))
        a.addButton(withTitle: L("Quit Anyway"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    private func setupMainMenu() {
        guard let desk else { return }
        let main = NSMenu()
        func item(_ m: NSMenu, _ t: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = desk
            m.addItem(it)
        }

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let am = NSMenu()
        am.addItem(NSMenuItem(title: L("Hide Scribblio"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        am.addItem(.separator())
        am.addItem(NSMenuItem(title: L("Quit Scribblio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = am

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fm = NSMenu(title: L("File"))
        item(fm, L("New Note"), #selector(Desk.newNoteAction(_:)), "n")
        item(fm, L("Open…"), #selector(Desk.openAction(_:)), "o")
        let recent = NSMenu(title: L("Open Recent"))
        recent.delegate = desk
        let ri = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: "")
        ri.submenu = recent
        fm.addItem(ri)
        fm.addItem(.separator())
        item(fm, L("Close Note"), #selector(Desk.closeAction(_:)), "w")
        item(fm, L("Save"), #selector(Desk.saveAction(_:)), "s")
        item(fm, L("Save As…"), #selector(Desk.saveAsAction(_:)), "s", [.command, .shift])
        fileItem.submenu = fm

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let em = NSMenu(title: L("Edit"))
        item(em, L("Undo"), #selector(Desk.undoAction(_:)), "z")
        item(em, L("Redo"), #selector(Desk.redoAction(_:)), "z", [.command, .shift])
        em.addItem(.separator())
        item(em, L("Cut"), #selector(Desk.cutAction(_:)), "x")
        item(em, L("Copy"), #selector(Desk.copyAction(_:)), "c")
        item(em, L("Paste"), #selector(Desk.pasteAction(_:)), "v")
        item(em, L("Select All"), #selector(Desk.selectAllAction(_:)), "a")
        em.addItem(.separator())
        item(em, L("Clear the Page"), #selector(Desk.clearPageAction(_:)), "\u{8}")
        editItem.submenu = em

        NSApp.mainMenu = main
    }
}

extension Desk: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(item) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
