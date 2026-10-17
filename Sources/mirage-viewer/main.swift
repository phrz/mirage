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
    var scenario: (String, Double)?
    var observe = false

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
        if let v = value("--scenario") { let p = v.split(separator: ":"); o.scenario = (String(p[0]), p.count > 1 ? Double(p[1]) ?? 30 : 30) }
        if let i = args.firstIndex(of: "--headless") { o.headless = true; args.remove(at: i) }
        if let i = args.firstIndex(of: "--observe") { o.observe = true; args.remove(at: i) }
        if let i = args.firstIndex(of: "--probe-input") { o.probeInput = true; args.remove(at: i) }
        if let v = value("--window") { let p = v.split(separator: "x").compactMap { Int($0) }; if p.count == 2 { o.window = (p[0], p[1]) } }
        if args.isEmpty { return o }   // launched from Finder/Dock: show the connect window
        if args.contains("-h") || args.contains("--help") {
            print("""
                usage: mirage-viewer HOST [--port N] [--pair CODE] [--bitrate KBPS] [--scale F]
                  --bitrate  bitrate cap in kbit/s (default 800); the host's controller stays at or below it; ⌃⌥⌘↑/↓ adjusts live
                  --scale    stream pixels = window points × backing scale × F (default 1.0)
                  --window   initial window size in points, WxH (default 1280x720)
                  --stats-log PATH  append one line of stats per second to PATH
                  --headless --duration S --stats PATH.json
                             no window: connect, request --window pixels (× --scale), decode for S seconds,
                             write per-second samples and medians to PATH.json, exit 0 (SSH-friendly)
                  --probe-input  (headless) after 8 s move the host pointer and open/close Spotlight
                  --scenario NAME:SECONDS  drive the host's "Mirage Test Bench" window: idle | typing | scroll | drag (GUI or headless)
                  --observe  show the picture but forward no local input (watching a scripted run without disturbing it)
                  ⌃⌥⌘S toggles the stats overlay, ⌃⌥⌘Q quits; all other keys go to the host.
                """)
            exit(0)
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
    var connectWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.environment["MIRAGE_NO_ACTIVATE"] == nil { NSApp.activate(ignoringOtherApps: true) }
        MainActor.assumeIsolated {
            if options.host.isEmpty { showConnectWindow() } else { startViewer(host: options.host, pairCode: options.pair) }
        }
    }

    /// The GUI entry point: paired hosts, a host field, an optional pairing code.
    @MainActor private func showConnectWindow() {
        let known = (try? Store().knownHosts()) ?? [:]
        let view = ConnectView(knownHosts: known.map { ($0.key, $0.value.hostName) }.sorted { $0.0 < $1.0 },
                               lastHost: UserDefaults.standard.string(forKey: "lastHost") ?? "") { [weak self] host, code in
            self?.connectWindow?.close(); self?.connectWindow = nil
            MainActor.assumeIsolated { self?.startViewer(host: host, pairCode: code) }
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Mirage"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        connectWindow = w
    }

    @MainActor private func startViewer(host: String, pairCode: String?) {
        UserDefaults.standard.set(host, forKey: "lastHost")
        model = ViewerModel(bitrateKbps: options.bitrate, pixelFactor: options.pixelFactor)
        model.observeOnly = options.observe || options.scenario != nil
        model.statsLog = options.statsLog.map { URL(fileURLWithPath: $0) }
        session = ViewerSession(host: host, port: options.port, pairCode: pairCode, model: model)
        let content = ContentView(session: session, model: model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: options.window.0, height: options.window.1),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Mirage — \(host)"
        w.contentView = NSHostingView(rootView: content)
        w.contentMinSize = NSSize(width: 480, height: 270)
        w.delegate = self
        w.center()
        if options.window == (1280, 720) { w.setFrameAutosaveName("MirageViewer") }
        w.makeKeyAndOrderFront(nil)
        window = w
        session.start()
        // A scripted run with the window visible: the stats overlay shows the picture being measured.
        if let (name, secs) = options.scenario {
            let runner = ScenarioRunner(session: session, name: name, seconds: secs)
            session.scenario = runner
            Task { try? await Task.sleep(for: .seconds(3)); await runner.run() }
            let s = session!
            Timer.scheduledTimer(withTimeInterval: options.duration, repeats: false) { _ in
                s.stop()
                let json = s.statsJSON()
                if let path = self.options.statsJSON { try? json.write(to: URL(fileURLWithPath: path)) }
                FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        session?.stop(); NSApp.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit Mirage Viewer", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.control, .option, .command]
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")   // standard editing shortcuts for the connect window's fields
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    @objc func quit(_ sender: Any?) { session?.stop(); NSApp.terminate(nil) }
}

/// First window of the app: pick a paired host or enter a new one (with its 6-digit code).
struct ConnectView: View {
    let knownHosts: [(alias: String, name: String)]
    @State var host: String
    @State private var code = ""
    let onConnect: (String, String?) -> Void

    init(knownHosts: [(String, String)], lastHost: String, onConnect: @escaping (String, String?) -> Void) {
        self.knownHosts = knownHosts.map { (alias: $0.0, name: $0.1) }
        self._host = State(initialValue: lastHost)
        self.onConnect = onConnect
    }

    private var isPaired: Bool { knownHosts.contains { $0.alias == host.trimmingCharacters(in: .whitespaces) } }
    private var canConnect: Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        return !h.isEmpty && (isPaired || PairingCode.normalize(code) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mirage").font(.system(size: 26, weight: .semibold))
                Text("Remote desktop for your Macs over your tailnet.").foregroundStyle(.secondary)
            }
            if !knownHosts.isEmpty {
                Text("Paired Macs").font(.headline)
                VStack(spacing: 0) {
                    ForEach(knownHosts, id: \.alias) { h in
                        Button { host = h.alias; code = "" } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading) {
                                    Text(h.name).fontWeight(.medium)
                                    Text(h.alias).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if h.alias == host { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .padding(8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(h.alias == host ? Color.accentColor.opacity(0.12) : .clear)
                        .cornerRadius(6)
                    }
                }
                .padding(4)
                .background(.quaternary.opacity(0.4))
                .cornerRadius(8)
            }
            Text(knownHosts.isEmpty ? "Add a Mac" : "Or another Mac").font(.headline)
            TextField("Host name or address (e.g. mac-daddy)", text: $host)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canConnect { connect() } }
            if !isPaired {
                TextField("6-digit code from `miraged pair` on that Mac", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canConnect { connect() } }
                Text("Pairing happens once; afterwards this Mac is remembered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
    }

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        onConnect(h, isPaired ? nil : PairingCode.normalize(code))
    }
}

struct ContentView: View {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoView(session: session, model: model)
            if model.showStats { StatsOverlay(model: model).padding(8) }
            if let r = model.reconnecting {
                VStack { Spacer(); HStack { Spacer()
                    Text("reconnecting… attempt \(r.attempt), next in \(r.inSeconds) s").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white).padding(8).background(.orange.opacity(0.85)).cornerRadius(8).padding(12)
                } }
            }
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
            Text(String(format: "rtt %4.0f ms   age %4.0f ms   %4.1f fps   video %5.0f kbps   tiles %5.0f kbps   (cap %d)", s.rttMs, s.frameAgeMs, s.fps, s.kbps, s.tileKbps, model.bitrateKbps))
            Text(String(format: "%@   target %d kbps   capacity %d   queue %.0f ms   rung %d (%.3gx%@)   tile budget %d", s.rate.tier?.name ?? "–", s.rate.targetKbps, s.rate.capacityKbps, s.rate.queueMs, s.rate.rung, s.rate.scale, s.upscaling ? " MetalFX" : "", s.rate.tileBudgetKbps))
            Text(String(format: "video %dx%d   decode %.1f ms   frames %d   lost %d   skipped %d   tile rects %d   copy-rects %d", s.width, s.height, s.decodeMs, s.frames, s.lost, s.dropped, s.tileRects, s.copyRects))
            Text(String(format: "predictions shown %d   confirmed %d   mismatched %d   expired %d", s.predictions.shown, s.predictions.confirmed, s.predictions.mismatched, s.predictions.expired))
            if let h = model.hostStatus {
                Text("host: \(h.consoleLocked ? "CONSOLE LOCKED" : "unlocked")   front: \(h.frontmostApp) — \(h.frontmostWindowTitle.prefix(40))")
                    .foregroundStyle(h.consoleLocked ? .red : .white)
            }
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
    if let (name, secs) = o.scenario {
        let runner = ScenarioRunner(session: session, name: name, seconds: secs)
        session.scenario = runner
        Task { try? await Task.sleep(for: .seconds(3)); await runner.run() }
    }
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
