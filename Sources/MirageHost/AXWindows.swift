import Foundation
import AppKit
import ApplicationServices
import MirageCore

/// Applies the client's window-management decisions through Accessibility (DESIGN §3.5 item 2): a
/// drag the client already shows becomes `kAXPositionAttribute`, a raise `AXRaise` plus app
/// activation, minimize/restore `kAXMinimizedAttribute`. Window elements are found per (pid, CGWindow
/// id) by matching the AX window's frame and title against the CGWindowList entry, and cached.
/// Every call blocks for a few ms of IPC, so this runs on its own serial queue.
final class AXWindows {
    private let queue = DispatchQueue(label: "mirage.host.ax", qos: .userInitiated)
    private var cache: [UInt32: AXUIElement] = [:]
    private let log: (String) -> Void
    private var lastLogNanos: UInt64 = 0
    private(set) var applied = 0, failed = 0

    init(log: @escaping (String) -> Void) { self.log = log }

    struct Target { let id: UInt32; let pid: Int32; let title: String; let bounds: CGRect }   // points, global top-left origin

    /// Applies a command; `target` is the window's current CGWindowList entry; `origin` in points.
    func apply(_ c: ControlMessage.WindowCommand, target: Target, origin: CGPoint?, completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            let ok = perform(c, target: target, origin: origin)
            if ok { applied += 1 } else { failed += 1 }
            completion?(ok)
        }
    }

    private func perform(_ c: ControlMessage.WindowCommand, target: Target, origin: CGPoint?) -> Bool {
        guard let elem = element(for: target) else {
            if Clock.nowNanos() - lastLogNanos > 2_000_000_000 { lastLogNanos = Clock.nowNanos(); log("ax: no accessibility window for \(target.id) (pid \(target.pid), '\(target.title.prefix(30))')") }
            return false
        }
        switch c.action {
        case .raise:
            let r = AXUIElementPerformAction(elem, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: target.pid)?.activate()
            if r != .success { cache[target.id] = nil }
            return r == .success
        case .move:
            guard var p = origin else { return false }
            guard let v = AXValueCreate(.cgPoint, &p) else { return false }
            let r = AXUIElementSetAttributeValue(elem, kAXPositionAttribute as CFString, v)
            if r != .success { cache[target.id] = nil }
            return r == .success
        case .minimize, .restore:
            let r = AXUIElementSetAttributeValue(elem, kAXMinimizedAttribute as CFString, (c.action == .minimize ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
            if r != .success { cache[target.id] = nil }
            return r == .success
        case .close:
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(elem, kAXCloseButtonAttribute as CFString, &button) == .success, let b = button else { return false }
            return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
        }
    }

    /// The AX window element matching a CGWindowList entry, by frame (within 2 pt) then title.
    private func element(for t: Target) -> AXUIElement? {
        if let e = cache[t.id], frame(of: e) != nil { return e }
        let app = AXUIElementCreateApplication(t.pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success, let windows = windowsRef as? [AXUIElement] else { return nil }
        var byTitle: AXUIElement? = nil
        for w in windows {
            if let f = frame(of: w), abs(f.minX - t.bounds.minX) <= 2, abs(f.minY - t.bounds.minY) <= 2, abs(f.width - t.bounds.width) <= 2, abs(f.height - t.bounds.height) <= 2 {
                cache[t.id] = w; return w
            }
            if byTitle == nil, !t.title.isEmpty {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef) == .success, let title = titleRef as? String, title == t.title { byTitle = w }
            }
        }
        if let w = byTitle { cache[t.id] = w }
        return byTitle
    }

    private func frame(of e: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos), AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    func forget(_ id: UInt32) { queue.async { self.cache[id] = nil } }
}
