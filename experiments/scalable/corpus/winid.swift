// Prints the window number of the on-screen, layer-0 window owned by PID (the Test Bench scene window),
// for `screencapture -l`. Only that window is ever captured, never the screen.
import CoreGraphics
import Foundation

let pid = Int(CommandLine.arguments.dropFirst().first ?? "") ?? -1
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let n = w[kCGWindowNumber as String] as? Int { print(n); break }
}
