import AppKit
import Combine
import Metal
import QuartzCore
import MirageCore

/// Viewer-local shortcuts, shared by the Desktop view and every Unified window: ⌃⌥⌘ + S (stats), ↑/↓ (bitrate),
/// U (Desktop ↔ Unified), Q (quit), ↩/⌫ (send or drop what was typed during a gap). Everything else goes to the host.
enum LocalShortcuts {
    @MainActor static var toggleStats: (() -> Void)?
    @MainActor static var toggleMode: (() -> Void)?
    @MainActor static func handle(_ e: NSEvent, session: ViewerSession?) -> Bool {
        let local: NSEvent.ModifierFlags = [.control, .option, .command]
        guard e.type == .keyDown, e.modifierFlags.intersection([.control, .option, .command, .shift]) == local else { return false }
        switch e.keyCode {
        case 1: toggleStats?(); return true                             // S
        case 32: toggleMode?(); return true                             // U
        case 126: session?.adjustBitrate(by: 200); return true          // ↑
        case 125: session?.adjustBitrate(by: -200); return true         // ↓
        case 12: session?.stop(); NSApp.terminate(nil); return true      // Q
        case 36: session?.flushInput(); return true                      // ↩
        case 51: session?.discardInput(); return true                    // ⌫
        default: return false
        }
    }
}

/// Unified mode (DESIGN §3.2, §3.5 item 2): every remote window is a native `NSWindow` drawing its layer's canvas,
/// pixel-exact; menus, popovers and tooltips are short-lived child windows cut from the display layer. Moving,
/// resizing, raising, minimizing and closing are the local window server's, and the host follows through
/// Accessibility. Same session, same layers, same progressive presentation as Desktop mode: switching is local.
@MainActor
final class UnifiedController: NSObject, NSWindowDelegate {
    let session: ViewerSession
    let model: ViewerModel
    private(set) var windows: [UInt32: RemoteWindow] = [:]
    private(set) var geometry = UnifiedGeometry(pixelsPerPoint: 2)
    private var timer: Timer?
    private var lastChromeRefresh: UInt64 = 0
    private var shotTimer: Timer?
    private var cursorSink: AnyCancellable?
    private(set) var active = false
    /// The host's frontmost normal window last seen, and the window we last raised (its echo is not a host-side raise).
    private var hostFront: UInt32 = 0
    private var raisedByUs: (id: UInt32, until: UInt64) = (0, 0)
    /// Windows the person minimized here: kept (miniaturized in the local Dock) while the host lists them no more.
    private var minimizedHere = Set<UInt32>()
    /// Measurement: local frame changes applied from the host's list, and from local moves.
    private(set) var hostFramesApplied = 0, localMoves = 0
    var onLayoutChange: (() -> Void)?
    /// Apps whose status item or menu-bar strip was just clicked here: their menus and popovers sit under that item.
    private var anchors: [Int32: (host: PixelRect, local: NSRect, since: UInt64)] = [:]
    private var pids: [UInt32: Int32] = [:]
    weak var chrome: NativeChromeController?

    func pid(of id: UInt32) -> Int32? { pids[id] }
    func anchor(pid: Int32, host: PixelRect, local: NSRect) { anchors[pid] = (host, local, Clock.nowNanos()) }
    /// The remote dock: that app's windows to the front here, its frontmost one key.
    func bringToFront(pid: Int32) {
        let order = session.hostOrder().filter { $0.pid == pid }.map(\.id)
        let mine = order.compactMap { windows[$0] }.filter { $0.role == .window }
        for w in mine.reversed() { if w.isMiniaturized { w.deminiaturize(nil) } else { w.orderFront(nil) } }
        if let front = mine.first { NSApp.activate(); front.makeKeyAndOrderFront(nil) }
    }

    init(session: ViewerSession, model: ViewerModel) { self.session = session; self.model = model }

