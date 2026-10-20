import AppKit
import CoreImage
import MirageCore

/// The host's menu-bar item (DESIGN §3.1 pairing): "Pair a Device…" opens a window with the rotating 6-digit code, a QR
/// code (a `miragerd://pair` link) and a countdown ring; a device that completes the exchange is asked about here
/// (Allow / Deny) before it is authorized.
///
/// Runs inside `miraged serve`, whose main thread runs `NSApplication.run()` from within a main-actor job: main-actor and
/// main-queue work would never run there, so everything here is AppKit driven by timers, target-action and
/// `RunLoop.main.perform` (no SwiftUI, no `await MainActor`). The host's sessions reach it only through `ctx.pairing`.
public final class HostMenu: NSObject {
    private let ctx: HostContext
    private let port: UInt16
    private let log: (String) -> Void
    private var statusItem: NSStatusItem?
    private var pairPanel: PairingPanel?
    private static var shared: HostMenu?

    /// Installs the menu-bar item and the pairing hooks, then runs the AppKit event loop (never returns).
    public static func run(ctx: HostContext, port: UInt16, log: @escaping (String) -> Void) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let m = HostMenu(ctx: ctx, port: port, log: log)
            shared = m
            m.install()
            app.run()
        }
        exit(0)
    }

    private init(ctx: HostContext, port: UInt16, log: @escaping (String) -> Void) {
        self.ctx = ctx; self.port = port; self.log = log
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Mirage")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        ctx.pairing.confirm = { [weak self] device in await self?.ask(device) ?? false }
        ctx.pairing.paired = { [weak self] device in RunLoop.main.perform { self?.pairPanel?.succeeded(device.name) } }
        // Test knob MIRAGE_TEST_OPEN_PAIRING: the pairing window opens at launch (screenshots without clicking the menu bar).
        if ProcessInfo.processInfo.environment["MIRAGE_TEST_OPEN_PAIRING"] != nil { pairDevice() }
    }

    @objc private func pairDevice() {
        if let p = pairPanel { p.show(); return }
        let window = PairingWindow()
        ctx.pairing.window = window
        let net = TailnetAddress.current()
        let p = PairingPanel(window: window, hostName: ctx.identity.name, linkHost: net.name ?? ctx.identity.name, address: net.address ?? "127.0.0.1",
                             port: port, hostKey: ctx.identity.publicKey) { [weak self] in
            window.close()
            if self?.ctx.pairing.window === window { self?.ctx.pairing.window = nil }
            self?.pairPanel = nil
        }
        pairPanel = p
        log("pairing window opened (\(net.address ?? "no tailnet address"), link host \(net.name ?? "-"))")
        p.show()
    }

    /// Allow / Deny on this Mac, before the device is authorized (code or link alike). No answer in 2 min is a deny.
    private func ask(_ device: DeviceRecord) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    let alert = NSAlert()
                    alert.messageText = "\(device.name) wants to pair with this Mac."
                    alert.informativeText = "Allow it to see and control this Mac through Mirage?\n\nDevice key \(PairingLink.fingerprintText(Data(hexString: device.id) ?? Data()))"
                    alert.addButton(withTitle: "Allow")
                    alert.addButton(withTitle: "Deny")
                    NSApp.activate(ignoringOtherApps: true)
                    let timer = Timer(timeInterval: 120, repeats: false) { _ in NSApp.abortModal() }
                    RunLoop.main.add(timer, forMode: .modalPanel)
                    let r = alert.runModal()
                    timer.invalidate()
                    c.resume(returning: r == .alertFirstButtonReturn)
                }
            }
        }
    }
}

extension HostMenu: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Mirage on \(ctx.identity.name)", action: nil, keyEquivalent: ""); title.isEnabled = false
        menu.addItem(title)
        let n = (try? ctx.store.authorizedDevices().count) ?? 0
        let devices = NSMenuItem(title: n == 1 ? "1 paired device" : "\(n) paired devices", action: nil, keyEquivalent: ""); devices.isEnabled = false
        menu.addItem(devices)
        menu.addItem(.separator())
        let pair = NSMenuItem(title: "Pair a Device…", action: #selector(pairDevice), keyEquivalent: "")
        pair.target = self
        menu.addItem(pair)
    }
}

