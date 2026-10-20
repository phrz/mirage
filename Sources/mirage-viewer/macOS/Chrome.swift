import AppKit
import MirageCore

/// Native chrome in Unified mode (DESIGN §3.8). While a remote window is key, the local menu bar holds the remote
/// app's menus, read from the host's Accessibility tree: the bar's titles and every menu's first level once per app,
/// each menu refreshed lazily when it opens (it shows what is cached at once and updates in place), a choice sent
/// back as an AXPress. The Apple menu and this app's own menu stay local. A remote dock lists the host's running apps
/// with icons cached by bundle id, and a strip under the right end of the menu bar shows the host's third-party
/// status items, cut from its menu bar, with clicks mapped back. Where an app exposes no menus, its menu bar is shown
/// as pixels in the same kind of strip.
@MainActor
final class NativeChromeController: NSObject, NSMenuDelegate {
    let session: ViewerSession
    let model: ViewerModel
    weak var unified: UnifiedController?
    /// The viewer's own menu bar (restored whenever no remote window is key) and its app menu (kept first in remote bars).
    let localMainMenu: NSMenu
    private(set) var apps: [ControlMessage.AppInfo] = []
    private var icons: [String: NSImage] = [:]
    private var iconsRequested = Set<String>()
    private struct Key: Hashable { var pid: Int32; var path: [Int] }
    private var cache: [Key: [ControlMessage.MenuItem]] = [:]
    private var requested: [Key: UInt64] = [:]
    private var built: [Key: NSMenu] = [:]
    private var menuKeys: [ObjectIdentifier: Key] = [:]
    private var failed = Set<Int32>()
    private var walkedAt: [Int32: UInt64] = [:]
    private(set) var installedPid: Int32?
    private var dock: RemoteDock?
    private var strip: StripPanel?
    private var menuStrip: StripPanel?
    private var observers: [NSObjectProtocol] = []
    var dockVisible = true { didSet { refreshPanels() } }
    /// Measurement: when a menu's request went out and when its items arrived (ms), per path.
    private(set) var menuLatencies: [Double] = []
    private(set) var menuPresses = 0
    private static let iconDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("com.paulherz.mirage/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    /// Status-item owners that describe the host rather than you (DESIGN §3.8): left out of the strip.
    static let systemOwners: Set<String> = ["Control Center", "SystemUIServer", "Window Server", "Spotlight", "TextInputMenuAgent", "Siri", "Notification Center", "loginwindow", "Dock"]
    /// Test only: MIRAGE_STATUS_APPS="A,B" limits the strip to those apps (a loopback run shows only the bench's item).
    static let statusApps: Set<String>? = ProcessInfo.processInfo.environment["MIRAGE_STATUS_APPS"].map { Set($0.split(separator: ",").map(String.init)) }

    init(session: ViewerSession, model: ViewerModel, localMainMenu: NSMenu) {
        self.session = session; self.model = model; self.localMainMenu = localMainMenu
        super.init()
        session.onChrome = { [weak self] m in self?.handle(m) }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.keyWindowChanged(n.object as? NSWindow) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPanels() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPanels() }
        })
    }

    // MARK: Messages from the host

    func handle(_ m: ControlMessage) {
        switch m {
        case .apps(let list):
            apps = list.apps
            for a in apps where icons[a.bundleID] == nil { loadIcon(a.bundleID) }
            dock?.update(apps: dockShown, icons: icons)
        case .icon(let i):
            guard let img = NSImage(data: i.png) else { return }
            icons[i.bundleID] = img
            try? i.png.write(to: Self.iconDir.appendingPathComponent(Self.fileName(i.bundleID)))
            dock?.update(apps: dockShown, icons: icons)
        case .statusItems(let l):
            hostStatusItems = l.items
            if strip != nil { updateStatusStrip() }
        case .menu(let c):
            let k = Key(pid: c.pid, path: c.path)
            if let t = requested[k] { menuLatencies.append(Double(Clock.elapsed(since: t, now: Clock.nowNanos())) / 1e6); requested[k] = nil }
            if c.path.isEmpty {
                if c.error != nil { failed.insert(c.pid) } else { failed.remove(c.pid) }
                let changed = cache[k] != c.items
                cache[k] = c.items
                // The walk: every menu's first level once per app.
                if c.error == nil, walkedAt[c.pid].map({ Clock.elapsed(since: $0, now: Clock.nowNanos()) > 30_000_000_000 }) ?? true {
                    walkedAt[c.pid] = Clock.nowNanos()
                    for i in c.items.indices { request(Key(pid: c.pid, path: [i])) }
                }
                if installedPid == c.pid, changed || c.error != nil { install(pid: c.pid) }
            } else {
                cache[k] = c.items
                if let menu = built[k] { fill(menu, key: k) }
            }
        default: break
        }
    }

    private static func fileName(_ bundleID: String) -> String { bundleID.replacingOccurrences(of: "/", with: "_") + ".png" }
    private func loadIcon(_ bundleID: String) {
        if let d = try? Data(contentsOf: Self.iconDir.appendingPathComponent(Self.fileName(bundleID))), let img = NSImage(data: d) { icons[bundleID] = img; return }
        guard !iconsRequested.contains(bundleID) else { return }
        iconsRequested.insert(bundleID)
        session.sendControl(.iconRequest(.init(bundleID: bundleID)))
    }

    private func request(_ k: Key) {
        let now = Clock.nowNanos()
        if let t = requested[k], Clock.elapsed(since: t, now: now) < 2_000_000_000 { return }
        requested[k] = now
        session.sendControl(.menuRequest(.init(pid: k.pid, path: k.path)))
    }

    // MARK: Menu bar

    private func keyWindowChanged(_ w: NSWindow?) {
        if let r = w as? RemoteWindow, r.role == .window, let pid = unified?.pid(of: r.remoteID) { install(pid: pid) }
        else if w is RemoteWindow { }   // a transient: keep what is installed
        else if w != nil { uninstall() }
        refreshPanels()
    }

    /// The remote app's menus in the local menu bar (the Apple menu and this app's menu stay first).
    func install(pid: Int32) {
        let barKey = Key(pid: pid, path: [])
        let fresh = walkedAt[pid].map { Clock.elapsed(since: $0, now: Clock.nowNanos()) < 30_000_000_000 } ?? false
        if !fresh { request(barKey) }
        installedPid = pid
        let bar = NSMenu()
        if let appItem = localMainMenu.items.first, let appMenu = appItem.submenu?.copy() as? NSMenu {
            let it = NSMenuItem(); it.submenu = appMenu; bar.addItem(it)
        }
        built = built.filter { $0.key.pid == pid }
        if let titles = cache[barKey], !failed.contains(pid) {
            for (i, t) in titles.enumerated() {
                let item = NSMenuItem(title: t.title, action: nil, keyEquivalent: "")
                item.submenu = menu(for: Key(pid: pid, path: [i]), title: t.title)
                bar.addItem(item)
            }
        }
        NSApp.mainMenu = bar
        menuStrip?.orderOut(nil); menuStrip = nil
        if failed.contains(pid) { showMenuStrip(pid: pid) }
    }
    func uninstall() {
        guard installedPid != nil else { return }
        installedPid = nil
        NSApp.mainMenu = localMainMenu
        menuStrip?.orderOut(nil); menuStrip = nil
    }

    private func menu(for k: Key, title: String) -> NSMenu {
        if let m = built[k] { return m }
        let m = NSMenu(title: title)
        m.autoenablesItems = false
        m.delegate = self
        built[k] = m; menuKeys[ObjectIdentifier(m)] = k
        fill(m, key: k)
        return m
    }

    private func fill(_ m: NSMenu, key k: Key) {
        m.removeAllItems()
        guard let items = cache[k] else {
            let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""); loading.isEnabled = false
            m.addItem(loading); return
        }
        for (j, it) in items.enumerated() {
            if it.separator { m.addItem(.separator()); continue }
            let mi = NSMenuItem(title: it.title, action: it.hasSubmenu ? nil : #selector(choose(_:)), keyEquivalent: it.key ?? "")
            mi.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: it.modifiers ?? 0)
            mi.isEnabled = it.enabled
            mi.target = self
            mi.representedObject = MenuChoice(pid: k.pid, path: k.path + [j], title: it.title)
            if let mark = it.mark { mi.state = mark == "✓" || mark == "✔" ? .on : .mixed }
            if it.hasSubmenu { mi.submenu = menu(for: Key(pid: k.pid, path: k.path + [j]), title: it.title) }
            m.addItem(mi)
        }
    }

    final class MenuChoice: NSObject { let pid: Int32; let path: [Int]; let title: String
        init(pid: Int32, path: [Int], title: String) { self.pid = pid; self.path = path; self.title = title } }

    @objc func choose(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? MenuChoice else { return }
        menuPresses += 1
        session.sendControl(.menuPress(.init(pid: c.pid, path: c.path, title: c.title)))
    }

    // Lazy per menu: shown from the cache at once, refreshed from the host on every open (enabled states and marks follow
    // the app's state), updated in place when the answer arrives.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { if let k = menuKeys[ObjectIdentifier(menu)] { request(k) } }
    }

    // MARK: Panels (dock, status strip, menu-bar strip)

    func start() {
        if dock == nil { dock = RemoteDock(controller: self) }
        dock?.update(apps: dockShown, icons: icons)
        refreshPanels()
    }
    func stop() {
        dock?.orderOut(nil); strip?.orderOut(nil); menuStrip?.orderOut(nil)
        dock = nil; strip = nil; menuStrip = nil
        uninstall()
    }

    /// Visible while this app is active and Unified is on; the strip only while a remote window is key.
    func refreshPanels() {
        guard model.unified else { return }
        let active = NSApp.isActive
        if let dock {
            if active && dockVisible && !dockShown.isEmpty { dock.place(); dock.orderFront(nil) } else { dock.orderOut(nil) }
        }
        let remoteKey = NSApp.keyWindow is RemoteWindow || (NSApp.keyWindow == nil && installedPid != nil)
        if active && remoteKey { updateStatusStrip() } else { strip?.orderOut(nil) }
    }

    /// The host's status items (from its Accessibility tree: macOS 26+ draws them all in one menu-bar window), the ones
    /// that describe the host itself (clock, Wi-Fi, battery, Control Center, Spotlight…) left out, left to right.
    private(set) var hostStatusItems: [ControlMessage.StatusItem] = []
    static let systemBundles: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight", "com.apple.TextInputMenuAgent",
                                             "com.apple.Siri", "com.apple.notificationcenterui", "com.apple.WindowManager", "com.apple.dock", "com.apple.loginwindow"]
    func statusItems() -> [ControlMessage.StatusItem] {
        hostStatusItems.filter { i in
            i.frame.y < 48 && i.frame.width > 0 && i.frame.width < 800 &&
            (Self.statusApps.map { $0.contains(i.app) } ?? !(Self.systemBundles.contains(i.bundleID) || Self.systemOwners.contains(i.app)))
        }
    }

    func updateStatusStrip() {
        guard let unified else { return }
        let items = statusItems()
        if items.isEmpty { strip?.orderOut(nil); return }
        let rects = items.map(\.frame)
        if strip == nil || strip?.rects != rects { strip?.orderOut(nil); strip = StripPanel(rects: rects, pids: items.map(\.pid), controller: unified, kind: .status) }
        strip?.placeUnderMenuBar(rightAligned: true)
        strip?.orderFront(nil)
    }

    /// An app without accessible menus: its menu-bar part of the host's menu bar, as pixels, clicks mapped back.
    private func showMenuStrip(pid: Int32) {
        guard let unified, let bar = session.hostOrder().first(where: { $0.windowLevel == 24 && $0.frame.y <= 0 }) else { return }
        let firstStatus = statusItems().map(\.frame.x).min() ?? bar.frame.width / 2
        let r = PixelRect(x: bar.frame.x, y: bar.frame.y, width: max(64, min(firstStatus, bar.frame.width / 2) - bar.frame.x), height: bar.frame.height)
        let s = StripPanel(rects: [r], pids: [pid], controller: unified, kind: .menuBar)
        s.placeUnderMenuBar(rightAligned: false)
        s.orderFront(nil)
        menuStrip = s
        session.log("menus: pid \(pid) exposes no menu bar through Accessibility; showing its menu bar as pixels")
    }

    /// Display-layer rects the strips show (the host streams them in Unified mode).
    func stripRects() -> [PixelRect] {
        var r: [PixelRect] = []
        if let s = strip, s.isVisible { r += s.rects }
        if let s = menuStrip { r += s.rects }
        // Status items are wanted before the strip first shows, so it never opens blank.
        if strip == nil { r += statusItems().map(\.frame) }
        return r
    }

    /// Test only: MIRAGE_DOCK_APPS="A,B" limits the remote dock to those apps (loopback screenshots show no one else's).
    static let dockApps: Set<String>? = ProcessInfo.processInfo.environment["MIRAGE_DOCK_APPS"].map { Set($0.split(separator: ",").map(String.init)) }
    var dockShown: [ControlMessage.AppInfo] { Self.dockApps.map { f in apps.filter { f.contains($0.name) } } ?? apps }

    /// The `chrome` scenario: the bench app's menus installed here, every top-level menu opened once (lazy refresh), one
    /// item chosen, the status strip and the dock shown; returns what it measured. No input is injected.
    func selfTest(pid: Int32, choose: String, log: (String) -> Void) async -> (barMs: Double?, openMs: [Double], items: Int, chosen: Bool, strip: Int) {
        let t0 = Clock.nowNanos()
        install(pid: pid)
        var barMs: Double? = nil
        for _ in 0..<300 {
            if cache[Key(pid: pid, path: [])] != nil { barMs = Double(Clock.elapsed(since: t0, now: Clock.nowNanos())) / 1e6; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let bar = cache[Key(pid: pid, path: [])] else { log("chrome: no menu bar from the host"); return (nil, [], 0, false, 0) }
        log("chrome: menu bar after \(barMs.map { String(format: "%.0f ms", $0) } ?? "?"): \(bar.map(\.title))")
        try? await Task.sleep(for: .seconds(1))   // the walk (every menu's first level)
        var opens: [Double] = [], items = 0, chosen = false
        for i in bar.indices {
            let k = Key(pid: pid, path: [i])
            let hadCache = cache[k] != nil
            requested[k] = nil
            let before = menuLatencies.count, t = Clock.nowNanos()
            if let m = built[k] { menuWillOpen(m) } else { request(k) }
            for _ in 0..<300 where menuLatencies.count == before { try? await Task.sleep(for: .milliseconds(10)) }
            if menuLatencies.count > before { opens.append(Double(Clock.elapsed(since: t, now: Clock.nowNanos())) / 1e6) }
            let m = built[k]
            items += m?.items.count ?? 0
            log("chrome: menu \(bar[i].title) (cached before open: \(hadCache)): \(m?.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.keyEquivalent.isEmpty ? "" : " ⌘" + $0.keyEquivalent) + ($0.state == .on ? " ✓" : "") + ($0.submenu != nil ? " ▸" : "") }.joined(separator: ", ") ?? "none")")
            if !chosen, let item = m?.items.first(where: { $0.title == choose }) { self.choose(item); chosen = true; log("chrome: chose '\(choose)' (menuPress sent)") }
        }
        updateStatusStrip()
        strip?.orderFront(nil)
        if let dock { dock.update(apps: dockShown, icons: icons); dock.place(); dock.orderFront(nil) }
        log("chrome: status strip \(strip.map { "\($0.rects.count) items, window \($0.windowNumber)" } ?? "none"), dock \(dock.map { "\(self.dockShown.count) apps, window \($0.windowNumber)" } ?? "none"), icons \(icons.count)")
        return (barMs, opens, items, chosen, strip?.rects.count ?? 0)
    }

    func activate(_ app: ControlMessage.AppInfo) {
        session.sendControl(.appCommand(.init(pid: app.pid, action: .activate)))
        unified?.bringToFront(pid: app.pid)
    }
}

/// A floating strip of cut-outs of the host's display layer (status items, or an app's part of the menu bar), each a
/// `RemoteWindowView`, so it draws and forwards clicks like any transient; a click anchors that app's next menus and
/// popovers under it.
final class StripPanel: NSPanel {
    enum Kind { case status, menuBar }
    let rects: [PixelRect]
    private weak var controller: UnifiedController?

    @MainActor init(rects: [PixelRect], pids: [Int32], controller: UnifiedController, kind: Kind) {
        self.rects = rects; self.controller = controller
        let g = controller.geometry.pixelsPerPoint
        let gap: CGFloat = kind == .status ? 4 : 0
        let widths = rects.map { CGFloat($0.width) / g }, h = CGFloat(rects.map(\.height).max() ?? 48) / g
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, rects.count - 1)) + 12
        super.init(contentRect: NSRect(x: 0, y: 0, width: total, height: h + 4), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true; level = .statusBar; hidesOnDeactivate = true
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        let root = NSView(frame: NSRect(x: 0, y: 0, width: total, height: h + 4))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        root.layer?.cornerRadius = 7; root.layer?.cornerCurve = .continuous
        root.layer?.borderColor = NSColor.systemPurple.withAlphaComponent(0.85).cgColor; root.layer?.borderWidth = 1.5
        var x: CGFloat = 6
        for (i, r) in rects.enumerated() {
            let e = UnifiedLayout.Entry(id: 0, pid: pids[i], role: .transient, source: .display(r), frame: r, parent: nil, level: 25, title: "", app: "", controls: nil)
            let v = RemoteWindowView(entry: e, controller: controller, outlined: false)
            v.frame = NSRect(x: x, y: 2, width: widths[i], height: CGFloat(r.height) / g)
            let pid = pids[i]
            v.onPress = { [weak controller, weak v] in
                guard let controller, let v, let w = v.window else { return }
                let local = w.convertToScreen(v.convert(v.bounds, to: nil))
                controller.anchor(pid: pid, host: r, local: local)
            }
            root.addSubview(v)
            x += widths[i] + gap
        }
        contentView = root
    }
    override var canBecomeKey: Bool { false }

    @MainActor func placeUnderMenuBar(rightAligned: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        let y = screen.frame.maxY - bar - frame.height - 2
        let x = rightAligned ? screen.frame.maxX - frame.width - 8 : screen.frame.minX + 8
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The remote dock: the host's regular running apps, icons cached by bundle id, the active one marked; a click
/// activates the app there and brings its windows up here. It sits above the local dock (inside the screen's visible
/// frame), purple-outlined, and only while this app is active.
final class RemoteDock: NSPanel {
    private weak var controller: NativeChromeController?
    private let stack = NSStackView()
    private var shown: [ControlMessage.AppInfo] = []
    private static let icon: CGFloat = 44

    @MainActor init(controller: NativeChromeController) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: Self.icon + 16), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true; level = .floating; hidesOnDeactivate = true
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        let fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16; fx.layer?.cornerCurve = .continuous; fx.layer?.masksToBounds = true
        fx.layer?.borderColor = NSColor.systemPurple.withAlphaComponent(0.85).cgColor; fx.layer?.borderWidth = 1.5
        stack.orientation = .horizontal; stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        contentView = fx
    }
    override var canBecomeKey: Bool { false }

    @MainActor func update(apps: [ControlMessage.AppInfo], icons: [String: NSImage]) {
        shown = apps
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, a) in apps.enumerated() {
            let b = NSButton(image: icons[a.bundleID] ?? NSWorkspace.shared.icon(for: .application), target: self, action: #selector(click(_:)))
            b.isBordered = false; b.imageScaling = .scaleProportionallyUpOrDown; b.tag = i
            b.toolTip = a.name
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: Self.icon).isActive = true
            b.heightAnchor.constraint(equalToConstant: Self.icon).isActive = true
            if a.active {
                b.wantsLayer = true
                let dot = CALayer(); dot.backgroundColor = NSColor.labelColor.withAlphaComponent(0.7).cgColor
                dot.frame = CGRect(x: Self.icon / 2 - 2, y: -5, width: 4, height: 4); dot.cornerRadius = 2
                b.layer?.addSublayer(dot); b.layer?.masksToBounds = false
            }
            if a.hidden { b.alphaValue = 0.55 }
            stack.addArrangedSubview(b)
        }
        let w = CGFloat(apps.count) * (Self.icon + 6) + 14
        setContentSize(NSSize(width: max(80, w), height: Self.icon + 14))
        place()
    }

    /// Centred above the local dock (the screen's visible frame already excludes it), never over it.
    @MainActor func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.minY + 8))
    }

    @objc private func click(_ b: NSButton) {
        MainActor.assumeIsolated {
            guard b.tag < shown.count else { return }
            controller?.activate(shown[b.tag])
        }
    }
}