    func start() {
        guard !active else { return }
        active = true
        streamChecked = false
        session.unified = self
        session.setViewInterest(.init(unified: true, displayRects: [], hiddenLayers: []))
        requestPixelExactStream()
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
        RunLoop.main.add(timer!, forMode: .common)
        cursorSink = model.$cursor.sink { [weak self] _ in DispatchQueue.main.async { self?.windows.values.forEach { $0.remoteView.cursorChanged() } } }
        if let dir = UnifiedShots.directory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var n = 0
            shotTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let ctx = self.session.context else { return }
                    n += 1
                    var lines: [String] = []
                    for (id, w) in self.windows where w.role == .window {
                        guard case .layer(let l) = w.remoteView.entry.source, let c = self.session.layerCanvas(l), c.width > 0 else { continue }
                        let g = self.geometry.pixelsPerPoint
                        let src = PixelRect(x: 0, y: 0, width: Int(w.frame.width * g), height: Int(w.frame.height * g))
                        UnifiedShots.write(c, source: src, context: ctx, to: dir.appendingPathComponent(String(format: "win-%u-%03d.png", id, n)))
                        lines.append("{\"n\":\(n),\"id\":\(id),\"x\":\(w.frame.minX),\"y\":\(w.frame.minY),\"w\":\(w.frame.width),\"h\":\(w.frame.height),\"key\":\(w.isKeyWindow),\"mini\":\(w.isMiniaturized)}")
                    }
                    if let h = try? FileHandle(forWritingTo: dir.appendingPathComponent("unified.jsonl")) { h.seekToEndOfFile(); h.write(Data((lines.joined(separator: "\n") + "\n").utf8)); try? h.close() }
                    else { FileManager.default.createFile(atPath: dir.appendingPathComponent("unified.jsonl").path, contents: Data((lines.joined(separator: "\n") + "\n").utf8)) }
                }
            }
        }
        sync()
        session.log("unified: on (\(geometry.pixelsPerPoint) px/pt, origin \(geometry.originX),\(geometry.originY))")
    }

    func stop() {
        guard active else { return }
        active = false
        session.unified = nil
        timer?.invalidate(); timer = nil; cursorSink = nil; shotTimer?.invalidate(); shotTimer = nil
        for w in windows.values { w.remoteView.detach(); w.orderOut(nil) }
        windows = [:]; minimizedHere = []
        session.setViewInterest(.init(unified: false))
        session.log("unified: off")
    }

    /// Unified wants one host point per local point, pixel-exact: if the stream is far from that, ask for it (a size
    /// change, not a reconnect).
    private var streamChecked = false
    private func requestPixelExactStream() {
        guard let info = model.streamInfo else {
            // No stream yet (started in Unified mode): ask for this screen's pixels; the host fits its aspect, and the
            // first stream info refines it.
            if let s = NSScreen.main { session.requestStream(width: Int(s.frame.width * s.backingScaleFactor), height: Int(s.frame.height * s.backingScaleFactor)) }
            return
        }
        streamChecked = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let (w, h) = UnifiedGeometry.wantedStream(current: (info.width, info.height), hostPoints: (info.displayWidth, info.displayHeight), backingScale: scale) {
            session.log("unified: requesting a \(w)x\(h) stream (one host point per local point)")
            session.requestStream(width: w, height: h)
        }
    }

    private func updateGeometry() {
        guard let screen = NSScreen.screens.first else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? screen.backingScaleFactor
        let hostBar = session.hostOrder().first { UnifiedLayout.menuBarLevels.contains($0.windowLevel) && $0.frame.y <= 0 }?.frame.height ?? 0
        let localBar = screen.frame.maxY - screen.visibleFrame.maxY
        geometry = .make(pixelsPerPoint: scale, screenX: Self.testOffset.x, screenY: Self.testOffset.y, hostMenuBarPx: hostBar, localMenuBarPoints: localBar)
    }
    /// Test only: MIRAGE_TEST_UNIFIED_OFFSET="dx,dy" (points) shifts every remote window, so on loopback the native windows
    /// do not sit on top of the host windows they show (the host would capture them over their own originals).
    static let testOffset: (x: Double, y: Double) = {
        let p = (ProcessInfo.processInfo.environment["MIRAGE_TEST_UNIFIED_OFFSET"] ?? "").split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (p[0], p[1]) : (0, 0)
    }()

    /// AppKit frame (bottom-left origin) of a host frame.
    func appKitFrame(_ r: PixelRect) -> NSRect {
        let l = geometry.local(r)
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: l.x, y: h - l.y - l.height, width: l.width, height: l.height)
    }
    func hostFrame(_ f: NSRect) -> PixelRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return geometry.host(.init(x: f.minX, y: h - f.maxY, width: f.width, height: f.height))
    }

    /// Brings the native windows in line with the arranged window list (60 Hz while Unified is on).
    func sync() {
        guard active else { return }
        if !streamChecked, model.streamInfo != nil { requestPixelExactStream() }
        guard let display = session.compositor, display.width > 0 else { return }
        if model.hostStatus?.consoleLocked == true { return }   // layering is paused on the host: keep what is shown
        updateGeometry()
        let arranged = session.arrangedWindows()
        let now = Clock.nowNanos()
        // An anchor lasts 30 s after its click, or for as long as that app shows a transient without a window of its own.
        let orphanPids = Set(arranged.filter { $0.windowLevel != 0 && !$0.isLayered && ($0.cutout ?? false) }.map(\.pid))
        anchors = anchors.filter { Clock.elapsed(since: $0.value.since, now: now) < 30_000_000_000 || (orphanPids.contains($0.key) && Clock.elapsed(since: $0.value.since, now: now) < 600_000_000_000) }
        let layout = UnifiedLayout.plan(arranged, hasCanvas: { (self.session.layerCanvas($0)?.width ?? 0) > 0 }, display: PixelRect(x: 0, y: 0, width: display.width, height: display.height), anchoredApps: Set(anchors.keys))
        for e in layout.entries { pids[e.id] = e.pid }
        let ids = Set(layout.entries.map(\.id))
        // Gone on the host: close, unless the person minimized it here (it waits in the local Dock).
        for (id, w) in windows where !ids.contains(id) {
            if minimizedHere.contains(id), w.isMiniaturized { continue }
            w.remoteView.detach(); w.parent?.removeChildWindow(w); w.orderOut(nil); windows[id] = nil; minimizedHere.remove(id)
        }
        // Back to front, so new windows stack like the host's.
        var created: [RemoteWindow] = []
        for e in layout.entries.reversed() {
            let w: RemoteWindow
            if let existing = windows[e.id], existing.role == e.role { w = existing }
            else {
                windows[e.id]?.orderOut(nil)
                w = RemoteWindow(entry: e, controller: self)
                w.delegate = self
                windows[e.id] = w
                created.append(w)
                session.log("unified: \(e.role == .window ? "window" : "transient") \(e.id) (\(e.app), level \(e.level)) as local window \(w.windowNumber) at \(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height))\(e.parent.map { ", child of \($0)" } ?? "")")
            }
            w.update(entry: e)
            var target = appKitFrame(e.frame)
            if e.role == .transient, let a = anchors[e.pid] {
                // Under the local item: the same offset from it as on the host, in local points.
                let g = geometry.pixelsPerPoint
                let dx = CGFloat(e.frame.x - a.host.x) / CGFloat(g), dy = CGFloat(e.frame.y - a.host.y) / CGFloat(g)
                target = NSRect(x: a.local.minX + dx, y: a.local.maxY - dy - target.height, width: target.width, height: target.height)
            }
            if !w.isMiniaturized, !w.localInteraction, !w.frame.isClose(to: target) {
                w.applyingHostFrame = true
                w.setFrame(target, display: false)
                w.applyingHostFrame = false
                hostFramesApplied += 1
            }
        }
        // Parents (transients and sheets move with their window).
        for e in layout.entries {
            guard let w = windows[e.id] else { continue }
            let p = anchors[e.pid] != nil && e.role == .transient ? nil : e.parent.flatMap { windows[$0] }
            if w.parent !== p {
                w.parent?.removeChildWindow(w)
                if let p { p.addChildWindow(w, ordered: .above) }
            }
        }
        for w in created {
            if w.role == .transient { w.orderFront(nil) }
            else if NSApp.isActive || windows.count == 1 { w.orderFront(nil) }
            else { w.orderFront(nil) }
        }
        followHostFront(arranged: session.hostOrder())
        if Clock.elapsed(since: lastChromeRefresh, now: now) > 500_000_000 { lastChromeRefresh = now; chrome?.refreshPanels() }
        // The host sends window layers by this arrangement, and of the display layer only what is shown here: its menus
        // and popovers (the host adds those itself, so a new menu costs no extra round trip) and the strips.
        session.setViewInterest(.init(unified: true, displayRects: chrome?.stripRects() ?? [], hiddenLayers: minimizedHere.sorted()))
        onLayoutChange?()
    }

    /// A raise that happened on the host (an app opened a window, ⌘-Tab there) brings that window to the front here, if
    /// this app is active; our own raises' echoes are not raises.
    private func followHostFront(arranged: [ControlMessage.WindowInfo]) {
        guard let front = arranged.first(where: { $0.windowLevel == 0 && windows[$0.id]?.role == .window })?.id else { return }
        defer { hostFront = front }
        guard front != hostFront, hostFront != 0 else { return }
        if raisedByUs.id == front, Clock.nowNanos() < raisedByUs.until { return }
        guard let w = windows[front], !w.isKeyWindow, !w.isMiniaturized else { return }
        if NSApp.isActive { w.followingHost = true; w.makeKeyAndOrderFront(nil); w.followingHost = false }
    }

    // MARK: Window delegate: local window management → host

    func windowDidBecomeKey(_ n: Notification) {
        guard let w = n.object as? RemoteWindow, w.role == .window, !w.followingHost else { return }
        tellHostRaised(w)
    }
    private func tellHostRaised(_ w: RemoteWindow) {
        raisedByUs = (w.remoteID, Clock.nowNanos() + 2_000_000_000)
        session.sendWindowCommand(.init(id: w.remoteID, action: .raise))
        session.localRaise(windowID: w.remoteID, inputSeq: 0)
    }
    /// A window to the front here without activating this app (scenarios), and the host told.
    func raise(_ w: RemoteWindow) { w.orderFront(nil); tellHostRaised(w) }
    func windowDidMove(_ n: Notification) {
        guard let w = n.object as? RemoteWindow, w.role == .window, !w.applyingHostFrame, !w.isMiniaturized else { return }
        w.noteLocalInteraction()
        localMoves += 1
        session.moveLayerLocally(windowID: w.remoteID, to: hostFrame(w.frame))
    }
    func windowDidResize(_ n: Notification) {
        guard let w = n.object as? RemoteWindow, w.role == .window, !w.applyingHostFrame, !w.isMiniaturized else { return }
        w.noteLocalInteraction()
        session.resizeLayerLocally(windowID: w.remoteID, to: hostFrame(w.frame), final: !w.inLiveResize)
    }
    func windowDidEndLiveResize(_ n: Notification) {
        guard let w = n.object as? RemoteWindow, w.role == .window else { return }
        w.noteLocalInteraction()
        session.resizeLayerLocally(windowID: w.remoteID, to: hostFrame(w.frame), final: true)
    }
    func windowWillMiniaturize(_ n: Notification) {
        guard let w = n.object as? RemoteWindow, w.role == .window else { return }
        minimizedHere.insert(w.remoteID)
        session.sendWindowCommand(.init(id: w.remoteID, action: .minimize))
    }
    func windowDidDeminiaturize(_ n: Notification) {
        guard let w = n.object as? RemoteWindow, w.role == .window else { return }
        minimizedHere.remove(w.remoteID)
        session.sendWindowCommand(.init(id: w.remoteID, action: .restore))
        session.sendWindowCommand(.init(id: w.remoteID, action: .raise))
    }
    /// Closing (⌘W goes to the host as a key; this is the Window menu, Mission Control, the local close path): the host
    /// closes it (and may ask to save first); the window goes when the host's list drops it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let w = sender as? RemoteWindow else { return true }
        session.sendWindowCommand(.init(id: w.remoteID, action: .close))
        return false
    }

    /// A click on a remote window's traffic lights, handled here (the buttons are the host's pixels).
    func perform(_ c: UnifiedLayout.TitleControl, on w: RemoteWindow) {
        switch c {
        case .close: session.sendWindowCommand(.init(id: w.remoteID, action: .close))
        case .minimize: w.miniaturize(nil)
        case .zoom: session.sendWindowCommand(.init(id: w.remoteID, action: .zoom))
        }
    }

    /// Stream pixels per host point (title-bar heights).
    var hostPixelsPerPoint: Double { session.pixelsPerPoint }
}

