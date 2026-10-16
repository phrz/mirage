import SwiftUI
import AppKit
import MirageCore

struct Options {
    var host = ""
    var port = Mirage.defaultPort
    var pair: String?
    var bitrate = 800
    var pixelFactor = 1.0
    var statsLog: String?
    var window = (1280, 720)
    var headless = false
    var probeInput = false
    var duration = 60.0
    var statsJSON: String?

    static func parse() -> Options {
        var o = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
        }
        if let v = value("--port"), let p = UInt16(v) { o.port = p }
        if let v = value("--pair") { o.pair = v }
        if let v = value("--bitrate"), let b = Int(v) { o.bitrate = b }
        if let v = value("--scale"), let f = Double(v) { o.pixelFactor = f }
        if let v = value("--stats-log") { o.statsLog = v }
        if let v = value("--duration"), let d = Double(v) { o.duration = d }
        if let v = value("--stats") { o.statsJSON = v }
        if let i = args.firstIndex(of: "--headless") { o.headless = true; args.remove(at: i) }
        if let i = args.firstIndex(of: "--probe-input") { o.probeInput = true; args.remove(at: i) }
        if let v = value("--window") { let p = v.split(separator: "x").compactMap { Int($0) }; if p.count == 2 { o.window = (p[0], p[1]) } }
        if args.contains("-h") || args.contains("--help") || args.isEmpty {
            print("""
                usage: mirage-viewer HOST [--port N] [--pair CODE] [--bitrate KBPS] [--scale F]
                  --bitrate  target video bitrate in kbit/s (default 800); ⌃⌥⌘↑/↓ adjusts live
                  --scale    stream pixels = window points × backing scale × F (default 1.0)
                  --window   initial window size in points, WxH (default 1280x720)
                  --stats-log PATH  append one line of stats per second to PATH
                  --headless --duration S --stats PATH.json
                             no window: connect, request --window pixels (× --scale), decode for S seconds,
                             write per-second samples and medians to PATH.json, exit 0 (SSH-friendly)
                  --probe-input  (headless) after 8 s move the host pointer and open/close Spotlight
                  ⌃⌥⌘S toggles the stats overlay, ⌃⌥⌘Q quits; all other keys go to the host.
                """)
            exit(args.isEmpty ? 2 : 0)
        }
        o.host = args[0]
        return o
    }
}

/// AppKit shell: one NSWindow hosting the SwiftUI content. (A SwiftUI `App` scene does not
/// reliably open a window when the executable is launched outside a bundle/LaunchServices.)
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options = Options.parse()
    var model: ViewerModel!
    var session: ViewerSession!
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = ViewerModel(bitrateKbps: options.bitrate, pixelFactor: options.pixelFactor)
        model.statsLog = options.statsLog.map { URL(fileURLWithPath: $0) }
        session = ViewerSession(host: options.host, port: options.port, pairCode: options.pair, model: model)
        let content = ContentView(session: session, model: model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: options.window.0, height: options.window.1),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Mirage — \(options.host)"
        w.contentView = NSHostingView(rootView: content)
        w.contentMinSize = NSSize(width: 480, height: 270)
        w.delegate = self
        w.center()
        if options.window == (1280, 720) { w.setFrameAutosaveName("MirageViewer") }
        w.makeKeyAndOrderFront(nil)
        window = w
        installMenu()
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.environment["MIRAGE_NO_ACTIVATE"] == nil { NSApp.activate(ignoringOtherApps: true) }
        session.start()
    }

    func windowWillClose(_ notification: Notification) { session.stop(); NSApp.terminate(nil) }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit Mirage Viewer", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.control, .option, .command]
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
    @objc func quit(_ sender: Any?) { session.stop(); NSApp.terminate(nil) }
}

struct ContentView: View {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoView(session: session, model: model)
            if model.showStats { StatsOverlay(model: model).padding(8) }
            if let e = model.error {
                Text(e).foregroundStyle(.white).padding().background(.red.opacity(0.8)).cornerRadius(8).padding(40)
            }
        }
        .background(.black)
    }
}

struct StatsOverlay: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 2) {
            Text(model.status)
            Text(String(format: "rtt %4.0f ms   age %4.0f ms   %4.1f fps   %5.0f kbps (target %d)", s.rttMs, s.frameAgeMs, s.fps, s.kbps, model.bitrateKbps))
            Text(String(format: "%dx%d   decode %.1f ms   frames %d   lost %d   skipped %d", s.width, s.height, s.decodeMs, s.frames, s.lost, s.dropped))
            Text("⌃⌥⌘S stats  ⌃⌥⌘↑↓ bitrate  ⌃⌥⌘Q quit").foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.6))
        .cornerRadius(6)
        .allowsHitTesting(false)
    }
}

if CommandLine.arguments.contains("--headless") {
    // Headless measurement mode: decode without presenting; usable over SSH on a machine with no GUI access.
    let o = Options.parse()
    let (model, session) = MainActor.assumeIsolated { () -> (ViewerModel, ViewerSession) in
        let m = ViewerModel(bitrateKbps: o.bitrate, pixelFactor: o.pixelFactor)
        m.statsLog = o.statsLog.map { URL(fileURLWithPath: $0) }
        return (m, ViewerSession(host: o.host, port: o.port, pairCode: o.pair, model: m))
    }
    session.start()
    session.requestStream(width: Int(Double(o.window.0) * o.pixelFactor), height: Int(Double(o.window.1) * o.pixelFactor))
    if o.probeInput { Task { try? await Task.sleep(for: .seconds(8)); await session.probeInput() } }
    Timer.scheduledTimer(withTimeInterval: o.duration, repeats: false) { _ in
        session.stop()
        let json = session.statsJSON()
        if let path = o.statsJSON { try? json.write(to: URL(fileURLWithPath: path)) }
        FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data("\n".utf8))
        let failed = MainActor.assumeIsolated { model.error != nil } && session.samples.isEmpty
        exit(failed ? 1 : 0)
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
