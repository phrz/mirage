import Foundation
import ArgumentParser
import MirageCore
import CMirageDesktop

@main
struct MirageHost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirage-host",
        abstract: "Mirage host for Linux: shares this computer's screen with paired Mirage viewers over QUIC.",
        subcommands: [Serve.self, Pair.self, Devices.self, Revoke.self, Check.self, Version.self, Update.self, Tray.self],
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
        HostSession.computerNoun = "computer"
        let settingsURL = store.url(HostSettings.fileName)
        // Lock When Finished (the host's settings, as on a Mac): when the last session ends, the screen locks.
        let lockIfLast: @Sendable (HostConnections) -> Void = { conns in
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard HostSettings.load(from: settingsURL).lockWhenFinished, await conns.streamingDeviceIDs().isEmpty, geteuid() == 0 else { return }
                log("the last session ended: locking the screen (Lock When Finished)")
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/loginctl"); p.arguments = ["lock-sessions"]
                try? p.run()
            }
        }
        let connections = HostConnectionsBox()
        var ctx = HostContext(identity: identity, store: store, tlsFingerprint: tls.fingerprint, log: { log($0) },
                              makeStreamer: { LinuxStreamer(source: source, log: { log($0) }, ended: { if let c = connections.value { lockIfLast(c) } }) })
        connections.value = ctx.connections
        // Share This Computer: off, streams and pairing are refused (read at each use, so the icon's change applies at once).
        ctx.sharing = { HostSettings.load(from: settingsURL).shareThisMac }
        if let updater {
            // A paired Mac's update arrow: this build, the newest verified one, and its trigger.
            ctx.updateInfo = {
                var info = HostUpdateInfo(latestAvailable: updater.latestAvailable,
                                          permission: UpdatePermission(policy: updater.disabled ? .ask : .automatic, viewerMayTrigger: true))
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
        if geteuid() == 0 {
            let s = HostSettings.load(from: settingsURL)
            StayAwake.shared.set(s.shareThisMac && s.stayReachable)
            let control = LinuxControlServer(ctx: ctx, port: port, log: { log($0) })
            do { try control.start(); controlServer = control } catch { log("local control unavailable: \(error)") }
            TrayLauncher.installAutostart(log: { log($0) })
            TrayLauncher.startInRunningSessions(log: { log($0) })
        }
        let host = QUICHost(port: port, tls: tls)
        host.log = { log($0) }
        try host.start(onStream: { stream, id, remote in
            Task { await HostSession.handle(stream: stream, connectionID: id, remote: remote, ctx: ctx) }
        })
        log("mirage host \(identity.name) (Linux) id=\(identity.id.prefix(12)) devices=\(try store.authorizedDevices().count), listening on udp/\(port)")
        if let updater {
            updater.watchTrial(ctx: ctx)   // a new build's trial ends the same way whether or not it installs on its own
            updater.watchFeed()
            updater.refreshSoon()
            if updater.disabled { log("automatic updates: off (\(updater.disabledPath)); a viewer's update still works") }
            else { updater.start(ctx: ctx) }
        }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}

/// The local control server, kept for the process's life (its socket's handlers hold it only weakly).
nonisolated(unsafe) var controlServer: LinuxControlServer?

/// Lets the streamer factory reach the context's connections, made after it.
final class HostConnectionsBox: @unchecked Sendable { var value: HostConnections? }

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a one-time 6-digit code and wait for a device to pair.")
    @Option(help: "Seconds the code stays valid.") var timeout: Int = 300

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try hostStore()
        let code = PairingCode.generate()
        let pending = Store.PendingPairing(code: code, expiresAt: Date().addingTimeInterval(TimeInterval(timeout)))
        try store.setPendingPairing(pending)
        let addresses = LinuxNetwork.addresses()
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

struct Tray: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The top-bar icon for this desktop session (started at login): Share This Computer, Pair a Device…, Allow / Deny, paired devices, updates.")
    func run() throws {
        // Only administrators can use the icon (the service serves no one else): others get none.
        guard let me = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_name) }), TrayLauncher.isAdmin(me) else { return }
        TrayLauncher.enableAppIndicators()
        let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("mirage-tray.js")
        try trayScript.write(toFile: path, atomically: true, encoding: .utf8)
        let args = ["gjs", "-m", path]
        var cargs = args.map { strdup($0) } + [nil]
        execvp("gjs", &cargs)
        print("cannot start gjs: \(String(cString: strerror(errno)))")
        throw ExitCode(1)
    }
}

