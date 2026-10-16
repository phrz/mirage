import Foundation
import CoreGraphics
import ApplicationServices
import MirageCore

/// Host window list (CGWindowList) in stream pixels, frame deltas between samples for drag
/// detection, and per-window scroll rects: from Accessibility (`AXScrollArea` under the pointer)
/// when available, else learned from the first detected copy-rect shift.
final class WindowTracker {
    struct Sample {
        var captureSeq: UInt32
        var windows: [ControlMessage.WindowInfo]
        var byID: [UInt32: ControlMessage.WindowInfo]
    }
    private var _current: Sample?
    private(set) var current: Sample? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }
    private var displayBounds: CGRect       // points, global
    private var pxPerPoint: Double
    private var lastSampleNanos: UInt64 = 0
    private let lock = NSLock()
    private var learned: [UInt32: PixelRect] = [:]
    private var axRects: [UInt32: (rect: PixelRect, size: PixelRect)] = [:]
    var minSampleInterval: UInt64 = 25_000_000

    init(displayID: CGDirectDisplayID, streamWidth: Int) {
        displayBounds = CGDisplayBounds(displayID)
        pxPerPoint = Double(streamWidth) / Double(displayBounds.width)
    }
    func setDisplay(_ id: CGDirectDisplayID, streamWidth: Int) {
        displayBounds = CGDisplayBounds(id)
        pxPerPoint = Double(streamWidth) / Double(displayBounds.width)
        lock.lock(); learned = [:]; axRects = [:]; lock.unlock()
    }

    func toPixels(_ r: CGRect) -> PixelRect {
        PixelRect(x: Int(((r.minX - displayBounds.minX) * pxPerPoint).rounded()), y: Int(((r.minY - displayBounds.minY) * pxPerPoint).rounded()),
                  width: Int((r.width * pxPerPoint).rounded()), height: Int((r.height * pxPerPoint).rounded()))
    }
    func toPoints(_ p: (Double, Double)) -> CGPoint { CGPoint(x: displayBounds.minX + p.0 / pxPerPoint, y: displayBounds.minY + p.1 / pxPerPoint) }

    struct Delta { let id: UInt32; let old: PixelRect; let new: PixelRect }

    /// Samples the window list (throttled). Returns the new sample and the windows that moved
    /// without resizing since the previous sample, or nil if throttled.
    func sample(captureSeq: UInt32, now: UInt64) -> (sample: Sample, moved: [Delta], changed: Bool)? {
        guard now - lastSampleNanos >= minSampleInterval else { return nil }
        lastSampleNanos = now
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return nil }
        var windows: [ControlMessage.WindowInfo] = []
        let display = displayBounds
        for (z, w) in list.enumerated() {
            guard let layer = w[kCGWindowLayer] as? Int, layer == 0,
                  let num = w[kCGWindowNumber] as? UInt32, let pid = w[kCGWindowOwnerPID] as? Int32,
                  let b = w[kCGWindowBounds] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b),
                  bounds.width >= 40, bounds.height >= 40, bounds.intersects(display) else { continue }
            if let alpha = w[kCGWindowAlpha] as? Double, alpha <= 0.01 { continue }
            let title = (w[kCGWindowName] as? String) ?? ""
            let scroll = scrollRect(for: num)
            windows.append(.init(id: num, pid: pid, title: title, frame: toPixels(bounds), z: z, scrollRect: scroll))
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
        let s = Sample(captureSeq: captureSeq, windows: windows, byID: byID)
        current = s
        return (s, moved, changed)
    }

    /// Topmost window under a stream-pixel point.
    func window(at x: Int, _ y: Int) -> ControlMessage.WindowInfo? {
        current?.windows.first { $0.frame.contains(x, y) }
    }

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
}
