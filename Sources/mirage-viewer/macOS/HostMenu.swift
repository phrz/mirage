import AppKit
import CoreImage
import MirageCore

/// The Mirage app's menu-bar item for this Mac as a host (DESIGN §3.1 pairing): it talks to the local `miraged` over the
/// control socket (LocalControl) — "Pair a Device…" opens a window with the rotating 6-digit code, a QR code and a
/// countdown ring; a device that completes the exchange is asked about here (Allow / Deny) before the host authorizes it.
/// `miraged` stays headless.
final class HostMenu: NSObject, NSMenuDelegate {
    private let store: Store?
    private var client: LocalControlClient?
    private var statusItem: NSStatusItem?
    private var panel: PairingPanel?
    private var hostName: String?
    private var status: LocalControl.Status?
    private var retry: Timer?

    override init() {
        store = try? Store()
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Mirage host")
        item.button?.image?.isTemplate = true
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        statusItem = item
        connect()
        // Test knob MIRAGE_TEST_OPEN_PAIRING: the pairing window opens at launch (screenshots without clicking the menu bar).
        if ProcessInfo.processInfo.environment["MIRAGE_TEST_OPEN_PAIRING"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pairDevice() } }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in if self?.client?.isConnected != true { self?.connect() } }
        RunLoop.main.add(t, forMode: .common)
        retry = t
    }

    var isConnected: Bool { client?.isConnected == true }

    private func connect() {
        guard let store else { return }
        let c = LocalControlClient(store: store)
        c.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
        c.onClose = { [weak self] in DispatchQueue.main.async { self?.hostName = nil; self?.status = nil; self?.panel?.hostGone() } }
        do { try c.connect(client: "Mirage") ; client = c } catch { client = nil }
    }

    private func handle(_ e: LocalControl.Event) {
        switch e {
        case .hello(_, let name, _): hostName = name
        case .status(let s): status = s
        case .pairing(let p): panel?.show(p)
        case .pairingClosed(let reason): panel?.closed(reason)
        case .paired(let name): panel?.succeeded(name)
        case .confirm(let c): ask(c)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        try? client?.send(.status)
        menu.removeAllItems()
        func label(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        if isConnected {
            label("Connections allowed to \(hostName ?? "this Mac")")
            if let s = status { label(s.pairedDevices == 1 ? "1 paired device" : "\(s.pairedDevices) paired devices") }
        } else {
            label("This Mac is not accepting connections")
        }
        menu.addItem(.separator())
        let pair = NSMenuItem(title: "Pair a Device…", action: isConnected ? #selector(pairDevice) : nil, keyEquivalent: "")
        pair.target = self
        menu.addItem(pair)
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
