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

    var statusItem: NSStatusItem?
    @objc func benchAction(_ sender: NSMenuItem) { NSLog("bench menu: %@", sender.title) }
    /// A main menu (File, Edit, View with a submenu, shortcuts, a checked item) and, with `--status`, a status item with
    /// its own menu: what the native-chrome check (menus from Accessibility, the status strip) reads, our app only.
    func installMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [(String, String)]) {
            let it = NSMenuItem(); let m = NSMenu(title: title)
            for (t, k) in items { if t == "-" { m.addItem(.separator()) } else { m.addItem(withTitle: t, action: #selector(benchAction(_:)), keyEquivalent: k).target = self } }
            it.submenu = m; main.addItem(it)
        }
        menu("Mirage Test Bench", [("About the Bench", ""), ("-", ""), ("Quit Bench", "q")])
        menu("File", [("New Measurement", "n"), ("Open…", "o"), ("-", ""), ("Close", "w")])
        menu("Edit", [("Undo", "z"), ("Copy", "c"), ("Paste", "v")])
        menu("View", [("Show Caption", ""), ("Zoom In", "+")])
        if let view = main.items.last?.submenu {
            view.items.first?.state = .on
            let sub = NSMenu(title: "Density"); for t in ["Compact", "Regular", "Roomy"] { sub.addItem(withTitle: t, action: #selector(benchAction(_:)), keyEquivalent: "").target = self }
            let it = NSMenuItem(title: "Density", action: nil, keyEquivalent: ""); it.submenu = sub; view.addItem(it)
        }
        NSApp.mainMenu = main
        if CommandLine.arguments.contains("--status") {
            let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            si.button?.title = "MTB"
            let m = NSMenu(); m.addItem(withTitle: "Bench status: measuring", action: nil, keyEquivalent: ""); m.addItem(withTitle: "Ping", action: #selector(benchAction(_:)), keyEquivalent: "").target = self
            si.menu = m
            statusItem = si
        }
    }

    var tooltips: [NSWindow] = []
    /// `--tooltip`: two bright green help-level windows (like the Dock's app-name tooltips) that fade in, stay 1.5 s, fade
    /// out and stay away 2.5 s, one over the desktop left of the bench and one over the bench's text: the transient-ghost
    /// check samples where they were after they go.
    func startTooltips(over bench: NSWindow) {
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
        let b = bench.frame
        // 0: over the desktop; 1: over the bench; 2: straddling the bench's left edge (the desktop tiles that touch a window).
        for (i, r) in [NSRect(x: max(8, b.minX - 200), y: b.midY, width: 160, height: 26), NSRect(x: b.midX - 80, y: b.midY - 60, width: 160, height: 26),
                       NSRect(x: b.minX - 100, y: b.minY + 80, width: 160, height: 26)].enumerated() {
            let t = NSWindow(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false)
            t.level = level; t.isOpaque = true; t.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.95, blue: 0.2, alpha: 1)
            t.hasShadow = true; t.ignoresMouseEvents = true; t.title = "Mirage Test Bench tooltip \(i)"
            t.collectionBehavior = [.transient, .ignoresCycle]
            tooltips.append(t)
        }
        func cycle() {
            for t in tooltips { t.alphaValue = 0; t.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.12; for t in tooltips { t.animator().alphaValue = 1 } })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSAnimationContext.runAnimationGroup({ c in c.duration = 0.15; for t in self.tooltips { t.animator().alphaValue = 0 } }, completionHandler: {
                    for t in self.tooltips { t.orderOut(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { cycle() }
                })
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { cycle() }
    }

    /// `--docklike`: what the Dock is on macOS 27, one full-screen transparent window at the Dock level (20), click-through,
    /// drawing its own app-name tooltips inside: here two green labels (one clear of the bench, one straddling its left
    /// edge) that fade in, stay 1.5 s, fade out and stay away 2.5 s. No window list change ever announces them.
    func startDockLike(screen: NSScreen, near b: NSRect) {
        let o = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        o.isOpaque = false; o.backgroundColor = .clear; o.hasShadow = false; o.ignoresMouseEvents = true
        o.level = NSWindow.Level(rawValue: 20); o.title = "Mirage Test Bench docklike"
        o.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size)); root.wantsLayer = true
        var labels: [NSView] = []
        for r in [NSRect(x: max(8, b.minX - screen.frame.minX - 200), y: b.minY - screen.frame.minY + 40, width: 160, height: 26),
                  NSRect(x: b.minX - screen.frame.minX - 100, y: b.minY - screen.frame.minY + 140, width: 160, height: 26)] {
            let v = NSView(frame: r); v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.95, blue: 0.2, alpha: 1).cgColor; v.layer?.cornerRadius = 6
            v.alphaValue = 0; root.addSubview(v); labels.append(v)
        }
        o.contentView = root
        o.orderFrontRegardless()
        dockLike = o
        func cycle() {
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.12; for v in labels { v.animator().alphaValue = 1 } })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; for v in labels { v.animator().alphaValue = 0 } })
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) { cycle() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { cycle() }
    }
    var dockLike: NSWindow?
    var vibrancy: [NSWindow] = []
    /// `--vibrancy`: a Dock hover without the Dock: a translucent behind-window material band near the bottom of the
    /// screen whose six "icons" magnify one after another (0.3 s each, like the pointer sweeping along the Dock), over a
    /// coloured block that moves behind it, so the band's blur re-renders every frame. A big region changing continuously
    /// that must stay motion/tiles for that region, never a whole-desktop restart (phrz's Dock hover on 949c064).
    func startVibrancy(screen: NSScreen) {
        let band = NSRect(x: screen.frame.minX + 120, y: screen.frame.minY + 90, width: min(900, screen.frame.width - 240), height: 110)
        let back = NSWindow(contentRect: NSRect(x: band.minX, y: band.minY - 20, width: 160, height: band.height + 40), styleMask: [.borderless], backing: .buffered, defer: false)
        back.backgroundColor = NSColor(calibratedRed: 0.9, green: 0.3, blue: 0.1, alpha: 1); back.title = "Mirage Test Bench vibrancy back"; back.ignoresMouseEvents = true
        back.level = NSWindow.Level(rawValue: 19); back.orderFrontRegardless()
        let w = NSWindow(contentRect: band, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.level = NSWindow.Level(rawValue: 20); w.ignoresMouseEvents = true; w.title = "Mirage Test Bench vibrancy"
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: band.size)); fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 18; fx.layer?.masksToBounds = true
        var icons: [NSView] = []
        for i in 0..<6 {
            let v = NSView(frame: NSRect(x: 30 + CGFloat(i) * 140, y: 25, width: 60, height: 60)); v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(calibratedHue: CGFloat(i) / 6, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor; v.layer?.cornerRadius = 14
            fx.addSubview(v); icons.append(v)
        }
        w.contentView = fx; w.orderFrontRegardless()
        vibrancy = [back, w]
        var t = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            t += 1
            let x = band.minX + CGFloat((t * 6) % Int(band.width - 160))
            back.setFrameOrigin(NSPoint(x: x, y: back.frame.minY))
            let hot = (t / 9) % 6
            for (i, v) in icons.enumerated() { let s: CGFloat = i == hot ? 1.5 : 1; v.layer?.setAffineTransform(CGAffineTransform(scaleX: s, y: s)) }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        installMenus()
        let screen = NSScreen.screens.first!
        // `--overlay`: a full-screen, fully transparent, click-through window at the floating level, like the
        // overlays some utilities keep on screen (the M3.1 field regression: a viewer that drew such a window as
        // a cut-out of the display layer painted the desktop over every window layer).
        // `--icons`: a full-screen, transparent window at the *normal* level, ordered behind everything, with a few
        // opaque icon-like squares: what a desktop-icons app window looks like to the window list (the M3.1 field
        // case where the bench's underlay was deferred as "covered twice" and a move uncovered fill).
        // `--photo`: a full-screen opaque photographic-looking picture (smooth gradients plus noise, > 4096 colours)
        // at the normal level behind everything: a wallpaper of our own for the underlay / upgrade path.
        if CommandLine.arguments.contains("--photo") {
            let o = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            o.hasShadow = false; o.ignoresMouseEvents = true; o.title = "Mirage photo backdrop (measurement, closes itself)"
            o.contentView = PhotoView(frame: NSRect(origin: .zero, size: screen.frame.size))
            // --front: above the person's windows (start the drifting bench after it, so the bench is on top).
            if CommandLine.arguments.contains("--front") { o.orderFrontRegardless() } else { o.orderBack(nil) }
            window = o
            return
        }
        if CommandLine.arguments.contains("--icons") {
            let o = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            o.isOpaque = false; o.backgroundColor = .clear; o.hasShadow = false; o.ignoresMouseEvents = true
            o.title = "Mirage Test Bench icons"
            o.contentView = IconsView(frame: NSRect(origin: .zero, size: screen.frame.size))
            o.orderBack(nil)
            window = o
            return
        }
        if CommandLine.arguments.contains("--overlay") {
            let o = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            o.isOpaque = false; o.backgroundColor = .clear; o.hasShadow = false; o.ignoresMouseEvents = true
            o.level = .floating; o.title = "Mirage Test Bench overlay"
            o.collectionBehavior = [.canJoinAllSpaces, .stationary]
            o.orderFrontRegardless()
            window = o
            return
        }
        // `--static`: cover the whole screen with a window that never changes (no caret, fixed caption),
        // so a loopback host sees a genuinely static picture (the static-picture refinement test).
        // `--motion`: the same full-screen cover with a continuously animating 640×480 region, so a loopback
        // host has a picture that changes every frame (the §4a loss and burst runs need a moving picture
        // of our own; nothing else on the display is involved).
        let isMotion = CommandLine.arguments.contains("--motion")
        // `--drift`: an 800×500 window that drags *itself* in 0.8 s bursts of 6×3 pt per 16 ms every 6 s
        // (what the drag scenario does with the pointer), without taking focus and without any input
        // being injected: the window-drag path is measured while the person at the machine keeps working.
        // `--burst`: a still window whose whole text is replaced every 8 s (a burst of changed pixels, then its
        // refinement: the presentation-steps test of DESIGN §3.3).
        let isBurst = CommandLine.arguments.contains("--burst")
        let isDrift = CommandLine.arguments.contains("--drift") || CommandLine.arguments.contains("--still") || isBurst
        // `--still`: the drift window without the motion (several instances make a cheap set of windows of our own
        // to measure per-window capture against), offset by --index N so they do not stack exactly.
        let isStill = CommandLine.arguments.contains("--still") || isBurst
        let index = CommandLine.arguments.firstIndex(of: "--index").flatMap { Int(CommandLine.arguments[$0 + 1]) } ?? 0
        let isStatic = CommandLine.arguments.contains("--static") || isMotion
        let size = isStatic ? NSSize(width: screen.frame.width, height: screen.frame.height - 25) : isDrift ? NSSize(width: 800, height: 500) : NSSize(width: 1100, height: 750)
        let origin = isStatic ? NSPoint(x: screen.frame.minX, y: screen.frame.minY) : NSPoint(x: screen.frame.minX + 240 + CGFloat(index * 40), y: screen.frame.maxY - 160 - size.height - CGFloat(index * 30))
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
            if CommandLine.arguments.contains("--tooltip") { startTooltips(over: w) }
            if CommandLine.arguments.contains("--docklike") { startDockLike(screen: screen, near: w.frame) }
            if CommandLine.arguments.contains("--vibrancy") { startVibrancy(screen: screen) }
            updateCaption()
            window = w
            if isBurst {
                var seed: UInt64 = 7
                Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { _ in
                    seed &+= 1
                    var r = seed &* 0x9E3779B97F4A7C15, t = ""
                    for i in 1...600 {
                        var line = String(format: "%4d  ", i)
                        for _ in 0..<9 { r = r &* 6364136223846793005 &+ 1442695040888963407; line += words[Int(r >> 33) % words.count] + " " }
                        t += line + "\n"
                    }
                    tv.string = t
                }
            }
            if isStill { return }
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
/// Smooth gradients with per-pixel noise: compresses like a photograph.
final class PhotoView: NSView {
    lazy var image: NSImage = {
        let w = Int(bounds.width), h = Int(bounds.height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        let p = rep.bitmapData!
        var rng: UInt32 = 7
        for y in 0..<h { for x in 0..<w {
            rng = rng &* 1664525 &+ 1013904223
            let n = Int(rng >> 28)
            let o = (y * w + x) * 4
            p[o] = UInt8(clamping: 60 + x * 120 / max(1, w) + n); p[o + 1] = UInt8(clamping: 90 + y * 100 / max(1, h) + n); p[o + 2] = UInt8(clamping: 140 + (x + y) % 90 + n); p[o + 3] = 255
        } }
        let img = NSImage(size: bounds.size); img.addRepresentation(rep); return img
    }()
    override func draw(_ dirty: NSRect) { image.draw(in: bounds) }
}
/// Six opaque "icons" down the right edge, the rest transparent.
final class IconsView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirty: NSRect) {
        NSColor.clear.setFill(); bounds.fill()
        for i in 0..<6 {
            NSColor(calibratedRed: 0.2, green: 0.5 + CGFloat(i) * 0.08, blue: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - 120, y: bounds.height - 140 - CGFloat(i) * 110, width: 72, height: 72), xRadius: 14, yRadius: 14).fill()
        }
    }
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
