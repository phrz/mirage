import AppKit
import SwiftUI
import CoreImage
import ServiceManagement
import MirageCore

/// The Mirage app's menu-bar item for this Mac as a host (DESIGN §3.1): "Allow Connections to This Mac" registers the host
/// inside the bundle (Contents/MacOS/miraged) as a login-item agent with SMAppService; the rest talks to that host over the
/// local control socket (LocalControl) — "Pair a Device…" (the rotating code and QR), Allow / Deny for a device that
/// finished the exchange, the paired devices with Revoke, who is streaming, and the Screen Recording and Accessibility
/// grants the host still needs. `miraged` stays headless.
final class HostMenu: NSObject, NSMenuDelegate {
    private let store: Store?
    private var client: LocalControlClient?
    private var statusItem: NSStatusItem?
    private var panel: PairingPanel?
    private var hostName: String?
    private var status: LocalControl.Status?
    private var retry: Timer?
    /// Set by the app: open the connect window (a viewer), and quit the app.
    var onConnectWindow: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        store = try? Store()
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarGlyph.image(update: false)
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        statusItem = item
        AppLog.write("Mirage \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") at \(Bundle.main.bundlePath), args \(CommandLine.arguments.dropFirst().joined(separator: " ")); \(AppLog.services())")
        // `--allow-connections` (the migration and deploy scripts): turn the host on without a click.
        if CommandLine.arguments.contains("--allow-connections") {
            if Self.agent.status != .enabled { AppLog.write("--allow-connections: registering"); toggleAllow() }
            else { AppLog.write("--allow-connections: already enabled") }
        }
        // launchd's launch constraint follows the signature registered: register again when it refuses the agent or
        // miraged is signed differently now (an update or deploy from Apple Development to Developer ID).
        if Self.agent.status == .enabled, let why = Self.reregistrationReason() {
            AppLog.write("host agent: \(why): registering it again"); Self.reregisterAgent(requestID: "launch")
        }
        connect()
        // Test knob MIRAGE_TEST_OPEN_PAIRING: the pairing window opens at launch (screenshots without clicking the menu bar).
        if ProcessInfo.processInfo.environment["MIRAGE_TEST_OPEN_PAIRING"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pairDevice() } }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.client?.isConnected != true { self.connect() }
            // The update dot follows the host's feed checks (U4): a status now and then, besides the menu's own.
            self.ticks += 1
            if self.ticks % 12 == 0 { try? self.client?.send(.status) }
        }
        RunLoop.main.add(t, forMode: .common)
        retry = t
    }

    var isConnected: Bool { client?.isConnected == true }
    private var ticks = 0
    /// The update's latest step, while one runs (U4).
    private var updateStatus: ControlMessage.UpdateStatus?

    private func connect() {
        guard let store else { return }
        let c = LocalControlClient(store: store)
        c.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
        c.onClose = { [weak self] in DispatchQueue.main.async { self?.hostName = nil; self?.status = nil; self?.panel?.hostGone(); self?.updateIndicators() } }
        let was = client?.isConnected == true
        do { try c.connect(client: "Mirage") ; client = c; if !was { AppLog.write("connected to the host's control socket") } } catch { client = nil }
    }

    private func handle(_ e: LocalControl.Event) {
        switch e {
        case .hello(_, let name, _): hostName = name
        case .status(let s): status = s; updateIndicators()
        case .pairing(let p): panel?.show(p)
        case .pairingClosed(let reason): panel?.closed(reason)
        case .paired(let name): panel?.succeeded(name)
        case .confirm(let c): ask(c)
        case .updateStatus(let u):
            updateStatus = u.isFinal ? nil : u
            AppLog.write("update: \(u.phase.rawValue) \(u.message)")
            updateIndicators(u)
            if u.isFinal { try? client?.send(.status) }
        }
    }

    // MARK: Update indicator (DESIGN §3.10, U4)

    /// The yellow dot over the menu-bar icon, and the connect window's bar, from the host's status.
    private func updateIndicators(_ step: ControlMessage.UpdateStatus? = nil) {
        let line = isConnected ? status?.updateLine : nil
        setUpdateDot(line != nil)
        let name = status?.hostName ?? hostName, can = status?.canUpdate ?? false
        MainActor.assumeIsolated {   // events arrive on the main queue
            let model = LocalHostUpdate.shared
            model.hostName = name
            model.line = line
            model.canUpdate = can
            let status = self.status
            model.apply(event: step, updating: status?.updating, lastUpdate: status?.lastUpdate)
            model.updateNow = { [weak self] in self?.updateNow() }
        }
    }

    @objc private func updateNow() {
        do { try client?.send(.updateNow) } catch { AppLog.write("update now: \(error)") }
        MainActor.assumeIsolated { LocalHostUpdate.shared.apply(event: .init(phase: .checking, message: "Checking for the update…", yours: true), updating: nil, lastUpdate: nil) }
    }

    /// The overlay hook on the status item: one small layer over the icon's top-right corner. The icon itself (its image)
    /// belongs to the icon work and is never touched here.
    private var updateDot: CALayer?
    private func setUpdateDot(_ on: Bool) {
        guard let button = statusItem?.button else { return }
        // The glyph: with an update, the variant whose top-right 6×6 pt is left empty for the dot (the icon work's art).
        button.image = MenuBarGlyph.image(update: on)
        button.setAccessibilityLabel(on ? "Mirage host: update available" : "Mirage host")
        if !on { updateDot?.removeFromSuperlayer(); updateDot = nil; return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let dot = updateDot ?? MenuBarGlyph.dotLayer()
        dot.frame = MenuBarGlyph.dotFrame(in: button.bounds, flipped: button.isFlipped)
        dot.autoresizingMask = [.layerMinXMargin, .layerMaxXMargin, .layerMinYMargin, .layerMaxYMargin]   // stays on the centred glyph
        if updateDot == nil { layer.addSublayer(dot); updateDot = dot }
    }

    // MARK: Menu

    /// The login-item agent in this bundle (Contents/Library/LaunchAgents).
    static let agent = SMAppService.agent(plistName: "com.paulherz.mirage.host.plist")
    /// The app itself as a login item: while this Mac accepts connections, Mirage starts at login as a menu-bar accessory
    /// (no Dock icon, no window), so Pair a Device… and Allow / Deny are always at hand.
    static let mainApp = SMAppService.mainApp
    /// This Mac accepts connections (or will once Login Items approves the host).
    static var hosting: Bool { [.enabled, .requiresApproval].contains(agent.status) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        try? client?.send(.status)
        menu.removeAllItems()
        func label(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func item(_ title: String, _ action: Selector?, _ object: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.representedObject = object; menu.addItem(i); return i
        }
        let agent = Self.agent.status
        let allow = item("Allow Connections to This Mac", #selector(toggleAllow))
        allow.state = agent == .enabled ? .on : agent == .requiresApproval ? .mixed : .off
        switch agent {
        case .requiresApproval:
            // Registered, but macOS holds it until it is approved: nothing runs until then.
            label("⚠︎ Waiting for approval in Login Items")
            _ = item("Open Login Items Settings…", #selector(openLoginItems))
        case .enabled where !isConnected: label("Starting the host…")
        case .notFound: label("The host is missing from this copy of Mirage")
        default: break
        }
        if isConnected, let u = updateStatus ?? status?.updating { label("Updating: \(u.message)") }
        else if isConnected, let line = status?.updateLine {
            label("Update available: \(line)")
            if status?.canUpdate == true { _ = item("Update Now", #selector(updateNow)) }
        }
        if isConnected, let s = status, s.restarting == true { label("Restarting to apply permissions…") }
        else if isConnected, let s = status {
            if s.screenRecording == false { _ = item("⚠︎ Mirage needs Screen Recording — Open Settings…", #selector(openScreenRecording)) }
            if s.accessibility == false { _ = item("⚠︎ Mirage needs \(PrivacyPane.accessibility()) — Open Settings…", #selector(openAccessibility)) }
            if let c = s.connected, !c.isEmpty { label("Connected: \(c.joined(separator: ", "))") }
        }
        menu.addItem(.separator())
        _ = item("Pair a Device…", isConnected ? #selector(pairDevice) : nil)
        if isConnected, let devices = status?.devices, !devices.isEmpty {
            defer {
                menu.addItem(.separator())
                _ = item("Connect to a Mac…", #selector(connectWindow))
                _ = item("Quit Mirage…", #selector(quit))
            }
            let sub = NSMenu()
            for d in devices.sorted(by: { $0.pairedAt < $1.pairedAt }) {
                let i = NSMenuItem(title: "Revoke \(d.name)…", action: #selector(revoke(_:)), keyEquivalent: ""); i.target = self; i.representedObject = d
                i.image = DeviceIcon.menuImage(model: d.model)   // the device's own picture (iPhone, MacBook Pro, …)
                sub.addItem(i)
            }
            let devicesItem = NSMenuItem(title: devices.count == 1 ? "1 Paired Device" : "\(devices.count) Paired Devices", action: nil, keyEquivalent: "")
            devicesItem.submenu = sub
            menu.addItem(devicesItem)
            return
        }
        menu.addItem(.separator())
        _ = item("Connect to a Mac…", #selector(connectWindow))
        _ = item("Quit Mirage…", #selector(quit))
    }
    @objc private func connectWindow() { onConnectWindow?() }
    @objc private func quit() { onQuit?() }

    @objc private func toggleAllow() {
        do {
            if Self.hosting { try Self.stopHosting(); client?.disconnect(); AppLog.write("connections off: \(AppLog.services())") }
            else {
                AppLog.write("registering: before \(AppLog.services())")
                try Self.agent.register()
                Self.recordRegistration(requestID: "allow", error: nil, settle: false)
                do { try Self.mainApp.register() } catch { AppLog.write("app login item: register failed: \(error)") }   // Mirage at login, as a menu-bar accessory
                AppLog.write("registered: \(AppLog.services())")
                if Self.agent.status == .requiresApproval || Self.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.connect() }
            }
        } catch {
            AppLog.write("allow connections: \(error) (\(AppLog.services()))")
            let a = NSAlert(); a.messageText = "Mirage could not change whether this Mac accepts connections."; a.informativeText = "\(error.localizedDescription)"; a.runModal()
        }
    }
    /// `Mirage.app --reregister-host ID` (DESIGN §3.10, the updater and the deploy scripts): the request's ID.
    static var reregisterRequest: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: HostAgent.reregisterFlag) else { return nil }
        return i + 1 < a.count ? a[i + 1] : "unnamed"
    }

    /// Registers the host agent again, so launchd's launch constraint follows the bundle's current signature: after an
    /// update or deploy whose miraged is signed differently, the old registration makes launchd refuse to spawn it
    /// ("Launch Constraint Violation", EX_CONFIG). Unregistering stops the running agent; registering starts the new one.
    /// The outcome goes to the app log and to host-registration.json, which the updater waits for.
    static func reregisterAgent(requestID: String) {
        AppLog.write("re-registering the host agent (\(requestID)): before \(AppLog.services()); launchd: \(HostAgent.currentStatus())")
        var failure: String?
        if agent.status != .notRegistered {
            do { try agent.unregister() } catch { AppLog.write("re-register: unregister failed: \(error)") }
        }
        do { try agent.register() } catch { failure = "\(error)"; AppLog.write("re-register: register failed: \(error)") }
        // The app's own login item carries a launch constraint from its signature too: renewed the same way; and a host
        // turned on by install-host.sh gets it as the Allow toggle gives it (Mirage at login, as a menu-bar accessory).
        do {
            if mainApp.status == .enabled { try mainApp.unregister() }
            try mainApp.register()
        } catch { AppLog.write("re-register: app login item: \(error)") }
        recordRegistration(requestID: requestID, error: failure, settle: true)
    }

    /// The bundle's miraged, whose signature launchd's constraint follows.
    static var hostExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/miraged") }

    static func reregistrationReason() -> String? {
        guard let root = try? Store().root else { return nil }
        return HostAgent.reregistrationReason(status: HostAgent.currentStatus(), recorded: HostAgent.readRegistration(storeRoot: root),
                                              currentRequirement: HostAgent.designatedRequirement(of: hostExecutable))
    }

    /// host-registration.json: what was registered (miraged's designated requirement) and how it went, with launchd's job
    /// state once it has had a moment (`settle`) to start the agent.
    static func recordRegistration(requestID: String, error: String?, settle: Bool) {
        if settle { Thread.sleep(forTimeInterval: 1.5) }
        let job = HostAgent.currentStatus()
        AppLog.write("registered (\(requestID)): \(AppLog.services()); launchd: \(job)")
        guard let root = try? Store().root else { return }
        HostAgent.writeRegistration(.init(requestID: requestID, at: Date(), status: AppLog.describe(agent.status), error: error,
                                          requirement: HostAgent.designatedRequirement(of: hostExecutable), jobState: "\(job)"), storeRoot: root)
    }

    /// Connections off: the host agent and Mirage-at-login both go.
    static func stopHosting() throws {
        do { try agent.unregister() } catch { AppLog.write("host agent: unregister failed: \(error)"); throw error }
        if mainApp.status != .notRegistered { do { try mainApp.unregister() } catch { AppLog.write("app login item: unregister failed: \(error)") } }
        AppLog.write("stopped hosting: \(AppLog.services())")
    }
    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func openScreenRecording() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    @objc private func openAccessibility() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }

    @objc private func revoke(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? LocalControl.Device else { return }
        let a = NSAlert()
        a.messageText = "Revoke \(d.name)?"
        a.informativeText = "It can no longer connect to this Mac until it is paired again."
        a.addButton(withTitle: "Revoke"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? client?.send(.revoke(deviceID: d.id))
    }

    @objc func pairDevice() {
        guard isConnected else { return }
        if panel == nil {
            panel = PairingPanel(onCancel: { [weak self] in try? self?.client?.send(.closePairing) }, onClose: { [weak self] in self?.panel = nil })
        }
        panel?.present()
        try? client?.send(.openPairing)
    }

    /// Allow / Deny, before the host authorizes the device (code or link alike).
    private func ask(_ c: LocalControl.Confirm) {
        let alert = NSAlert()
        alert.messageText = "\(c.deviceName) wants to pair with this Mac."
        alert.informativeText = "Allow it to see and control this Mac through Mirage?\n\nDevice key \(PairingLink.fingerprintText(Data(hex: c.deviceID)))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        let allow = alert.runModal() == .alertFirstButtonReturn
        try? client?.send(.decide(requestID: c.requestID, allow: allow))
    }
}

/// The app's own log (~/Library/Logs/mirage-app.log): launch mode, SMAppService registration and status, the host link.
/// A silent failure (the first `--allow-connections` on mac-daddy registered nothing and said nothing) shows here.
enum AppLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/mirage-app.log")
    private static let lock = NSLock()
    static func write(_ s: String) {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = Data("\(f.string(from: Date())) \(s)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
    static func services() -> String { "agent \(describe(HostMenu.agent.status)), app \(describe(HostMenu.mainApp.status))" }
}

/// The pairing window: code (3 + 3, large), QR code, a ring counting down to the next rotation; closes on success, on
/// expiry (5 min) or on Cancel.
final class PairingPanel: NSObject, NSWindowDelegate {
    private let onCancel: () -> Void
    private let onClose: () -> Void
    private let window: NSPanel
    private let code = NSTextField(labelWithString: "")
    private let qr = NSImageView()
    private let ring = CountdownRing()
    private let status = NSTextField(labelWithString: "Waiting for the host…")
    private var current: LocalControl.Pairing?
    private var timer: Timer?
    private var finished = false

    init(onCancel: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onCancel = onCancel; self.onClose = onClose
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Pair a Device"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshClock() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func build() {
        let v = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let heading = NSTextField(wrappingLabelWithString: "Scan with the Mirage app on your iPhone, or type the code on the other device.")
        heading.alignment = .center; heading.font = .systemFont(ofSize: 13); heading.textColor = .secondaryLabelColor
        code.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold); code.alignment = .center
        qr.imageScaling = .scaleProportionallyUpOrDown
        status.alignment = .center; status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        for (sub, frame) in [(heading as NSView, NSRect(x: 20, y: 410, width: 320, height: 40)), (qr, NSRect(x: 70, y: 180, width: 220, height: 220)),
                             (code, NSRect(x: 20, y: 110, width: 270, height: 56)), (ring, NSRect(x: 296, y: 120, width: 36, height: 36)),
                             (status, NSRect(x: 20, y: 70, width: 320, height: 32)), (cancel, NSRect(x: 130, y: 20, width: 100, height: 32))] {
            sub.frame = frame; v.addSubview(sub)
        }
        window.contentView = v
        window.center()
    }

    func present() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }

    func show(_ p: LocalControl.Pairing) {
        guard !finished else { return }
        current = p
        code.stringValue = "\(p.code.prefix(3)) \(p.code.suffix(3))"
        qr.image = Self.qrImage(p.link, side: 440)
        refreshClock()
    }

    private func refreshClock() {
        guard !finished, let p = current else { return }
        let now = Date()
        ring.fraction = max(0, min(1, p.rotatesAt.timeIntervalSince(now) / PairingWindow.rotation))
        let left = max(0, Int(p.closesAt.timeIntervalSince(now)))
        status.stringValue = "New code every 30 s · window closes in \(left / 60):\(String(format: "%02d", left % 60))\nThis Mac: \(p.hostName) · \(p.address)"
    }

    func succeeded(_ device: String) { finish("✓ Paired \(device).", closeAfter: 2) }
    func closed(_ reason: String) { if !finished { finish(reason == "expired" ? "The code expired. Choose Pair a Device… again for a new one." : "Pairing closed (\(reason)).", closeAfter: 3) } }
    func hostGone() { if !finished { finish("The host stopped.", closeAfter: 3) } }

    private func finish(_ message: String, closeAfter: TimeInterval) {
        finished = true
        timer?.invalidate()
        code.stringValue = ""; qr.image = nil; ring.fraction = 0
        status.stringValue = message
        let t = Timer(timeInterval: closeAfter, repeats: false) { [weak self] _ in self?.window.close() }
        RunLoop.main.add(t, forMode: .common)
    }

    @objc private func cancel() { window.close() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        if !finished { onCancel() }
        onClose()
    }

    static func qrImage(_ text: String, side: CGFloat) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: side / out.extent.width, y: side / out.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}

/// A ring that empties as the current code ages.
final class CountdownRing: NSView {
    var fraction: Double = 1 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        let c = NSPoint(x: r.midX, y: r.midY), radius = min(r.width, r.height) / 2
        NSColor.tertiaryLabelColor.setStroke()
        let track = NSBezierPath(ovalIn: r); track.lineWidth = 3; track.stroke()
        guard fraction > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = 3; arc.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke(); arc.stroke()
    }
}

private extension Data {
    init(hex: String) {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), let b = UInt8(hex[i..<j], radix: 16) { d.append(b); i = j }
        self = d
    }
}

/// This Mac's own host as the connect window's bar shows it (DESIGN §3.10, U4): out of date, and how an update goes.
@MainActor
final class LocalHostUpdate: ObservableObject {
    static let shared = LocalHostUpdate()
    @Published var hostName: String?
    /// "0.1 (448) → 0.1 (449)" while an update is available.
    @Published var line: String?
    @Published var canUpdate = false
    /// The update's latest step while one runs (or how it failed).
    @Published var step: ControlMessage.UpdateStatus?
    /// Later: hidden until another build comes out.
    @Published var dismissed: String?
    var updateNow: (() -> Void)?
    /// The step came from the host's status (an update running there), not from this app's own events.
    private(set) var stepFromStatus = false
    /// The outcome already shown (or dismissed), so a status does not bring it back.
    private var shownOutcome: Date?

    /// One place decides the bar's step (U6 review): an event from this app's update wins; a status never overwrites a
    /// step under way from an event; a running update elsewhere shows while it runs and goes with it; a rollback (or
    /// failure) the host reports after its restart shows once.
    func apply(event: ControlMessage.UpdateStatus?, updating: ControlMessage.UpdateStatus?, lastUpdate: ControlMessage.UpdateStatus?) {
        if let e = event {
            step = e.isFinal && e.phase == .done ? nil : e
            stepFromStatus = false
            if e.isFinal { shownOutcome = e.at ?? Date() }
            return
        }
        if let u = updating {
            if step == nil || stepFromStatus || step?.isFinal == true { step = u; stepFromStatus = true }
            return
        }
        if stepFromStatus, step?.isFinal == false { step = nil; stepFromStatus = false }
        if let l = lastUpdate, [.rolledBack, .failed].contains(l.phase), step == nil, let at = l.at, shownOutcome.map({ at > $0 }) ?? true {
            step = l; stepFromStatus = true; shownOutcome = at
        }
    }
    func dismissStep() { if let at = step?.at { shownOutcome = at }; step = nil; stepFromStatus = false }
}

/// "Mirage host mac-daddy is out of date: 0.1 (448) → 0.1 (449)" with Update and Later, across the top of the window.
struct LocalUpdateBar: View {
    @ObservedObject var model: LocalHostUpdate

    var body: some View {
        if let step = model.step {
            bar {
                if !step.isFinal { ProgressView().controlSize(.small) }
                Text(step.phase == .failed ? "Update failed: \(step.message)" : step.phase == .rolledBack ? "Update rolled back: \(step.message)" : step.message)
                    .lineLimit(2)
                Spacer()
                if step.isFinal { Button("Dismiss") { model.dismissStep() } }
            }
        } else if let line = model.line, model.dismissed != line {
            bar {
                Image(systemName: "arrow.up.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.black, .yellow)
                Text("Mirage host \(model.hostName ?? "on this Mac") is out of date: \(line)").lineLimit(2)
                Spacer()
                Button("Later") { model.dismissed = line }
                if model.canUpdate { Button("Update") { model.updateNow?() }.keyboardShortcut(.defaultAction) }
            }
        }
    }

    private func bar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8, content: content)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.yellow.opacity(0.18))
            Divider()
        }
    }
}

/// The menu-bar item's glyph (the icon work's Waves B template images, Resources/MenuBar, in App/Assets.xcassets) and the
/// update dot, a separate layer over it (U4): the glyph's art is never drawn into.
enum MenuBarGlyph {
    /// The template images are 18×18 pt.
    static let size = CGSize(width: 18, height: 18)
    /// The dot: a 5 pt circle centred in the glyph's empty top-right 6×6 pt (MirageMenuBarStatus).
    static let dotDiameter: CGFloat = 5
    static let dotCell: CGFloat = 6

    /// The plain glyph, or the variant with room for the dot. A build without the asset catalog (the SwiftPM viewer)
    /// falls back to a system symbol.
    static func image(update: Bool) -> NSImage {
        let img = NSImage(named: update ? "MirageMenuBarStatus" : "MirageMenuBar")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "Mirage host") ?? NSImage()
        img.isTemplate = true
        return img
    }

    /// Where the 18 pt glyph sits in the status button: centred.
    static func glyphRect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The dot's frame in the button's coordinates (a flipped view's y grows downwards).
    static func dotFrame(in bounds: CGRect, flipped: Bool) -> CGRect {
        let g = glyphRect(in: bounds)
        let inset = (dotCell - dotDiameter) / 2
        let x = g.maxX - dotCell + inset
        let y = flipped ? g.minY + inset : g.maxY - dotCell + inset
        return CGRect(x: x, y: y, width: dotDiameter, height: dotDiameter)
    }

    static func dotLayer() -> CALayer {
        let dot = CALayer()
        dot.cornerRadius = dotDiameter / 2
        dot.backgroundColor = NSColor.systemYellow.cgColor
        // A hairline keeps it apart from a light bar and from the active item's highlight.
        dot.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dot.borderWidth = 0.5
        return dot
    }
}
