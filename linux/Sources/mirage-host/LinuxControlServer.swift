import Foundation
import MirageCore
import CMirageDesktop

/// The Linux service's end of the local control socket (LocalControl, as the Mac's miraged serves the Mirage app): the
/// top-bar icon (`mirage-host tray`, one per logged-in user) opens pairing windows, answers Allow / Deny, revokes devices,
/// updates, and changes the host settings. The service runs as root; the socket is /run/mirage/control.sock (0666 so any
/// user's icon can connect), and a peer is served only when it is root or an administrator (a member of sudo, admin or
/// wheel): pairing a device hands over the whole computer. All state lives on one serial queue.
final class LinuxControlServer: @unchecked Sendable {
    static let directory = "/run/mirage"
    static var path: String { directory + "/" + LocalControl.socketName }

    private var ctx: HostContext
    private let port: UInt16
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "mirage.host.local-control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var ticker: DispatchSourceTimer?
    private var shownIssue: Date?
    private var pendingConfirms: [String: CheckedContinuation<Bool?, Never>] = [:]
    private var address: String = "127.0.0.1"

    private final class Client {
        let fd: Int32
        let user: String
        var buffer = Data()
        let source: DispatchSourceRead
        init(fd: Int32, user: String, source: DispatchSourceRead) { self.fd = fd; self.user = user; self.source = source }
    }

    init(ctx: HostContext, port: UInt16, log: @escaping @Sendable (String) -> Void) {
        self.ctx = ctx; self.port = port; self.log = log
    }

    func start() throws {
        mkdir(Self.directory, 0o755)
        chmod(Self.directory, 0o755)
        let s = socket(AF_UNIX, LocalControl.streamType, 0)
        guard s >= 0 else { throw MirageError.transport("control socket: \(String(cString: strerror(errno)))") }
        unlink(Self.path)
        var addr = sockaddr_un.make(Self.path)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { let e = String(cString: strerror(errno)); close(s); throw MirageError.transport("control socket bind: \(e)") }
        chmod(Self.path, 0o666)   // any user's icon connects; who may act is checked per peer
        guard listen(s, 8) == 0 else { close(s); throw MirageError.transport("control socket listen failed") }
        listenFD = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        acceptSource = src
        ctx.pairing.confirm = { [weak self] device in await self?.ask(device) }
        ctx.pairing.paired = { [weak self] device in self?.queue.async { self?.broadcast(.paired(deviceName: device.name)); self?.closePairing("paired \(device.name)") } }
        log("local control on \(Self.path)")
    }

    // MARK: Peers

    /// The peer's user, when it may control the host: root, or an administrator.
    static func admittedUser(fd: Int32) -> String? {
        var uid: UInt32 = 0
        guard md_peer_uid(fd, &uid) == 0, let pw = getpwuid(uid) else { return nil }
        let name = String(cString: pw.pointee.pw_name)
        if uid == 0 { return name }
        var count: Int32 = 64
        var groups = [gid_t](repeating: 0, count: Int(count))
        if getgrouplist(pw.pointee.pw_name, pw.pointee.pw_gid, &groups, &count) < 0 { return nil }
        for g in groups.prefix(Int(max(count, 0))) {
            if let gr = getgrgid(g), ["sudo", "admin", "wheel"].contains(String(cString: gr.pointee.gr_name)) { return name }
        }
        return nil
    }

