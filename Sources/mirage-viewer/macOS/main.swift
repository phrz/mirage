import SwiftUI
import AppKit
import MirageCore

struct Options {
    var host = ""
    var port = Mirage.defaultPort
    var pair: String?
    /// nil: the Settings window's cap (automatic by default); headless runs: automatic.
    var bitrate: Int?
    /// --throttle: a preset's name, or DOWN/UP/RTT[/LOSS] (kbps, kbps, ms, %).
    var throttle: NetworkThrottle?
    var pixelFactor = 1.0
    var statsLog: String?
    var window = (1280, 720)
    var headless = false
    var probeInput = false
    var duration = 60.0
    var statsJSON: String?
    var scenario: (String, Double)?
    var observe = false
    /// Start in Unified mode (remote windows as native windows).
    var unified = false
    /// Seconds after connecting before the video-gap (freeze) metric starts counting.
    var steadyAfter = 3.0

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
        if let v = value("--throttle") { o.throttle = Self.throttle(v) }
        if let v = value("--scale"), let f = Double(v) { o.pixelFactor = f }
        if let v = value("--stats-log") { o.statsLog = v }
        if let v = value("--duration"), let d = Double(v) { o.duration = d }
        if let v = value("--stats") { o.statsJSON = v }
        if let v = value("--steady-after"), let d = Double(v) { o.steadyAfter = d }
        if let v = value("--scenario") { let p = v.split(separator: ":"); o.scenario = (String(p[0]), p.count > 1 ? Double(p[1]) ?? 30 : 30) }
        if let i = args.firstIndex(of: "--headless") { o.headless = true; args.remove(at: i) }
        if let i = args.firstIndex(of: "--observe") { o.observe = true; args.remove(at: i) }
        if let i = args.firstIndex(of: "--unified") { o.unified = true; args.remove(at: i) }
        if let i = args.firstIndex(of: "--probe-input") { o.probeInput = true; args.remove(at: i) }
        // The host companion's flags (HostMenu, applicationWillFinishLaunching), and the -NSDocumentRevisionsDebugMode style
        // pairs macOS may pass: not a host name.
        args.removeAll { $0 == "--background" || $0 == "--allow-connections" || $0 == "--permissions" }
        _ = value(HostAgent.reregisterFlag)   // the updater's request (HostMenu.reregisterAgent): not a host name
        if let v = value("--window") { let p = v.split(separator: "x").compactMap { Int($0) }; if p.count == 2 { o.window = (p[0], p[1]) } }
        if args.isEmpty { return o }   // launched from Finder/Dock: show the connect window
        if args.contains("-h") || args.contains("--help") {
            print("""
                usage: mirage-viewer HOST [--port N] [--pair CODE] [--bitrate KBPS] [--scale F]
                  --bitrate  bitrate cap in kbit/s (default: automatic, 0); the host's controller stays at or below it; ⌃⌥⌘↑/↓ adjusts live
                  --throttle NAME | DOWN/UP/RTT[/LOSS]  simulate a link: Fast 4G, Slow 4G, 3G, Japan bus 4G, Extreme, or kbps/kbps/ms/%
                  --scale    stream pixels = window points × backing scale × F (default 1.0)
                  --window   initial window size in points, WxH (default 1280x720)
                  --stats-log PATH  append one line of stats per second to PATH
                  --headless --duration S --stats PATH.json
                             no window: connect, request --window pixels (× --scale), decode for S seconds,
                             write per-second samples and medians to PATH.json, exit 0 (SSH-friendly)
                  --probe-input  (headless) after 8 s move the host pointer and open/close Spotlight
                  --steady-after S  count video freezes (maxVideoGapMs) only from S seconds after connecting (default 3)
                  --scenario NAME:SECONDS  drive the host's "Mirage Test Bench" window: idle | typing | scroll | drag | login | fovea (GUI or headless)
                             keys:N sends N scripted keystrokes to a host in input-sink mode only (input-integrity test)
                  --observe  show the picture but forward no local input (watching a scripted run without disturbing it)
                  --unified  start in Unified mode: every remote window a native window (⌃⌥⌘U switches Desktop ↔ Unified)
                  ⌃⌥⌘S toggles the stats overlay (off by default; remembered), ⌃⌥⌘, opens Settings, ⌃⌥⌘Q quits; all other keys go
                  to the host (⌘-shortcuts too, unless View › Send Keyboard Shortcuts to Mac is off).
                """)
            exit(0)
        }
        o.host = args[0]
        return o
    }

    /// "Slow 4G" (any case, spaces optional) or "1000/500/300/1" (down kbps / up kbps / added RTT ms / loss %).
    static func throttle(_ v: String) -> NetworkThrottle? {
        let key = v.lowercased().replacingOccurrences(of: " ", with: "")
        if let p = NetworkThrottle.presets.first(where: { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == key }) { return p }
        let n = v.split(separator: "/").compactMap { Double($0) }
        guard n.count >= 3 else { FileHandle.standardError.write(Data("unknown --throttle \(v)\n".utf8)); return nil }
        return NetworkThrottle(name: NetworkThrottle.customName, downKbps: Int(n[0]), upKbps: Int(n[1]), rttMs: n[2], lossPercent: n.count > 3 ? n[3] : 0)
    }
}

