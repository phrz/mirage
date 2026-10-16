import ApplicationServices
import AppKit
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
var items = 0
func walk(_ e: AXUIElement, depth: Int, out: inout [String]) {
    for c in children(e) {
        let role = attr(c, kAXRoleAttribute) as? String ?? "?"
        let title = attr(c, kAXTitleAttribute) as? String ?? ""
        let enabled = (attr(c, kAXEnabledAttribute) as? Bool) ?? true
        let cmd = attr(c, kAXMenuItemCmdCharAttribute) as? String ?? ""
        if role == "AXMenuItem" || role == "AXMenuBarItem" { items += 1 }
        if depth < 2 && role == "AXMenuBarItem" { out.append(String(repeating: "  ", count: depth) + "\(title)") }
        if depth == 2 && out.count < 40 && !title.isEmpty { out.append(String(repeating: "  ", count: depth) + "\(title)\(cmd.isEmpty ? "" : "  ⌘\(cmd)")\(enabled ? "" : " (disabled)")") }
        if depth < 4 { walk(c, depth: depth + 1, out: &out) }
    }
}
for name in ["Mail", "Finder", "Sketch"] {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { print("\(name): not running"); continue }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let bar = attr(ax, kAXMenuBarAttribute) else { print("\(name): no AXMenuBar"); continue }
    let t0 = Date(); items = 0; var out = [String]()
    walk(bar as! AXUIElement, depth: 0, out: &out)
    print("\(name): \(items) menu items walked in \(Int(Date().timeIntervalSince(t0) * 1000)) ms; top-level: \(out.filter { !$0.hasPrefix(" ") }.joined(separator: " | "))")
    print("   sample: " + out.filter { $0.hasPrefix("    ") }.prefix(6).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " / "))
}
// Status items: windows at the status bar layer, by owner.
let wl = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var owners = [String: Int]()
for w in wl where (w[kCGWindowLayer as String] as? Int) == 25 { owners[w[kCGWindowOwnerName as String] as? String ?? "?", default: 0] += 1 }
print("status-item windows (layer 25) by owner: \(owners.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