/// Where the top-bar icon comes from: a login autostart entry (written by the root service), and, at the service's start,
/// the icon started in the desktop sessions already running for administrators (others cannot use it).
enum TrayLauncher {
    static let autostart = "/etc/xdg/autostart/mirage-tray.desktop"
    static var entry: String {
        """
        [Desktop Entry]
        Type=Application
        Name=Mirage
        Comment=Share this computer with Mirage
        Exec=\(LinuxUpdater.binary) tray
        NoDisplay=true
        X-GNOME-Autostart-enabled=true
        OnlyShowIn=GNOME;Unity;

        """
    }
    static func installAutostart(log: (String) -> Void) {
        guard (try? String(contentsOfFile: autostart, encoding: .utf8)) != entry else { return }
        do { try entry.write(toFile: autostart, atomically: true, encoding: .utf8); log("top-bar icon: \(autostart) written") }
        catch { log("top-bar icon: cannot write \(autostart): \(error)") }
    }

    /// Graphical sessions' users that are administrators, each once.
    static func adminSessionUsers() -> [String] {
        guard let list = run("/usr/bin/loginctl", ["list-sessions", "--no-legend"]) else { return [] }
        var users: [String] = []
        for line in list.split(separator: "\n") {
            guard let id = line.split(separator: " ").first.map(String.init),
                  let props = run("/usr/bin/loginctl", ["show-session", id, "-p", "Type", "-p", "Class", "-p", "Name", "-p", "Active"]) else { continue }
            var p: [String: String] = [:]
            for l in props.split(separator: "\n") { let kv = l.split(separator: "=", maxSplits: 1); if kv.count == 2 { p[String(kv[0])] = String(kv[1]) } }
            guard ["wayland", "x11"].contains(p["Type"] ?? ""), p["Class"] == "user", let name = p["Name"], !users.contains(name), isAdmin(name) else { continue }
            users.append(name)
        }
        return users
    }

    static func startInRunningSessions(log: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            for user in adminSessionUsers() {
                // Its own process in that user's session (the user's systemd manager has the desktop's environment). A second
                // copy only activates the first (one Gio application per session).
                _ = run("/usr/bin/systemd-run", ["--machine=\(user)@.host", "--user", "--collect", "--quiet", LinuxUpdater.binary, "tray"])
                log("top-bar icon: started for \(user)")
            }
        }
    }

    static func isAdmin(_ user: String) -> Bool {
        guard let pw = getpwnam(user) else { return false }
        if pw.pointee.pw_uid == 0 { return true }
        var count: Int32 = 64
        var groups = [gid_t](repeating: 0, count: Int(count))
        if getgrouplist(pw.pointee.pw_name, pw.pointee.pw_gid, &groups, &count) < 0 { return false }
        return groups.prefix(Int(max(count, 0))).contains { g in getgrgid(g).map { ["sudo", "admin", "wheel"].contains(String(cString: $0.pointee.gr_name)) } ?? false }
    }

    /// GNOME shows other apps' top-bar icons through the AppIndicator extension (on Ubuntu installed, though not always on).
    static func enableAppIndicators() {
        let ext = "ubuntu-appindicators@ubuntu.com"
        guard (ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"] ?? "").contains("GNOME"),
              let info = run("/usr/bin/gnome-extensions", ["info", ext]), !info.contains("State: ACTIVE") else { return }
        _ = run("/usr/bin/gnome-extensions", ["enable", ext])
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
    }
}