/// The pairing window: code (3 + 3, large), QR code, a ring counting down to the next rotation, closing after 5 min.
final class PairingPanel: NSObject, NSWindowDelegate {
    private let window: PairingWindow
    private let hostName: String, linkHost: String, address: String, port: UInt16, hostKey: Data
    private let onClose: () -> Void
    private let panel: NSPanel
    private let code = NSTextField(labelWithString: "")
    private let qr = NSImageView()
    private let ring = CountdownRing()
    private let status = NSTextField(labelWithString: "")
    private var shownIssue: Date?
    private var timer: Timer?
    private var finished = false

    init(window: PairingWindow, hostName: String, linkHost: String, address: String, port: UInt16, hostKey: Data, onClose: @escaping () -> Void) {
        self.window = window; self.hostName = hostName; self.linkHost = linkHost; self.address = address; self.port = port; self.hostKey = hostKey
        self.onClose = onClose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Pair a Device"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating
        build()
        refresh()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func build() {
        let v = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        let heading = NSTextField(wrappingLabelWithString: "Scan with the Mirage app on your iPhone, or type the code on the other device.")
        heading.alignment = .center
        heading.font = .systemFont(ofSize: 13)
        heading.textColor = .secondaryLabelColor
        code.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        code.alignment = .center
        qr.imageScaling = .scaleProportionallyUpOrDown
        status.alignment = .center
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        for (sub, frame) in [(heading as NSView, NSRect(x: 20, y: 410, width: 320, height: 40)),
                             (qr, NSRect(x: 70, y: 180, width: 220, height: 220)),
                             (code, NSRect(x: 20, y: 110, width: 270, height: 56)),
                             (ring, NSRect(x: 296, y: 120, width: 36, height: 36)),
                             (status, NSRect(x: 20, y: 70, width: 320, height: 32)),
                             (cancel, NSRect(x: 130, y: 20, width: 100, height: 32))] {
            sub.frame = frame
            v.addSubview(sub)
        }
        panel.contentView = v
        panel.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        guard !finished else { return }
        let now = Date()
        guard window.isOpen(now: now) else { finish("The code expired. Choose Pair a Device… again for a new one.", closeAfter: 3); return }
        let c = window.current(now: now)
        if shownIssue != c.issued {
            shownIssue = c.issued
            code.stringValue = "\(c.code.prefix(3)) \(c.code.suffix(3))"
            let link = window.link(hostName: linkHost, address: address, port: port, hostPublicKey: hostKey, now: now)
            qr.image = Self.qrImage(link.url.absoluteString, side: 440)
        }
        ring.fraction = max(0, c.rotatesAt.timeIntervalSince(now) / PairingWindow.rotation)
        let left = Int(window.closesAt.timeIntervalSince(now))
        status.stringValue = "New code every 30 s · window closes in \(left / 60):\(String(format: "%02d", left % 60))\nThis Mac: \(hostName) · \(address)"
    }

    func succeeded(_ device: String) { finish("✓ Paired \(device).", closeAfter: 2) }

    private func finish(_ message: String, closeAfter: TimeInterval) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        window.close()
        code.stringValue = ""
        qr.image = nil
        ring.fraction = 0
        status.stringValue = message
        let t = Timer(timeInterval: closeAfter, repeats: false) { [weak self] _ in self?.panel.close() }
        RunLoop.main.add(t, forMode: .common)
    }

    @objc private func cancel() { panel.close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        window.close()
        onClose()
    }

    static func qrImage(_ text: String, side: CGFloat) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: side / out.extent.width, y: side / out.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
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
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }
}

/// This Mac's tailnet name and address, for the pairing link: Tailscale's own status when its CLI is installed, else the
/// first 100.64.0.0/10 IPv4 address (Tailscale's range) and this Mac's local host name.
public enum TailnetAddress {
    public static func current() -> (name: String?, address: String?) {
        for path in ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = ["status", "--self", "--json"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let me = j["Self"] as? [String: Any] {
                let dns = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
                let ip = (me["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
                if ip != nil { return (dns.flatMap { $0.isEmpty ? nil : $0 }, ip) }
            }
        }
        return (Host.current().localizedName, cgnatAddress())
    }

    static func cgnatAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if a & 0xFFC0_0000 == 0x6440_0000 {   // 100.64.0.0/10
                return "\(a >> 24).\((a >> 16) & 255).\((a >> 8) & 255).\(a & 255)"
            }
        }
        return nil
    }
}

private extension Data {
    init?(hexString: String) {
        var d = Data(); var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}
