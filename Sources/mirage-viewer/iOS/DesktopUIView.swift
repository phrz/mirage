import UIKit
import Metal
import QuartzCore
import CoreText
import MirageCore

/// Presents the session's scene on a CAMetalLayer and turns touches into Mac input, in one of two modes (`TouchMode`,
/// switched from the control pill and kept in UserDefaults):
/// - Direct touch (the default; `DirectTouch` decides the gestures from the raw touches): everything happens where the
///   finger is. A tap clicks there (taps in a row double-click); a finger held still for 0.35 s presses the button there
///   (a tinted ring round the pointer while it is down), moving then drags and lifting releases; a one-finger swipe pans
///   the view (presentation only) as a UIScrollView does, because it is one: its pan recognizer, moved onto this view,
///   with its deceleration and its rubber band past the picture's edges (at fit it only rubber-bands); two fingers
///   scroll at the point where they came down (the pointer goes there first); a two-finger tap right-clicks at its
///   centre. The pointer jumps to the touches; there is no relative motion and no edge follow.
/// - Trackpad: one finger moves the pointer (relative, accelerated), a tap clicks (two taps in a row double-click), two
///   fingers scroll at the pointer (with momentum), a two-finger tap right-clicks, a long press holds the button for a
///   drag, and zoomed, the view follows the pointer at the edges.
/// In both, title-bar drags move the window here at once: a window layer moves locally and the host is sent its frame
/// (as the Mac viewer does), a window the display layer carries runs the window-drag prediction; both stay where macOS
/// lets a window go (`WindowDragLimits`). Typing goes through the on-screen keyboard or a hardware keyboard, both with
/// typeahead. The picture keeps its size when the keyboard shows and lifts so the pointer stays above it.
///
/// The stream is the host display at its native pixels (as the Mac viewer's native snap), drawn downscaled at fit with an
/// area filter, so zoom up to 1:1 shows real host pixels, sharp. Zoom and pan are presentation only (`ZoomViewport`):
/// the stream, and every message to the host, are the same at any zoom, orientation or keyboard state. A pinch zooms
/// about its centre (and its fingers' travel pans), from fit up to 1:1 host pixels and beyond; a three-finger drag
/// pans; a two-finger double tap toggles fit and 1:1 there. Zoomed, the view follows the pointer at the edges and,
/// from 1.5×, the caret while typing.
final class DesktopUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIScrollViewDelegate {
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
    private let presenter = ScenePresenter()
    private var forceRedraw: Bool { get { presenter.forceRedraw } set { presenter.forceRedraw = newValue } }

    var pointer = TrackpadPointer()
    private var pointerFromHost = false
    private var lastPanTranslation = CGPoint.zero, lastPanTime: CFTimeInterval = 0
    private var lastScrollTranslation = CGPoint.zero
    private var momentum = ScrollMomentum()
    /// One axis per scroll gesture (vertical, horizontal or, for a clearly diagonal one, free), as a Mac trackpad: what is
    /// sent, its momentum and the local prediction all keep to it.
    private var axisLock = ScrollAxisLock()
    /// Scroll messages sent (the demo reads it): how many, and how many moved each axis.
    private var scrollsSent = (count: 0, dx: 0, dy: 0)
    private var lastTap: (time: CFTimeInterval, x: Double, y: Double, count: Int)?
    private var pressLocation = CGPoint.zero
    private var pressing = false
    private var drag: (windowID: UInt32, frame: PixelRect)?
    /// A press on a window layer's title bar (right of the traffic lights): a local drag once the pointer moves, else the
    /// click goes on release (as the Mac viewer: the press itself never travels while it may be a drag).
    private var layerDrag: (windowID: UInt32, frame: PixelRect, start: (Int, Int), moved: Bool)?
    /// The tinted ring round the pointer while a direct-touch hold keeps the button down.
    private let holdRing = CAShapeLayer()

    /// Direct touch or trackpad; switching ends whatever gesture is in progress.
    var touchMode = TouchMode.stored() { didSet { if touchMode != oldValue { touchModeChanged() } } }
    private var direct = DirectTouch()
    /// The trackpad mode's recognizers (off in direct mode, which reads the raw touches), and direct mode's
    /// scroll-wheel-only one (an iPad's trackpad or mouse wheel scrolls at the pointer).
    private var trackpadRecognizers: [UIGestureRecognizer] = []
    private weak var wheelRecognizer: UIPanGestureRecognizer?
    private var lastWheelTranslation = CGPoint.zero
    /// A three-finger view pan's coast after the fingers lift (view points per second). One finger is the scroll view's.
    private var viewMomentum = ScrollMomentum()
    private var threeFingerPan = false
    /// Direct touch's one-finger pan: a real UIScrollView, so the pan, its deceleration, its rubber band and its spring
    /// back are UIKit's own. Its content is the picture (`zoomView`, the fitted size, at zoomScale = the zoom), its
    /// contentInset the viewport's range (`ZoomViewport.scrollInsets`), its contentOffset −origin. It takes no touches
    /// itself (they all reach this view and `DirectTouch`); its pan recognizer is moved onto this view, held back by
    /// `panGate` until the finger has moved past the tap slop, and refused once a hold or a second finger has begun.
    private let scrollView = UIScrollView()
    private let zoomView = UIView()
    private let panGate = PanGate()
    /// Set while this view moves the scroll view itself (its delegate calls then are echoes, not motion).
    private var pushing = false
    private var pushedFit = CGSize.zero
    /// A touch that stopped a coasting pan is no click (as in any iOS scroll view).
    private var touchStoppedCoast = false
    /// The demo's record of the last one-finger drag (where it was let go, how fast, where UIKit said it would stop).
    fileprivate var demoDrag = DragRecord()
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
    /// The bottom of the control pill (or its handle) in this view: the picture can be panned down until it clears it.
    var topObstruction: CGFloat = 0 { didSet { if topObstruction != oldValue { syncViewport() } } }
    /// What the current two- or three-finger gesture turned out to be: undecided until the fingers either spread
    /// (zoom) or travel together (scroll); three fingers pan the view.
    private enum MultiTouch { case idle, undecided, scroll, zoom, viewPan }
    private var multi = MultiTouch.idle
    /// Trackpad mode's scroll-or-pinch decision (the same rule as direct touch's).
    private var twoFinger: TwoFingerClassifier?
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
        holdRing.zPosition = 9
        holdRing.fillColor = UIColor.systemBlue.withAlphaComponent(0.22).cgColor
        holdRing.strokeColor = UIColor.systemBlue.withAlphaComponent(0.75).cgColor
        holdRing.lineWidth = 2
        holdRing.path = UIBezierPath(ovalIn: CGRect(x: -Self.ringRadius, y: -Self.ringRadius, width: 2 * Self.ringRadius, height: 2 * Self.ringRadius)).cgPath
        holdRing.isHidden = true
        layer.addSublayer(holdRing)
        installScrollView()
        installGestures()
        applyTouchMode()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func attach(_ session: ViewerSession) {
        self.session = session
        metalLayer.device = session.compositor?.device ?? session.context?.device
        session.onChange = { [weak self] in DispatchQueue.main.async { self?.forceRedraw = true } }
        // The host's tunables (DESIGN §3.0): touch thresholds and the zoom limit come from the host, not from this build.
        session.onTunables = { [weak self] t in self?.apply(t) }
        apply(session.tunables)
        if UserDefaults.standard.string(forKey: "demo") != nil { Task { @MainActor in await self.runDemo() } }
    }
    private func apply(_ t: Tunables) {
        t.apply(to: &direct)
        t.apply(to: &viewport)
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
        if touchMode == .direct { perform(direct.tick(time: CACurrentMediaTime())) }
        stepViewMomentum(dt: dt)
        if scrollView.isTracking || scrollView.isDecelerating { pullFromScrollView() }
        syncViewport()
        applyStartZoom()
        stepZoomAnimation()
        followCaret(dt: dt)
        // The scene's presentation is the Mac viewer's too (`ScenePresenter`); the viewport says where the picture goes.
        guard let session else { return }
        if presenter.tick(session, layer: metalLayer, videoRect: videoRect) { drawTypeahead() }
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
        if scrollView.frame != bounds { pushing = true; scrollView.frame = bounds; pushing = false; pushedFit = .zero }
        syncViewport()
        pushViewport()
        updateCursorLayer()
        scheduleStreamRequest()
    }

