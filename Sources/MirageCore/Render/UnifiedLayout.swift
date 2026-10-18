import Foundation

/// Unified mode (DESIGN §3.2, §3.5 item 2, §3.8): which host windows become native windows on the client, what
/// each shows, where it sits on the local screen and which local window it belongs to. Separate from AppKit so it
/// can be tested; the viewer turns every entry into an `NSWindow`.
///
/// - A window the host captures as its own layer, whose canvas the viewer holds, is a *window* showing that canvas.
/// - Menus, popovers, tooltips and other cut-out-safe windows above the normal level are *transients*: short-lived
///   child windows of the frontmost window of the same app that they touch (else of that app's frontmost window),
///   showing their rect of the display layer; one whose app has no remote window is not shown. The dock and the menu
///   bar are not shown (native chrome replaces them), nor normal windows the host does not capture as layers.
/// - A window of the same app lying in the top band of a larger one (a sheet, an attached panel) is that window's
///   child, so it moves with it.
public struct UnifiedLayout: Equatable {
    public enum Source: Equatable { case layer(UInt32), display(PixelRect) }
    public enum Role: Equatable { case window, transient }
    public struct Entry: Equatable {
        public var id: UInt32
        public var pid: Int32
        public var role: Role
        public var source: Source
        /// Display-layer pixels (may extend beyond the display).
        public var frame: PixelRect
        public var parent: UInt32?
        public var level: Int
        public var title: String
        public var app: String
        public var controls: PixelRect?
        public init(id: UInt32, pid: Int32, role: Role, source: Source, frame: PixelRect, parent: UInt32?, level: Int, title: String, app: String, controls: PixelRect?) {
            self.id = id; self.pid = pid; self.role = role; self.source = source; self.frame = frame; self.parent = parent; self.level = level; self.title = title; self.app = app; self.controls = controls
        }
    }
    public var entries: [Entry]   // front to back

    public static let dockLevel = 20, menuBarLevels: Set<Int> = [24, 25]

    /// `anchoredApps`: apps whose status item (or menu-bar strip) the person just clicked here: their transients are shown
    /// without a remote window, and the viewer places them under the local item.
    public static func plan(_ windows: [ControlMessage.WindowInfo], hasCanvas: (UInt32) -> Bool, display: PixelRect, anchoredApps: Set<Int32> = []) -> UnifiedLayout {
        var entries: [Entry] = []
        for w in windows {
            let level = w.windowLevel
            let entry: Entry
            if w.isLayered {
                guard hasCanvas(w.id) else { continue }
                entry = Entry(id: w.id, pid: w.pid, role: .window, source: .layer(w.id), frame: w.frame, parent: nil, level: level, title: w.title, app: w.app ?? "", controls: w.controls)
            } else if w.cutout ?? false {
                // Normal windows the host does not capture (beyond the layer cap, or kept out by policy) are not shown:
                // their display-layer pixels may be covered on the host. Neither are the dock and the menu bar.
                if level == 0 || level == dockLevel || menuBarLevels.contains(level) { continue }
                let onScreen = w.frame.intersection(display)
                guard !onScreen.isEmpty else { continue }
                // Never anything desktop-sized above the normal level (an overlay the host misjudged).
                if level != 0, onScreen.area * 10 >= display.area * 9 { continue }
                entry = Entry(id: w.id, pid: w.pid, role: .transient, source: .display(onScreen), frame: onScreen, parent: nil, level: level, title: w.title, app: w.app ?? "", controls: w.controls)
            } else { continue }
            entries.append(entry)
        }
        // Parents: transients attach to the frontmost same-app window they touch, else that app's frontmost window;
        // a smaller same-app window inside a larger one's top band (a sheet) attaches to it.
        let windowsOnly = entries.filter { $0.role == .window }
        for i in entries.indices {
            let e = entries[i]
            let sameApp = windowsOnly.filter { $0.pid == e.pid && $0.id != e.id }
            switch e.role {
            case .transient:
                entries[i].parent = (sameApp.first { !$0.frame.intersection(grown(e.frame, 8)).isEmpty } ?? sameApp.first)?.id
            case .window:
                if let p = sameApp.first(where: { p in
                    p.frame.area > e.frame.area && e.frame.x >= p.frame.x - 2 && e.frame.maxX <= p.frame.maxX + 2
                        && e.frame.y >= p.frame.y && e.frame.y <= p.frame.y + max(120, p.frame.height / 6) && e.frame.maxY <= p.frame.maxY + 2
                }) { entries[i].parent = p.id }
            }
        }
        // A transient belongs to a remote window of its app; one with none (another app's menu, Spotlight) is not shown.
        entries.removeAll { $0.role == .transient && $0.parent == nil && !anchoredApps.contains($0.pid) }
        return UnifiedLayout(entries: entries)
    }

