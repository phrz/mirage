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
        // `--static`: cover the whole screen with a window that never changes (no caret, fixed caption),
        // so a loopback host sees a genuinely static picture (the static-picture refinement test).
        // `--motion`: the same full-screen cover with a continuously animating 640×480 region, so a loopback
        // host has a picture that changes every frame (the §4a loss and burst runs need a moving picture
        // of our own; nothing else on the display is involved).
        let isMotion = CommandLine.arguments.contains("--motion")
        // `--drift`: an 800×500 window that drags *itself* in 0.8 s bursts of 6×3 pt per 16 ms every 6 s
        // (what the drag scenario does with the pointer), without taking focus and without any input
        // being injected: the window-drag path is measured while the person at the machine keeps working.
        let isDrift = CommandLine.arguments.contains("--drift")
        let isStatic = CommandLine.arguments.contains("--static") || isMotion
        let size = isStatic ? NSSize(width: screen.frame.width, height: screen.frame.height - 25) : isDrift ? NSSize(width: 800, height: 500) : NSSize(width: 1100, height: 750)
        let origin = isStatic ? NSPoint(x: screen.frame.minX, y: screen.frame.minY) : NSPoint(x: screen.frame.minX + 240, y: screen.frame.maxY - 160 - size.height)
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
        // An NSBox, not a layer-backed view: layer-backing the window makes the text view re-render every
        // frame, which the measuring host sees as a full-window change (measured: 1.5 Mbps of refinement).
        let band = NSBox(frame: NSRect(x: 0, y: size.height - captionHeight, width: size.width, height: captionHeight))
        band.boxType = .custom; band.borderWidth = 0; band.fillColor = NSColor(calibratedRed: 0.42, green: 0.2, blue: 0.75, alpha: 1)
        band.autoresizingMask = [.width, .minYMargin]
        band.contentView?.addSubview(cap)
        caption = cap
        // A password-style field (the "login-screen typing" acceptance test types into it, never into the real login).
        let fieldHeight: CGFloat = 40
        let field = NSSecureTextField(frame: NSRect(x: 20, y: size.height - captionHeight - fieldHeight + 6, width: 360, height: 28))
        field.placeholderString = "password-style field for the typing-latency test"
        field.autoresizingMask = [.minYMargin]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - captionHeight - fieldHeight))
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
        content.addSubview(scroll); content.addSubview(field); content.addSubview(band)
        if isMotion {
            let mv = MotionView(frame: NSRect(x: (size.width - 640) / 2, y: (size.height - 480) / 2 - 60, width: 640, height: 480))
            content.addSubview(mv)
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in mv.step() }
        }
        w.contentView = content
        if isDrift {
            // Normal level (the host's window list only carries layer-0 windows), ordered front without activating.
            tv.isSelectable = false; tv.isEditable = false
            w.orderFrontRegardless()
            updateCaption()
            var dir: CGFloat = 1
            Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
                guard let self, let win = self.window else { return }
                var step = 0
                Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { t in
                    step += 1
                    var f = win.frame; f.origin.x += 6 * dir; f.origin.y -= 3 * dir
                    win.setFrameOrigin(f.origin)
                    if step >= 50 { t.invalidate(); dir = -dir }
                }
            }
            window = w
            return
        }
        w.makeKeyAndOrderFront(nil)
        updateCaption()
        if !isStatic { Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.updateCaption() } }
        if isStatic { w.level = .floating; w.makeFirstResponder(nil); tv.isSelectable = false; tv.isEditable = false } else { w.makeFirstResponder(tv) }
        tv.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateCaption() {
        // Only redraw when the status really changed: every caption change is a pixel change the host must send.
        let status = (try? String(contentsOfFile: statusPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard status != lastStatus || caption.stringValue.isEmpty else { return }
        lastStatus = status
        let what = status.isEmpty ? "idle, waiting for the next scenario" : status
        caption.stringValue = "Mirage M2 measurement bench (started by Claude) — \(what) — a script scrolls, types into and drags this window; safe to ignore, it closes itself"
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
/// A bouncing disc over moving stripes with a frame counter: every 30 fps tick changes most of the region.
final class MotionView: NSView {
    var t = 0
    var x = 100.0, y = 100.0, vx = 7.0, vy = 5.0
    override var isOpaque: Bool { true }
    func step() {
        t += 1
        x += vx; y += vy
        if x < 40 || x > bounds.width - 40 { vx = -vx }
        if y < 40 || y > bounds.height - 40 { vy = -vy }
        needsDisplay = true
    }
    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
        // Stripes that drift one pixel per frame (photographic-ish motion the encoder cannot skip).
        for i in stride(from: -64, to: Int(bounds.width) + 64, by: 32) {
            let shade = CGFloat((i / 32) % 2 == 0 ? 0.22 : 0.3)
            NSColor(calibratedRed: shade, green: shade * 0.9, blue: shade * 1.2, alpha: 1).setFill()
            NSRect(x: CGFloat(i + t % 64), y: 0, width: 16, height: bounds.height).fill()
        }
        NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.2, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 36, y: y - 36, width: 72, height: 72)).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.white]
        ("frame \(t)" as NSString).draw(at: NSPoint(x: 16, y: bounds.height - 48), withAttributes: attrs)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let d = App(); app.delegate = d
app.run()