    private func accept() {
        let c = Glibc.accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        guard let user = Self.admittedUser(fd: c) else { log("local control: refused a peer that is not an administrator"); close(c); return }
        // Never blocks the queue: an icon that stops reading is dropped (EAGAIN) instead of stalling everyone else's.
        _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: queue)
        let client = Client(fd: c, user: user, source: src)
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
        if clients.isEmpty {
            for (_, k) in pendingConfirms { k.resume(returning: nil) }
            pendingConfirms = [:]
            closePairing("the icon disconnected")
        }
    }

    // MARK: Requests

    private var settingsURL: URL { ctx.store.url(HostSettings.fileName) }

    private func handle(_ r: LocalControl.Request, from c: Client) {
        switch r {
        case .hello:
            send(.hello(version: LocalControl.version, hostName: ctx.identity.name, hostID: ctx.identity.id), to: c)
            sendStatus(to: c)
            if let w = ctx.pairing.window, w.isOpen() { shownIssue = nil; tick() }
        case .openPairing:
            guard ctx.sharing() else { send(.pairingClosed(reason: "this computer is not shared"), to: c); return }
            openPairing()
        case .closePairing: closePairing("closed by \(c.user)")
        case .decide(let id, let allow):
            if let k = pendingConfirms.removeValue(forKey: id) { log("pairing: \(allow ? "allowed" : "denied") by \(c.user)"); k.resume(returning: allow) }
        case .status: sendStatus(to: c)
        case .updateNow:
            guard let handler = ctx.updateHandler else { send(.updateStatus(.init(phase: .failed, message: "this host cannot update itself")), to: c); return }
            log("update now, from \(c.user)'s icon")
            Task { await handler(.update(targetBuild: nil), .thisMac, { [weak self] st in self?.queue.async { self?.broadcast(.updateStatus(st)) } }) }
        case .setHostSettings(let new):
            let was = HostSettings.load(from: settingsURL)
            do {
                try new.save(to: settingsURL)
                log("host settings from \(c.user): share \(new.shareThisMac ? "on" : "off"), lock when finished \(new.lockWhenFinished ? "on" : "off"), stay reachable \(new.stayReachable ? "on" : "off")")
                StayAwake.shared.set(new.shareThisMac && new.stayReachable)
                if new.shareThisMac != was.shareThisMac, !new.shareThisMac { closePairing("sharing turned off") }
            } catch { log("host settings not saved: \(error)") }
            broadcastStatus()
        case .revoke(let id):
            let removed = (try? ctx.store.revoke(idPrefix: id)) ?? []
            for d in removed { log("revoked \(d.name) (\(d.id.prefix(12))) from \(c.user)'s icon") }
            broadcastStatus()
        case .requestUnlock, .agentSessionExtend, .agentSessionDone, .requestPermission:
            // Mac-only (Unlock with biometry, agent sessions, TCC grants).
            if case .requestUnlock = r { send(.unlockOutcome(.refused), to: c) }
            if case .agentSessionExtend = r { send(.agentSession(open: false), to: c) }
            if case .agentSessionDone = r { send(.agentSession(open: false), to: c) }
        }
    }

    func broadcastStatus() { queue.async { for c in self.clients.values { self.sendStatus(to: c) } } }

    private func sendStatus(to c: Client) {
        let devices = (try? ctx.store.authorizedDevices()) ?? []
        let base = LocalControl.Status(hostName: ctx.identity.name, pairedDevices: devices.count, pairingOpen: ctx.pairing.window?.isOpen() ?? false,
                                       devices: devices.map { .init(id: $0.id, name: $0.name, pairedAt: $0.pairedAt, model: $0.model) })
        let conns = ctx.connections
        let ctx = self.ctx
        Task {
            let ids = await conns.streamingDeviceIDs()
            self.queue.async {
                var s = base
                s.hostSettings = HostSettings.load(from: self.settingsURL)
                s.hostVersion = .current
                let info = ctx.updateInfo?()
                s.latestAvailable = info?.latestAvailable
                s.updatePolicy = info?.permission?.policy
                s.updateChannel = info?.channel
                s.canUpdate = ctx.updateHandler != nil
                s.connected = ids.map { id in devices.first { $0.id == id }?.name ?? String(id.prefix(12)) }
                if self.clients[c.fd] === c { self.send(.status(s), to: c) }
            }
        }
    }

    // MARK: Pairing window (rotating code and link, as on the Mac)

    private func openPairing() {
        if let w = ctx.pairing.window, w.isOpen() { shownIssue = nil; tick(); return }
        address = LinuxNetwork.pairingAddress() ?? "127.0.0.1"
        ctx.pairing.window = PairingWindow()
        shownIssue = nil
        log("pairing window opened (\(address))")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker?.cancel()
        ticker = t
    }

    private func tick() {
        guard let w = ctx.pairing.window else { return }
        let now = Date()
        guard w.isOpen(now: now) else { closePairing("expired"); return }
        let c = w.current(now: now)
        guard c.issued != shownIssue else { return }
        shownIssue = c.issued
        let link = w.link(hostName: ctx.identity.name, address: address, port: port, hostPublicKey: ctx.identity.publicKey, now: now)
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

    /// Allow / Deny on an administrator's icon; nil when no icon is connected (the host then falls back to `mirage-host
    /// pair`'s terminal, else denies). No answer in 2 min: deny.
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
        let n = line.withUnsafeBytes { Glibc.send(c.fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        if n != line.count { log("local control: \(c.user)'s icon is not reading; dropped"); drop(c) }
    }
}

/// Stay Reachable: while on, a logind inhibitor keeps the computer from sleeping on its own (the display still blanks).
final class StayAwake: @unchecked Sendable {
    static let shared = StayAwake()
    private let lock = NSLock()
    private var process: Process?

    func set(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on, process?.isRunning != true {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/systemd-inhibit")
            p.arguments = ["--what=sleep:idle", "--who=Mirage", "--why=Stay Reachable: paired devices can connect", "--mode=block", "sleep", "infinity"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { process = p }
        } else if !on, let p = process {
            p.terminate(); process = nil
        }
    }
}

/// Addresses for pairing links and `mirage-host pair`.
enum LinuxNetwork {
    /// IPv4 addresses of up, non-loopback interfaces: LAN first, the tailnet's after; containers' bridges left out.
    static func addresses() -> [String] {
        var lan: [String] = [], tail: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt16(AF_INET), i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  i.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(a, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: i.pointee.ifa_name), addr = String(cString: host)
            if name.hasPrefix("docker") || name.hasPrefix("br-") || name.hasPrefix("virbr") || name.hasPrefix("veth") || addr.hasPrefix("169.254.") { continue }
            if name.hasPrefix("tailscale") { tail.append(addr) } else { lan.append(addr) }
        }
        return lan + tail
    }
    /// The address a pairing link names: the tailnet's when there is one (it reaches this computer from anywhere), else the
    /// LAN's.
    static func pairingAddress() -> String? {
        let all = addresses()
        return all.first { $0.hasPrefix("100.") } ?? all.first
    }
}