    /// The container (where the picture is fitted) is the safe area; in landscape the picture also takes the full height
    /// (nothing sits above it, and the home indicator floats over it).
    private var containerRect: CGRect {
        var i = safeInsets
        if bounds.width > bounds.height { i.top = 0; i.bottom = 0 }
        return bounds.inset(by: i)
    }

    /// What nothing covers (but the keyboard): the safe area in either orientation (the Dynamic Island, the home
    /// indicator, the rounded corners), below the control pill. A zoomed picture pans until its edges meet this; the
    /// container alone reached under the pill (portrait and landscape) and under the home indicator (landscape), so the
    /// menu bar's right end and the Dock's bottom could never be uncovered there.
    private var unobstructedRect: CGRect {
        let r = bounds.inset(by: safeInsets)
        let top = min(max(r.minY, topObstruction), r.maxY)
        return CGRect(x: r.minX, y: top, width: r.width, height: r.maxY - top)
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
        viewport.setLayout(container: containerRect, unobstructed: unobstructedRect, keyboardTop: keyboardHeight > 0 ? Double(bounds.height - keyboardHeight) : nil, content: content)
        viewport.setZoomRange(oneToOne: oneToOne)
        if viewport != before { viewportChanged() }
    }

    /// Something moved the picture: redraw, and move the overlays with it (and the scroll view, unless it moved it).
    private func viewportChanged(byScrollView: Bool = false) {
        forceRedraw = true
        updateCursorLayer()
        if !byScrollView { pushViewport() }
    }

    /// Stops what moves the view by itself (a double tap's zoom, the caret glide, a coast) when a person takes over.
    private func stopAutoMotion() { zoomAnimation = nil; caretGlide = nil; viewMomentum.stop(); stopScrollPhysics() }

    /// A three-finger pan's coast (one finger's is the scroll view's).
    private func stepViewMomentum(dt: Double) {
        guard viewMomentum.active else { return }
        let d = viewMomentum.step(dt: dt), before = viewport.origin
        viewport.pan(by: CGPoint(x: d.dx, y: d.dy))
        if viewport.origin == before { viewMomentum.stop() }   // at the edge: nothing left to coast
        caretGlide = nil
        viewportChanged()
    }

    // MARK: The scroll view (direct touch's one-finger pan)

    private func installScrollView() {
        let s = scrollView
        s.isUserInteractionEnabled = false   // every touch reaches this view; only its pan recognizer works here
        s.backgroundColor = .clear
        s.contentInsetAdjustmentBehavior = .never
        s.automaticallyAdjustsScrollIndicatorInsets = false
        s.showsHorizontalScrollIndicator = false; s.showsVerticalScrollIndicator = false
        s.decelerationRate = .normal
        s.bounces = true; s.alwaysBounceHorizontal = true; s.alwaysBounceVertical = true   // at fit it still gives, and returns
        s.bouncesZoom = false
        s.scrollsToTop = false
        s.delegate = self
        zoomView.isUserInteractionEnabled = false
        zoomView.backgroundColor = .clear
        s.addSubview(zoomView)
        insertSubview(s, at: 0)
        let pan = s.panGestureRecognizer
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false   // DirectTouch keeps seeing the finger (and decides tap, hold, pan, two fingers)
        pan.delaysTouchesEnded = false
        pan.allowedScrollTypesMask = []    // an iPad trackpad's scroll scrolls the Mac (the wheel recognizer), never the view
        addGestureRecognizer(pan)
        panGate.slop = direct.slop
        panGate.delegate = self
        addGestureRecognizer(panGate)
        pan.require(toFail: panGate)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomView }

