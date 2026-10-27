import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import MirageCore

/// Host window list (CGWindowList) in stream pixels: every on-screen window at every level (normal
/// windows, menus, the dock, the menu bar) front to back, frame deltas between samples for drag
/// detection of windows the display layer still carries, and per-window scroll rects: from Accessibility
/// (`AXScrollArea` under the pointer) when available, else learned from the first detected copy-rect shift.
final class WindowTracker {
    struct Sample {
        var captureSeq: UInt32
        var windows: [ControlMessage.WindowInfo]
        var byID: [UInt32: ControlMessage.WindowInfo]
        /// Window bounds in points (global, top-left origin), for Accessibility and capture sizing.
        var pointBounds: [UInt32: CGRect]
        /// Child windows folded into their parent (the traffic-light window macOS 26 gives every titled
        /// window, sheets' accessories): same owner, inside the parent, tiny. They are not listed to the
        /// client; a layered parent's capture includes them, and the display stream excludes them with it.
        var children: [UInt32: [UInt32]]
    }
    private var _current: Sample?
    private(set) var current: Sample? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }
    private var displayBounds: CGRect       // points, global
    private(set) var pxPerPoint: Double
    private var lastSampleNanos: UInt64 = 0
    private let lock = NSLock()
    private var learned: [UInt32: PixelRect] = [:]
    private var axRects: [UInt32: (rect: PixelRect, size: PixelRect)] = [:]
    private var lastSeen: [UInt32: UInt64] = [:]
    var minSampleInterval: UInt64 = 25_000_000

    private var displayID: CGDirectDisplayID
    init(displayID: CGDirectDisplayID, streamWidth: Int) {
        self.displayID = displayID
        displayBounds = CGDisplayBounds(displayID)
        pxPerPoint = Double(streamWidth) / Double(displayBounds.width)
    }
    func setDisplay(_ id: CGDirectDisplayID, streamWidth: Int) {
        displayID = id
        displayBounds = CGDisplayBounds(id)
        pxPerPoint = Double(streamWidth) / Double(displayBounds.width)
        lock.lock(); learned = [:]; axRects = [:]; chromeInsets = nil; lock.unlock()
    }

    /// The menu bar and Dock insets in points (top, bottom, left, right) from NSScreen, and the Dock's own frame (global points,
    /// top-left origin) from Accessibility, refreshed on the main queue every 2 s.
    private var chromeInsets: (top: Double, bottom: Double, left: Double, right: Double)?
    private var dockFrame: CGRect?
    private var chromeAskedNanos: UInt64 = 0
    /// The desktop's always-visible chrome (menu bar, Dock) in stream pixels (DesktopChrome). The menu bar from NSScreen (a
    /// 24-pt bar until it answers). The Dock from, in order: its Accessibility list's frame (exact; visibleFrame in the
    /// launchd agent left the Dock out on mac-daddy, auto-hide off, and its window list has only a full-screen window), the
    /// visibleFrame insets, then its preferences (orientation, tile size; none while it auto-hides).
    func chromeRects(width: Int, height: Int) -> [PixelRect] {
        let now = Clock.nowNanos()
        lock.lock()
        let insets = chromeInsets ?? (24, 0, 0, 0)
        let dock = dockFrame
        let ask = now &- chromeAskedNanos > 2_000_000_000
        if ask { chromeAskedNanos = now }
        let id = displayID, ppp = pxPerPoint
        lock.unlock()
        if ask {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var i = (top: 24.0, bottom: 0.0, left: 0.0, right: 0.0)
                if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
                    let f = screen.frame, v = screen.visibleFrame   // bottom-left origin, y up
                    i = (top: Double(max(0, f.maxY - v.maxY)), bottom: Double(max(0, v.minY - f.minY)), left: Double(max(0, v.minX - f.minX)), right: Double(max(0, f.maxX - v.maxX)))
                }
                let d = Self.axDockFrame()
                self.lock.lock(); self.chromeInsets = i; self.dockFrame = d; self.lock.unlock()
            }
        }
        var rects = DesktopChrome.bands(width: width, height: height, pxPerPoint: ppp, top: insets.top, bottom: 0, left: 0, right: 0)
        let display = PixelRect(x: 0, y: 0, width: width, height: height)
        if let d = dock, !toPixels(d).intersection(display).isEmpty {
            rects.append(toPixels(d).intersection(display))
        } else if insets.bottom > 0 || insets.left > 0 || insets.right > 0 {
            rects += DesktopChrome.bands(width: width, height: height, pxPerPoint: ppp, top: 0, bottom: insets.bottom, left: insets.left, right: insets.right)
        } else {
            let prefs = UserDefaults(suiteName: "com.apple.dock")
            if let band = DesktopChrome.dockBand(orientation: prefs?.string(forKey: "orientation"), tileSize: prefs?.object(forKey: "tilesize") as? Double,
                                                 autohide: prefs?.bool(forKey: "autohide") ?? false, width: width, height: height, pxPerPoint: ppp) { rects.append(band) }
        }
        return rects
    }

    /// The Dock's icon list frame from Accessibility (global points, top-left origin), nil if unavailable.
    private static func axDockFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] else { return nil }
        for e in list {
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role) == .success, (role as? String) == (kAXListRole as String) else { continue }
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success else { continue }
            var p = CGPoint.zero, sz = CGSize.zero
            guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &sz), sz.width > 0, sz.height > 0 else { continue }
            return CGRect(origin: p, size: sz)
        }
        return nil
    }

    func toPixels(_ r: CGRect) -> PixelRect {
        PixelRect(x: Int(((r.minX - displayBounds.minX) * pxPerPoint).rounded()), y: Int(((r.minY - displayBounds.minY) * pxPerPoint).rounded()),
                  width: Int((r.width * pxPerPoint).rounded()), height: Int((r.height * pxPerPoint).rounded()))
    }
    func toPoints(_ p: (Double, Double)) -> CGPoint { CGPoint(x: displayBounds.minX + p.0 / pxPerPoint, y: displayBounds.minY + p.1 / pxPerPoint) }
    /// A stream-pixel origin (display coordinates) as a global point.
    func originInPoints(x: Int, y: Int) -> CGPoint { toPoints((Double(x), Double(y))) }

    struct Delta { let id: UInt32; let old: PixelRect; let new: PixelRect }

    /// Whether a CGWindowList entry is something the client should know about: on screen, visible,
    /// not the desktop, not the cursor. The menu bar and the dock are kept (they stack above windows).
    static func wanted(level: Int, owner: String, bounds: CGRect, alpha: Double) -> Bool {
        if level < 0 || alpha <= 0.01 || bounds.width < 2 || bounds.height < 2 { return false }
        if owner == "Window Server" && level > 1000 { return false }   // the cursor window and friends
        return true
    }

    /// This process (the curtain's windows are its only ones).
    static let ownPID = getpid()
    /// Samples the window list (throttled). Returns the new sample, the windows that moved without
    /// resizing since the previous sample, and whether anything changed; nil if throttled.
    func sample(captureSeq: UInt32, now: UInt64, force: Bool = false) -> (sample: Sample, moved: [Delta], changed: Bool)? {
        guard force || Clock.elapsed(since: lastSampleNanos, now: now) >= minSampleInterval else { return nil }
        lastSampleNanos = now
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return nil }
        var windows: [ControlMessage.WindowInfo] = []
        var pointBounds: [UInt32: CGRect] = [:]
        let display = displayBounds
        for w in list {
            guard let layer = w[kCGWindowLayer] as? Int,
                  let num = w[kCGWindowNumber] as? UInt32, let pid = w[kCGWindowOwnerPID] as? Int32,
                  let b = w[kCGWindowBounds] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b),
                  bounds.intersects(display) else { continue }
            // The curtain (DESIGN §3.12), this process's or another miraged's (a test instance): never a layer, never listed.
            if pid == Self.ownPID || (w[kCGWindowName] as? String) == Curtain.windowTitle { continue }
            let owner = (w[kCGWindowOwnerName] as? String) ?? ""
            let alpha = w[kCGWindowAlpha] as? Double ?? 1
            guard Self.wanted(level: layer, owner: owner, bounds: bounds, alpha: alpha) else { continue }
            let title = (w[kCGWindowName] as? String) ?? ""
            pointBounds[num] = bounds
            windows.append(.init(id: num, pid: pid, title: title, frame: toPixels(bounds), z: windows.count, scrollRect: scrollRect(for: num), level: layer, layered: false, app: owner))
        }
        // Fold children into parents: a window in front of a larger one of the same owner, inside it (2 px slack), under 2 % of its area.
        var children: [UInt32: [UInt32]] = [:]
        var childIDs = Set<UInt32>()
        for (i, w) in windows.enumerated() where w.frame.area > 0 {
            for p in windows[(i + 1)...] where p.pid == w.pid && p.windowLevel == w.windowLevel && p.frame.area >= w.frame.area * 50 {
                let slack = PixelRect(x: p.frame.x - 2, y: p.frame.y - 2, width: p.frame.width + 4, height: p.frame.height + 4)
                if slack.intersection(w.frame) == w.frame { children[p.id, default: []].append(w.id); childIDs.insert(w.id); break }
            }
        }
        // The traffic lights (macOS 26+: a child window of their own, ~66×20 pt near the parent's top-left corner):
        // published relative to the parent so Unified mode can handle them locally.
        for i in windows.indices {
            guard let kids = children[windows[i].id] else { continue }
            let p = windows[i].frame
            if let c = kids.compactMap({ id in windows.first { $0.id == id }?.frame }).first(where: { f in
                let w = Double(f.width) / pxPerPoint, h = Double(f.height) / pxPerPoint
                return w >= 40 && w <= 100 && h >= 12 && h <= 32 && Double(f.x - p.x) / pxPerPoint < 40 && Double(f.y - p.y) / pxPerPoint < 40
            }) { windows[i].controls = PixelRect(x: c.x - p.x, y: c.y - p.y, width: c.width, height: c.height) }
        }
        if !childIDs.isEmpty {
            windows.removeAll { childIDs.contains($0.id) }
            for i in windows.indices { windows[i].z = i }
        }
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var moved: [Delta] = []
        var resized = false
        if let prev = current {
            for w in windows {
                if let o = prev.byID[w.id], o.frame != w.frame, o.frame.width == w.frame.width, o.frame.height == w.frame.height {
                    moved.append(Delta(id: w.id, old: o.frame, new: w.frame))
                }
                if let o = prev.byID[w.id], o.frame.width != w.frame.width || o.frame.height != w.frame.height {
                    lock.lock(); learned[w.id] = nil; axRects[w.id] = nil; lock.unlock()   // scroll rects are stale after a resize
                    resized = true
                }
            }
        }
        let changed = resized || (current.map { $0.windows != windows } ?? true)
        let s = Sample(captureSeq: captureSeq, windows: windows, byID: byID, pointBounds: pointBounds, children: children)
        current = s
        // Review L9: forget scroll rects of windows gone for over a minute.
        lock.lock()
        for w in windows { lastSeen[w.id] = now }
        for (id, t) in lastSeen where now &- t > 60_000_000_000 { lastSeen[id] = nil; learned[id] = nil; axRects[id] = nil }
        lock.unlock()
        return (s, moved, changed)
    }

    /// The frontmost normal window (first level-0 window in the on-screen list) and its owner, for the host status.
    func frontmost() -> (app: String, id: UInt32, title: String) {
        guard let w = current?.windows.first(where: { $0.windowLevel == 0 }) else { return ("", 0, "") }
        return (w.app ?? "", w.id, w.title)
    }

    /// Topmost window under a stream-pixel point.
    func window(at x: Int, _ y: Int) -> ControlMessage.WindowInfo? {
        current?.windows.first { $0.frame.contains(x, y) }
    }
    /// The topmost normal-level window (level 0) under a point: what a wheel event scrolls. Overlays and shields above it
    /// (transparent, other levels) took the attribution, so a scrolled window's captures never knew a wheel event hit them.
    func appWindow(at x: Int, _ y: Int) -> ControlMessage.WindowInfo? {
        guard let c = current else { return nil }
        // Front to back: an app window takes it; the Dock, a menu, a popover (smaller windows at other levels) keep it (nil:
        // not the window beneath); only a large window at another level (an overlay or shield over most of the display) is
        // passed through.
        let large = Int(displayBounds.width * displayBounds.height * pxPerPoint * pxPerPoint) / 2   // stream pixels
        for w in c.windows where w.frame.contains(x, y) {
            if w.windowLevel == 0 { return w }
            if w.frame.area < large { return nil }
        }
        return nil
    }

    /// Scroll rect in display coordinates, if known.
    func scrollRect(for id: UInt32) -> PixelRect? {
        lock.lock(); defer { lock.unlock() }
        return axRects[id]?.rect ?? learned[id]
    }

    func learn(scrollRect r: PixelRect, for id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard axRects[id] == nil else { return }
        learned[id] = learned[id].map { $0.union(r) } ?? r
    }

    /// Asks Accessibility for the scroll area under a stream-pixel point (a few ms of IPC; call
    /// off the capture queue). Remembered per window until it resizes.
    func queryAXScrollArea(at x: Int, _ y: Int, windowID: UInt32) {
        lock.lock(); let cached = axRects[windowID] != nil; lock.unlock()
        if cached { return }
        let p = toPoints((Double(x), Double(y)))
        let sys = AXUIElementCreateSystemWide()
        var elem: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &elem) == .success, var e = elem else { return }
        for _ in 0..<12 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &roleRef) == .success, let role = roleRef as? String, role == kAXScrollAreaRole {
                var posRef: CFTypeRef?, sizeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &posRef) == .success,
                      AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sizeRef) == .success else { return }
                var pos = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos), AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return }
                let rect = toPixels(CGRect(origin: pos, size: size))
                guard rect.width >= 64, rect.height >= 64 else { return }
                lock.lock(); axRects[windowID] = (rect, rect); lock.unlock()
                return
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parentRef) == .success, let parent = parentRef else { return }
            e = parent as! AXUIElement
        }
    }

    static func occlusion(of w: ControlMessage.WindowInfo, in list: [ControlMessage.WindowInfo], display: PixelRect) -> (visibleFraction: Double, covering: [PixelRect]) {
        WindowTrackerOcclusion.occlusion(of: w, in: list, display: display)
    }
}
