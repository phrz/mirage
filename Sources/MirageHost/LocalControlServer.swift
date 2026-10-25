import Foundation
import MirageCore

/// `miraged`'s end of the local control socket (LocalControl): the Mirage app on this Mac opens pairing windows, gets their
/// rotating code and link, and answers Allow / Deny. Owner-only: the socket is 0600 inside the store's 0700 directory and a
/// peer whose uid is not ours is dropped. All state lives on one serial queue.
public final class LocalControlServer: @unchecked Sendable {
    private let ctx: HostContext
    private let port: UInt16
    private let path: String
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "mirage.host.local-control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var ticker: DispatchSourceTimer?
    private var shownIssue: Date?
    private var pendingConfirms: [String: CheckedContinuation<Bool?, Never>] = [:]
    private var restarting = false
    /// Tells the app the host is about to restart (to apply newly granted permissions).
    public func announceRestart() {
        queue.sync {
            restarting = true
            for c in clients.values { sendStatus(to: c) }
        }
    }
    /// The tailnet name and address, looked up once per pairing window (it runs the Tailscale CLI).
    private var net: (name: String?, address: String?) = (nil, nil)

    private final class Client {
        let fd: Int32
        var buffer = Data()
        let source: DispatchSourceRead
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    public init(ctx: HostContext, port: UInt16, log: @escaping (String) -> Void) {
        self.ctx = ctx; self.port = port; self.log = log
        path = ctx.store.url(LocalControl.socketName).path
    }

    public func start() throws {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw MirageError.transport("control socket: \(String(cString: strerror(errno)))") }
        unlink(path)   // a stale socket from an earlier run (or a crash)
        var addr = sockaddr_un.make(path)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { let e = String(cString: strerror(errno)); close(s); throw MirageError.transport("control socket bind: \(e)") }
        chmod(path, 0o600)
        guard listen(s, 4) == 0 else { close(s); throw MirageError.transport("control socket listen failed") }
        listenFD = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        acceptSource = src
        // The pairing hooks: the app answers Allow / Deny; nil (no app connected) lets the host fall back.
        ctx.pairing.confirm = { [weak self] device in await self?.ask(device) }
        ctx.pairing.paired = { [weak self] device in self?.queue.async { self?.broadcast(.paired(deviceName: device.name)); self?.closePairing("paired \(device.name)") } }
        log("local control on \(path)")
    }

