import Foundation
import AppKit
import ApplicationServices
import MirageCore

/// Typeahead's host half (DESIGN §3.5 item 4): the focused text element's insertion point, line height, font and colour,
/// read through Accessibility and sent when they change. Polled every 40 ms for 2 s after each keystroke or click (the
/// caret moves then), else every 500 ms; one serial queue, since every call is IPC into the focused app.
final class CaretTracker {
    private let queue = DispatchQueue(label: "mirage.host.caret", qos: .userInitiated)
    private let send: (ControlMessage) -> Void
    private let toPixels: (CGRect) -> PixelRect
    private let inputSeq: () -> UInt64
    private var timer: DispatchSourceTimer?
    private var activeUntil: UInt64 = 0
    private var last: ControlMessage.CaretInfo?
    private var lastPoll: UInt64 = 0
    private(set) var reads = 0, sent = 0

    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField", "AXWebArea"]

    init(toPixels: @escaping (CGRect) -> PixelRect, inputSeq: @escaping () -> UInt64, send: @escaping (ControlMessage) -> Void) {
        self.toPixels = toPixels; self.inputSeq = inputSeq; self.send = send
    }
    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: .milliseconds(40))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }
    func stop() { timer?.cancel(); timer = nil }
    /// A keystroke or click was injected: the caret is about to move.
    func kick() { queue.async { self.activeUntil = Clock.nowNanos() + 2_000_000_000 } }
    func resend() { queue.async { self.last = nil } }

    private func tick() {
        let now = Clock.nowNanos()
        let fast = now < activeUntil
        guard fast || Clock.elapsed(since: lastPoll, now: now) > 500_000_000 else { return }
        lastPoll = now
        let seq = inputSeq()   // before the read: the caret read reflects at least this input
        let info = read(seq: seq)
        reads += 1
        // Changes only (the sequence alone changing is no news unless keys are flowing).
        var cmp = info; cmp.inputSeq = last?.inputSeq ?? 0
        if cmp == last, !fast { return }
        if info == last { return }
        last = info
        sent += 1
        send(.caret(info))
    }

    private func read(seq: UInt64) -> ControlMessage.CaretInfo {
        let none = ControlMessage.CaretInfo(caret: nil, field: nil, pid: 0, font: nil, size: nil, color: nil, selection: false, secure: false, inputSeq: seq)
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        guard let focused: AXUIElement = attr(sys, kAXFocusedUIElementAttribute) else { return none }
        AXUIElementSetMessagingTimeout(focused, 0.15)
        var pid: pid_t = 0; AXUIElementGetPid(focused, &pid)
        let role: String = attr(focused, kAXRoleAttribute) ?? ""
        let subrole: String = attr(focused, kAXSubroleAttribute) ?? ""
        guard Self.textRoles.contains(role) else { return none }
        let secure = subrole == kAXSecureTextFieldSubrole
        guard let rangeVal: AXValue = attr(focused, kAXSelectedTextRangeAttribute) else { return none }
        var range = CFRange(); guard AXValueGetValue(rangeVal, .cfRange, &range) else { return none }
        let field: PixelRect? = frame(focused).map(toPixels)
        // The caret: the right edge of the character before it (or the left edge of the first one), its line's height.
        var caretRect: CGRect? = nil
        var fontName: String? = nil, fontSize: Double? = nil, color: [Double]? = nil
        let probe = range.location > 0 ? CFRange(location: range.location - 1, length: 1) : CFRange(location: 0, length: 1)
        if let r = bounds(focused, probe), r.height > 1 {
            caretRect = CGRect(x: range.location > 0 ? r.maxX : r.minX, y: r.minY, width: 0, height: r.height)
            // Font and colour of that character.
            var p = probe
            if let pv = AXValueCreate(.cfRange, &p) {
                var out: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(focused, kAXAttributedStringForRangeParameterizedAttribute as CFString, pv, &out) == .success, let a = out as? NSAttributedString, a.length > 0 {
                    let attrs = a.attributes(at: 0, effectiveRange: nil)
                    if let f = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
                        fontName = f["AXFontName"] as? String; fontSize = (f["AXFontSize"] as? NSNumber)?.doubleValue
                    }
                    if let c = attrs[NSAttributedString.Key("AXForegroundColor")] {
                        let cg = c as! CGColor
                        if let s = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil), let comps = s.components, comps.count >= 3 { color = comps.map(Double.init) }
                    }
                }
            }
        } else if range.location == 0, let f = frame(focused) {
            // An empty field: the caret sits at its left edge, vertically centred, with no font known.
            caretRect = CGRect(x: f.minX + 4, y: f.midY - 8, width: 0, height: 16)
        }
        return .init(caret: caretRect.map(toPixels), field: field, pid: pid, font: fontName, size: fontSize, color: color, selection: range.length > 0, secure: secure, inputSeq: seq)
    }

    private func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &ref) == .success, let ref else { return nil }
        return ref as? T
    }
    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let p: AXValue = attr(e, kAXPositionAttribute), let s: AXValue = attr(e, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &pos), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }
    private func bounds(_ e: AXUIElement, _ r: CFRange) -> CGRect? {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, v, &out) == .success, let o = out else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(o as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
