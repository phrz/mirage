import Foundation
import ArgumentParser
import MirageCore
import CMirageDesktop

@main
struct MirageHost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirage-host",
        abstract: "Mirage host for Linux: shares this computer's screen with paired Mirage viewers over QUIC.",
        subcommands: [Serve.self, Pair.self, Devices.self, Revoke.self, Check.self, Version.self, Update.self],
        defaultSubcommand: Serve.self)
}

/// As root (the system service, from boot) the host keeps its identity and pairings in /var/lib/mirage; as a user, in
/// ~/.local/share/Mirage.
let systemStore = URL(fileURLWithPath: "/var/lib/mirage", isDirectory: true)
func hostStore() throws -> Store { geteuid() == 0 ? try Store(root: systemStore) : try Store() }

func log(_ s: String) {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    FileHandle.standardError.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the host (foreground; the installer runs it as a systemd service).",
        discussion: "As root it shows and drives the screen itself (the kernel's display and virtual input devices): the login screen, the lock screen and any desktop. As a user it shares that user's GNOME session.")
    @Option(name: .shortAndLong, help: "UDP port to listen on.") var port: UInt16 = Mirage.defaultPort
    @Option(help: "Host name shown to viewers (default: this computer's host name).") var name: String?
    @Flag(help: "As a user: let GNOME lock the screen when idle. GNOME ends screen sharing when it locks, so viewers then get no picture until someone unlocks it at the computer.") var allowLock = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        log("mirage-host build \(LinuxBuild.number) (\(LinuxBuild.commit))")
        MirageVersion.current = LinuxUpdater.current   // what Welcomes report
        // First: a build on trial that fails anywhere later is counted.
        let updater = geteuid() == 0 ? LinuxUpdater(dir: systemStore, log: { log($0) }) : nil
        updater?.beginStart()
        let store = try hostStore()
        let identity = try store.identity(role: "host", name: name ?? DeviceNames.current())
        let tls = try TLSIdentity.loadOrCreate(store: store)
        let source: DesktopSource
        if geteuid() == 0 {
            source = try KMSDesktop(log: { log($0) })
            log("showing the screen itself (login screen, lock screen, any desktop)")
        } else {
            let gnome = GnomeSession()
            gnome.start(log: { log($0) })
            source = gnome
        }
        var ctx = HostContext(identity: identity, store: store, tlsFingerprint: tls.fingerprint, log: { log($0) },
                              makeStreamer: { LinuxStreamer(source: source, log: { log($0) }) })
        if let updater {
            // A paired Mac's update arrow: this build, the newest verified one, and its trigger.
            ctx.updateInfo = {
                var info = HostUpdateInfo(latestAvailable: updater.latestAvailable, permission: UpdatePermission(policy: .automatic, viewerMayTrigger: true))
                info.channel = .stable
                info.installed = LinuxUpdater.current
                return info
            }
            ctx.updateHandler = { cmd, _, reply in await updater.handle(cmd, reply: reply) }
            ctx.welcomed = { updater.refreshSoon() }
        }
        if geteuid() != 0, !allowLock {
            var err = [CChar](repeating: 0, count: 256)
            if md_inhibit_idle("Shared with Mirage: GNOME stops screen sharing when the screen locks", &err, err.count) == 0 {
                log("the screen will not idle-lock while mirage-host runs (GNOME ends screen sharing when it locks); --allow-lock turns this off")
            } else {
                log("could not keep the screen from idle-locking: \(String(cString: err))")
            }
        }
        let host = QUICHost(port: port, tls: tls)
        host.log = { log($0) }
        try host.start(onStream: { stream, id, remote in
            Task { await HostSession.handle(stream: stream, connectionID: id, remote: remote, ctx: ctx) }
        })
        log("mirage host \(identity.name) (Linux) id=\(identity.id.prefix(12)) devices=\(try store.authorizedDevices().count), listening on udp/\(port)")
        if let updater {
            updater.watchTrial(ctx: ctx)   // a new build's trial ends the same way whether or not it installs on its own
            if updater.disabled { log("automatic updates: off (\(updater.disabledPath)); a viewer's update still works") }
            else { updater.start(ctx: ctx) }
        }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a one-time 6-digit code and wait for a device to pair.")
    @Option(help: "Seconds the code stays valid.") var timeout: Int = 300

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try hostStore()
        let code = PairingCode.generate()
        let pending = Store.PendingPairing(code: code, expiresAt: Date().addingTimeInterval(TimeInterval(timeout)))
        try store.setPendingPairing(pending)
        let addresses = localAddresses()
        print("""

            Pairing code:  \(code.prefix(3)) \(code.suffix(3))

            On your Mac, in Mirage: click +, enter \(addresses.first ?? DeviceNames.current()) and this code.
            \(addresses.count > 1 ? "Other addresses of this computer: \(addresses.dropFirst().joined(separator: ", "))\n" : "")\
            Valid for \(timeout / 60) minutes, one attempt. Waiting…
            """)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout) + 65)
        while Date() < deadline {
            if let q = try store.takePairingConfirmRequest(attemptID: pending.attemptID) {
                print("\n\(q.deviceName) wants to pair with this computer (key \(q.deviceID.prefix(16))…). Allow? [y/N] ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
                try store.setPairingDecision(attemptID: pending.attemptID, allow: answer == "y" || answer == "yes")
            }
            if let r = try store.takePairingResult(attemptID: pending.attemptID) {
                print(r.ok ? "✓ \(r.message)" : "✗ \(r.message)")
                throw ExitCode(r.ok ? 0 : 1)
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        store.remove("pending-pair.json")
        print("✗ timed out, code expired")
        throw ExitCode(1)
    }

    /// IPv4 addresses of this computer's up, non-loopback interfaces, LAN first.
    func localAddresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt16(AF_INET), i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  i.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let name = String(cString: i.pointee.ifa_name)
                let addr = String(cString: host)
                if name.hasPrefix("docker") || name.hasPrefix("br-") || name.hasPrefix("virbr") || name.hasPrefix("veth") { continue }
                if name.hasPrefix("tailscale") { out.append(addr) } else { out.insert(addr, at: 0) }
            }
        }
        return out
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List paired devices.")
    func run() throws {
        let list = try hostStore().authorizedDevices()
        if list.isEmpty { print("no paired devices"); return }
        let f = ISO8601DateFormatter()
        for d in list { print("\(d.id.prefix(12))  \(f.string(from: d.pairedAt))  \(d.name)") }
    }
}

