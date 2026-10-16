// Mirage Test Bench: one window with a monospaced text view (600 lines), focused, at a fixed
// place on the main display. Used by `mirage-viewer --headless --scenario …` to measure typing,
// scrolling and window dragging over the real link without touching anything else on the host.
import AppKit

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.screens.first!
        let size = NSSize(width: 1100, height: 750)
        let origin = NSPoint(x: screen.frame.minX + 240, y: screen.frame.maxY - 160 - size.height)
        let w = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Mirage Test Bench"
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: NSRect(origin: .zero, size: size))
        tv.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.isRichText = false; tv.autoresizingMask = [.width]; tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        var text = ""
        let words = ["mirage", "tailnet", "quic", "hevc", "tile", "lossless", "copy-rect", "scroll", "latency", "budget", "canvas", "keyframe", "refine", "predict", "crisp"]
        var rng: UInt64 = 42
        for i in 1...600 {
            var line = String(format: "%4d  ", i)
            for _ in 0..<9 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; line += words[Int(rng >> 33) % words.count] + " " }
            text += line + "\n"
        }
        tv.string = text
        scroll.documentView = tv
        w.contentView = scroll
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let d = App(); app.delegate = d
app.run()
