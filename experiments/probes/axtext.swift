import ApplicationServices
import AppKit
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func param(_ e: AXUIElement, _ a: String, _ p: AnyObject) -> AnyObject? { var v: AnyObject?; AXUIElementCopyParameterizedAttributeValue(e, a as CFString, p, &v); return v }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
var visited = 0
func findText(_ e: AXUIElement, depth: Int, found: inout [AXUIElement]) {
    visited += 1
    if visited > 20000 || found.count >= 3 || depth > 14 { return }
    let role = attr(e, kAXRoleAttribute) as? String ?? ""
    if (role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox"), let v = attr(e, kAXValueAttribute) as? String, v.count >= 1 { found.append(e) }
    if role == "AXStaticText", found.count < 3, depth > 6, let v = attr(e, kAXValueAttribute) as? String, v.count > 8 { found.append(e) }
    for c in children(e) { findText(c, depth: depth + 1, found: &found) }
}
for name in ["Helium", "Claude"] {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { print("\(name): not running"); continue }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    if name == "Claude" || name == "Helium" {
        // Chromium/Electron only build their AX tree when an assistive client announces itself.
        let r1 = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let r2 = AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        print("\(name): enabled AXManualAccessibility=\(r1.rawValue) AXEnhancedUserInterface=\(r2.rawValue)")
        Thread.sleep(forTimeInterval: 1.5)
    }
    var found = [AXUIElement](); visited = 0
    let t0 = Date()
    findText(ax, depth: 0, found: &found)
    print("\(name): \(found.count) text elements found after visiting \(visited) nodes in \(Int(Date().timeIntervalSince(t0)*1000)) ms")
    for e in found.prefix(2) {
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        let value = (attr(e, kAXValueAttribute) as? String ?? "")
        var range = CFRange(location: 0, length: min(3, value.count))
        let rv = AXValueCreate(.cfRange, &range)!
        var bounds = "n/a"
        if let b = param(e, kAXBoundsForRangeParameterizedAttribute, rv) { var r = CGRect.zero; AXValueGetValue(b as! AXValue, .cgRect, &r); bounds = "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
        var font = "n/a"
        if let s = param(e, kAXAttributedStringForRangeParameterizedAttribute, rv) as? NSAttributedString, s.length > 0 {
            let a = s.attributes(at: 0, effectiveRange: nil)
            if let f = a[.font] as? NSFont { font = "\(f.fontName) \(f.pointSize)" }
            else if let d = a[NSAttributedString.Key("AXFont")] as? [String: Any] { font = "AXFont \(d["AXFontName"] ?? "?") \(d["AXFontSize"] ?? "?")" }
            else { font = "attrs: \(a.keys.map { $0.rawValue }.joined(separator: ","))" }
        }
        let sel = attr(e, kAXSelectedTextRangeAttribute) != nil
        print("   \(role) value=\"\(value.prefix(20).replacingOccurrences(of: "\n", with: "⏎"))\"  boundsForRange(0..3)=\(bounds)  font=\(font)  selectedRange=\(sel)")
    }
}
