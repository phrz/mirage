// Mirage Test Bench: one window with a monospaced text view (600 lines), focused, at a fixed
// place on the main display. Used by `mirage-viewer --headless --scenario …` to measure typing,
// scrolling and window dragging over the real link without touching anything else on the host.
import AppKit

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var caption: NSTextField!
    var started = Date()
    var lastStatus = ""
    /// Written by the measuring session (over ssh) before each scenario; shown live in the window.
    let statusPath = "/tmp/mirage-bench-status.txt"

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.screens.first!
        let size = NSSize(width: 1100, height: 750)
        let origin = NSPoint(x: screen.frame.minX + 240, y: screen.frame.maxY - 160 - size.height)
        let w = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Mirage Test Bench — measurement window started by Claude, safe to ignore"
        let captionHeight: CGFloat = 44
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let cap = NSTextField(labelWithString: "")
        cap.frame = NSRect(x: 12, y: size.height - captionHeight + 6, width: size.width - 24, height: captionHeight - 12)
        cap.autoresizingMask = [.width, .minYMargin]
        cap.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        cap.textColor = .white
        cap.lineBreakMode = .byTruncatingTail
        let band = NSView(frame: NSRect(x: 0, y: size.height - captionHeight, width: size.width, height: captionHeight))
        band.wantsLayer = true; band.layer?.backgroundColor = NSColor(calibratedRed: 0.42, green: 0.2, blue: 0.75, alpha: 1).cgColor
        band.autoresizingMask = [.width, .minYMargin]
        band.addSubview(cap)
        caption = cap
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - captionHeight))
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
        content.addSubview(scroll); content.addSubview(band)
        w.contentView = content
        w.makeKeyAndOrderFront(nil)
        updateCaption()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateCaption() }
        w.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateCaption() {
        let status = (try? String(contentsOfFile: statusPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status != lastStatus { lastStatus = status; started = Date() }
        let secs = Int(Date().timeIntervalSince(started))
        let what = status.isEmpty ? "idle, waiting for the next scenario" : "\(status), running for \(secs) s"
        caption.stringValue = "Mirage M2 measurement bench (started by Claude) — \(what) — this window is being scrolled, typed into and dragged by a script; safe to ignore, it closes itself"
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let d = App(); app.delegate = d
app.run()
