import AppKit
import Metal
import QuartzCore
import SwiftUI
import MirageCore

/// Presents the compositor's canvas on a CAMetalLayer, draws the host cursor at the local pointer,
/// forwards input, and starts local scroll / window-drag predictions (DESIGN §3.5).
final class VideoNSView: NSView {
    let metalLayer = CAMetalLayer()
    let cursorLayer = CALayer()
    var session: ViewerSession?
    var model: ViewerModel?
    private var blankCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: img, hotSpot: .zero)
    }()
    private var aspect: CGFloat = 16.0 / 9.0
    private var resizeWork: DispatchWorkItem?
    private var pointerInside = false
    private var localPointer: CGPoint = .zero
    private var lastRequested: (Int, Int) = (0, 0)
    private var displayLink: CADisplayLink?
    private var drag: (windowID: UInt32, frame: PixelRect, last: (Int, Int))?
    /// A press on a layered window's title bar: a drag if the pointer moves, else the click is sent on release
    /// (DESIGN §3.2: the window moves locally, the host is told the frame; the press itself never travels).
    private var layerDrag: (windowID: UInt32, frame: PixelRect, start: (Int, Int), moved: Bool, downEvent: NSEvent)?
    var onToggleStats: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.presentsWithTransaction = false
        layer?.addSublayer(metalLayer)
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        layer?.addSublayer(cursorLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }   // top-left origin, like the host display

    func attach(_ session: ViewerSession) {
        self.session = session
        metalLayer.device = session.compositor?.device
        session.onChange = { [weak self] in DispatchQueue.main.async { self?.forceRedraw = true; self?.needsDisplay = true } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard let session, let comp = session.compositor, comp.width > 0, let context = session.context else { return }
        let ppp = MainActor.assumeIsolated { session.pixelsPerPoint }
        guard let scene = session.scene(pxPerPoint: ppp) else { return }
        let arrangement = session.arrangementGeneration
        var layersDirty = false
        for it in scene.items { if case .layer(let c, _, _, _) = it, c.needsRender { layersDirty = true; break } }
        let changed = comp.needsRender || layersDirty || !scene.displacements.isEmpty || lastDisplacementCount != scene.displacements.count || arrangement != lastArrangement || session.hasPendingPredictions || forceRedraw
        lastDisplacementCount = scene.displacements.count; lastArrangement = arrangement; forceRedraw = false
        guard changed, let drawable = metalLayer.nextDrawable() else { return }
        let scale = metalLayer.contentsScale
        let r = videoRect
        let dest = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        session.lastDest = dest
        SceneRenderer.render(scene, context: context, to: drawable, dest: dest)
        drawTypeahead()
    }

    // Typeahead overlay (DESIGN §3.5 item 4): predicted glyphs in the host's font at the predicted caret, underlined until
    // the host's caret confirms them; gone when the host's pixels over them arrive.
    private let typeaheadLayer = CALayer()
    private var glyphLayers: [UInt64: (text: CATextLayer, line: CALayer)] = [:]
    private func drawTypeahead() {
        guard let session, let comp = session.compositor, comp.width > 0 else { return }
        if typeaheadLayer.superlayer == nil { typeaheadLayer.zPosition = 5; layer?.addSublayer(typeaheadLayer) }
        let v = session.typeaheadSnapshot()
        let r = videoRect, k = r.width / CGFloat(comp.width)
        let ppp = MainActor.assumeIsolated { session.pixelsPerPoint }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let live = Set(v.glyphs.map(\.seq))
        for (seq, l) in glyphLayers where !live.contains(seq) { l.text.removeFromSuperlayer(); l.line.removeFromSuperlayer(); glyphLayers[seq] = nil }
        let pt = CGFloat(v.size) * CGFloat(ppp) * k
        let font = v.font.flatMap { NSFont(name: $0, size: pt) } ?? NSFont.systemFont(ofSize: pt)
        let color = v.color.map { NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: $0.count > 3 ? $0[3] : 1) } ?? NSColor.textColor
        for g in v.glyphs {
            let frame = CGRect(x: r.minX + CGFloat(g.rect.x) * k, y: r.minY + CGFloat(g.rect.y) * k, width: CGFloat(g.rect.width) * k + 2, height: CGFloat(g.rect.height) * k)
            let l = glyphLayers[g.seq] ?? {
                let t = CATextLayer(); t.contentsScale = window?.backingScaleFactor ?? 2; t.alignmentMode = .left
                let line = CALayer(); line.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
                typeaheadLayer.addSublayer(t); typeaheadLayer.addSublayer(line)
                glyphLayers[g.seq] = (t, line); return (t, line)
            }()
            l.text.string = NSAttributedString(string: g.text, attributes: [.font: font, .foregroundColor: color])
            // The line box: the glyph's baseline sits where the font puts it in a line of that height.
            let lineH = font.ascender - font.descender
            l.text.frame = CGRect(x: frame.minX, y: frame.minY + (frame.height - lineH) / 2, width: frame.width, height: lineH + 2)
            l.line.frame = CGRect(x: frame.minX, y: frame.maxY - max(1, k * 2), width: frame.width - 2, height: max(1, k * 2))
            l.line.isHidden = g.confirmed
        }
    }
    private var lastDisplacementCount = 0
    private var lastArrangement = -1
    private var forceRedraw = false

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        CATransaction.commit()
        session?.compositor?.invalidate()
        scheduleStreamRequest()
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true; scheduleStreamRequest() }

    private func scheduleStreamRequest() {
        resizeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sendStreamRequest() }
        resizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: w)
    }

    /// Forget what was requested (back from Unified mode, which asks for its own size).
    func resetStreamRequest() { lastRequested = (0, 0) }
    func sendStreamRequest() {
        guard let session, let model, bounds.width > 0, !model.unified else { return }
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale * model.pixelFactor), h = Int(bounds.height * scale * model.pixelFactor)
        guard (w, h) != lastRequested else { return }
        lastRequested = (w, h)
        session.requestStream(width: w, height: h)
    }

    /// Where the picture actually is inside the view (letterboxed), in points.
    var videoRect: CGRect {
        let b = bounds
        if let comp = session?.compositor, comp.width > 0 { aspect = CGFloat(comp.width) / CGFloat(comp.height) }
        guard b.width > 0, b.height > 0 else { return b }
        if b.width / b.height > aspect {
            let w = b.height * aspect
            return CGRect(x: (b.width - w) / 2, y: 0, width: w, height: b.height)
        } else {
            let h = b.width / aspect
            return CGRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
        }
    }

    private func normalized(_ e: NSEvent) -> (Double, Double) {
        let p = convert(e.locationInWindow, from: nil)
        let r = videoRect
        return (Double((p.x - r.minX) / r.width), Double((p.y - r.minY) / r.height))
    }
    /// Host stream pixel under an event.
    private func streamPixel(_ e: NSEvent) -> (Int, Int)? {
        guard let comp = session?.compositor, comp.width > 0 else { return nil }
        let (x, y) = normalized(e)
        return (Int(x * Double(comp.width)), Int(y * Double(comp.height)))
    }

    // MARK: Cursor

    func updateCursorLayer() {
        guard let model else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let c = model.cursor else { cursorLayer.isHidden = true; return }
        var pos: CGPoint? = nil
        if pointerInside { pos = localPointer }
        else if let rc = model.remoteCursor {
            let r = videoRect
            pos = CGPoint(x: r.minX + rc.x * r.width, y: r.minY + rc.y * r.height)
        }
        guard let pos else { cursorLayer.isHidden = true; return }
        cursorLayer.isHidden = false
        cursorLayer.contents = c.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cursorLayer.frame = CGRect(x: pos.x - c.hotspot.x, y: pos.y - c.hotspot.y, width: c.size.width, height: c.size.height)
    }

    override func cursorUpdate(with event: NSEvent) { blankCursor.set() }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; blankCursor.set(); updateCursorLayer() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; NSCursor.arrow.set(); updateCursorLayer() }

    // MARK: Input forwarding

    private func flags(_ e: NSEvent) -> UInt64 { e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue) }

    private var observeOnly: Bool { model?.observeOnly ?? false }
    private func moved(_ e: NSEvent) {
        localPointer = convert(e.locationInWindow, from: nil)
        pointerInside = bounds.contains(localPointer)
        updateCursorLayer()
        guard !observeOnly else { return }
        let (x, y) = normalized(e)
        session?.sendMouseMove(x: x, y: y)
    }
    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseDragged(with event: NSEvent) {
        if observeOnly { moved(event); return }
        if var ld = layerDrag, let session, let p = streamPixel(event) {
            localPointer = convert(event.locationInWindow, from: nil); updateCursorLayer()
            let dx = p.0 - ld.start.0, dy = p.1 - ld.start.1
            if !ld.moved, abs(dx) < 3, abs(dy) < 3 { return }
            if !ld.moved { ld.moved = true; session.beginLayerDrag(windowID: ld.windowID) }
            layerDrag = ld
            session.dragLayer(windowID: ld.windowID, to: ld.frame.offset(dx, dy))
            return
        }
        // Window drag prediction: translate the window's pixels with the pointer, send the move as usual.
        if let drag, let session, let p = streamPixel(event) {
            self.drag?.last = p
            localPointer = convert(event.locationInWindow, from: nil); updateCursorLayer()
            let (x, y) = normalized(event)
            let seq = session.send(.mouseMove(.init(x: x, y: y)))
            session.dragPointer(windowID: drag.windowID, pointer: p, inputSeq: seq)
            return
        }
        moved(event)
    }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }

    @discardableResult
    private func button(_ e: NSEvent, _ b: Int, down: Bool) -> UInt64 {
        guard !observeOnly else { return 0 }
        let (x, y) = normalized(e)
        return session?.send(.mouseButton(.init(button: b, down: down, x: x, y: y, clickCount: e.clickCount, modifiers: flags(e)))) ?? 0
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        session?.typeaheadInvalidateBeforeClick()
        if let d = drag { session?.endDrag(windowID: d.windowID) }
        drag = nil; layerDrag = nil
        guard !observeOnly else { return }
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if let session, let p = streamPixel(event), let w = session.window(at: p.0, p.1) {
            let ppp = MainActor.assumeIsolated { session.pixelsPerPoint }
            let titleBar = Int(28 * ppp), trafficLights = Int(80 * ppp)
            if w.isLayered {
                // A press on a layered window raises it here at once; on its title bar (right of the traffic
                // lights) it may be a drag: hold the click until the pointer moves or the button is released.
                if plain, event.clickCount == 1, p.1 < w.frame.y + titleBar, p.0 > w.frame.x + trafficLights {
                    layerDrag = (w.id, w.frame, p, false, event)
                    return
                }
                let seq = button(event, 0, down: true)
                if plain, w.windowLevel == 0 { session.localRaise(windowID: w.id, inputSeq: seq) }
                return
            }
            let seq = button(event, 0, down: true)
            // Title-bar hit test on a window the display layer still carries: a plain left press there starts a predicted (copy-rect) drag.
            if plain, event.clickCount == 1, p.1 < w.frame.y + titleBar { drag = (w.id, w.frame, p); session.beginDrag(windowID: w.id, frame: w.frame, pointer: p, inputSeq: seq) }
            return
        }
        button(event, 0, down: true)
    }
    override func mouseUp(with event: NSEvent) {
        if let ld = layerDrag {
            layerDrag = nil
            if ld.moved { session?.endLayerDrag(windowID: ld.windowID) }
            else {
                // It was a click after all: the press goes now, then the release (one RTT later than it could have, invisibly).
                let seq = button(ld.downEvent, 0, down: true)
                session?.localRaise(windowID: ld.windowID, inputSeq: seq)
                button(event, 0, down: false)
            }
            return
        }
        button(event, 0, down: false); if let d = drag { session?.endDrag(windowID: d.windowID) }; drag = nil
    }
    override func rightMouseDown(with event: NSEvent) { button(event, 1, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, 1, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, max(2, event.buttonNumber), down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, max(2, event.buttonNumber), down: false) }

    override func scrollWheel(with event: NSEvent) {
        guard !observeOnly else { return }
        let (x, y) = normalized(event)
        let precise = event.hasPreciseScrollingDeltas
        let dx = precise ? event.scrollingDeltaX : event.deltaX, dy = precise ? event.scrollingDeltaY : event.deltaY
        guard let session else { return }
        let seq = session.send(.scroll(.init(x: x, y: y, dx: dx, dy: dy, precise: precise, modifiers: flags(event))))
        // Scroll prediction: shift the scrollable rect's pixels now; the host's copy-rect confirms it later.
        guard precise, event.modifierFlags.intersection([.command, .option, .control]).isEmpty, let p = streamPixel(event), let w = session.window(at: p.0, p.1) else { return }
        let ppp = MainActor.assumeIsolated { session.pixelsPerPoint }
        let sdx = Int((dx * ppp).rounded()), sdy = Int((dy * ppp).rounded())
        guard sdx != 0 || sdy != 0 else { return }
        let rect = session.scrollRect(for: w, titleBarPx: Int(28 * ppp))
        let lp = w.isLayered ? (p.0 - w.frame.x, p.1 - w.frame.y) : p
        guard rect.contains(lp.0, lp.1) else { return }
        session.predict(kind: .scroll, windowID: w.id, rect: rect, dx: sdx, dy: sdy, inputSeq: seq)
    }

    private func handleLocal(_ e: NSEvent) -> Bool { MainActor.assumeIsolated { LocalShortcuts.handle(e, session: session) } }

    private func key(_ e: NSEvent, down: Bool) {
        guard !observeOnly, let session else { return }
        let seq = session.send(.key(.init(keyCode: e.keyCode, down: down, isRepeat: down && e.isARepeat, modifiers: flags(e),
                                          characters: down ? e.characters : nil)))
        if down { session.typeaheadKey(keyCode: e.keyCode, characters: e.characters, modifiers: e.modifierFlags, seq: seq) }
    }
    override func keyDown(with event: NSEvent) { if !handleLocal(event) { key(event, down: true) } }
    override func keyUp(with event: NSEvent) { if !observeOnly, event.modifierFlags.intersection([.control, .option, .command, .shift]) == [.control, .option, .command] { return }; key(event, down: false) }
    override func flagsChanged(with event: NSEvent) { if !observeOnly { session?.send(.modifiers(.init(keyCode: event.keyCode, modifiers: flags(event)))) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Swallow ⌘-shortcuts so the viewer's own menu does not eat them; forward to the host.
        guard window?.firstResponder === self else { return false }
        if handleLocal(event) { return true }
        if event.type == .keyDown { key(event, down: true) } else if event.type == .keyUp { key(event, down: false) }
        return true
    }
}

struct VideoView: NSViewRepresentable {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel

    func makeNSView(context: Context) -> VideoNSView {
        let v = VideoNSView(frame: .zero)
        v.model = model
        v.attach(session)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ v: VideoNSView, context: Context) {
        v.updateCursorLayer()
        v.sendStreamRequest()
    }
}