struct Revoke: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a paired device by id prefix.")
    @Argument var idPrefix: String
    func run() throws {
        let removed = try hostStore().revoke(idPrefix: idPrefix)
        if removed.isEmpty { print("no device matches \(idPrefix)"); throw ExitCode(1) }
        for d in removed { print("revoked \(d.id.prefix(12)) \(d.name)") }
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "As root: check that this computer's screen can be read and driven (the installer runs it before switching to the system service).")
    func run() async throws {
        let source: KMSDesktop
        do { source = try KMSDesktop(log: { _ in }) } catch { print("✗ \(error)"); throw ExitCode(1) }
        guard let lease = source.acquire(timeout: 10) else { print("✗ \(source.unavailableReason ?? "no picture")"); throw ExitCode(1) }
        var w: Int32 = 0, h: Int32 = 0
        md_picture_size(lease.picture, &w, &h)
        print("✓ screen \(w)x\(h), keyboard and pointer ready")
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print this build.")
    func run() throws { print("mirage-host build \(LinuxBuild.number) (\(LinuxBuild.commit)) \(LinuxUpdater.arch)") }
}

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "As root: check for a newer build now and install it (the service also checks every 6 hours).")
    func run() async throws {
        guard geteuid() == 0 else { print("run it with sudo"); throw ExitCode(1) }
        let updater = LinuxUpdater(dir: systemStore, log: { print($0) })
        guard let build = try await updater.stage() else { print("up to date (build \(LinuxBuild.number))"); return }
        updater.install(build, restart: true)
    }
}
