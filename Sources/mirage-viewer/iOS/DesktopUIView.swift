import UIKit
import Metal
import QuartzCore
import CoreText
import MirageCore

/// Presents the session's scene on a CAMetalLayer and turns touches into Mac input, trackpad style: one finger moves
/// the pointer (relative, accelerated), a tap clicks (two taps in a row double-click), two fingers scroll (into the
/// session's scroll prediction, with momentum), a two-finger tap right-clicks, a long press holds the button for a
/// drag (title-bar drags run the window-drag prediction). Typing goes through the on-screen keyboard or a hardware
/// keyboard, both with typeahead. The picture keeps its size when the keyboard shows and lifts so the pointer stays
/// above it.
///
/// Zoom and pan are presentation only (`ZoomViewport`): the stream, and every message to the host, are the same at any
/// zoom. A pinch zooms about its centre (and its fingers' travel pans), from fit up to 1:1 host pixels and beyond; a
/// three-finger drag pans; a two-finger double tap toggles fit and 1:1 there. Zoomed, the view follows the pointer at
/// the edges and, from 1.5×, the caret while typing.
final class DesktopUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let cursorLayer = CALayer()
    private let typeaheadLayer = CALayer()
    private var glyphLayers: [UInt64: (text: CATextLayer, line: CALayer)] = [:]
    var session: ViewerSession?
    var model: ViewerModel?
    private var displayLink: CADisplayLink?
    private var lastRequested = (0, 0)
    private var resizeWork: DispatchWorkItem?
    private var forceRedraw = false
    private var lastDisplacementCount = 0, lastArrangement = -1

    var pointer = TrackpadPointer()
    private var pointerFromHost = false
    private var lastPanTranslation = CGPoint.zero, lastPanTime: CFTimeInterval = 0
    private var lastScrollTranslation = CGPoint.zero
    private var momentum = ScrollMomentum()
    private var lastTap: (time: CFTimeInterval, x: Double, y: Double, count: Int)?
    private var pressLocation = CGPoint.zero
    private var pressing = false
    private var drag: (windowID: UInt32, frame: PixelRect)?
    /// On-screen keyboard: shown on request; sticky modifiers from its accessory bar apply to the next key.
    private var softKeyboard = false
    private var sticky: UInt64 = 0
    private var keyboardHeight: CGFloat = 0
    /// Hardware keyboard: modifier flags held now.
    private var hardwareFlags: UInt64 = 0

    /// Where the picture is drawn: fit, zoom and pan (view points). Never sent anywhere.
    private(set) var viewport = ZoomViewport()
    /// The screen's safe area in this view (SwiftUI passes it in; the view itself covers the whole screen).
    var safeInsets: UIEdgeInsets = .zero { didSet { if safeInsets != oldValue { syncViewport() } } }
    /// What the current two- or three-finger gesture turned out to be: undecided until the fingers either spread
    /// (zoom) or travel together (scroll); three fingers pan the view.
    private enum MultiTouch { case idle, undecided, scroll, zoom, viewPan }
    private var multi = MultiTouch.idle
    private var multiActive = Set<ObjectIdentifier>()
    private weak var pinchRecognizer: UIPinchGestureRecognizer?
    private var pinchBase = 1.0, pinchLast = CGPoint.zero
    private var lastViewPan = CGPoint.zero
    /// A two-finger double tap's animated zoom: from this viewport, about this point, to this zoom.
    private var zoomAnimation: (from: ZoomViewport, anchor: CGPoint, to: Double, start: CFTimeInterval, duration: Double)?
    /// Caret follow: the origin being glided to, and the caret it was computed for.
    private var caretGlide: CGPoint?
    private var lastCaret: PixelRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        cursorLayer.zPosition = 10
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        layer.addSublayer(cursorLayer)
        typeaheadLayer.zPosition = 5
        layer.addSublayer(typeaheadLayer)
        installGestures()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func attach(_ session: ViewerSession) {
        self.session = session
        metalLayer.device = session.compositor?.device ?? session.context?.device
        session.onChange = { [weak self] in DispatchQueue.main.async { self?.forceRedraw = true } }
        if UserDefaults.standard.string(forKey: "demo") != nil { Task { @MainActor in await self.runDemo() } }
    }
    /// Asks the screen to show or hide the on-screen keyboard (its toggle state lives in SwiftUI).
    var onKeyboardRequest: ((Bool) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        DispatchQueue.main.async { self.becomeFirstResponder() }   // hardware keys arrive here; the soft keyboard stays hidden
    }

    // MARK: Presentation

    @objc private func tick(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        if momentum.active { let d = momentum.step(dt: dt); scroll(viewDX: d.dx, viewDY: d.dy) }
        syncViewport()
        stepZoomAnimation()
        followCaret(dt: dt)
        guard let session, let comp = session.compositor, comp.width > 0, let context = session.context else { return }
        guard let scene = session.scene(pxPerPoint: session.pixelsPerPoint) else { return }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        CATransaction.commit()
        session?.compositor?.invalidate()
        forceRedraw = true
        syncViewport()
        updateCursorLayer()
        scheduleStreamRequest()
    }

    /// The container is the safe area; in landscape the picture also takes the full height (nothing sits above it, and
    /// the home indicator floats over it).
    private var containerRect: CGRect {
        var i = safeInsets
        if bounds.width > bounds.height { i.top = 0; i.bottom = 0 }
        return bounds.inset(by: i)
    }

    private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    /// Zoom at which one host display pixel is one device pixel.
    private var oneToOne: Double {
        guard let i = model?.streamInfo, i.displayWidth > 0 else { return 2 }
        return viewport.oneToOneZoom(hostPixelWidth: Double(i.displayWidth) * max(1, i.displayScale), screenScale: Double(screenScale))
    }

    /// Brings the viewport up to date with the container, the keyboard and the stream's size.
    private func syncViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var content = CGSize(width: 16, height: 10)
        if let comp = session?.compositor, comp.width > 0, comp.height > 0 { content = CGSize(width: comp.width, height: comp.height) }
        let before = viewport
        viewport.setLayout(container: containerRect, keyboardTop: keyboardHeight > 0 ? Double(bounds.height - keyboardHeight) : nil, content: content)
        viewport.setZoomRange(oneToOne: oneToOne)
        if viewport != before { viewportChanged() }
    }

    /// Something moved the picture: redraw, and move the overlays with it.
    private func viewportChanged() {
        forceRedraw = true
        updateCursorLayer()
    }

    /// Stops what moves the view by itself (a double tap's zoom, the caret glide) when a person takes over.
    private func stopAutoMotion() { zoomAnimation = nil; caretGlide = nil }

    private func animateZoom(to z: Double, about anchor: CGPoint, duration: Double = 0.25) {
        caretGlide = nil
        zoomAnimation = (viewport, anchor, z, CACurrentMediaTime(), duration)
    }

    private func stepZoomAnimation() {
        guard let a = zoomAnimation else { return }
        let t = min(1, (CACurrentMediaTime() - a.start) / a.duration), e = t * t * (3 - 2 * t)
        var v = a.from
        v.setLayout(container: viewport.container, keyboardTop: viewport.keyboardTop, content: viewport.content)
        v.setZoom(a.from.zoom * pow(a.to / a.from.zoom, e), about: a.anchor)
        viewport = v
        if t >= 1 { zoomAnimation = nil }
        viewportChanged()
    }

    /// Text-entry convenience: from 1.5×, when the caret moves (the host's report or a predicted glyph), glide so it
    /// stays in view above the keyboard. Only on a move: a person panning away is left alone until the next keystroke.
    private func followCaret(dt: Double) {
        guard let session else { return }
        let c = session.typingCaret()
        if c != lastCaret {
            lastCaret = c
            if let c, zoomAnimation == nil, multi == .idle || multi == .undecided {
                caretGlide = viewport.caretTarget(viewport.viewRect(contentRect: CGRect(x: c.x, y: c.y, width: max(1, c.width), height: c.height)))
            }
        }
        guard let target = caretGlide else { return }
        if viewport.glide(toward: target, dt: dt) { caretGlide = nil }
        viewportChanged()
    }

    /// Sent 300 ms after the first call, at the size of that moment: a rotation passes through in-between sizes (new
    /// bounds before the new safe area), each of which would otherwise re-stream. Later calls in the window join it
    /// (SwiftUI calls this on every model update, so restarting the wait could put the request off indefinitely).
    func scheduleStreamRequest() {
        if let r = resizeWork, !r.isCancelled { return }
        let w = DispatchWorkItem { [weak self] in self?.resizeWork = nil; self?.sendStreamRequest() }
        resizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: w)
    }

    /// The stream is the container's pixel size (× the pixel factor); the host fits its display into it. Neither the
    /// keyboard nor zoom and pan change it: a zoomed picture is the same stream drawn larger.
    func sendStreamRequest() {
        guard let session, let model, bounds.width > 0, bounds.height > 0 else { return }
        let c = containerRect, scale = screenScale
        let w = Int(c.width * scale * model.pixelFactor), h = Int(c.height * scale * model.pixelFactor)
        guard w > 0, h > 0, (w, h) != lastRequested else { return }
        lastRequested = (w, h)
        session.requestStream(width: w, height: h)
    }

    /// Where the picture is drawn, in points: fitted into the safe area, zoomed and panned, lifted above the keyboard.
    var videoRect: CGRect { viewport.pictureRect }

    private var pointerInView: CGPoint { viewport.viewPoint(CGPoint(x: pointer.x, y: pointer.y)) }
    private func streamPixel() -> (Int, Int)? {
        guard let comp = session?.compositor, comp.width > 0 else { return nil }
        return (Int(pointer.x * Double(comp.width)), Int(pointer.y * Double(comp.height)))
    }

    // MARK: Cursor

    private static let fallbackCursor: CGImage? = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18))
        return r.image { ctx in
            UIColor.black.withAlphaComponent(0.6).setStroke(); UIColor.white.setFill()
            let p = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 12, height: 12)); p.lineWidth = 2; p.fill(); p.stroke()
        }.cgImage
    }()

    func updateCursorLayer() {
        guard let model else { return }
        if !pointerFromHost, let rc = model.remoteCursor { pointer.x = rc.x; pointer.y = rc.y; pointerFromHost = true }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard session?.compositor?.width ?? 0 > 0 else { cursorLayer.isHidden = true; return }
        let pos = pointerInView
        cursorLayer.isHidden = false
        if let c = model.cursor, let img = c.image.cgImage {
            cursorLayer.contents = img
            cursorLayer.frame = CGRect(x: pos.x - c.hotspot.x, y: pos.y - c.hotspot.y, width: c.size.width, height: c.size.height)
        } else {
            cursorLayer.contents = Self.fallbackCursor
            cursorLayer.frame = CGRect(x: pos.x - 9, y: pos.y - 9, width: 18, height: 18)
        }
    }

    // MARK: Typeahead overlay (as the Mac viewer draws it: predicted glyphs at the predicted caret, underlined until confirmed)

    private func drawTypeahead() {
        guard let session, let comp = session.compositor, comp.width > 0 else { return }
        let v = session.typeaheadSnapshot()
        let r = videoRect, k = r.width / CGFloat(comp.width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let live = Set(v.glyphs.map(\.seq))
        for (seq, l) in glyphLayers where !live.contains(seq) { l.text.removeFromSuperlayer(); l.line.removeFromSuperlayer(); glyphLayers[seq] = nil }
        let pt = CGFloat(v.size) * CGFloat(session.pixelsPerPoint) * k
        let font = v.font.flatMap { UIFont(name: $0, size: pt) } ?? UIFont.systemFont(ofSize: pt)
        let color = v.color.map { UIColor(red: $0[0], green: $0[1], blue: $0[2], alpha: $0.count > 3 ? $0[3] : 1) } ?? .label
        for g in v.glyphs {
            let frame = CGRect(x: r.minX + CGFloat(g.rect.x) * k, y: r.minY + CGFloat(g.rect.y) * k, width: CGFloat(g.rect.width) * k + 2, height: CGFloat(g.rect.height) * k)
            let l = glyphLayers[g.seq] ?? {
                let t = CATextLayer(); t.contentsScale = metalLayer.contentsScale; t.alignmentMode = .left
                let line = CALayer(); line.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
                typeaheadLayer.addSublayer(t); typeaheadLayer.addSublayer(line)
                glyphLayers[g.seq] = (t, line); return (t, line)
            }()
            l.text.font = CTFontCreateWithName(font.fontName as CFString, pt, nil)
            l.text.fontSize = pt
            l.text.foregroundColor = color.cgColor
            l.text.string = g.text
            let lineH = font.ascender - font.descender
            l.text.frame = CGRect(x: frame.minX, y: frame.minY + (frame.height - lineH) / 2, width: frame.width, height: lineH + 2)
            l.line.frame = CGRect(x: frame.minX, y: frame.maxY - max(1, k * 2), width: frame.width - 2, height: max(1, k * 2))
            l.line.isHidden = g.confirmed
        }
    }

    // MARK: Gestures

    private var observeOnly: Bool { model?.observeOnly ?? false }

    private func installGestures() {
        let move = UIPanGestureRecognizer(target: self, action: #selector(movePan(_:)))
        move.minimumNumberOfTouches = 1; move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .continuous   // an iPad trackpad's two-finger scroll too
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(rightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        press.minimumPressDuration = 0.35
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))   // an iPad's mouse or trackpad pointer
        // Presentation only: pinch zooms, three fingers pan the view, a two-finger double tap toggles fit and 1:1.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        pinchRecognizer = pinch
        let viewPan = UIPanGestureRecognizer(target: self, action: #selector(viewPan(_:)))
        viewPan.minimumNumberOfTouches = 3; viewPan.maximumNumberOfTouches = 3
        let zoomTap = UITapGestureRecognizer(target: self, action: #selector(zoomTap(_:)))
        zoomTap.numberOfTouchesRequired = 2; zoomTap.numberOfTapsRequired = 2
        rightTap.require(toFail: zoomTap)   // a right click waits out the double tap (~0.3 s)
        for g in [move, scroll, tap, rightTap, press, hover, pinch, viewPan, zoomTap] as [UIGestureRecognizer] { g.delegate = self; addGestureRecognizer(g) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer { return true }
        // Scroll, pinch and the three-finger pan all see the fingers; `multi` decides which one acts.
        func isMulti(_ r: UIGestureRecognizer) -> Bool {
            r is UIPinchGestureRecognizer || ((r as? UIPanGestureRecognizer).map { $0.minimumNumberOfTouches >= 2 } ?? false)
        }
        return isMulti(g) && isMulti(other)
    }

    /// No system three-finger editing gestures (undo/redo swipes, copy/paste pinches): three fingers pan the view.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    private func multiBegan(_ g: UIGestureRecognizer) {
        if multiActive.isEmpty, multi == .idle { multi = .undecided }
        multiActive.insert(ObjectIdentifier(g))
        stopAutoMotion()
    }
    private func multiEnded(_ g: UIGestureRecognizer) {
        multiActive.remove(ObjectIdentifier(g))
        if multiActive.isEmpty { multi = .idle }
    }

    /// Pinch: once the fingers have spread or closed by 5 % (before travelling together far enough to be a scroll), the
    /// gesture is a zoom about the fingers' centre until they lift, and the centre's travel pans (two fingers after a pinch).
    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        let loc = g.location(in: self)
        switch g.state {
        case .began: multiBegan(g)
        case .changed:
            if multi == .undecided, abs(log(Double(g.scale))) > 0.05 {
                multi = .zoom; momentum.stop()
                pinchBase = viewport.zoom / Double(g.scale); pinchLast = loc
            }
            guard multi == .zoom else { return }
            guard g.numberOfTouches >= 2 else { pinchLast = loc; return }   // a finger lifted: the centre jumps, do not pan
            pinchStep(zoom: pinchBase * Double(g.scale), at: loc)
        default: multiEnded(g)
        }
    }

    /// One step of a pinch (also the demo's): pan by the centre's travel, then zoom about it.
    func pinchStep(zoom z: Double, at loc: CGPoint) {
        viewport.pan(by: CGPoint(x: loc.x - pinchLast.x, y: loc.y - pinchLast.y)); pinchLast = loc
        viewport.setZoom(z, about: loc)
        viewportChanged()
    }

    /// Three fingers: pan the view (presentation only; nothing is sent).
    @objc private func viewPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: multiBegan(g); multi = .viewPan; momentum.stop(); lastViewPan = g.translation(in: self)
        case .changed:
            let t = g.translation(in: self)
            panView(by: CGPoint(x: t.x - lastViewPan.x, y: t.y - lastViewPan.y))
            lastViewPan = t
        default: multiEnded(g)
        }
    }

    func panView(by d: CGPoint) {
        stopAutoMotion()
        viewport.pan(by: d)
        viewportChanged()
    }

    /// Two-finger double tap: fit ↔ 1:1 host pixels at that point.
    @objc private func zoomTap(_ g: UITapGestureRecognizer) { toggleZoom(at: g.location(in: self)) }
    func toggleZoom(at p: CGPoint) {
        momentum.stop()
        animateZoom(to: viewport.toggleTarget(oneToOne: oneToOne), about: p)
    }

    private func movePointer(by d: CGPoint, now: CFTimeInterval) {
        let r = videoRect
        let dt = lastPanTime > 0 ? now - lastPanTime : 0
        lastPanTime = now
        pointer.move(dx: d.x, dy: d.y, pictureWidth: r.width, pictureHeight: r.height, dt: dt)
        followPointer()
        updateCursorLayer()
    }

    /// Pointer follow: zoomed (or lifted above the keyboard), the view pans when the pointer nears its edge.
    func followPointer() {
        let before = viewport.origin
        viewport.follow(pointerInView, margin: keyboardHeight > 0 ? 48 : 40)
        if viewport.origin != before { caretGlide = nil; viewportChanged() }
    }

    @objc private func movePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: momentum.stop(); lastPanTranslation = .zero; lastPanTime = 0
        case .changed:
            let t = g.translation(in: self)
            movePointer(by: CGPoint(x: t.x - lastPanTranslation.x, y: t.y - lastPanTranslation.y), now: CACurrentMediaTime())
            lastPanTranslation = t
            if !observeOnly { session?.sendMouseMove(x: pointer.x, y: pointer.y) }
        default: lastPanTime = 0
        }
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        guard videoRect.width > 0 else { return }
        let n = viewport.normalized(g.location(in: self))
        pointer.x = min(1, max(0, Double(n.x))); pointer.y = min(1, max(0, Double(n.y)))
        updateCursorLayer()
        if !observeOnly { session?.sendMouseMove(x: pointer.x, y: pointer.y) }
    }

    private var modifierFlags: UInt64 { sticky | hardwareFlags }

    @discardableResult
    private func button(_ b: Int, down: Bool, clickCount: Int = 1) -> UInt64 {
        guard !observeOnly, let session else { return 0 }
        return session.send(.mouseButton(.init(button: b, down: down, x: pointer.x, y: pointer.y, clickCount: clickCount, modifiers: modifierFlags)))
    }

    @objc private func tap(_ g: UITapGestureRecognizer) { tapForDemo() }
    func momentumStartForDemo(vy: Double) { momentum.start(vx: 0, vy: vy) }
    func tapForDemo() {
        momentum.stop()
        guard !observeOnly, let session else { return }
        session.typeaheadInvalidateBeforeClick()
        let now = CACurrentMediaTime()
        var count = 1
        if let t = lastTap, now - t.time < 0.45, abs(t.x - pointer.x) < 0.02, abs(t.y - pointer.y) < 0.02 { count = min(3, t.count + 1) }
        lastTap = (now, pointer.x, pointer.y, count)
        let seq = button(0, down: true, clickCount: count)
        if let p = streamPixel(), let w = session.window(at: p.0, p.1), w.isLayered, w.windowLevel == 0, modifierFlags == 0 { session.localRaise(windowID: w.id, inputSeq: seq) }
        button(0, down: false, clickCount: count)
        clearSticky()
    }

    @objc private func rightTap(_ g: UITapGestureRecognizer) {
        momentum.stop()
        session?.typeaheadInvalidateBeforeClick()
        button(1, down: true); button(1, down: false)
        clearSticky()
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        guard !observeOnly, let session else { return }
        let loc = g.location(in: self)
        switch g.state {
        case .began:
            momentum.stop()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            session.typeaheadInvalidateBeforeClick()
            pressing = true; pressLocation = loc; lastPanTime = 0
            let seq = button(0, down: true)
            // A press on a title bar the display layer carries: the drag moves the window's pixels here at once (DESIGN §3.5).
            if let p = streamPixel(), let w = session.window(at: p.0, p.1), !w.isLayered {
                let titleBar = Int(28 * session.pixelsPerPoint)
                if p.1 < w.frame.y + titleBar { drag = (w.id, w.frame); session.beginDrag(windowID: w.id, frame: w.frame, pointer: p, inputSeq: seq) }
            }
        case .changed:
            movePointer(by: CGPoint(x: loc.x - pressLocation.x, y: loc.y - pressLocation.y), now: CACurrentMediaTime())
            pressLocation = loc
            if let d = drag, let p = streamPixel() {
                let seq = session.send(.mouseMove(.init(x: pointer.x, y: pointer.y)))
                session.dragPointer(windowID: d.windowID, pointer: p, inputSeq: seq)
            } else {
                session.sendMouseMove(x: pointer.x, y: pointer.y)
            }
        default:
            guard pressing else { return }
            pressing = false
            button(0, down: false)
            if let d = drag { session.endDrag(windowID: d.windowID) }
            drag = nil
            clearSticky()
        }
    }

    /// Two fingers travelling together scroll the remote content. Until the gesture is decided (they could still spread
    /// into a pinch) nothing is sent; once it is a scroll, the travel so far goes out at once.
    @objc private func scrollPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: multiBegan(g); momentum.stop(); lastScrollTranslation = .zero
        case .changed:
            if g.numberOfTouches >= 3 { multi = .viewPan }
            let t = g.translation(in: self)
            if multi == .undecided {
                let spread = abs(log(Double(pinchRecognizer?.scale ?? 1)))
                if (t.x * t.x + t.y * t.y).squareRoot() > 12, spread < 0.05 { multi = .scroll }
            }
            guard multi == .scroll else { return }
            scroll(viewDX: t.x - lastScrollTranslation.x, viewDY: t.y - lastScrollTranslation.y)
            lastScrollTranslation = t
        case .ended:
            if multi == .scroll { let v = g.velocity(in: self); momentum.start(vx: v.x, vy: v.y) }
            multiEnded(g)
        default: multiEnded(g)
        }
    }

    /// A scroll of `viewDX`, `viewDY` points of finger travel at the pointer: natural scrolling (the content follows the
    /// fingers), sent as precise deltas in host points, and predicted locally like the Mac viewer's trackpad scroll.
    func scroll(viewDX: Double, viewDY: Double) {
        guard !observeOnly, let session, let comp = session.compositor, comp.width > 0 else { return }
        let r = videoRect
        guard r.width > 0 else { return }
        let ppp = session.pixelsPerPoint
        let k = Double(comp.width) / Double(r.width)   // stream pixels per view point
        let dx = viewDX * k / ppp, dy = viewDY * k / ppp
        guard dx != 0 || dy != 0 else { return }
        let seq = session.send(.scroll(.init(x: pointer.x, y: pointer.y, dx: dx, dy: dy, precise: true, modifiers: modifierFlags)))
        guard modifierFlags & (MacKeys.commandFlag | MacKeys.optionFlag | MacKeys.controlFlag) == 0, let p = streamPixel(), let w = session.window(at: p.0, p.1) else { return }
        let sdx = Int((dx * ppp).rounded()), sdy = Int((dy * ppp).rounded())
        guard sdx != 0 || sdy != 0 else { return }
        let rect = session.scrollRect(for: w, titleBarPx: Int(28 * ppp))
        let lp = w.isLayered ? (p.0 - w.frame.x, p.1 - w.frame.y) : p
        guard rect.contains(lp.0, lp.1) else { return }
        session.predict(kind: .scroll, windowID: w.id, rect: rect, dx: sdx, dy: sdy, inputSeq: seq)
    }

    // MARK: Keyboard

    private lazy var noKeyboard = UIView(frame: .zero)
    private lazy var accessoryBar = KeyAccessoryBar(owner: self)
    override var canBecomeFirstResponder: Bool { true }
    /// While the on-screen keyboard is off the view stays first responder (hardware keys arrive here) with an empty input view.
    override var inputView: UIView? { softKeyboard ? nil : noKeyboard }
    override var inputAccessoryView: UIView? { softKeyboard ? accessoryBar : nil }

    func setSoftKeyboard(_ on: Bool) {
        guard on != softKeyboard else { return }
        softKeyboard = on
        if !isFirstResponder { becomeFirstResponder() }
        reloadInputViews()
        if !on { keyboardChanged(height: 0) }
    }

    @objc private func keyboardFrame(_ n: Notification) {
        guard softKeyboard, let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let window else { return }
        let local = convert(f, from: window.screen.coordinateSpace)
        keyboardChanged(height: max(0, bounds.maxY - local.minY))
    }
    @objc private func keyboardHidden(_ n: Notification) { keyboardChanged(height: 0) }

    /// The picture keeps its size; the visible area ends at the keyboard's top, the pointer is kept above it, and the
    /// caret is looked at again (it may now be under the keyboard).
    private func keyboardChanged(height: CGFloat) {
        keyboardHeight = height
        syncViewport()
        if height > 0 { followPointer() }
        lastCaret = nil
        viewportChanged()
    }

    // UITextInputTraits: the host does its own correction; nothing is changed on the way.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark

    var hasText: Bool { true }   // backspace is always delivered
    func insertText(_ text: String) { for ch in text { type(ch) } }
    func deleteBackward() { key(MacKeys.delete, characters: "\u{7F}", flags: modifierFlags); clearSticky() }

    /// A character from the on-screen keyboard: its US-layout key (shift if it takes it), and the character itself.
    private func type(_ ch: Character) {
        let k = MacKeys.key(for: ch)
        let chars = ch == "\n" ? "\r" : String(ch)
        key(k?.keyCode ?? 0, characters: chars, flags: modifierFlags | (k?.shift == true ? MacKeys.shiftFlag : 0))
        clearSticky()
    }

    /// One key press (down, up), with the sticky modifiers pressed around it.
    func key(_ code: UInt16, characters: String?, flags: UInt64) {
        defer { clearSticky() }
        guard !observeOnly, let session else { return }
        let flags = flags | sticky
        let mods: [(UInt64, UInt16)] = [(MacKeys.controlFlag, MacKeys.control), (MacKeys.optionFlag, MacKeys.option), (MacKeys.commandFlag, MacKeys.command)]
        var held: UInt64 = 0
        for (f, c) in mods where sticky & f != 0 { held |= f; session.send(.modifiers(.init(keyCode: c, modifiers: held))) }
        let seq = session.send(.key(.init(keyCode: code, down: true, isRepeat: false, modifiers: flags, characters: characters)))
        session.typeaheadKey(keyCode: code, characters: characters, modifiers: Self.keyModifiers(flags), seq: seq)
        session.send(.key(.init(keyCode: code, down: false, isRepeat: false, modifiers: flags, characters: nil)))
        for (f, c) in mods.reversed() where sticky & f != 0 { held &= ~f; session.send(.modifiers(.init(keyCode: c, modifiers: held))) }
    }

    static func keyModifiers(_ flags: UInt64) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags & MacKeys.shiftFlag != 0 { m.insert(.shift) }
        if flags & MacKeys.controlFlag != 0 { m.insert(.control) }
        if flags & MacKeys.optionFlag != 0 { m.insert(.option) }
        if flags & MacKeys.commandFlag != 0 { m.insert(.command) }
        return m
    }

    func toggleSticky(_ flag: UInt64) { sticky ^= flag; accessoryBar.update(sticky: sticky) }
    private func clearSticky() { if sticky != 0 { sticky = 0; accessoryBar.update(sticky: 0) } }

    // Hardware keyboard: every key by its HID usage, modifiers as flag changes, as a Mac keyboard would send them.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !hardware(presses, down: true) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !hardware(presses, down: false) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !hardware(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    private func hardware(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for p in presses {
            guard let k = p.key, let code = MacKeys.keyCode(hidUsage: k.keyCode.rawValue) else { continue }
            handled = true
            guard !observeOnly, let session else { continue }
            if MacKeys.isModifier(code) {
                let bit: UInt64
                switch code {
                case MacKeys.shift, MacKeys.rightShift: bit = MacKeys.shiftFlag
                case MacKeys.control, MacKeys.rightControl: bit = MacKeys.controlFlag
                case MacKeys.option, MacKeys.rightOption: bit = MacKeys.optionFlag
                case MacKeys.capsLock: bit = MacKeys.capsLockFlag
                default: bit = MacKeys.commandFlag
                }
                if code == MacKeys.capsLock { if down { hardwareFlags ^= bit } } else if down { hardwareFlags |= bit } else { hardwareFlags &= ~bit }
                session.send(.modifiers(.init(keyCode: code, modifiers: hardwareFlags)))
                continue
            }
            var flags: UInt64 = 0
            let m = k.modifierFlags
            if m.contains(.shift) { flags |= MacKeys.shiftFlag }
            if m.contains(.control) { flags |= MacKeys.controlFlag }
            if m.contains(.alternate) { flags |= MacKeys.optionFlag }
            if m.contains(.command) { flags |= MacKeys.commandFlag }
            if m.contains(.alphaShift) { flags |= MacKeys.capsLockFlag }
            let chars = MacKeys.characters(forSpecialKey: code) ?? (k.characters.isEmpty ? nil : k.characters)
            let seq = session.send(.key(.init(keyCode: code, down: down, isRepeat: false, modifiers: flags, characters: down ? chars : nil)))
            if down { session.typeaheadKey(keyCode: code, characters: chars, modifiers: Self.keyModifiers(flags), seq: seq) }
        }
        return handled
    }
}