extension NSRect {
    func isClose(to o: NSRect, within d: CGFloat = 1) -> Bool {
        abs(minX - o.minX) <= d && abs(minY - o.minY) <= d && abs(width - o.width) <= d && abs(height - o.height) <= d
    }
}

/// One remote window (or a transient: menu, popover, tooltip). A titled window with the system's buttons hidden and a
/// transparent, full-size title bar, so the window server gives it a native shadow, native resizing, Mission Control,
/// ⌘`, the Window menu, tiling and the genie minimize, while every pixel inside is the host's (its traffic lights
/// included, placed and styled for that window's toolbar by the host; local buttons would have to be re-placed per
/// window style and would show twice whenever they missed).
final class RemoteWindow: NSWindow {
    let remoteID: UInt32
    let role: UnifiedLayout.Role
    let remoteView: RemoteWindowView
    var applyingHostFrame = false
    var followingHost = false
    private var lastLocalInteraction: UInt64 = 0
    /// The person is moving or resizing it (host frames are not applied meanwhile).
    var localInteraction: Bool { inLiveResize || Clock.elapsed(since: lastLocalInteraction, now: Clock.nowNanos()) < 500_000_000 }
    func noteLocalInteraction() { lastLocalInteraction = Clock.nowNanos() }

    @MainActor init(entry e: UnifiedLayout.Entry, controller: UnifiedController) {
        remoteID = e.id; role = e.role
        remoteView = RemoteWindowView(entry: e, controller: controller)
        let frame = controller.appKitFrame(e.frame)
        if e.role == .window {
            super.init(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            titlebarSeparatorStyle = .none
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
            tabbingMode = .disallowed
            collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
            animationBehavior = .none
        } else {
            super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            level = .popUpMenu
            animationBehavior = .none
            collectionBehavior = [.transient, .ignoresCycle]
        }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isRestorable = false
        contentView = remoteView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { role == .window }
    override var canBecomeMain: Bool { role == .window }

    @MainActor func update(entry e: UnifiedLayout.Entry) {
        // Loopback: a title the host's MIRAGE_LAYER_APPS test filter cannot match (it matches titles too), or this window
        // would be captured back as a layer (ScreenCaptureKit no longer honours sharingType = .none).
        let t = remoteView.controller?.session.isLoopback == true ? "remote window \(e.id)" : (e.title.isEmpty ? e.app : e.title)
        if title != t { title = t }
        remoteView.entry = e
    }
}

/// Draws one canvas region into a CAMetalLayer (1:1 with the backing pixels), outlines it in purple (remote content,
/// DESIGN §3.8), and forwards input with the window's host coordinates.
final class RemoteWindowView: NSView {
    @MainActor var entry: UnifiedLayout.Entry
    private(set) weak var controller: UnifiedController?
    private let metalLayer = CAMetalLayer()
    private let outline = CALayer()
    private var displayLink: CADisplayLink?
    private var lastGeneration = -1, lastSize = CGSize.zero, lastDisplacements = 0
    private var cornerRadiusPx: Double? = nil
    private var pendingTitle: (event: NSEvent, start: NSPoint)?
    private var pendingControl: UnifiedLayout.TitleControl?
    private var pointerInside = false
    private var cursorCache: (key: ObjectIdentifier, cursor: NSCursor)?
    /// Measurement: frames drawn.
    private(set) var framesDrawn = 0

    /// Called on a press before it is forwarded (a status-strip item anchors its app's popovers).
    var onPress: (() -> Void)?

    @MainActor init(entry: UnifiedLayout.Entry, controller: UnifiedController, outlined: Bool = true) {
        self.entry = entry; self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        metalLayer.device = controller.session.context?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.presentsWithTransaction = false
        layer?.addSublayer(metalLayer)
        outline.borderColor = NSColor.systemPurple.withAlphaComponent(0.85).cgColor
        outline.borderWidth = 1.5
        outline.cornerCurve = .continuous
        outline.zPosition = 5
        if outlined { layer?.addSublayer(outline) }
        if entry.role == .transient && outlined {
            layer?.cornerRadius = 8; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
            outline.cornerRadius = 8
        } else { outline.cornerRadius = 12 }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor func detach() { displayLink?.invalidate(); displayLink = nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        outline.frame = bounds
        CATransaction.commit()
        lastGeneration = -1
    }

    /// Canvas and source rect for this window.
    @MainActor private var source: (Compositor, PixelRect)? {
        guard let controller else { return nil }
        let s = controller.session
        switch entry.source {
        case .layer(let id):
            guard let c = s.layerCanvas(id), c.width > 0 else { return nil }
            let g = controller.geometry.pixelsPerPoint
            return (c, PixelRect(x: 0, y: 0, width: Int((bounds.width * g).rounded()), height: Int((bounds.height * g).rounded())))
        case .display(let r):
            guard let c = s.compositor, c.width > 0 else { return nil }
            return (c, r)
        }
    }

    @objc private func tick() {
        MainActor.assumeIsolated {
            guard let controller, let context = controller.session.context, let (c, src) = source else { return }
            let gen = c.currentGeneration
            var disp: [Predictor.Displacement] = [], colors: [UInt32: SIMD4<Float>] = [:]
            if case .layer(let id) = entry.source { (disp, colors) = controller.session.displacements(forWindow: id) }
            let size = metalLayer.drawableSize
            guard gen != lastGeneration || c.hasActiveFades || !disp.isEmpty || disp.count != lastDisplacements || size != lastSize else { return }
            guard let drawable = metalLayer.nextDrawable() else { return }
            lastGeneration = gen; lastSize = size; lastDisplacements = disp.count
            // Drawable pixels per canvas pixel: 1 on the screen the stream was sized for; another screen's backing scale otherwise.
            let scale = Double(window?.backingScaleFactor ?? 2) / controller.geometry.pixelsPerPoint
            let clear = MTLClearColor(red: 0.93, green: 0.93, blue: 0.93, alpha: entry.role == .window && (lastSize.width > Double(c.width) * scale + 1 || lastSize.height > Double(c.height) * scale + 1) ? 1 : 0)
            SceneRenderer.renderCrop(c, source: src, scale: scale, displacements: disp, bandColors: colors, context: context, target: drawable.texture, clear: clear, present: drawable)
            framesDrawn += 1
            if entry.role == .window, cornerRadiusPx == nil, c.hasAlpha { measureCorner(c) }
        }
    }

    /// The window's corner radius, from its canvas alpha (the outline follows the host's shape, whatever the window style).
    @MainActor private func measureCorner(_ c: Compositor) {
        cornerRadiusPx = 0
        c.sampleCornerRadius { [weak self] r in
            DispatchQueue.main.async {
                guard let self, let r else { self?.cornerRadiusPx = nil; return }
                self.cornerRadiusPx = r
                let pts = r / (self.controller?.geometry.pixelsPerPoint ?? 2)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.outline.cornerRadius = pts
                CATransaction.commit()
                self.window?.invalidateShadow()
            }
        }
    }

    // MARK: Input

    @MainActor private var session: ViewerSession? { controller?.session }
    @MainActor private var observeOnly: Bool { controller?.model.observeOnly ?? false }

    /// Window-relative stream pixels and the normalized display position of an event.
    @MainActor private func position(_ e: NSEvent) -> (local: (Int, Int), normalized: (Double, Double))? {
        guard let controller, let display = controller.session.compositor, display.width > 0 else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        let g = controller.geometry.pixelsPerPoint
        let lx = Int((p.x * g).rounded()), ly = Int((p.y * g).rounded())
        let f = entry.frame
        return ((lx, ly), (Double(f.x + lx) / Double(display.width), Double(f.y + ly) / Double(display.height)))
    }
    private func flags(_ e: NSEvent) -> UInt64 { e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue) }

    @MainActor @discardableResult
    private func button(_ e: NSEvent, _ b: Int, down: Bool) -> UInt64 {
        guard !observeOnly, let p = position(e) else { return 0 }
        return session?.send(.mouseButton(.init(button: b, down: down, x: p.normalized.0, y: p.normalized.1, clickCount: e.clickCount, modifiers: flags(e)))) ?? 0
    }

    override func mouseMoved(with e: NSEvent) {
        MainActor.assumeIsolated {
            guard !observeOnly, let p = position(e) else { return }
            session?.sendMouseMove(x: p.normalized.0, y: p.normalized.1)
        }
    }
    override func mouseDown(with e: NSEvent) {
        MainActor.assumeIsolated {
            window?.makeFirstResponder(self)
            pendingTitle = nil; pendingControl = nil
            guard !observeOnly, let controller, let p = position(e) else { return }
            onPress?()
            let plain = e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if entry.role == .window, plain, let c = UnifiedLayout.control(at: p.local.0, p.local.1, controls: entry.controls) { pendingControl = c; return }
            let hp = controller.hostPixelsPerPoint
            if entry.role == .window, plain, e.clickCount == 1,
               UnifiedLayout.isDragRegion(p.local.0, p.local.1, controls: entry.controls, titleBarPx: Int(28 * hp), trafficLightsPx: Int(80 * hp)) {
                pendingTitle = (e, e.locationInWindow); return
            }
            button(e, 0, down: true)
        }
    }
    override func mouseDragged(with e: NSEvent) {
        MainActor.assumeIsolated {
            if let t = pendingTitle {
                let d = hypot(e.locationInWindow.x - t.start.x, e.locationInWindow.y - t.start.y)
                if d >= 3 { pendingTitle = nil; (window as? RemoteWindow)?.noteLocalInteraction(); window?.performDrag(with: t.event) }
                return
            }
            if pendingControl != nil { return }
            guard !observeOnly, let p = position(e) else { return }
            session?.sendMouseMove(x: p.normalized.0, y: p.normalized.1)
        }
    }
    override func mouseUp(with e: NSEvent) {
        MainActor.assumeIsolated {
            if let c = pendingControl {
                pendingControl = nil
                if let p = position(e), UnifiedLayout.control(at: p.local.0, p.local.1, controls: entry.controls) == c, let w = window as? RemoteWindow { controller?.perform(c, on: w) }
                return
            }
            if let t = pendingTitle {
                // A click on the title bar after all: press and release now.
                pendingTitle = nil
                button(t.event, 0, down: true)
            }
            button(e, 0, down: false)
        }
    }
    override func rightMouseDown(with e: NSEvent) { MainActor.assumeIsolated { _ = button(e, 1, down: true) } }
    override func rightMouseUp(with e: NSEvent) { MainActor.assumeIsolated { _ = button(e, 1, down: false) } }
    override func rightMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func otherMouseDown(with e: NSEvent) { MainActor.assumeIsolated { _ = button(e, max(2, e.buttonNumber), down: true) } }
    override func otherMouseUp(with e: NSEvent) { MainActor.assumeIsolated { _ = button(e, max(2, e.buttonNumber), down: false) } }
    override func otherMouseDragged(with e: NSEvent) { mouseMoved(with: e) }

    override func scrollWheel(with e: NSEvent) {
        MainActor.assumeIsolated {
            guard !observeOnly, let session, let p = position(e) else { return }
            let precise = e.hasPreciseScrollingDeltas
            let dx = precise ? e.scrollingDeltaX : e.deltaX, dy = precise ? e.scrollingDeltaY : e.deltaY
            let seq = session.send(.scroll(.init(x: p.normalized.0, y: p.normalized.1, dx: dx, dy: dy, precise: precise, modifiers: flags(e))))
            // Scroll prediction on the window's own canvas (DESIGN §3.5 item 3), as in Desktop mode.
            guard precise, case .layer(let id) = entry.source, e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let w = session.arrangedWindows().first(where: { $0.id == id }) else { return }
            let ppp = session.pixelsPerPoint
            let sdx = Int((dx * ppp).rounded()), sdy = Int((dy * ppp).rounded())
            guard sdx != 0 || sdy != 0 else { return }
            let rect = session.scrollRect(for: w, titleBarPx: Int(28 * ppp))
            guard rect.contains(p.local.0, p.local.1) else { return }
            session.predict(kind: .scroll, windowID: id, rect: rect, dx: sdx, dy: sdy, inputSeq: seq)
        }
    }

    @MainActor private func key(_ e: NSEvent, down: Bool) {
        guard !observeOnly else { return }
        session?.send(.key(.init(keyCode: e.keyCode, down: down, isRepeat: down && e.isARepeat, modifiers: flags(e), characters: down ? e.characters : nil)))
    }
    override func keyDown(with e: NSEvent) { MainActor.assumeIsolated { if !LocalShortcuts.handle(e, session: session) { key(e, down: true) } } }
    override func keyUp(with e: NSEvent) { MainActor.assumeIsolated { key(e, down: false) } }
    override func flagsChanged(with e: NSEvent) { MainActor.assumeIsolated { if !observeOnly { session?.send(.modifiers(.init(keyCode: e.keyCode, modifiers: flags(e)))) } } }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        MainActor.assumeIsolated {
            // ⌘-shortcuts belong to the remote app (its menus are the host's); only ours stay here.
            guard window?.firstResponder === self else { return false }
            if LocalShortcuts.handle(e, session: session) { return true }
            if e.type == .keyDown { key(e, down: true) } else if e.type == .keyUp { key(e, down: false) }
            return true
        }
    }

    // MARK: Cursor: the host's shape as a real cursor over remote windows

    override func mouseEntered(with e: NSEvent) { pointerInside = true; MainActor.assumeIsolated { cursorChanged() } }
    override func mouseExited(with e: NSEvent) { pointerInside = false }
    override func cursorUpdate(with e: NSEvent) { MainActor.assumeIsolated { cursorChanged() } }
    @MainActor func cursorChanged() {
        guard pointerInside, let c = controller?.model.cursor else { return }
        let key = ObjectIdentifier(c.image)
        if cursorCache?.key != key { cursorCache = (key, NSCursor(image: c.image, hotSpot: c.hotspot)) }
        cursorCache?.cursor.set()
    }
}