    static func grown(_ r: PixelRect, _ m: Int) -> PixelRect { PixelRect(x: r.x - m, y: r.y - m, width: r.width + 2 * m, height: r.height + 2 * m) }

    // MARK: Traffic lights

    public enum TitleControl: String, Equatable { case close, minimize, zoom }
    /// Which traffic light a window-relative pixel hits: the controls rect split into thirds, grown a little (the
    /// buttons' hit areas are larger than their glyphs). Nil without a controls rect: the click goes to the host.
    public static func control(at x: Int, _ y: Int, controls: PixelRect?) -> TitleControl? {
        guard let c = controls, c.width >= 3 else { return nil }
        let g = grown(c, 2)
        guard g.contains(x, y) else { return nil }
        let third = Double(c.width) / 3
        switch Int(Double(x - c.x) / third) {
        case ..<1: return .close
        case 1: return .minimize
        default: return .zoom
        }
    }

    /// Whether a press at a window-relative pixel may start a window drag: the title-bar band (`titleBarPx` tall),
    /// right of the traffic lights.
    public static func isDragRegion(_ x: Int, _ y: Int, controls: PixelRect?, titleBarPx: Int, trafficLightsPx: Int) -> Bool {
        guard y >= 0, y < titleBarPx else { return false }
        let right = controls.map { $0.maxX + 4 } ?? trafficLightsPx
        return x > right
    }
}

/// Host display pixels ↔ local screen points for Unified mode, pixel-exact: one stream pixel is one local backing
/// pixel, so a remote window is as crisp as a local one. The host display's top-left sits at the local main
/// screen's top-left, pushed down by however much taller the local menu bar is (a notched MacBook), so a window
/// just under the host's menu bar lands just under the local one. Local coordinates here are top-left-origin
/// global points (AppKit's are flipped by the viewer).
public struct UnifiedGeometry: Equatable {
    /// Stream pixels per local point (the local backing scale).
    public var pixelsPerPoint: Double
    /// Local top-left-origin point of the host display's (0, 0).
    public var originX: Double, originY: Double
    public init(pixelsPerPoint: Double, originX: Double = 0, originY: Double = 0) {
        self.pixelsPerPoint = max(0.25, pixelsPerPoint); self.originX = originX; self.originY = originY
    }
    /// `hostMenuBarPx`: the host menu bar's height in stream pixels; `localMenuBarPoints`: the local one's.
    public static func make(pixelsPerPoint: Double, screenX: Double, screenY: Double, hostMenuBarPx: Int, localMenuBarPoints: Double) -> UnifiedGeometry {
        let hostBar = Double(hostMenuBarPx) / max(0.25, pixelsPerPoint)
        return UnifiedGeometry(pixelsPerPoint: pixelsPerPoint, originX: screenX, originY: screenY + max(0, localMenuBarPoints - hostBar))
    }
    public struct LocalRect: Equatable { public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height } }
    public func local(_ r: PixelRect) -> LocalRect {
        LocalRect(x: originX + Double(r.x) / pixelsPerPoint, y: originY + Double(r.y) / pixelsPerPoint, width: Double(r.width) / pixelsPerPoint, height: Double(r.height) / pixelsPerPoint)
    }
    public func host(_ r: LocalRect) -> PixelRect {
        PixelRect(x: Int(((r.x - originX) * pixelsPerPoint).rounded()), y: Int(((r.y - originY) * pixelsPerPoint).rounded()),
                  width: Int((r.width * pixelsPerPoint).rounded()), height: Int((r.height * pixelsPerPoint).rounded()))
    }
    /// The stream size Unified mode wants: the host display at one host point per local point. Nil when the current
    /// stream is within 15 % of it (keeping it avoids a fresh picture for nothing).
    public static func wantedStream(current: (Int, Int), hostPoints: (Int, Int), backingScale: Double) -> (Int, Int)? {
        let w = Int(Double(hostPoints.0) * backingScale), h = Int(Double(hostPoints.1) * backingScale)
        guard w > 0, h > 0 else { return nil }
        if current.0 > 0, abs(Double(current.0) / Double(w) - 1) <= 0.15 { return nil }
        return (w, h)
    }
}
