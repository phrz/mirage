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
    /// The permissions requested in this run (each at most once).
    private var requestedThisRun: Set<HostPermissions.Kind> = []
    /// Tells the app the host is about to restart (to apply newly granted permissions).
    public func announceRestart() {
        queue.sync {
            restarting = true
            for c in clients.values { sendStatus(to: c) }
        }
    }
    /// Share This Mac changed (miraged restarts into the new role).
    public var onShareChange: ((Bool) -> Void)?
    /// Every connected app hears the current status (a grant changed).
    public func broadcastStatus() { queue.async { for c in self.clients.values { self.sendStatus(to: c) } } }
    /// Asks the Mirage app to show its permissions window; false when no app is connected.
    @discardableResult
    public func askToShowPermissions(reason: String? = nil) -> Bool {
        queue.sync {
            guard !clients.isEmpty else { return false }
            broadcast(.showPermissions(reason: reason))
            return true
        }
    }
    public var hasClients: Bool { queue.sync { !clients.isEmpty } }

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
            guard var r = try? LocalControl.decode(LocalControl.Request.self, line: line) else { continue }
            if case .setHostSettings = r, let sent = Self.sentSettings(line) {
                // Keys an older app leaves out keep their stored values (not the defaults).
                r = .setHostSettings(HostSettings.merged(message: sent, over: HostSettings.load(from: ctx.store.url(HostSettings.fileName))))
            }
            handle(r, from: c)
        }
    }

    /// The settings object as sent in a `setHostSettings` line (`{"setHostSettings":{"_0":{…}}}`).
    static func sentSettings(_ line: Data) -> Data? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let wrap = obj["setHostSettings"] as? [String: Any],
              let inner = wrap["_0"] ?? wrap.values.first else { return nil }
        return try? JSONSerialization.data(withJSONObject: inner)
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
        case .openPairing:
            guard ctx.sharing() else { send(.pairingClosed(reason: "this Mac is not shared"), to: c); return }
            openPairing()
        case .closePairing: closePairing("closed in the app")
        case .decide(let id, let allow):
            if let k = pendingConfirms.removeValue(forKey: id) { k.resume(returning: allow) }
        case .status: sendStatus(to: c)
        case .updateNow:
            guard let handler = ctx.updateHandler else {
                send(.updateStatus(.init(phase: .failed, message: "this host cannot update itself (a development build or a test instance)")), to: c); return
            }
            log("update now, from the Mirage app")
            Task { await handler(.update(targetBuild: nil), .thisMac, { [weak self] st in self?.queue.async { self?.broadcast(.updateStatus(st)) } }) }
        case .setHostSettings(let new):
            let was = HostSettings.load(from: ctx.store.url(HostSettings.fileName))
            do {
                try new.save(to: ctx.store.url(HostSettings.fileName))
                log("host settings from the Mirage app: curtain \(new.curtain ? "on" : "off"), lock when finished \(new.lockWhenFinished ? "on" : "off") (from the next session), stay reachable \(new.stayReachable ? "on" : "off")")
                if new.shareThisMac { StayReachable.shared.set(new.stayReachable) }
                if new.shareThisMac != was.shareThisMac {
                    log("share this Mac: \(new.shareThisMac ? "on" : "off"), from the Mirage app")
                    onShareChange?(new.shareThisMac)
                }
            } catch { log("host settings not saved: \(error)") }
            sendStatus(to: c)
        case .requestUnlock(let reason, _):
            // The requester as the host finds it from the socket's peer (what the asker says about itself is ignored).
            // A Mac that is not shared offers no unlock (and no agent sessions).
            guard ctx.sharing(), ctx.unlockHandler != nil else { send(.unlockOutcome(.refused), to: c); return }
            let peer = PeerIdentity.requester(fd: c.fd)
            let who = UnlockLogic.clean(peer.label, limit: 160), why = UnlockLogic.clean(reason)
            log("unlock requested by \(who): \(why)")
            let requests = ctx.unlockRequests
            Task {
                let o = await requests.request(reason: why, requester: who, anchor: peer.anchor)
                self.log("unlock request by \(who): \(o.rawValue)")
                self.queue.async { self.send(.unlockOutcome(o), to: c) }
            }
        case .agentSessionExtend where !ctx.sharing(), .agentSessionDone where !ctx.sharing():
            send(.agentSession(open: false), to: c)
        case .agentSessionExtend:
            // Only the program that asked for the unlock keeps its session going (verified from this peer, not claimed).
            let anchor = PeerIdentity.requester(fd: c.fd).anchor
            AgentSessions.shared.extend(anchor: anchor) { open, extended in self.queue.async { self.send(.agentSession(open: open && extended), to: c) } }
        case .agentSessionDone:
            AgentSessions.shared.end(by: UnlockLogic.clean(PeerIdentity.requester(fd: c.fd).label, limit: 160)) { had in self.queue.async { self.send(.agentSession(open: had), to: c) } }
        case .requestPermission(let raw):
            guard let kind = HostPermissions.Kind(rawValue: raw) else { return }
            // A Mac that is not shared never asks for a grant.
            guard ctx.sharing() else { log("permissions: \(raw) asked while this Mac is not shared; ignored"); sendStatus(to: c); return }
            // At most once per kind in this run: a second ask (another Allow, or any client of this user) never raises the
            // dialog again over System Settings.
            if HostPermissions.granted(kind) || requestedThisRun.contains(kind) { sendStatus(to: c); return }
            requestedThisRun.insert(kind)
            log("permissions: requesting \(raw), asked in the Mirage app")
            PermissionRequests.record(kind, store: ctx.store)
            DispatchQueue.main.async { HostPermissions.request(kind) }
            sendStatus(to: c)
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
                                       // Not shared: the grants are never read (nil: nothing to ask for).
                                       screenRecording: ctx.sharing() ? HostPermissions.screenRecordingGranted() : nil,
                                       accessibility: ctx.sharing() ? HostPermissions.accessibilityGranted() : nil)
        let asked = PermissionRequests.asked(store: ctx.store).map(\.rawValue)
        let conns = ctx.connections
        Task {
            let ids = await conns.streamingDeviceIDs()
            self.queue.async {
                var s = base
                s.restarting = self.restarting ? true : nil
                s.permissionsAsked = asked.isEmpty ? nil : asked
                s.hostSettings = HostSettings.load(from: self.ctx.store.url(HostSettings.fileName))
                s.lockFailedAt = HostLockStatus.lastFailure
                s.hostVersion = .current
                s.latestAvailable = self.ctx.updateInfo?().latestAvailable
                s.canUpdate = self.ctx.updateHandler != nil
                let last = self.ctx.updateInfo?().lastResult
                s.updating = last.flatMap { $0.isFinal || $0.phase == .unknown ? nil : $0 }
                s.lastUpdate = last.flatMap { $0.isFinal ? $0 : nil }
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
