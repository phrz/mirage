import CoreGraphics
import Foundation
let wl = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in wl {
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as! [String: CGFloat]
    guard b["Y"]! < 2, b["Height"]! <= 40 else { continue }
    print("layer \(layer)\t\(w[kCGWindowOwnerName as String] ?? "?")\t\(Int(b["X"]!)),\(Int(b["Y"]!)) \(Int(b["Width"]!))x\(Int(b["Height"]!))\t\(w[kCGWindowName as String] as? String ?? "")")
}