    /// The viewport as the scroll view's zoom, content, insets and offset (no-op when they already match).
    private func pushViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let s = scrollView
        pushing = true; defer { pushing = false }
        s.minimumZoomScale = min(viewport.minZoom, viewport.zoom)
        s.maximumZoomScale = max(viewport.maxZoom, viewport.zoom)
        s.pinchGestureRecognizer?.isEnabled = false   // the pinch is DirectTouch's (scroll unless they clearly pinch)
        let fit = viewport.fitSize
        if fit != pushedFit {
            s.zoomScale = 1
            zoomView.transform = .identity
            zoomView.frame = CGRect(origin: .zero, size: fit)
            s.contentSize = fit
            pushedFit = fit
        }
        if abs(s.zoomScale - viewport.zoom) > 1e-9 { s.zoomScale = viewport.zoom }
        let i = viewport.scrollInsets(viewSize: bounds.size)
        let inset = UIEdgeInsets(top: i.top, left: i.left, bottom: i.bottom, right: i.right)
        if s.contentInset != inset { s.contentInset = inset }
        let offset = CGPoint(x: -viewport.origin.x, y: -viewport.origin.y)
        // UIKit rounds offsets to device pixels: a smaller difference is that rounding, not a move.
        if abs(s.contentOffset.x - offset.x) > 0.25 || abs(s.contentOffset.y - offset.y) > 0.25 { s.setContentOffset(offset, animated: false) }
    }

    /// The scroll view moved the picture (a drag, its deceleration, its rubber band springing back).
    private func pullFromScrollView() {
        let o = CGPoint(x: -scrollView.contentOffset.x, y: -scrollView.contentOffset.y)
        guard o != viewport.origin else { return }
        viewport.scrolled(to: o)
        viewportChanged(byScrollView: true)
    }

    func scrollViewDidScroll(_ s: UIScrollView) { if !pushing { pullFromScrollView() } }

    func scrollViewWillBeginDragging(_ s: UIScrollView) {
        momentum.stop(); zoomAnimation = nil; caretGlide = nil; viewMomentum.stop()
        demoDrag.began(at: s.contentOffset)
    }
    func scrollViewWillEndDragging(_ s: UIScrollView, withVelocity v: CGPoint, targetContentOffset t: UnsafeMutablePointer<CGPoint>) {
        demoDrag.ended(at: s.contentOffset, velocity: v, target: t.pointee)
    }

    /// Whether the scroll view holds the picture past its range (its rubber band).
    private var scrollOutOfRange: Bool {
        let r = viewport.originRange, o = viewport.origin
        return o.x < r.x.lowerBound - 0.5 || o.x > r.x.upperBound + 0.5 || o.y < r.y.lowerBound - 0.5 || o.y > r.y.upperBound + 0.5
    }

    /// Stops the scroll view's coast (where it is) and any rubber band (back in range at once): something else moves the view now.
    private func stopScrollPhysics() {
        guard scrollView.isDecelerating || scrollOutOfRange else { return }
        pushing = true; scrollView.setContentOffset(scrollView.contentOffset, animated: false); pushing = false
        pullFromScrollView()
        viewport.clamp()
        viewportChanged()
    }

    /// Ends the scroll view's drag (a second finger came down: two fingers scroll or pinch from here).
    private func cancelScrollPan() {
        let p = scrollView.panGestureRecognizer
        guard p.state == .began || p.state == .changed else { return }
        p.isEnabled = false; p.isEnabled = touchMode == .direct
    }

    /// Settings › Display › On Connect: 1:1 host pixels (from the top-left, where the menu bar starts) instead of fit, once
    /// per session, when the first picture's size is known.
    private var startZoomApplied = false
    private func applyStartZoom() {
        guard !startZoomApplied, model?.streamInfo != nil, let c = session?.compositor, c.width > 0 else { return }
        startZoomApplied = true
        guard UserDefaults.standard.bool(forKey: ViewerSettings.startAtOneToOneKey) else { return }
        animateZoom(to: oneToOne, about: CGPoint(x: containerRect.minX, y: containerRect.minY), duration: 0.3)
    }

    private func animateZoom(to z: Double, about anchor: CGPoint, duration: Double = 0.25) {
        caretGlide = nil
        stopScrollPhysics()
        zoomAnimation = (viewport, anchor, z, CACurrentMediaTime(), duration)
    }

    private func stepZoomAnimation() {
        guard let a = zoomAnimation else { return }
        let t = min(1, (CACurrentMediaTime() - a.start) / a.duration), e = t * t * (3 - 2 * t)
        var v = a.from
        v.setLayout(container: viewport.container, unobstructed: viewport.unobstructed, keyboardTop: viewport.keyboardTop, content: viewport.content)
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

    /// Native stream (the default, as the Mac viewer's native snap): the host's display at its own pixels, whatever this
    /// screen's size or orientation. `-nativeStream 0` (launch argument or default) asks for the old fit-sized stream.
    static var nativeStream: Bool { UserDefaults.standard.object(forKey: "nativeStream") as? Bool ?? true }

    /// Sent 300 ms after the first call, at the size of that moment: a rotation passes through in-between sizes (new
    /// bounds before the new safe area), each of which would otherwise re-stream a fit-sized stream. Later calls in the
    /// window join it (SwiftUI calls this on every model update, so restarting the wait could put the request off
    /// indefinitely). A native stream's request never changes, so it goes out once.
    func scheduleStreamRequest() {
        if let r = resizeWork, !r.isCancelled { return }
        let w = DispatchWorkItem { [weak self] in self?.resizeWork = nil; self?.sendStreamRequest() }
        resizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: w)
    }

    /// The stream size this view asks for. Native: a box no display exceeds, which the host resolves to its display's own
    /// pixels (StreamScale.nativeRequest), so zoom up to 1:1 is sharp and fit is that stream drawn smaller (an area
    /// filter, no shimmer); it depends on nothing here, so rotation, the keyboard, zoom and pan never re-stream. Fit (the
    /// old stream): the container's pixel size × the pixel factor, which a rotation changes.
    func wantedStreamSize() -> (Int, Int)? {
        if Self.nativeStream { return StreamScale.nativeRequest }
        guard let model, bounds.width > 0, bounds.height > 0 else { return nil }
        let c = containerRect, scale = screenScale
        let w = Int(c.width * scale * model.pixelFactor), h = Int(c.height * scale * model.pixelFactor)
        return w > 0 && h > 0 ? (w, h) : nil
    }

    func sendStreamRequest() {
        guard let session, let (w, h) = wantedStreamSize(), (w, h) != lastRequested else { return }
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

    static let ringRadius: CGFloat = 22

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
        guard session?.compositor?.width ?? 0 > 0 else { cursorLayer.isHidden = true; holdRing.isHidden = true; return }
        let pos = pointerInView
        holdRing.position = pos
        holdRing.isHidden = !(pressing && touchMode == .direct)
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
        // Direct mode: no touches, only an iPad trackpad's or mouse's scroll events (scrolling at the pointer).
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheel(_:)))
        wheel.allowedTouchTypes = []
        wheel.allowedScrollTypesMask = .all
        wheelRecognizer = wheel
        trackpadRecognizers = [move, scroll, tap, rightTap, press, pinch, viewPan, zoomTap]
        for g in [move, scroll, tap, rightTap, press, hover, pinch, viewPan, zoomTap, wheel] as [UIGestureRecognizer] { g.delegate = self; addGestureRecognizer(g) }
    }

    /// Turns the trackpad recognizers on or off for the mode (direct mode reads the raw touches itself).
    private func applyTouchMode() {
        for g in trackpadRecognizers { g.isEnabled = touchMode == .trackpad }
        wheelRecognizer?.isEnabled = touchMode == .direct
        scrollView.isScrollEnabled = touchMode == .direct   // its pan recognizer: direct touch's one-finger pan
        panGate.isEnabled = touchMode == .direct
    }

    private func touchModeChanged() {
        perform(direct.cancel())
        if pressing { pressEnded() }
        momentum.stop(); viewMomentum.stop(); stopScrollPhysics()
        multi = .idle; multiActive.removeAll()
        applyTouchMode()
        updateCursorLayer()
        session?.log("touch mode: \(touchMode.rawValue)")
    }

    // MARK: Direct touch

    private func touchID(_ t: UITouch) -> Int { ObjectIdentifier(t).hashValue }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchMode == .direct else { super.touchesBegan(touches, with: event); return }
        let now = CACurrentMediaTime()
        // A finger on a coasting view stops it there (and is no click), as in any scroll view; a rubber band finishes.
        if direct.touchCount == 0 { touchStoppedCoast = false }
        if scrollView.isDecelerating, !scrollOutOfRange { stopScrollPhysics(); touchStoppedCoast = true }
        for t in touches { perform(direct.began(touchID(t), at: t.location(in: self), time: now)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchMode == .direct else { super.touchesMoved(touches, with: event); return }
        let now = CACurrentMediaTime()
        for t in touches { perform(direct.moved(touchID(t), to: t.location(in: self), time: now)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchMode == .direct else { super.touchesEnded(touches, with: event); return }
        let now = CACurrentMediaTime()
        for t in touches { perform(direct.ended(touchID(t), at: t.location(in: self), time: now)) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchMode == .direct else { super.touchesCancelled(touches, with: event); return }
        perform(direct.cancel())
    }

    /// Carries out what the direct-touch gestures decided. Every Mac action first puts the pointer where it applies.
    private func perform(_ actions: [DirectTouch.Action]) {
        for a in actions {
            switch a {
            case .click(let p, let n):
                guard !touchStoppedCoast else { continue }
                jumpPointer(to: p); click(count: n)
            case .holdBegan(let p):
                panGate.hold()   // no pan from here: the finger drags what it holds
                jumpPointer(to: p); pressBegan()
            case .holdMoved(let p):
                jumpPointer(to: p, send: false); pressMoved()
            case .holdEnded(let p):
                jumpPointer(to: p, send: false); pressEnded()
            case .rightClick(let p):
                jumpPointer(to: p); rightClick()
            case .scrollBegan(let p):
                momentum.stop(); stopAutoMotion(); jumpPointer(to: p); axisLock.begin()
            case .scroll(let dx, let dy):
                scroll(viewDX: dx, viewDY: dy)
            case .scrollEnded(let vx, let vy):
                scrollEnded(vx: vx, vy: vy)
            case .pinchBegan(let p):
                momentum.stop(); stopAutoMotion(); pinchBase = viewport.zoom; pinchLast = p
            case .pinch(let s, let p):
                pinchStep(zoom: pinchBase * s, at: p)
            case .pinchEnded:
                break
            case .pan(let dx, let dy):
                // One finger: the scroll view pans (its recognizer sees the same finger). Three: the view pans here.
                guard case .multi(.viewPan) = direct.phase else { continue }
                momentum.stop(); stopAutoMotion(); threeFingerPan = true
                viewport.pan(by: CGPoint(x: dx, y: dy))
                viewportChanged()
            case .panEnded(let vx, let vy):
                if threeFingerPan { threeFingerPan = false; viewMomentum.start(vx: vx, vy: vy) }
                else if direct.touchCount >= 2 { cancelScrollPan() }   // a second finger: it scrolls or pinches now
            case .zoomToggle(let p):
                toggleZoom(at: p)
            }
        }
    }

    /// Direct touch: the pointer jumps to a view point (clamped to the picture), and the host is told unless `send` is false.
    private func jumpPointer(to p: CGPoint, send: Bool = true) {
        let n = viewport.normalized(p)
        pointer.x = min(1, max(0, Double(n.x))); pointer.y = min(1, max(0, Double(n.y)))
        updateCursorLayer()
        if send, !observeOnly { session?.sendMouseMove(x: pointer.x, y: pointer.y) }
    }

    /// Direct mode's iPad trackpad or mouse wheel: scrolls at the pointer (where the hover put it).
    @objc private func wheel(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: momentum.stop(); lastWheelTranslation = .zero; axisLock.begin()
        case .changed:
            let t = g.translation(in: self)
            scroll(viewDX: t.x - lastWheelTranslation.x, viewDY: t.y - lastWheelTranslation.y)
            lastWheelTranslation = t
        case .ended: let v = g.velocity(in: self); scrollEnded(vx: v.x, vy: v.y)
        default: break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer { return true }
        if g === panGate || other === panGate { return true }   // it only ever holds the scroll view's pan back
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
        if multiActive.isEmpty { multi = .idle; twoFinger = nil }
    }

    /// Trackpad mode, two fingers undecided: the same scroll-or-pinch rule as direct touch (`TwoFingerClassifier`: a
    /// scroll unless they clearly pinch), fed from whichever recognizer saw them move. The decision holds until they lift.
    private func classifyTwoFingers(_ g: UIGestureRecognizer) {
        guard multi == .undecided, g.numberOfTouches == 2 else { return }
        let a = g.location(ofTouch: 0, in: self), b = g.location(ofTouch: 1, in: self)
        guard var k = twoFinger else { var n = TwoFingerClassifier(a, b); session?.tunables.apply(to: &n); twoFinger = n; return }
        let d = k.update(a, b, time: CACurrentMediaTime())
        twoFinger = k
        switch d {
        case .undecided: break
        case .scroll: multi = .scroll
        case .pinch:
            multi = .zoom; momentum.stop()
            // The zoom follows the fingers from here: no jump for the travel it took to decide.
            if let p = pinchRecognizer { pinchBase = viewport.zoom / Double(p.scale); pinchLast = p.location(in: self) }
        }
    }

    /// Pinch: once the fingers clearly pinch (`classifyTwoFingers`), the gesture is a zoom about the fingers' centre until
    /// they lift, and the centre's travel pans (two fingers after a pinch).
    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        let loc = g.location(in: self)
        switch g.state {
        case .began: multiBegan(g); classifyTwoFingers(g)
        case .changed:
            classifyTwoFingers(g)
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
        case .began:
            multiBegan(g); lastViewPan = g.translation(in: self)
            if multi == .undecided { multi = .viewPan; momentum.stop() }   // a decided scroll or pinch holds until the fingers lift
        case .changed:
            guard multi == .viewPan else { return }
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
        guard touchMode == .trackpad else { return }   // direct touch: the view moves only when a person moves it
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
    func momentumStartForDemo(vy: Double) { scrollEnded(vx: 0, vy: vy) }
    /// Trackpad mode's tap: a click at the pointer (taps in a row at the same place double- and triple-click).
    func tapForDemo() {
        let now = CACurrentMediaTime()
        var count = 1
        if let t = lastTap, now - t.time < 0.45, abs(t.x - pointer.x) < 0.02, abs(t.y - pointer.y) < 0.02 { count = min(3, t.count + 1) }
        lastTap = (now, pointer.x, pointer.y, count)
        click(count: count)
    }

    /// A left click at the pointer; a click in a window layer brings it to the front here at once.
    private func click(count: Int) {
        momentum.stop()
        guard !observeOnly, let session else { return }
        session.typeaheadInvalidateBeforeClick()
        let seq = button(0, down: true, clickCount: count)
        if let p = streamPixel(), let id = session.press(at: p.0, p.1, plain: modifierFlags == 0).raises { session.localRaise(windowID: id, inputSeq: seq) }
        button(0, down: false, clickCount: count)
        clearSticky()
    }

    @objc private func rightTap(_ g: UITapGestureRecognizer) { rightClick() }
    private func rightClick() {
        momentum.stop()
        session?.typeaheadInvalidateBeforeClick()
        button(1, down: true); button(1, down: false)
        clearSticky()
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        let loc = g.location(in: self)
        switch g.state {
        case .began:
            pressLocation = loc
            pressBegan()
        case .changed:
            guard pressing else { return }
            movePointer(by: CGPoint(x: loc.x - pressLocation.x, y: loc.y - pressLocation.y), now: CACurrentMediaTime())
            pressLocation = loc
            pressMoved()
        default:
            pressEnded()
        }
    }

    /// The button goes down at the pointer (a long press, a direct-touch hold). On a title bar the drag that may follow
    /// moves the window here at once: a window layer locally, its press held back until it is clearly a click (as the Mac
    /// viewer does); a window the display layer carries through the window-drag prediction (DESIGN §3.5).
    private func pressBegan() {
        guard !observeOnly, let session else { return }
        momentum.stop()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.typeaheadInvalidateBeforeClick()
        pressing = true; lastPanTime = 0
        defer { updateCursorLayer() }   // the hold ring
        guard let p = streamPixel() else { button(0, down: true); return }
        // The same rule as the Mac viewer (`WindowHitTest`): the overlay is never hit, only a plain press raises or drags.
        let target = session.press(at: p.0, p.1, plain: modifierFlags == 0)
        switch target {
        case .layerTitleBar(let id, let frame):
            layerDrag = (id, frame, p, false)
        case .displayTitleBar(let id, let frame):
            let seq = button(0, down: true)
            drag = (id, frame); session.beginDrag(windowID: id, frame: frame, pointer: p, inputSeq: seq)
        default:
            let seq = button(0, down: true)
            if let id = target.raises { session.localRaise(windowID: id, inputSeq: seq) }
        }
    }

    /// The pointer moved (already updated) with the button down.
    private func pressMoved() {
        guard pressing, !observeOnly, let session else { return }
        if var ld = layerDrag, let p = streamPixel() {
            let dx = p.0 - ld.start.0, dy = p.1 - ld.start.1
            if !ld.moved {
                guard abs(dx) >= 3 || abs(dy) >= 3 else { return }
                ld.moved = true; layerDrag = ld
                session.beginLayerDrag(windowID: ld.windowID)
            }
            session.dragLayer(windowID: ld.windowID, to: ld.frame.offset(dx, dy))   // held where macOS lets a window go
            return
        }
        if let d = drag, let p = streamPixel() {
            let seq = session.send(.mouseMove(.init(x: pointer.x, y: pointer.y)))
            session.dragPointer(windowID: d.windowID, pointer: p, inputSeq: seq)
        } else {
            session.sendMouseMove(x: pointer.x, y: pointer.y)
        }
    }

    /// The button comes up at the pointer; a held-back title-bar press that never moved goes out as a click now.
    private func pressEnded() {
        guard pressing else { return }
        pressing = false
        defer { updateCursorLayer(); clearSticky() }
        guard let session, !observeOnly else { layerDrag = nil; drag = nil; return }
        if let ld = layerDrag {
            layerDrag = nil
            if ld.moved { session.endLayerDrag(windowID: ld.windowID) }
            else {
                let seq = button(0, down: true)
                session.localRaise(windowID: ld.windowID, inputSeq: seq)
                button(0, down: false)
            }
            return
        }
        button(0, down: false)
        if let d = drag { session.endDrag(windowID: d.windowID) }
        drag = nil
    }

    /// Two fingers scroll the remote content unless they clearly pinch. Until the gesture is decided nothing is sent; once
    /// it is a scroll, the travel so far goes out at once.
    @objc private func scrollPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: multiBegan(g); momentum.stop(); lastScrollTranslation = .zero; axisLock.begin(); classifyTwoFingers(g)
        case .changed:
            if g.numberOfTouches >= 3, multi == .undecided { multi = .viewPan }
            classifyTwoFingers(g)
            let t = g.translation(in: self)
            guard multi == .scroll else { return }
            scroll(viewDX: t.x - lastScrollTranslation.x, viewDY: t.y - lastScrollTranslation.y)
            lastScrollTranslation = t
        case .ended:
            if multi == .scroll { let v = g.velocity(in: self); scrollEnded(vx: v.x, vy: v.y) }
            multiEnded(g)
        default: multiEnded(g)
        }
    }

    /// The fingers lifted: travel the axis lock still held goes out, and the momentum keeps to the gesture's axis.
    private func scrollEnded(vx: Double, vy: Double) {
        let e = axisLock.end(vx: vx, vy: vy, time: CACurrentMediaTime())
        if let f = e.flush { send(scrollViewDX: f.dx, viewDY: f.dy) }
        momentum.start(vx: e.velocity.vx, vy: e.velocity.vy)
    }

    /// A scroll of `viewDX`, `viewDY` points of finger travel (or momentum) at the pointer, kept to the gesture's axis
    /// (`axisLock`; the first ~10 pt decide it, a 250 ms pause starts a new gesture).
    func scroll(viewDX: Double, viewDY: Double) {
        guard let d = axisLock.filter(dx: viewDX, dy: viewDY, time: CACurrentMediaTime()) else { return }
        send(scrollViewDX: d.dx, viewDY: d.dy)
    }

    /// Natural scrolling (the content follows the fingers), sent as precise deltas in host points, and predicted locally
    /// like the Mac viewer's trackpad scroll, along the same axis as what is sent.
    private func send(scrollViewDX viewDX: Double, viewDY: Double) {
        guard !observeOnly, let session, let comp = session.compositor, comp.width > 0 else { return }
        let r = videoRect
        guard r.width > 0 else { return }
        let ppp = session.pixelsPerPoint
        let k = Double(comp.width) / Double(r.width)   // stream pixels per view point
        let dx = viewDX * k / ppp, dy = viewDY * k / ppp
        guard dx != 0 || dy != 0 else { return }
        scrollsSent.count += 1; scrollsSent.dx += dx != 0 ? 1 : 0; scrollsSent.dy += dy != 0 ? 1 : 0
        let seq = session.send(.scroll(.init(x: pointer.x, y: pointer.y, dx: dx, dy: dy, precise: true, modifiers: modifierFlags)))
        guard modifierFlags & (MacKeys.commandFlag | MacKeys.optionFlag | MacKeys.controlFlag) == 0, let p = streamPixel(), let w = session.window(at: p.0, p.1) else { return }
        let sdx = Int((dx * ppp).rounded()), sdy = Int((dy * ppp).rounded())
        guard sdx != 0 || sdy != 0 else { return }
        // Only over the host's scroll rect (as the Mac viewer): a guessed one predicted the whole window body moving.
        let lp = w.isLayered ? (p.0 - w.frame.x, p.1 - w.frame.y) : p
        guard let rect = session.knownScrollRect(for: w), rect.contains(lp.0, lp.1) else { return }
        session.predict(kind: .scroll, windowID: w.id, rect: rect, dx: sdx, dy: sdy, inputSeq: seq)
    }

    // MARK: Keyboard

    private lazy var noKeyboard = UIView(frame: .zero)
    private lazy var accessoryBar = KeyAccessoryBar(owner: self)
    override var canBecomeFirstResponder: Bool { true }
    /// While the on-screen keyboard is off the view stays first responder (hardware keys arrive here) with an empty input view.
    override var inputView: UIView? { softKeyboard ? nil : noKeyboard }
    override var inputAccessoryView: UIView? { softKeyboard && accessoryRow ? accessoryBar : nil }
    /// Settings › Input › Keyboard Accessory Row: esc, tab, ⌃⌥⌘ and the arrows above the on-screen keyboard.
    var accessoryRow = true { didSet { if accessoryRow != oldValue, softKeyboard { reloadInputViews() } } }

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

/// Holds the scroll view's pan back until DirectTouch would call the touch a pan: the finger has moved past the tap
/// slop before the hold began, alone. It fails then (the pan may begin: `require(toFail:)`), and recognizes (the pan
/// never begins) when a hold begins (`hold()`) or a second finger comes down first. It never cancels or delays a touch:
/// DirectTouch sees every one.
final class PanGate: UIGestureRecognizer {
    var slop: CGFloat = 10
    private var start: CGPoint?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { return }
        if start != nil || touches.count > 1 { state = .ended; return }   // two fingers: they scroll or pinch
        start = touches.first?.location(in: view)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let s = start, let p = touches.first?.location(in: view) else { return }
        if hypot(p.x - s.x, p.y - s.y) > slop { state = .failed }   // a pan: the scroll view takes it from here
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { if state == .possible { state = .failed } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { if state == .possible { state = .failed } }
    /// DirectTouch's hold began: the finger drags what it holds, the view stays.
    func hold() { if state == .possible { state = .ended } }
    override func reset() { start = nil }
}

/// The demo's view of one drag of the scroll view: where it was let go and how fast, where UIKit said it would come to
/// rest (`targetContentOffset`), and how far past the picture's range the rubber band went.
struct DragRecord {
    var count = 0
    var start = CGPoint.zero, lift = CGPoint.zero, velocity = CGPoint.zero, target = CGPoint.zero
    var liftTime = 0.0, ended = false
    mutating func began(at o: CGPoint) { count += 1; start = o; ended = false }
    mutating func ended(at o: CGPoint, velocity v: CGPoint, target t: CGPoint) { lift = o; velocity = v; target = t; liftTime = CACurrentMediaTime(); ended = true }
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
    /// for a screenshot: portrait-fit, portrait-zoomed-keyboard, one-to-one, landscape.
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
        if UserDefaults.standard.string(forKey: "demo") == "pan" { await runPanDemo(log: log, describe: describe, hold: hold); return }
        if touchMode == .direct { await runDirectDemo(bench: bench, log: log, describe: describe, hold: hold); return }
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
        log("shot one-to-one: two-finger double tap: 1:1, \(describe())")
        await pause(hold)
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

    /// Direct touch's demo (the default mode; `-touchMode trackpad` runs the one above): the same raw-touch path a finger
    /// takes, through `DirectTouch`. Shots: direct-hold (the ring round the pointer while a hold keeps the button down),
    /// direct-drag-clamped (the bench's title bar dragged far above the display, held at the menu bar), direct-drag-shadow
    /// (the bench mid-drag, its shadow attached; a second bench, `--still --index 10`, behind it shows the shadow).
    func runDirectDemo(bench: ControlMessage.WindowInfo?, log: (String) -> Void, describe: () -> String, hold: Double) async {
        func pause(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        guard let session, let comp = session.compositor, comp.width > 0 else { return }
        // The largest bench window (a `--still` one behind it has the same title).
        let bench = session.windowsSnapshot().filter { $0.title.contains("Mirage Test Bench") && !$0.title.contains("overlay") }.max { $0.frame.area < $1.frame.area } ?? bench
        func view(_ x: Int, _ y: Int) -> CGPoint { viewport.viewPoint(CGPoint(x: Double(x) / Double(comp.width), y: Double(y) / Double(comp.height))) }
        func now() -> Double { CACurrentMediaTime() }
        func down(_ id: Int, _ p: CGPoint) { perform(direct.began(id, at: p, time: now())) }
        func move(_ id: Int, _ p: CGPoint) { perform(direct.moved(id, to: p, time: now())) }
        func up(_ id: Int, _ p: CGPoint) { perform(direct.ended(id, at: p, time: now())) }
        func benchFrame() -> PixelRect? { bench.flatMap { b in session.arrangedWindows().first { $0.id == b.id }?.frame } }
        let ppp = session.pixelsPerPoint
        let f0 = benchFrame() ?? PixelRect(x: comp.width / 4, y: comp.height / 4, width: comp.width / 2, height: comp.height / 2)
        // A point of the bench at height `y` that no other window covers (the person's own windows may be in front of
        // it: they are black in the picture but still take the clicks), from the right.
        func benchX(atY y: Int) -> Int {
            guard let id = bench?.id else { return f0.x + f0.width / 2 }
            for x in stride(from: f0.maxX - Int(100 * ppp), to: f0.x + Int(100 * ppp), by: -Int(20 * ppp)) where session.window(at: x, y)?.id == id { return x }
            return f0.x + f0.width / 2
        }
        let body = view(benchX(atY: f0.y + f0.height / 2), f0.y + f0.height / 2)
        log("direct touch: picture \(comp.width)x\(comp.height) at \(String(format: "%.2f", ppp)) px/pt, bench \(f0), body at \(Int(body.x)),\(Int(body.y)); \(describe())")

        log("tap (click) on the bench")
        down(1, body); await pause(0.08); up(1, body)
        log(String(format: "pointer %.3f,%.3f after the tap", pointer.x, pointer.y))
        await pause(1)

        let spot = CGPoint(x: body.x - 20, y: body.y + 30)
        log("two-finger swipe at \(Int(spot.x)),\(Int(spot.y)) (the pointer goes there first)")
        down(1, CGPoint(x: spot.x - 18, y: spot.y)); down(2, CGPoint(x: spot.x + 18, y: spot.y))
        for i in 1...30 { let y = spot.y - Double(i) * 4; move(1, CGPoint(x: spot.x - 18, y: y)); move(2, CGPoint(x: spot.x + 18, y: y)); await pause(0.016) }
        up(1, CGPoint(x: spot.x - 18, y: spot.y - 120)); up(2, CGPoint(x: spot.x + 18, y: spot.y - 120))
        let n = viewport.normalized(spot)
        log(String(format: "scrolled with the pointer at %.3f,%.3f (the swipe began at %.3f,%.3f)", pointer.x, pointer.y, n.x, n.y))
        await pause(2.5)

        // phrz's scrolls (2026-10-20): the fingers drift apart and sideways and are not quite parallel. It must scroll
        // (not zoom), vertically only, momentum included.
        func twoFingerTrace(_ name: String, from c: CGPoint, spread s0: Double, spreadEnd s1: Double, travel: Double, degrees: Double, steps: Int) async {
            let z0 = viewport.zoom
            scrollsSent = (0, 0, 0)
            let ux = sin(degrees * .pi / 180), uy = -cos(degrees * .pi / 180)   // 0°: straight up the screen
            func fingers(_ i: Int) -> (CGPoint, CGPoint) {
                let f = Double(i) / Double(steps), e = f * f * (3 - 2 * f)   // eased, as a finger accelerates and settles
                let s = s0 + (s1 - s0) * f, m = CGPoint(x: c.x + ux * travel * e, y: c.y + uy * travel * e)
                let lag = 3 * sin(f * .pi)   // the second finger trails a little
                return (CGPoint(x: m.x - s / 2, y: m.y), CGPoint(x: m.x + s / 2 - lag * ux, y: m.y - lag * uy))
            }
            let (a0, b0) = fingers(0)
            down(1, a0); down(2, b0)
            for i in 1...steps { let (a, b) = fingers(i); move(1, a); move(2, b); await pause(0.016) }
            let (a, b) = fingers(steps)
            up(1, a); up(2, b)
            await pause(1.5)   // the momentum
            log(String(format: "%@: zoom %.2f → %.2f, axis %@, %d scroll messages sent, %d moved x, %d moved y", name, z0, viewport.zoom, "\(axisLock.axis.map { "\($0)" } ?? "none")", scrollsSent.count, scrollsSent.dx, scrollsSent.dy))
        }
        await twoFingerTrace("natural scroll (spread 44 → 50 pt, 14° sideways)", from: spot, spread: 44, spreadEnd: 50, travel: 150, degrees: 14, steps: 18)
        await pause(1)
        await twoFingerTrace("natural scroll (spread 60 → 54 pt, 18° sideways, down)", from: CGPoint(x: spot.x, y: spot.y - 120), spread: 60, spreadEnd: 54, travel: -150, degrees: -18, steps: 14)
        await pause(1)
        await twoFingerTrace("diagonal scroll (45°)", from: spot, spread: 44, spreadEnd: 46, travel: 120, degrees: 45, steps: 18)
        await pause(1.5)

        log("hold on the bench's text")
        let holdAt = CGPoint(x: body.x + 30, y: body.y + 10)
        down(1, holdAt)
        await pause(0.6)
        log("shot direct-hold: holding \(direct.holding), ring shown \(!holdRing.isHidden) at \(Int(holdRing.position.x)),\(Int(holdRing.position.y))")
        await pause(hold)
        up(1, holdAt)
        await pause(1)

        // Title bar, right of the traffic lights: a local drag of the window layer.
        let grabX = benchX(atY: f0.y + Int(14 * ppp))
        let grab = view(grabX, f0.y + Int(14 * ppp))
        log("hold the bench's title bar at \(Int(grab.x)),\(Int(grab.y)), then drag far above the display")
        down(1, grab); await pause(0.6)
        let under = streamPixel().flatMap { session.window(at: $0.0, $0.1) }
        log("holding \(direct.holding), pressing \(pressing), layer drag \(layerDrag.map { "\($0.windowID)" } ?? "none"), under the finger \(under.map { "\($0.id) \($0.frame) layered \($0.isLayered) level \($0.windowLevel)" } ?? "nothing"), pointer px \(streamPixel().map { "\($0)" } ?? "?")")
        var p = grab
        for _ in 0..<40 { p.y -= 8; move(1, p); await pause(0.016) }
        let limits = session.windowDragLimits()
        log("shot direct-drag-clamped: ring at \(Int(holdRing.position.x)),\(Int(holdRing.position.y)) shown \(!holdRing.isHidden), bench at \(benchFrame().map { "\($0)" } ?? "?"), menu bar bottom \(limits?.menuBarBottom ?? -1), pointer y \(String(format: "%.3f", pointer.y))")
        await pause(hold)
        let mid = view(grabX + Int(400 * ppp), f0.y + Int(14 * ppp) - Int(80 * ppp))   // its bottom edge over the --still bench
        let from = p
        for i in 1...40 { move(1, CGPoint(x: from.x + (mid.x - from.x) * Double(i) / 40, y: from.y + (mid.y - from.y) * Double(i) / 40)); await pause(0.016) }
        await pause(0.5)
        log("shot direct-drag-shadow: bench at \(benchFrame().map { "\($0)" } ?? "?") mid-drag")
        await pause(hold)
        // Back where it was, then let go (the host is sent the final frame).
        for i in 1...30 { move(1, CGPoint(x: mid.x + (grab.x - mid.x) * Double(i) / 30, y: mid.y + (grab.y - mid.y) * Double(i) / 30)); await pause(0.016) }
        up(1, grab)
        log("dropped: bench at \(benchFrame().map { "\($0)" } ?? "?")")
        await pause(1.5)

        log("pinch out about the bench")
        down(1, CGPoint(x: body.x - 30, y: body.y)); down(2, CGPoint(x: body.x + 30, y: body.y))
        for i in 1...30 { let s = 30 + Double(i) * 2.5; move(1, CGPoint(x: body.x - s, y: body.y)); move(2, CGPoint(x: body.x + s, y: body.y)); await pause(0.016) }
        up(1, CGPoint(x: body.x - 105, y: body.y)); up(2, CGPoint(x: body.x + 105, y: body.y))
        await pause(0.5)
        log("pinched: \(describe())")
        // One-finger pans are the scroll view's: `-demo pan` drives them with real touches.
        log("two-finger tap: right click at its centre")
        down(1, CGPoint(x: body.x - 15, y: body.y)); down(2, CGPoint(x: body.x + 15, y: body.y)); await pause(0.08)
        up(1, CGPoint(x: body.x - 15, y: body.y)); up(2, CGPoint(x: body.x + 15, y: body.y))
        await pause(0.6)
        log("two-finger double tap: back to fit")
        for _ in 0..<2 {
            down(1, CGPoint(x: body.x - 15, y: body.y)); down(2, CGPoint(x: body.x + 15, y: body.y)); await pause(0.06)
            up(1, CGPoint(x: body.x - 15, y: body.y)); up(2, CGPoint(x: body.x + 15, y: body.y)); await pause(0.12)
        }
        await pause(1)
        log("done: \(describe()); typeahead \(session.typeaheadCounts()), predictions \(model?.stats.predictions ?? (0, 0, 0, 0))")
    }

    /// `-demo pan`: direct touch's one-finger pan (the scroll view) at 2× and 3×, with real touches: a UIScrollView's
    /// pan recognizer cannot be driven from code, so each step logs `demo: await …` and waits (up to `-demoWait` s,
    /// default 120) for a swipe from the simulator's touch injection, then reports where the picture came to rest
    /// against the visible area. First a fling (momentum: UIKit's own deceleration and where it said it would stop),
    /// then a pan toward each corner at 2× and at 3× (`demo: shot corner-3x-…` holds for a screenshot once there).
    /// `-demoLandscape 1` runs it in landscape.
    func runPanDemo(log: @escaping (String) -> Void, describe: () -> String, hold: Double) async {
        func pause(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        let wait = Double(UserDefaults.standard.string(forKey: "demoWait") ?? "") ?? 120
        if UserDefaults.standard.bool(forKey: "demoLandscape") { rotateForDemo(.landscapeRight); await pause(4) }
        func rect(_ r: CGRect) -> String { String(format: "%.1f,%.1f %.1fx%.1f", r.minX, r.minY, r.width, r.height) }
        func geometry() -> String {
            "bounds \(rect(bounds)), safe area \(safeInsets.top),\(safeInsets.left),\(safeInsets.bottom),\(safeInsets.right), pill bottom \(topObstruction), container \(rect(viewport.container)), visible \(rect(viewport.visible)), picture \(rect(viewport.pictureRect)) at \(String(format: "%.2f", viewport.zoom))x; scroll view: zoom \(String(format: "%.2f", scrollView.zoomScale)), content \(Int(scrollView.contentSize.width))x\(Int(scrollView.contentSize.height)), inset \(scrollView.contentInset), offset \(scrollView.contentOffset)"
        }
        log("pan demo: \(geometry())")
        /// Waits for one or more drags (each followed by its coast and rubber band) until `done` holds at rest, or no new
        /// drag starts for 8 s after the last one came to rest. Returns the number of drags and the farthest the picture
        /// went past its range.
        func awaitDrags(until done: () -> Bool) async -> (drags: Int, overshoot: Double) {
            let first = demoDrag.count, t0 = CACurrentMediaTime()
            var overshoot = 0.0, restSince: Double?
            while CACurrentMediaTime() - t0 < wait {
                let r = viewport.originRange, o = viewport.origin
                let past = max(r.x.lowerBound - o.x, o.x - r.x.upperBound, r.y.lowerBound - o.y, o.y - r.y.upperBound, 0)
                overshoot = max(overshoot, past)
                let moving = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || past > 0.5 || direct.touchCount > 0
                if demoDrag.count > first, !moving {
                    if done() { break }
                    if restSince == nil { restSince = CACurrentMediaTime() }
                    if CACurrentMediaTime() - restSince! > 8 { break }
                } else { restSince = nil }
                await pause(0.016)
            }
            return (demoDrag.count - first, overshoot)
        }
        func zoom(to z: Double) async {
            animateZoom(to: z, about: CGPoint(x: viewport.visible.midX, y: viewport.visible.midY))
            await pause(0.6)
            log(String(format: "zoomed to %.2fx: ", viewport.zoom) + geometry())
        }

        await zoom(to: 2)
        log("await fling: one fast swipe, any direction")
        let t0 = CACurrentMediaTime()
        let f = await awaitDrags { true }
        let d = demoDrag
        let coast = hypot(scrollView.contentOffset.x - d.lift.x, scrollView.contentOffset.y - d.lift.y)
        log(String(format: "fling: %d drag(s); let go at %.0f,%.0f at %.2f,%.2f pt/ms; UIKit's target %.0f,%.0f; came to rest at %.0f,%.0f after coasting %.0f pt in %.2f s; rubber band at most %.1f pt past the edge (%.1f s in all)",
                   f.drags, d.lift.x, d.lift.y, d.velocity.x, d.velocity.y, d.target.x, d.target.y, scrollView.contentOffset.x, scrollView.contentOffset.y, coast,
                   d.ended ? CACurrentMediaTime() - d.liftTime : 0, f.overshoot, CACurrentMediaTime() - t0))
        log("after the fling: " + geometry())

        let corners: [(name: String, n: CGPoint)] = [("top-left", CGPoint(x: 0, y: 0)), ("top-right", CGPoint(x: 1, y: 0)), ("bottom-left", CGPoint(x: 0, y: 1)), ("bottom-right", CGPoint(x: 1, y: 1))]
        for z in [2.0, 3.0] {
            await zoom(to: z)
            for c in corners {
                guard let comp = session?.compositor, comp.width > 0 else { return }
                // The corner pixel of the picture, as a view rect: reached when it is inside the visible area.
                func pixel() -> CGRect {
                    viewport.viewRect(contentRect: CGRect(x: c.n.x * CGFloat(comp.width - 1), y: c.n.y * CGFloat(comp.height - 1), width: 1, height: 1))
                }
                func reached() -> Bool { viewport.visible.insetBy(dx: -0.5, dy: -0.5).contains(pixel()) }
                log("await corner \(c.name) at \(Int(z))x: swipe toward it (the picture's \(c.name) corner comes into view)")
                let r = await awaitDrags(until: reached)
                let p = viewport.pictureRect, v = viewport.visible
                let edges = String(format: "picture edges vs visible: left %+.1f, top %+.1f, right %+.1f, bottom %+.1f", p.minX - v.minX, p.minY - v.minY, p.maxX - v.maxX, p.maxY - v.maxY)
                log("corner \(c.name) at \(Int(z))x: \(reached() ? "REACHED" : "NOT reached") after \(r.drags) drag(s), rubber band at most \(String(format: "%.1f", r.overshoot)) pt; pixel \(rect(pixel())); \(edges)")
                if z == 3 {
                    log("shot corner-3x-\(c.name): " + geometry())
                    await pause(hold)
                }
            }
        }
        await zoom(to: 1)
        log("done: " + geometry())
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
