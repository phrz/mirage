import Foundation
import AppKit
import ApplicationServices
import MirageCore

/// Native chrome on the host side (DESIGN §3.8): an app's menus read through Accessibility (the menu bar's titles,
/// then one menu's items at a time, on request), menu items pressed with AXPress, the regular running apps as a list
/// (on change), their icons as 128-px PNGs, and app activation for the remote dock. Accessibility calls are IPC to
/// the app and may block for a while on a busy one, so everything runs on one serial queue of its own.
final class NativeChrome {
    private let queue = DispatchQueue(label: "mirage.host.chrome", qos: .userInitiated)
    private let log: (String) -> Void
    private let send: (ControlMessage) -> Void
    private var observers: [NSObjectProtocol] = []
    private var lastApps: [ControlMessage.AppInfo] = []
    private var appsWork: DispatchWorkItem?
    private(set) var menuRequests = 0, menuPresses = 0, menuFailures = 0
    /// Input-sink mode (loopback measurements): menus are read, presses and activations are recorded, never performed.
    var sink: ((ControlMessage) -> Void)?

    init(log: @escaping (String) -> Void, send: @escaping (ControlMessage) -> Void) {
        self.log = log; self.send = send
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.scheduleApps() })
        }
        scheduleApps(force: true)
    }
    func stop() {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
    }
    /// A resumed connection: everything again.
    func resend() { queue.async { self.lastApps = [] }; scheduleApps(force: true) }

    // MARK: Apps

    private func scheduleApps(force: Bool = false) {
        appsWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.publishApps(force: force) }
        appsWork = w
        queue.asyncAfter(deadline: .now() + .milliseconds(force ? 0 : 150), execute: w)
    }
    private func publishApps(force: Bool) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }.map {
            ControlMessage.AppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "pid.\($0.processIdentifier)", name: $0.localizedName ?? "?", active: $0.isActive, hidden: $0.isHidden)
        }
        guard force || apps != lastApps else { return }
        lastApps = apps
        send(.apps(.init(apps: apps)))
    }

    func icon(_ r: ControlMessage.IconRequest) {
        queue.async { [self] in
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == r.bundleID }),
                  let url = app.bundleURL else { return }
            let img = NSWorkspace.shared.icon(forFile: url.path)
            guard let png = Self.png(img, size: 128) else { return }
            send(.icon(.init(bundleID: r.bundleID, png: png)))
        }
    }
    static func png(_ img: NSImage, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func app(_ c: ControlMessage.AppCommand, locked: Bool) {
        if locked { return }
        if let sink { sink(.appCommand(c)); return }
        queue.async {
            guard let app = NSRunningApplication(processIdentifier: c.pid) else { return }
            switch c.action {
            case .activate: if app.isHidden { app.unhide() }; app.activate()
            case .hide: app.hide()
            }
        }
    }

    // MARK: Menus

    func menu(_ r: ControlMessage.MenuRequest) {
        queue.async { [self] in
            menuRequests += 1
            let t0 = Clock.nowNanos()
            let content: ControlMessage.MenuContent
            if let items = items(pid: r.pid, path: r.path) { content = .init(pid: r.pid, path: r.path, items: items) }
            else { menuFailures += 1; content = .init(pid: r.pid, path: r.path, items: [], error: "no accessible menu") }
            let ms = Double(Clock.elapsed(since: t0, now: Clock.nowNanos())) / 1e6
            if ms > 200 || content.error != nil { log(String(format: "menus: pid %d path %@: %d items in %.0f ms%@", r.pid, "\(r.path)", content.items.count, ms, content.error.map { " (\($0))" } ?? "")) }
            send(.menu(content))
        }
    }

    func press(_ p: ControlMessage.MenuPress, locked: Bool) {
        if locked { return }
        if let sink { sink(.menuPress(p)); return }
        queue.async { [self] in
            menuPresses += 1
            guard let e = element(pid: p.pid, path: p.path), string(e, kAXTitleAttribute) == p.title else {
                log("menus: '\(p.title.prefix(40))' is no longer at \(p.path) in pid \(p.pid); not pressed"); return
            }
            // The app should be frontmost for its menu actions to target its key window.
            NSRunningApplication(processIdentifier: p.pid)?.activate()
            let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
            if r != .success { log("menus: AXPress '\(p.title.prefix(40))' failed (\(r.rawValue))") }
        }
    }

    /// The bar (path []) or the menu at `path`, as items.
    private func items(pid: Int32, path: [Int]) -> [ControlMessage.MenuItem]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return nil }
        if path.isEmpty {
            // The bar's items; the Apple menu (first) stays the client's own.
            return children(bar).dropFirst().map { .init(title: string($0, kAXTitleAttribute) ?? "", hasSubmenu: true) }
        }
        guard let parent = element(in: bar, path: path) else { return nil }
        guard let menu = children(parent).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole }) else { return [] }
        return children(menu).map(item)
    }

    /// The element at `path` (indices into the bar without its Apple menu, then into each menu's items).
    private func element(pid: Int32, path: [Int]) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return nil }
        return element(in: bar, path: path)
    }
    private func element(in bar: AXUIElement, path: [Int]) -> AXUIElement? {
        guard let first = path.first else { return nil }
        let top = Array(children(bar).dropFirst())
        guard first >= 0, first < top.count else { return nil }
        var e = top[first]
        for i in path.dropFirst() {
            guard let menu = children(e).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole }) else { return nil }
            let items = children(menu)
            guard i >= 0, i < items.count else { return nil }
            e = items[i]
        }
        return e
    }

    private func item(_ e: AXUIElement) -> ControlMessage.MenuItem {
        let names = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute, kAXMenuItemCmdCharAttribute,
                     kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdVirtualKeyAttribute, kAXChildrenAttribute] as [CFString]
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let v = values as? [Any], v.count == names.count else { return .init(title: "", enabled: false, separator: true) }
        func val<T>(_ i: Int) -> T? { (CFGetTypeID(v[i] as CFTypeRef) == AXValueGetTypeID() && AXValueGetType(v[i] as! AXValue) == .axError) ? nil : v[i] as? T }
        let title: String = val(0) ?? ""
        let enabled: Bool = val(1) ?? true
        let mark: String? = val(2)
        let cmdChar: String? = val(3)
        let mods: Int = val(4) ?? 0
        let vkey: Int? = val(5)
        let kids: [AXUIElement] = val(6) ?? []
        let separator = title.isEmpty && !enabled && kids.isEmpty && cmdChar == nil
        var key = cmdChar.map { $0.lowercased() }
        if key == nil || key == "", let vk = vkey { key = Self.functionKey(vk) }
        return .init(title: title, enabled: enabled, separator: separator, hasSubmenu: !kids.isEmpty, mark: mark?.isEmpty == false ? mark : nil,
                     key: key?.isEmpty == false ? key : nil, modifiers: key == nil ? nil : Self.modifierFlags(mods))
    }

    /// kAXMenuItemCmdModifiers (bit 0 shift, 1 option, 2 control, 3 no-command) → NSEvent.ModifierFlags raw value.
    static func modifierFlags(_ m: Int) -> UInt {
        var f: NSEvent.ModifierFlags = []
        if m & 1 != 0 { f.insert(.shift) }
        if m & 2 != 0 { f.insert(.option) }
        if m & 4 != 0 { f.insert(.control) }
        if m & 8 == 0 { f.insert(.command) }
        return f.rawValue
    }
    /// Virtual key codes of keys a menu shows without a character (Delete, arrows, F-keys, Return, Escape, Tab).
    static func functionKey(_ vk: Int) -> String? {
        let map: [Int: Int] = [51: NSBackspaceCharacter, 117: NSDeleteFunctionKey, 36: NSCarriageReturnCharacter, 53: 0x1b, 48: NSTabCharacter,
                               123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
                               122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey, 118: NSF4FunctionKey, 96: NSF5FunctionKey, 97: NSF6FunctionKey,
                               98: NSF7FunctionKey, 100: NSF8FunctionKey, 101: NSF9FunctionKey, 109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey]
        guard let c = map[vk], let u = Unicode.Scalar(c) else { return nil }
        return String(Character(u))
    }

    private func attribute<T>(_ e: AXUIElement, _ name: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &ref) == .success else { return nil }
        return ref as? T
    }
    private func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) }
    private func children(_ e: AXUIElement) -> [AXUIElement] { attribute(e, kAXChildrenAttribute) ?? [] }
}