    private func accept() {
        let c = Darwin.accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { log("local control: refused a peer of another user"); close(c); return }
        var on: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: queue)
        let client = Client(fd: c, source: src)
        clients[c] = client
        src.setEventHandler { [weak self] in self?.readable(client) }
        src.setCancelHandler { close(c) }
        src.resume()
    }

    private func readable(_ c: Client) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(c.fd, &chunk, chunk.count)
        guard n > 0 else { drop(c); return }
        c.buffer.append(contentsOf: chunk[0..<n])
        if c.buffer.count > 65536 { drop(c); return }
        for line in LocalControl.takeLines(&c.buffer) {
            guard let r = try? LocalControl.decode(LocalControl.Request.self, line: line) else { continue }
            handle(r, from: c)
        }
    }

    private func drop(_ c: Client) {
        clients[c.fd] = nil
        c.source.cancel()
        // With no app left to answer, pending questions fall back (nil) and the window closes.
        if clients.isEmpty {
            for (_, k) in pendingConfirms { k.resume(returning: nil) }
            pendingConfirms = [:]
            closePairing("the app disconnected")
        }
    }

    private func handle(_ r: LocalControl.Request, from c: Client) {
        switch r {
        case .hello:
            send(.hello(version: LocalControl.version, hostName: ctx.identity.name, hostID: ctx.identity.id), to: c)
            sendStatus(to: c)
            if let w = ctx.pairing.window, w.isOpen() { shownIssue = nil; tick() }
        case .openPairing: openPairing()
        case .closePairing: closePairing("closed in the app")
        case .decide(let id, let allow):
            if let k = pendingConfirms.removeValue(forKey: id) { k.resume(returning: allow) }
        case .status: sendStatus(to: c)
        case .revoke(let id):
            // Future connections and resumes are refused (both authenticate against the store); a stream in progress ends
            // with its connection.
            let removed = (try? ctx.store.revoke(idPrefix: id)) ?? []
            for d in removed { log("revoked \(d.name) (\(d.id.prefix(12))) from the Mirage app") }
            sendStatus(to: c)
        }
    }

    /// The status, with who is streaming (an actor call) and the host's own grants.
    private func sendStatus(to c: Client) {
        let devices = (try? ctx.store.authorizedDevices()) ?? []
        let base = LocalControl.Status(hostName: ctx.identity.name, pairedDevices: devices.count, pairingOpen: ctx.pairing.window?.isOpen() ?? false,
                                       devices: devices.map { .init(id: $0.id, name: $0.name, pairedAt: $0.pairedAt, model: $0.model) },
                                       screenRecording: HostPermissions.screenRecordingGranted(), accessibility: HostPermissions.accessibilityGranted(prompt: false))
        let conns = ctx.connections
        Task {
            let ids = await conns.streamingDeviceIDs()
            self.queue.async {
                var s = base
                s.restarting = self.restarting ? true : nil
                s.connected = ids.map { id in devices.first { $0.id == id }?.name ?? String(id.prefix(12)) }
                if self.clients[c.fd] === c { self.send(.status(s), to: c) }
            }
        }
    }

    private func openPairing() {
        if let w = ctx.pairing.window, w.isOpen() { shownIssue = nil; tick(); return }
        // At once with the address; the name (MagicDNS, by reverse lookup) fills in when it comes: nothing here may block
        // the control socket (the Tailscale app's binary did, ~15 s, and raised a prompt on the host).
        net = (nil, TailnetAddress.address())
        ctx.pairing.window = PairingWindow()
        shownIssue = nil
        log("pairing window opened (\(net.address ?? "no tailnet address"))")
        if let a = net.address {
            TailnetAddress.name(of: a) { [weak self] name in
                self?.queue.async {
                    guard let self, let name, self.ctx.pairing.window?.isOpen() == true, self.net.address == a else { return }
                    self.net.name = name; self.shownIssue = nil   // the next tick sends the link with the name
                    self.log("pairing link host \(name)")
                }
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker?.cancel()
        ticker = t
    }

    /// Sends the window's credentials whenever they rotate; closes it when its 5 minutes are up.
    private func tick() {
        guard let w = ctx.pairing.window else { return }
        let now = Date()
        guard w.isOpen(now: now) else { closePairing("expired"); return }
        let c = w.current(now: now)
        guard c.issued != shownIssue else { return }
        shownIssue = c.issued
        let address = net.address ?? "127.0.0.1"
        let link = w.link(hostName: net.name ?? ctx.identity.name, address: address, port: port, hostPublicKey: ctx.identity.publicKey, now: now)
        broadcast(.pairing(.init(code: c.code, link: link.url.absoluteString, rotatesAt: c.rotatesAt, closesAt: w.closesAt, hostName: ctx.identity.name, address: address)))
    }

    private func closePairing(_ reason: String) {
        ticker?.cancel(); ticker = nil
        guard let w = ctx.pairing.window else { return }
        w.close()
        ctx.pairing.window = nil
        shownIssue = nil
        broadcast(.pairingClosed(reason: reason))
        log("pairing window closed (\(reason))")
    }

    /// Allow / Deny in the app; nil when no app is connected to ask (the host then falls back). No answer in 2 min: deny.
    private func ask(_ device: DeviceRecord) async -> Bool? {
        await withCheckedContinuation { (k: CheckedContinuation<Bool?, Never>) in
            queue.async {
                guard !self.clients.isEmpty else { k.resume(returning: nil); return }
                let id = UUID().uuidString
                self.pendingConfirms[id] = k
                self.broadcast(.confirm(.init(requestID: id, deviceName: device.name, deviceID: device.id)))
                self.queue.asyncAfter(deadline: .now() + 120) {
                    if let k = self.pendingConfirms.removeValue(forKey: id) { k.resume(returning: false) }
                }
            }
        }
    }

    private func broadcast(_ e: LocalControl.Event) { for c in clients.values { send(e, to: c) } }
    private func send(_ e: LocalControl.Event, to c: Client) {
        guard let line = try? LocalControl.encodeLine(e) else { return }
        _ = line.withUnsafeBytes { write(c.fd, $0.baseAddress, $0.count) }
    }
}