/// AppKit shell: one NSWindow hosting the SwiftUI content. (A SwiftUI `App` scene does not
/// reliably open a window when the executable is launched outside a bundle/LaunchServices.)
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let options = Options.parse()
    var model: ViewerModel!
    var session: ViewerSession!
    var window: NSWindow!
    var connectWindow: NSWindow?
    var unified: UnifiedController?
    var chrome: NativeChromeController?
    /// The toolbar's, the View menu's and Settings' state: the stats overlay and where ⌘-shortcuts go (remembered).
    lazy var controls: ViewerControls = MainActor.assumeIsolated { ViewerControls(remember: options.scenario == nil && !options.observe) }
    private var toolbar: ViewerToolbar?
    /// Disconnect (toolbar, menu): the viewer window closes and the connect window comes back, the app stays.
    private var disconnecting = false
    /// The session's `streamStop` is on its way (window closed, or quitting): sent once; quitting waits for it.
    private var endingSession: ViewerSession?
    /// This Mac as a host: the menu-bar item that drives the local `miraged` (Pair a Device…, Allow / Deny).
    var hostMenu: HostMenu?

    /// Started at login (Mirage is a login item while this Mac accepts connections) or by the scripts: menu-bar only.
    private var launchedInBackground = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The updater's re-registration request: no Dock icon, no menu, no window; it quits when done.
        if HostMenu.reregisterRequest != nil { NSApp.setActivationPolicy(.prohibited); return }
        let e = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = e?.eventID == kAEOpenApplication && e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        launchedInBackground = options.host.isEmpty && (loginItem || CommandLine.arguments.contains("--allow-connections") || CommandLine.arguments.contains("--background")
                                                       || CommandLine.arguments.contains("--permissions"))
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if hostMenu != nil { MainActor.assumeIsolated { HostProbeCenter.shared.appBecameActive() } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = HostMenu.reregisterRequest { HostMenu.reregisterAgent(requestID: id); NSApp.terminate(nil); return }
        installMenu()
        MainActor.assumeIsolated {
            controls.onSettings = { [weak self] in self?.showSettings(nil) }
            controls.onDisconnect = { [weak self] in self?.disconnect() }
        }
        if options.scenario == nil, ProcessInfo.processInfo.environment["MIRAGE_NO_HOST_MENU"] == nil {
            let m = HostMenu()
            m.onConnectWindow = { [weak self] in MainActor.assumeIsolated { self?.openViewer() } }
            m.onQuit = { [weak self] in self?.requestQuit() }
            hostMenu = m
            // The update card reads this Mac's own channel too (its host's, as it reports it).
            MainActor.assumeIsolated { ViewerFeedCenter.shared.ownChannels = { LocalHostUpdate.shared.channel.map { [$0] } ?? [] } }
            // Removing a paired Mac ends the session to it first.
            MainActor.assumeIsolated {
                HostRemovalCenter.shared.endSession = { [weak self] alias in
                    MainActor.assumeIsolated { if self?.session?.host == alias { self?.disconnect() } }
                }
            }
            // Status probes of the paired Macs (U7): now, then every 10 min in the background (every 60 s with the list).
            MainActor.assumeIsolated { HostProbeCenter.shared.appBecameActive() }
        }
        if launchedInBackground {
            // A menu-bar accessory: no Dock icon, no window, until a viewer opens.
            NSApp.setActivationPolicy(.accessory)
            return
        }
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.environment["MIRAGE_NO_ACTIVATE"] == nil { NSApp.activate(ignoringOtherApps: true) }
        MainActor.assumeIsolated {
            if options.host.isEmpty { showConnectWindow() } else { startViewer(host: options.host, pairCode: options.pair) }
            // Test knob MIRAGE_TEST_OPEN_SETTINGS: the Settings window opens at launch (screenshots without clicking).
            if ProcessInfo.processInfo.environment["MIRAGE_TEST_OPEN_SETTINGS"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showSettings(nil) } }
        }
    }

    /// While this Mac accepts connections the app stays as a menu-bar accessory without windows; a viewer makes it regular.
    private var hostingCompanion: Bool { hostMenu != nil && HostMenu.hosting }

    /// "Connect to a Mac…" (or a Dock click): the connect window, or the running viewer.
    @MainActor func openViewer() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = window, session != nil { w.makeKeyAndOrderFront(nil); return }
        if let c = connectWindow { c.makeKeyAndOrderFront(nil); return }
        showConnectWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { openViewer() } }
        return true
    }

    /// No windows left while hosting: back to the menu bar.
    private func becomeAccessoryIfIdle() {
        guard hostingCompanion else { return }
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// Quit (the app menu or the menu-bar item): while this Mac is shared, ask whether it keeps accepting connections. The
    /// host runs headless either way; "Stop Allowing" turns Share This Mac off (the agent stays, keeping Mirage up to date).
    /// A Mac that isn't shared (viewer only), or whose sharing isn't known yet, just quits: nothing to ask about.
    @MainActor func requestQuit() {
        guard hostingCompanion, HostShareState.shared.sharing == true else { endSessionAndQuit(); return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Keep allowing connections to this Mac?"
        a.informativeText = "Paired devices can connect while Mirage is not running. Mirage opens again at your next login."
        a.addButton(withTitle: "Keep Allowing")
        a.addButton(withTitle: "Stop Allowing")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn:
            HostShareState.shared.set(false)
            // The setting goes to the host over the local socket: give it a moment before the app (and the socket) goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.endSessionAndQuit() }
            return
        default: return
        }
        endSessionAndQuit()
    }
    /// Quitting ends an open session first (applicationShouldTerminate waits for the host to hear it).
    private func endSessionAndQuit() { NSApp.terminate(nil) }

    /// The GUI entry point: the paired Macs (double-click or Return connects), + for another one with its pairing code.
    @MainActor private func showConnectWindow() {
        let hosts = ConnectList.load()
        let view = ConnectView(hosts: hosts, lastHost: UserDefaults.standard.string(forKey: "lastHost"),
                               openAdd: ProcessInfo.processInfo.environment["MIRAGE_TEST_OPEN_ADD"] != nil) { [weak self] host, code in
            self?.connectWindow?.close(); self?.connectWindow = nil
            MainActor.assumeIsolated { self?.startViewer(host: host, pairCode: code) }
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Mirage"
        // The SwiftUI toolbar (the + button) becomes this window's toolbar.
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = [.toolbars]
        w.contentViewController = host
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 420, height: 340))
        w.contentMinSize = NSSize(width: 340, height: 220)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        connectWindow = w
    }

    /// Pair a Device… (the Connection menu): this Mac's rotating code and QR for another device, as the menu-bar item does.
    @MainActor private func pairDevice() {
        if let m = hostMenu, m.isConnected { m.pairDevice(); return }
        info("This Mac does not accept connections yet.", "Turn on Allow Connections to This Mac in Mirage's menu-bar item, then choose Pair a Device… again.")
    }

    /// A `miragerd://pair` link (a scanned QR code, or one clicked): never connects silently. "Pair with <host>?" with the key
    /// fingerprint the link pins, then pairs with its secret and refuses a host with any other key.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme?.lowercased() == PairingLink.scheme }) else { return }
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
            guard let link = PairingLink(url: url) else { return info("That is not a valid Mirage pairing link.", "") }
            guard !link.isExpired() else { return info("That pairing code has expired.", "Codes change every 30 seconds. Show a fresh one on the Mac (Pair a Device… in its menu bar) and scan it again.") }
            guard session == nil else { return info("Mirage is already connected.", "Disconnect, then open the pairing link again.") }
            let alert = NSAlert()
            alert.messageText = "Pair with \(link.hostName)?"
            alert.informativeText = "\(link.address):\(link.port)\nHost key \(PairingLink.fingerprintText(link.keyHash))\n\nThe Mac will ask to allow this device too."
            alert.addButton(withTitle: "Pair")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard !link.isExpired() else { return info("That pairing code has expired.", "Show a fresh one on the Mac and scan it again.") }
            // Pairing returns to the list (phrz, 2026-10-26): the new row waits for the Mac's Allow; no session opens.
            HostPairingCenter.shared.pair(link: link)
            if let w = connectWindow { w.makeKeyAndOrderFront(nil) } else { showConnectWindow() }
        }
    }
    @MainActor private func info(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    @MainActor private func startViewer(host: String, pairCode: String?, pairLink: PairingLink? = nil) {
        ViewerSettings.noteConnected(host)
        let prefs = ViewerPreferences.shared
        if let t = options.throttle { prefs.throttle = t }
        model = ViewerModel(bitrateKbps: options.bitrate ?? prefs.bitrateKbps, pixelFactor: options.pixelFactor, throttle: prefs.throttle)
        model.observeOnly = options.observe || options.scenario != nil
        model.statsLog = options.statsLog.map { URL(fileURLWithPath: $0) }
        session = ViewerSession(host: host, port: pairLink?.port ?? options.port, pairCode: pairCode, pairLink: pairLink, model: model)
        prefs.session = session
        // A scripted run with the window visible: the stats overlay shows the picture being measured (not remembered).
        if options.scenario != nil { controls.setShowStats(true) }
        controls.model = model
        if options.scenario != nil { session.inputAutoFlush = true }
        let content = ContentView(session: session, model: model, controls: controls)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: options.window.0, height: options.window.1),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = host
        // Held by `window` and dropped in windowWillClose: AppKit's own release on close would release it a second time
        // (a crash in the autorelease pool when a session window closes while the app stays open).
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content)
        w.contentMinSize = NSSize(width: 480, height: 270)
        w.collectionBehavior.insert(.fullScreenPrimary)
        // The toolbar: unified with the title bar, the iOS button bar's actions; it hides with the menu bar in full screen.
        let tb = ViewerToolbar(controls: controls)
        w.toolbarStyle = .unified
        w.toolbar = tb.toolbar
        toolbar = tb
        w.delegate = self
        w.center()
        if options.window == (1280, 720) { w.setFrameAutosaveName("MirageViewer") }
        w.makeKeyAndOrderFront(nil)
        window = w
        unified = UnifiedController(session: session, model: model)
        if let menu = NSApp.mainMenu {
            let c = NativeChromeController(session: session, model: model, localMainMenu: menu)
            c.unified = unified; unified?.chrome = c; chrome = c
        }
        LocalShortcuts.toggleStats = { [weak self] in self?.controls.toggleStats() }
        LocalShortcuts.openSettings = { [weak self] in self?.showSettings(nil) }
        LocalShortcuts.toggleMode = { [weak self] in self?.setUnified(!(self?.model.unified ?? false)) }
        if options.unified { setUnified(true) }
        session.start()
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
                FrameRecorder.drain()
                exit(0)
            }
        }
    }

    /// Disconnect (toolbar, Connection menu): the session ends, the viewer window closes, the connect window comes back.
    @MainActor func disconnect() {
        guard session != nil, let w = window else { return }
        if model?.unified == true { setUnified(false) }
        disconnecting = true
        w.close()   // windowWillClose stops the session
    }

    /// Desktop ↔ Unified, on the same session: the Desktop window hides and every remote window becomes a native one,
    /// or back.
    @MainActor func setUnified(_ on: Bool) {
        guard let model, let unified, model.unified != on else { return }
        model.unified = on
        if on {
            window.orderOut(nil)
            unified.start()
            chrome?.start()
        } else {
            chrome?.stop()
            unified.stop()
            window.makeKeyAndOrderFront(nil)
            if let v = findVideoView(window.contentView) { v.resetStreamRequest(); v.sendStreamRequest() }
        }
    }
    private func findVideoView(_ v: NSView?) -> VideoNSView? {
        guard let v else { return nil }
        if let vv = v as? VideoNSView { return vv }
        for s in v.subviews { if let f = findVideoView(s) { return f } }
        return nil
    }
    @objc func toggleDock(_ sender: Any?) { MainActor.assumeIsolated { if let c = chrome { c.dockVisible.toggle() } } }
    @objc func toggleUnified(_ sender: Any?) { MainActor.assumeIsolated { setUnified(!(model?.unified ?? false)) } }
    @objc func toggleStats(_ sender: Any?) { MainActor.assumeIsolated { controls.toggleStats() } }
    @objc func toggleShortcuts(_ sender: Any?) { MainActor.assumeIsolated { controls.toggleCaptureShortcuts() } }
    @objc func disconnectMenu(_ sender: Any?) { MainActor.assumeIsolated { disconnect() } }
    @objc func newConnection(_ sender: Any?) { MainActor.assumeIsolated { openViewer() } }

    /// Check for Updates… (the app menu): a fresh check, then an alert; Update Now runs this Mac's updater, its progress in
    /// the update card (the connect window comes up for it). Shared or not, the same.
    private var checkingUpdates = false
    @objc func checkForUpdates(_ sender: Any?) {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        Task { @MainActor in
            let outcome = await hostMenu?.checkForUpdates() ?? .noHost
            checkingUpdates = false
            let a = outcome.alert
            let alert = NSAlert()
            alert.messageText = a.title
            alert.informativeText = a.message
            for b in a.buttons { alert.addButton(withTitle: b) }
            NSApp.activate(ignoringOtherApps: true)
            let first = alert.runModal() == .alertFirstButtonReturn
            if first, case .available(_, _, true) = outcome {
                hostMenu?.updateNowFromCheck()
                openViewer()
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch item.action {
            case #selector(toggleStats(_:)): item.state = controls.showStats ? .on : .off; return true
            case #selector(toggleShortcuts(_:)): item.state = controls.captureShortcuts ? .on : .off; return true
            case #selector(toggleUnified(_:)): item.state = model?.unified == true ? .on : .off; return session != nil
            case #selector(toggleDock(_:)): return model?.unified == true
            case #selector(disconnectMenu(_:)): return session != nil
            case #selector(checkForUpdates(_:)): return !checkingUpdates && !(hostMenu?.updating ?? false)
            default: return true
            }
        }
    }

    /// Full screen: the toolbar hides with the menu bar and comes back with it, as in other Mac apps.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === connectWindow { connectWindow = nil; becomeAccessoryIfIdle(); return }
        guard (notification.object as? NSWindow) === window else { return }
        let back = disconnecting
        disconnecting = false
        // Closing the viewer ends the session (phrz, 2026-10-28): the host gets `streamStop` before the connection closes,
        // so it stops (curtain down, Lock When Finished) instead of suspending as for a dropped connection.
        let quitAfter = !(back || hostingCompanion)
        endSession { [weak self] in if quitAfter { self?.session = nil; NSApp.terminate(nil) } }
        MainActor.assumeIsolated { ViewerPreferences.shared.session = nil; controls.model = nil }
        chrome?.stop(); unified?.stop()
        // Disconnect: back to the connect window. Closing the viewer while hosting: the app stays in the menu bar.
        // Otherwise closing the viewer quits, as before (once the host has heard the session end).
        if !quitAfter {
            session = nil; window = nil; model = nil; toolbar = nil; unified = nil; chrome = nil
            if back { MainActor.assumeIsolated { showConnectWindow() } } else { becomeAccessoryIfIdle() }
        }
    }
    /// Sends the session's `streamStop` once and runs `then` on the main queue when the host has it (about a second at
    /// most); at once when there is no session.
    private func endSession(then: @escaping @MainActor () -> Void) {
        guard let s = session, endingSession == nil else { if endingSession == nil { MainActor.assumeIsolated { then() } }; return }
        endingSession = s
        s.stop { DispatchQueue.main.async { MainActor.assumeIsolated { self.endingSession = nil; then() } } }
    }
    /// Quitting (⌘Q, the menu, logout) with a session open: it ends first, so the host does not keep it suspended for a
    /// day with the curtain up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session != nil, endingSession == nil else { return .terminateNow }
        endSession { [weak self] in self?.session = nil; NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    /// Not in Unified mode: the Desktop window is hidden there, and remote windows come and go with the host's. Never while
    /// hosting (the menu-bar item stays).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { MainActor.assumeIsolated { !hostingCompanion && !disconnecting && !(model?.unified ?? false) && unified?.active != true } }

    private func installMenu() {
        let main = NSMenu()
        func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            menu.addItem(i)
            return i
        }
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        _ = item(appMenu, "About Mirage", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        appMenu.addItem(.separator())
        // ⌘, while the picture has focus goes to the host when shortcuts are sent to the Mac; ⌃⌥⌘, opens Settings there.
        _ = item(appMenu, "Settings…", #selector(showSettings(_:)), ",")
        _ = item(appMenu, "Check for Updates…", #selector(checkForUpdates(_:)))
        appMenu.addItem(.separator())
        _ = item(appMenu, "Hide Mirage", #selector(NSApplication.hide(_:)), "h")
        _ = item(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        _ = item(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        _ = item(appMenu, "Quit Mirage", #selector(quit(_:)), "q")
        appItem.submenu = appMenu

        let connItem = NSMenuItem(); main.addItem(connItem)
        let conn = NSMenu(title: "Connection")
        _ = item(conn, "Connect to a Mac…", #selector(newConnection(_:)), "n")
        _ = item(conn, "Disconnect", #selector(disconnectMenu(_:)), "d", [.command, .shift])
        conn.addItem(.separator())
        _ = item(conn, "Pair a Device with This Mac…", #selector(pairDeviceMenu(_:)))
        conn.addItem(.separator())
        _ = item(conn, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        connItem.submenu = conn

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")   // standard editing shortcuts for the connect window's fields
        _ = item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        _ = item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        _ = item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        _ = item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        _ = item(view, "Show Stats", #selector(toggleStats(_:)), "s", [.control, .option, .command])
        _ = item(view, "Send Keyboard Shortcuts to Mac", #selector(toggleShortcuts(_:)))
        view.addItem(.separator())
        _ = item(view, "Unified Windows", #selector(toggleUnified(_:)), "u", [.control, .option, .command])
        _ = item(view, "Show Remote Dock", #selector(toggleDock(_:)))
        view.addItem(.separator())
        _ = item(view, "Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])
        _ = item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        viewItem.submenu = view

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        _ = item(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        _ = item(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
    @objc func quit(_ sender: Any?) { MainActor.assumeIsolated { requestQuit() } }
    @objc func pairDeviceMenu(_ sender: Any?) { MainActor.assumeIsolated { pairDevice() } }

    /// Settings (⌘, from the menu, ⌃⌥⌘, over the picture, the toolbar's gear): iOS's sections, applied to the connected
    /// session at once.
    private var settingsWindow: NSWindow?
    @objc func showSettings(_ sender: Any?) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let w = settingsWindow {
                (w.contentView as? NSHostingView<MacSettingsView>)?.rootView = MacSettingsView(prefs: ViewerPreferences.shared, controls: controls, model: model)
                w.makeKeyAndOrderFront(nil); return
            }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.contentView = NSHostingView(rootView: MacSettingsView(prefs: ViewerPreferences.shared, controls: controls, model: model))
            w.isReleasedWhenClosed = false
            w.center()
            w.makeKeyAndOrderFront(nil)
            settingsWindow = w
        }
    }
}

/// The Mac's Settings window, iOS's sections: Connection (bitrate cap; the network throttle under Developer), Input (where
/// ⌘-shortcuts go: the Mac's counterpart of the touch mode), Display (the stats overlay), About.
struct MacSettingsView: View {
    @ObservedObject var prefs: ViewerPreferences
    @ObservedObject var controls: ViewerControls
    let model: ViewerModel?
    var body: some View {
        Form {
            ShareThisMacSection()
            ConnectionSettingsSection(prefs: prefs)
            Section {
                Toggle("Send Keyboard Shortcuts to Mac", isOn: Binding(get: { controls.captureShortcuts }, set: { controls.setCaptureShortcuts($0) }))
            } header: {
                Text("Input")
            } footer: {
                Text("⌘-shortcuts typed over the picture go to the remote Mac. Off, Mirage's menus get them first (⌘Q, ⌘W, ⌘,) and the rest still go to the Mac. ⌃⌥⌘ shortcuts are always Mirage's.")
            }
            UnlockSettingsSection()
            Section {
                Toggle("Stats Overlay", isOn: Binding(get: { controls.showStats }, set: { controls.setShowStats($0) }))
            } header: {
                Text("Display")
            } footer: {
                Text("Connection numbers over the picture. Also in the toolbar and View › Show Stats (⌃⌥⌘S).")
            }
            AboutSettingsSection(model: model)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 620)
    }
}

/// First window of the app: the paired Macs, each with its device icon, most recently connected first. Double-click or
/// Return connects; + (the toolbar) adds another Mac by name or address with its pairing code.
struct ConnectView: View {
    @State private var hosts: [PairedHost]
    @State private var selection: String?
    @State private var adding: Bool
    @ObservedObject private var updates = HostUpdateCenter.shared
    @ObservedObject private var localUpdate = LocalHostUpdate.shared
    @ObservedObject private var probes = HostProbeCenter.shared
    @ObservedObject private var removal = HostRemovalCenter.shared
    @ObservedObject private var pairing = HostPairingCenter.shared
    /// The Mac whose removal waits for confirmation (right-click Remove…, or Delete on the selected row).
    @State private var removing: PairedHost?
    @ObservedObject private var notices = ListNotices.shared
    @ObservedObject private var feedChecks = ViewerFeedCenter.shared
    let onConnect: (String, String?) -> Void

    init(hosts: [PairedHost], lastHost: String?, openAdd: Bool = false, onConnect: @escaping (String, String?) -> Void) {
        let center = HostPairingCenter.shared
        let rows = center.rows(hosts)
        self._hosts = State(initialValue: rows)
        self._selection = State(initialValue: center.takeSelection() ?? ConnectList.initialSelection(rows, lastHost: lastHost))
        self._adding = State(initialValue: openAdd)
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 0) {
            // This Mac's own host, out of date (DESIGN §3.10, U4): the bar across the top of the window.
            LocalUpdateBar(model: localUpdate)
            list
            // A passing note (a Mac ready after pairing, an update done): gone after a few seconds.
            if let n = notices.note {
                Text(n).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .onChange(of: removal.revision) { reload() }
        .onChange(of: pairing.revision) { reload() }
        // What needs acknowledging: an NSAlert with OK, one at a time.
        .onChange(of: notices.current) { showAlert() }
        .onAppear { showAlert() }
        // ⌘I: Get Info on the selected row.
        .background {
            Button("Get Info") { if let s = selection, let h = hosts.first(where: { $0.alias == s }) { HostInfoWindows.show(h) } }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .alert(removing.map { HostRemovalCenter.confirmation($0.title).title } ?? "",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { h in
            Button("Remove", role: .destructive) { Task { await removal.remove(h) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { h in
            Text(HostRemovalCenter.confirmation(h.title).message)
        }
        .onChange(of: updates.revision) { reload() }
        .onChange(of: probes.revision) { reload() }
        .onChange(of: feedChecks.revision) { reload() }
        .onAppear { probes.listAppeared(); feedChecks.nudge() }
        .onDisappear { probes.listDisappeared() }
        .hostUpdatePrompt(updates)
    }

    /// Known-hosts with the pairings under way; the selection follows a new Mac, and a removed one's moves to the first.
    private func reload() {
        hosts = pairing.rows(ConnectList.load())
        if let s = pairing.takeSelection() { selection = s }
        if let s = selection, !hosts.contains(where: { $0.alias == s }) { selection = hosts.first?.alias }
    }

    @State private var alerting = false
    private func showAlert() {
        guard !alerting, let a = notices.current else { return }
        alerting = true
        let alert = NSAlert()
        alert.messageText = a.title
        alert.informativeText = a.message
        alert.addButton(withTitle: "OK")
        let done: (NSApplication.ModalResponse) -> Void = { _ in
            alerting = false
            notices.dismiss()
        }
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Mirage" && $0.contentViewController is NSHostingController<ConnectView> }) {
            alert.beginSheetModal(for: w, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    /// Connects to a row that takes it (not while its Mac has yet to allow this one).
    private func connect(_ alias: String) {
        guard hosts.first(where: { $0.alias == alias })?.canConnect ?? true else { return }
        onConnect(alias, nil)
    }

    private var list: some View {
        Group {
            if hosts.isEmpty {
                VStack(spacing: 12) {
                    Text("No paired Macs yet.").foregroundStyle(.secondary)
                    Button { adding = true } label: { Label("Add a Mac", systemImage: "plus") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(hosts, selection: $selection) { h in
                    row(h).tag(h.alias)
                }
                .listStyle(.inset)
                // Delete on the selected row: the same confirmation.
                .onDeleteCommand { if let s = selection, let h = hosts.first(where: { $0.alias == s }), h.canConnect { removing = h } }
                .alternatingRowBackgrounds(.disabled)
                .contextMenu(forSelectionType: String.self) { items in
                    if let a = items.first, hosts.first(where: { $0.alias == a })?.canConnect ?? true { Button("Connect") { connect(a) } }
                    if let a = items.first, let h = hosts.first(where: { $0.alias == a }), h.canConnect {
                        Button("Get Info") { HostInfoWindows.show(h) }
                        Divider()
                        Button("Remove \(h.title)…") { removing = h }
                    }
                    // Right-click → Update, straight away (the arrow asks first).
                    if let a = items.first, let h = hosts.first(where: { $0.alias == a }), !h.dimmed, case .updateAvailable = h.update, UpdatePrompt.state(h) == .canUpdate, !updates.isRunning(a) {
                        Button("Update \(h.title)") { updates.update(h) }
                    }
                } primaryAction: { items in
                    if let a = items.first { connect(a) }   // double-click, Return
                }
            }
        }
        .frame(minWidth: 340, minHeight: 220)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add a Mac", systemImage: "plus") }
                    .help("Add a Mac")
            }
        }
        .sheet(isPresented: $adding) {
            AddHostSheet(paired: hosts.filter(\.canConnect), onCancel: { adding = false }) { address, code in
                adding = false
                // A new Mac pairs and stays in the list until it allows this one (phrz, 2026-10-26); a paired one connects.
                if let code { pairing.pair(address: address, code: code) } else { onConnect(address, nil) }
            }
        }
    }

    private func row(_ h: PairedHost) -> some View {
        HStack(spacing: 10) {
            DeviceIconView(model: h.model, family: h.family, size: 36, png: h.icon)
                .opacity(h.dimmed ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.title).fontWeight(.medium).foregroundStyle(h.dimmed ? .secondary : .primary)
                if let d = updates.line(h.alias) ?? h.detail() { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if h.pairing?.inProgress == true { ProgressView().controlSize(.small) } else { HostUpdateBadge(host: h) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Get Info for a paired Mac (right-click Get Info, or ⌘I): a small window of its own per Mac, "<host> Info", with its
/// details as label and value (phrz, 2026-10-26: not lines in the row). Asking again brings it forward with fresh values.
@MainActor
enum HostInfoWindows {
    private(set) static var open: [String: NSPanel] = [:]

    /// `present`: false in tests (the window is made, never put on screen).
    @discardableResult
    static func show(_ h: PairedHost, present: Bool = true) -> NSPanel {
        let view = HostInfoView(host: h)
        if let p = open[h.alias] {
            (p.contentViewController as? NSHostingController<HostInfoView>)?.rootView = view
            p.title = "\(h.title) Info"
            p.setContentSize(p.contentViewController?.view.fittingSize ?? p.frame.size)
            if present { p.makeKeyAndOrderFront(nil) }
            return p
        }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "\(h.title) Info"
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentViewController = NSHostingController(rootView: view)
        p.setContentSize(p.contentViewController?.view.fittingSize ?? NSSize(width: 300, height: 200))
        p.center()
        let alias = h.alias
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { _ = open.removeValue(forKey: alias) }
        }
        open[alias] = p
        if present { p.makeKeyAndOrderFront(nil) }
        return p
    }
}

struct HostInfoView: View {
    let host: PairedHost
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DeviceIconView(model: host.model, family: host.family, size: 40, png: host.icon)
                Text(host.title).font(.headline)
            }
            let rows = host.info()
            if rows.isEmpty {
                Text("Nothing known yet: it has not answered since it was paired.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(rows, id: \.self) { r in
                        GridRow {
                            Text(r.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(r.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
            UnlockInfoSection(host: host).font(.callout)
        }
        .padding(20)
        .frame(minWidth: 260, alignment: .leading)
        .fixedSize()
    }
}

/// The + sheet: a Mac by name or address, and its 6-digit pairing code (Pair a Device… in Mirage's menu-bar item on that
/// Mac) unless this Mac is already paired with it.
struct AddHostSheet: View {
    let paired: [PairedHost]
    let onCancel: () -> Void
    let onConnect: (String, String?) -> Void
    @State private var form = AddHostForm()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name or Address", text: $form.address, prompt: Text("mac-studio.local"))
                    .onSubmit(connect)
                if form.needsCode(paired) {
                    TextField("Pairing Code", text: $form.code, prompt: Text("6 digits"))
                        .onSubmit(connect)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(form.needsCode(paired) ? "Pair" : "Connect", action: connect).keyboardShortcut(.defaultAction).disabled(form.request(paired) == nil)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func connect() {
        guard let r = form.request(paired) else { return }
        onConnect(r.address, r.code)
    }
}

struct ContentView: View {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    let controls: ViewerControls
    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoView(session: session, model: model, controls: controls)
            if model.showStats { StatsOverlay(model: model).padding(8) }
            // The connection's state, as iOS shows it (`SessionBanners`); no numbers unless the stats overlay is on.
            // Hit-testable (phrz, 2026-10-27): its buttons take clicks, and the picture's view leaves the pointer to them.
            VStack(alignment: .leading) { Spacer(); SessionBanners(session: session, model: model) }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .coordinateSpace(name: pictureSpace)
        .onPreferenceChange(LocalOverlayKey.self) { model.localOverlays = $0 }
        .background(.black)
    }
}

struct StatsOverlay: View {
    @ObservedObject var model: ViewerModel
    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 2) {
            Text(model.status)
            Text(String(format: "rtt %4.0f ms   age %4.0f ms   %4.1f fps   video %5.0f kbps   tiles %5.0f kbps   (cap %@)", s.rttMs, s.frameAgeMs, s.fps, s.kbps, s.tileKbps, model.bitrateKbps > 0 ? "\(model.bitrateKbps)" : "auto"))
            if let t = model.throttle { Text("Throttled: \(t.name) (\(t.summary))").foregroundStyle(.orange) }
            Text(String(format: "%@   target %d kbps   capacity %d   queue %.0f ms   rung %d (%.3gx%@)   tile budget %d", s.rate.tier?.name ?? "–", s.rate.targetKbps, s.rate.capacityKbps, s.rate.queueMs, s.rate.rung, s.rate.scale, s.upscaling ? " MetalFX" : "", s.rate.tileBudgetKbps))
            Text(String(format: "video %dx%d   decode %.1f ms   frames %d   lost %d   skipped %d   tile rects %d   copy-rects %d   nacks %d (recovered %d, parity %d)", s.width, s.height, s.decodeMs, s.frames, s.lost, s.dropped, s.tileRects, s.copyRects, s.nacks, s.recoveredByNack, s.recoveredByParity))
            Text(String(format: "predictions shown %d   confirmed %d   mismatched %d   expired %d   layers %d (%d MB)", s.predictions.shown, s.predictions.confirmed, s.predictions.mismatched, s.predictions.expired, s.layers, s.layerMB))
            if model.inputQueued > 0 || model.inputDropped > 0 {
                Text("input: \(model.inputQueued) queued" + (model.inputDropped > 0 ? ", \(model.inputDropped) dropped (queue full)" : ""))
            }
            if let h = model.hostStatus {
                Text("host: \(h.consoleLocked ? "SCREEN LOCKED" : "unlocked")   front: \(h.frontmostApp) — \(h.frontmostWindowTitle.prefix(40))")
                    .foregroundStyle(h.consoleLocked ? .red : .white)
            }
            Text("⌃⌥⌘S stats  ⌃⌥⌘U unified  ⌃⌥⌘↑↓ bitrate  ⌃⌥⌘, settings  ⌃⌥⌘Q quit").foregroundStyle(.secondary)
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
        let m = ViewerModel(bitrateKbps: o.bitrate ?? 0, pixelFactor: o.pixelFactor, throttle: o.throttle)
        m.statsLog = o.statsLog.map { URL(fileURLWithPath: $0) }
        return (m, ViewerSession(host: o.host, port: o.port, pairCode: o.pair, model: m))
    }
    session.inputAutoFlush = true   // no one is there to choose: the queue flushes when the path returns
    session.steadyAfterNanos = UInt64(o.steadyAfter * 1e9)
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
} else if let i = CommandLine.arguments.firstIndex(of: "--render-update-card"), i + 1 < CommandLine.arguments.count {
    // The device list with this Mac's update card, sample data, drawn offscreen to a PNG: `--render-update-card PATH`.
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.accessory)
    let path = CommandLine.arguments[i + 1]
    let ok = MainActor.assumeIsolated { () -> Bool in
        let m = LocalHostUpdate.shared
        let suite = "mirage-render-\(UUID().uuidString)"
        m.memory = OwnUpdateCard.Memory(defaults: UserDefaults(suiteName: suite)!)
        m.store = { nil }
        m.running = MirageVersion(version: "0.1", build: 498, commit: "a", channel: .nightly)
        m.reported = CommandLine.arguments.contains("nocard") ? nil : MirageVersion(version: "0.1", build: 499, commit: "b", channel: .nightly)
        m.policy = .ask; m.canUpdate = true
        let ago = Date().addingTimeInterval(-3 * 3600)
        let hosts = [PairedHost(alias: "mac-daddy", name: "mac-daddy", model: "Mac15,14", lastSeen: ago),
                     PairedHost(alias: "green-machine", name: "green-machine", model: "iMac21,1", lastSeen: Date().addingTimeInterval(-120)),
                     PairedHost(alias: "big-mac", name: "big-mac", model: "Mac16,10", unreachable: true)]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Mirage"
        w.contentViewController = NSHostingController(rootView: ConnectView(hosts: hosts, lastHost: "mac-daddy") { _, _ in })
        w.setContentSize(NSSize(width: 420, height: 340))
        w.layoutIfNeeded(); w.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        w.displayIfNeeded()
        guard let frame = w.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return false }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
    exit(ok ? 0 : 1)
} else if let i = CommandLine.arguments.firstIndex(of: "--render-permissions"), i + 1 < CommandLine.arguments.count {
    // The permissions window in a sample state, drawn to a PNG (no screen capture): `--render-permissions PATH
    // screenRecording=1 accessibility=0`.
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.accessory)
    let args = CommandLine.arguments
    let ok = MainActor.assumeIsolated {
        PermissionsWindow.render(to: args[i + 1], screenRecording: args.contains("screenRecording=1"), accessibility: args.contains("accessibility=1"))
    }
    exit(ok ? 0 : 1)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