/// The on-screen keyboard's extra row: keys an iPhone keyboard lacks (Esc, Tab, arrows) and sticky ⌃ ⌥ ⌘ for the next key.
final class KeyAccessoryBar: UIView {
    private weak var owner: DesktopUIView?
    private var buttons: [UIButton] = []
    private var modifierButtons: [(UInt64, UIButton)] = []

    init(owner: DesktopUIView) {
        self.owner = owner
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 46))
        autoresizingMask = .flexibleWidth
        backgroundColor = UIColor(white: 0.12, alpha: 0.92)
        func make(_ title: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
            b.titleLabel?.numberOfLines = 1
            b.setTitleColor(.white, for: .normal)
            b.backgroundColor = UIColor(white: 0.32, alpha: 1)
            b.layer.cornerRadius = 6
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            addSubview(b); buttons.append(b); return b
        }
        _ = make("esc") { [weak self] in self?.owner?.key(MacKeys.escape, characters: "\u{1B}", flags: 0) }
        _ = make("tab") { [weak self] in self?.owner?.key(MacKeys.tab, characters: "\t", flags: 0) }
        for (f, t) in [(MacKeys.controlFlag, "⌃"), (MacKeys.optionFlag, "⌥"), (MacKeys.commandFlag, "⌘")] {
            modifierButtons.append((f, make(t) { [weak self] in self?.owner?.toggleSticky(f) }))
        }
        for (code, t) in [(MacKeys.left, "←"), (MacKeys.up, "↑"), (MacKeys.down, "↓"), (MacKeys.right, "→")] {
            _ = make(t) { [weak self] in self?.owner?.key(code, characters: MacKeys.characters(forSpecialKey: code), flags: 0) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = max(6, safeAreaInsets.left), gap: CGFloat = 6
        let w = (bounds.width - 2 * inset - gap * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        for (i, b) in buttons.enumerated() { b.frame = CGRect(x: inset + CGFloat(i) * (w + gap), y: 5, width: w, height: bounds.height - 10) }
    }

    func update(sticky: UInt64) {
        for (f, b) in modifierButtons { b.backgroundColor = sticky & f != 0 ? .systemBlue : UIColor(white: 0.32, alpha: 1) }
    }
}

// MARK: Demo script

extension DesktopUIView {
    /// Test hook (`-demo 1` launch argument): drives the same pointer, click, scroll, zoom, pan and keyboard paths a
    /// person's touches do, on a fixed timeline, so a simulator run can be watched and screenshotted without a touch
    /// injector. Aimed at the "Mirage Test Bench" window when the host lists one (run the host in input-sink mode:
    /// nothing is injected). Each `demo: shot NAME` log line is followed by `-demoHold` seconds (default 6) of stillness
    /// for a screenshot: portrait-fit, portrait-zoomed-keyboard, landscape.
    func runDemo() async {
        // Also appended to tmp/demo.log in the app's container: a simulator's relayed stderr can lag by many seconds, too
        // late to time screenshots by (`xcrun simctl get_app_container … data`).
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demo.log")
        try? Data().write(to: file)
        func log(_ s: String) {
            session?.log("demo: \(s)")
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data("demo: \(s)\n".utf8)); try? h.close() }
        }
        func pause(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        func describe() -> String {
            let r = viewport.pictureRect
            let v = viewport.visible
            return String(format: "zoom %.2f, picture %.0f,%.0f %.0fx%.0f in %.0fx%.0f, visible y %.0f…%.0f", viewport.zoom, r.minX, r.minY, r.width, r.height, bounds.width, bounds.height, v.minY, v.maxY)
        }
        let hold = Double(UserDefaults.standard.string(forKey: "demoHold") ?? "") ?? 6
        for _ in 0..<300 where (session?.compositor?.width ?? 0) == 0 { await pause(0.1) }
        await pause(3)
        guard let session, let comp = session.compositor, comp.width > 0 else { log("no picture"); return }
        let bench = session.windowsSnapshot().first { $0.title.contains("Mirage Test Bench") && !$0.title.contains("overlay") }
        let target = bench.map { (Double($0.frame.x + $0.frame.width / 2) / Double(comp.width), Double($0.frame.y + $0.frame.height / 3) / Double(comp.height)) } ?? (0.4, 0.4)
        log("moving the pointer to \(target); \(describe()); 1:1 is \(String(format: "%.2f", oneToOne))x, max \(String(format: "%.2f", viewport.maxZoom))x")
        // One finger: 40 small relative moves toward the target, as a pan would deliver them.
        for i in 0..<40 {
            let r = videoRect
            movePointerForDemo(dx: (target.0 - pointer.x) * Double(r.width) / Double(40 - i), dy: (target.1 - pointer.y) * Double(r.height) / Double(40 - i))
            await pause(0.02)
        }
        await pause(1)
        log("tap (click)")
        tapForDemo()
        await pause(1.5)
        log("shot portrait-fit: \(describe())")
        await pause(hold)

        log("two-finger scroll, then momentum")
        for _ in 0..<2 {
            for _ in 0..<50 { scroll(viewDX: 0, viewDY: -2.5); await pause(0.016) }
            momentumStartForDemo(vy: -700)
            await pause(2.5)
        }

        // Pinch out about the caret (else the pointer) to 2.6x in 0.8 s, the fingers' centre drifting up 24 pt as it does.
        let caret = session.typingCaret().map { viewport.viewRect(contentRect: CGRect(x: $0.x, y: $0.y, width: max(1, $0.width), height: $0.height)) }
        let anchor = caret.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointerInView
        log("pinch about \(caret == nil ? "the pointer" : "the caret") at \(Int(anchor.x)),\(Int(anchor.y))")
        pinchLast = anchor
        for i in 1...48 {
            pinchStep(zoom: pow(2.6, Double(i) / 48), at: CGPoint(x: anchor.x, y: anchor.y - Double(i) * 0.5))
            await pause(0.016)
        }
        log("pinched: \(describe())")
        await pause(1.5)
        log("three-finger pan: 90 pt right, then back")
        for _ in 0..<45 { panView(by: CGPoint(x: 2, y: 0)); await pause(0.016) }
        await pause(0.5)
        for _ in 0..<45 { panView(by: CGPoint(x: -2, y: 0)); await pause(0.016) }
        log("panned: \(describe())")
        await pause(1)
        let o = viewport.origin
        log("pointer to the right edge (pointer follow)")
        for _ in 0..<70 { movePointerForDemo(dx: 6, dy: 0); await pause(0.016) }
        log(String(format: "pointer follow moved the view by %.0f pt; ", viewport.origin.x - o.x) + describe())
        await pause(1)

        log("on-screen keyboard")
        onKeyboardRequest?(true)
        await pause(2)
        log("keyboard up: \(describe())")
        for ch in "typed on an iPhone" { insertText(String(ch)); await pause(0.14) }
        await pause(1)
        log("shot portrait-zoomed-keyboard: \(describe()), caret \(session.typingCaret().map { "\($0)" } ?? "none")")
        await pause(hold)
        onKeyboardRequest?(false)
        await pause(1.5)

        toggleZoom(at: pointerInView); await pause(1)
        log("two-finger double tap at the pointer: fit, \(describe())")
        toggleZoom(at: pointerInView); await pause(1)
        log("two-finger double tap: 1:1, \(describe())")
        await pause(1.5)
        toggleZoom(at: pointerInView); await pause(1)
        log("two-finger double tap: fit, \(describe())")

        log("rotate to landscape")
        rotateForDemo(.landscapeRight)
        await pause(5)   // the toolbar hides itself after 3 s
        log("shot landscape: \(describe())")
        await pause(hold)
        pinchLast = CGPoint(x: bounds.midX, y: bounds.midY)
        for i in 1...30 { pinchStep(zoom: pow(1.8, Double(i) / 30), at: pinchLast); await pause(0.016) }
        log("landscape pinched: \(describe())")
        await pause(2)
        rotateForDemo(.portrait)
        await pause(3)
        log("portrait again: \(describe())")
        log("done; typeahead \(session.typeaheadCounts()), predictions \(model?.stats.predictions ?? (0, 0, 0, 0))")
    }

    /// A one-finger pan's relative move (at the slow-speed gain), with the pointer follow and the host message it sends.
    func movePointerForDemo(dx: Double, dy: Double) {
        lastPanTime = 0
        movePointer(by: CGPoint(x: dx, y: dy), now: 0)
        session?.sendMouseMove(x: pointer.x, y: pointer.y)
    }

    func rotateForDemo(_ o: UIInterfaceOrientationMask) {
        window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: o)) { [weak self] e in self?.session?.log("demo: rotation refused: \(e)") }
    }
}
