import AppKit
import Foundation
import ArgumentParser
import MirageCore
import MirageHost
import MirageUpdater
import Network

@main
struct Miraged: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "miraged",
        abstract: "Mirage host daemon: serves this Mac to paired devices over QUIC.",
        subcommands: [Serve.self, Pair.self, Devices.self, Revoke.self, Unlock.self, Install.self, Uninstall.self, ProbeLayers.self, Update.self],
        defaultSubcommand: Serve.self)
}

/// The host is invisible: no Dock tile, no activation, ever. miraged lives in Mirage.app/Contents/MacOS, so LaunchServices
/// files it under the app's bundle, whose Info.plist has no LSUIElement (the viewer goes accessory at run time); at its first
/// window-server contact it checked in as a Foreground app, a second "Mirage" in the Dock that could bounce (phrz,
/// 2026-10-23). Called first, before any ScreenCaptureKit, CoreGraphics or AppKit use; the binary (and its TCC grants) are
/// unchanged. Its one prompt, pairing, is the menu-bar app's (over the control socket). scripts/check-host-invisible.sh checks.
func stayInvisible() {
    _ = NSApplication.shared.setActivationPolicy(.prohibited)
}

/// Kept for the process's life: SIGTERM ends an open agent session before exiting (AgentSessions.endForShutdown).
nonisolated(unsafe) var terminationSource: DispatchSourceSignal?

func log(_ s: String) {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    FileHandle.standardError.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the host (foreground).")
    @Option(name: .shortAndLong, help: "UDP port to listen on.") var port: UInt16 = Mirage.defaultPort
    @Option(help: "Host name shown to clients (default: this Mac's computer name).") var name: String?
    @Option(help: "Append stdout and stderr to this file (~ expands): the app's login-item agent cannot name ~ in its plist.") var logFile: String?
    @Flag(help: "No local control socket and no permission watcher: a second, test instance beside the login-item agent (whose control.sock it would otherwise take over).") var noLocalControl = false
    @Flag(name: .customLong("self-test"), help: "Load, read the stores, print this build's version and exit (the updater runs it on a staged bundle).") var selfTest = false

    func run() async throws {
        // Before anything else, and with no window-server contact: the updater runs this on a bundle it has not installed.
        if selfTest { try runSelfTest(); return }
        stayInvisible()
        if let logFile {
            let path = (logFile as NSString).expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            freopen(path, "a", stdout); freopen(path, "a", stderr)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try Store()
        // Updates (DESIGN §3.10): a build on trial counts this start first, and rolls back (exits, so launchd starts the
        // previous build) after too many starts or past its deadline. A test instance leaves the real app's update alone.
        let paths = InstallPaths(app: InstallPaths.installedApp(support: store.root), support: store.root)
        let health = noLocalControl ? nil : HostHealth(paths: paths, logFile: logFile.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }, log: { log($0) })
        if let health, !health.launch() { Foundation.exit(0) }
        if Bundle.main.object(forInfoDictionaryKey: "MirageTestExitInMain") as? String == "YES" {
            log("deliberately broken build (MirageTestExitInMain, scripts/release.sh --broken): exiting in main")
            Foundation.exit(1)
        }
        let identity = try store.identity(role: "host", name: name ?? DeviceNames.current())
        let tls = try TLSIdentity.loadOrCreate(store: store)
        var ctx = HostContext(identity: identity, store: store, tlsFingerprint: tls.fingerprint, log: { log($0) },
                              makeStreamer: { MacDesktopStreamer(log: { log($0) }) })
        ctx.updateInfo = { hostUpdateInfo(paths: paths) }
        ctx.hostIcon = HostIconRenderer.make()   // its own icon (model and colour) for the device lists, once per start
        // A viewer's Welcome (a session's or a status probe's) refreshes a feed record older than 10 min (rate-limited),
        // so the next one shows a release minutes after it is out; a test instance does not check.
        if !noLocalControl { ctx.welcomed = { Task.detached { await checkFeed(paths: paths, reason: "a viewer asked", welcome: true, log: { log($0) }) } } }
        // The agent takes update triggers (U4) from paired viewers and this Mac's app, and runs the Automatic policy (U6);
        // a test instance does neither.
        if !noLocalControl {
            let handler = makeUpdateHandler(paths: paths, ctx: ctx, log: { log($0) })
            ctx.updateHandler = handler
            scheduleAutomaticUpdates(paths: paths, ctx: ctx, handler: handler, log: { log($0) })
        }
        let host = try QUICHost(port: port, tls: tls)
        host.log = { log($0) }
        log("mirage host build \(MirageVersion.current.display) \(MirageVersion.current.commit) (\(MirageVersion.current.channelName))")
        log("mirage host \(identity.name) id=\(identity.id.prefix(12)) tls=\(tls.fingerprint.prefix(6).map { String(format: "%02x", $0) }.joined()) devices=\(try store.authorizedDevices().count)")
        // TCC (DESIGN §3.7a): the host never raises a permission prompt by itself. It reads its grants without prompting,
        // stays up for pairing and probes without them, says so in its status, and asks the Mirage app to show its
        // permissions window, where the person's Allow makes the request (LocalControl.requestPermission).
        // MIRAGE_NO_PERMISSION_PROMPTS: a test instance (on a Mac whose grants belong to another binary).
        let prompts = ProcessInfo.processInfo.environment["MIRAGE_NO_PERMISSION_PROMPTS"] == nil
        // A test host (no permission prompts of its own) does not start while a system prompt is on screen: it may be this
        // binary's own consent prompt, which is a person's to answer, and it changes every picture measured.
        if !prompts, !WarmPool.systemPromptWindows().isEmpty {
            log("not starting: system prompt windows on screen \(WarmPool.systemPromptWindows()) (UserNotificationCenter); a person must answer them")
            throw ExitCode(3)
        }
        // Share This Mac (HostSettings): off, this agent only keeps Mirage up to date (HostRole); a change restarts it.
        let role = HostRole(settings: HostSettings.load(from: ctx.store.url(HostSettings.fileName)))
        ctx.sharing = { role.sharing }
        if role.warmCaptures { WarmPool.shared.start(log: { log($0) }) }   // warm host (M-FIVE): a display snapshot kept while nobody is connected
        let (screen, ax) = role.grantsAtStart()
        ctx.missingPermissions = { role.missingPermissions() }
        if role.sharing {
            log("permissions: screen recording \(screen ? "granted" : "MISSING (\(PrivacyPane.path(PrivacyPane.screenRecording)) → enable miraged)")"
                + ", accessibility \(ax ? "granted" : "MISSING (\(PrivacyPane.path(PrivacyPane.accessibility())) → enable miraged)")")
        } else {
            log("this Mac is not shared (Share This Mac off): only updates run; no streams, pairing, capture or permission requests")
        }
        // Unlock with biometry (DESIGN §3.13): the login-item host only; a test instance never types at the lock screen.
        // And only with the hardened runtime (a debugger could otherwise attach and read a password mid-typing). Not on a
        // Mac that is not shared: no unlock and no agent sessions there.
        if !noLocalControl, role.sharing {
            if LockScreenUnlocker.hardenedRuntime() {
                ctx.unlockHandler = { secret in
                    log("unlock: lock check: \(LockScreenUnlocker.StrictLock.describe())")
                    return await LockScreenUnlocker.unlock(secret)
                }
                let coordinator = ctx.unlockCoordinator
                LockScreenUnlocker.watchUnlocks { Task { await coordinator.macUnlocked() } }
                ctx.agentUnlocked = { who, anchor in AgentSessions.shared.begin(requester: who, anchor: anchor) }
                ctx.endAgentSession = { by in AgentSessions.shared.end(by: by) }
                let notices = ctx.agentSessionNotices
                AgentSessions.shared.start(store: store, log: { log($0) }, notify: { info in Task { await notices.set(info) } })
                // A clean stop (bootout, uninstall, an update's restart) ends an open agent session first.
                signal(SIGTERM, SIG_IGN)
                let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                term.setEventHandler { AgentSessions.shared.endForShutdown { Foundation.exit(0) } }
                term.resume()
                terminationSource = term
            } else {
                log("unlock with biometry: off (this miraged is not signed with the hardened runtime)")
            }
        }
        host.start(onStream: { conn, id, remote in
            Task { await HostSession.handle(connection: conn, connectionID: id, remote: remote, ctx: ctx) }
        }, onState: { state in
            switch state {
            case .ready: log("listening on udp/\(port)"); health?.passed(.listener)
            case .failed(let e): log("listener failed: \(e)"); Foundation.exit(1)
            default: break
            }
        })
        // The Mirage app on this Mac drives pairing through the local control socket (Pair a Device…, Allow / Deny).
        let control = LocalControlServer(ctx: ctx, port: port, log: { log($0) })
        if noLocalControl { log("test instance: no local control, no permission watcher") }
        // The curtain (DESIGN §3.12) is the login-item host's: a test instance never curtains (or locks) the Mac someone may be
        // using, unless a test asks for it.
        Curtain.allowed = role.curtain && (!noLocalControl || ProcessInfo.processInfo.environment["MIRAGE_TEST_CURTAIN"] == "1")
        Curtain.testInstance = noLocalControl
        if noLocalControl { log("test instance: curtain \(Curtain.allowed ? "on (MIRAGE_TEST_CURTAIN=1)" : "off")") }
        else {
            do { try control.start(); health?.passed(.control) } catch { log("local control unavailable: \(error)") }
            let underLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.paulherz.mirage.host" || getppid() == 1
            control.onShareChange = { on in
                guard underLaunchd else { log("restart miraged to \(on ? "share this Mac" : "stop sharing it")"); return }
                log("restarting to \(on ? "share this Mac" : "stop sharing it")")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { Foundation.exit(0) }
            }
            if role.stayReachable { StayReachable.shared.start(enabled: HostSettings.load(from: ctx.store.url(HostSettings.fileName)).stayReachable, log: { log($0) }) }
            if role.watchesPermissions {
                let store = ctx.store
                ctx.onShareAttempt = { reason in
                    let settings = HostSettings.load(from: store.url(HostSettings.fileName))
                    guard PermissionWindowRule.shouldShow(reason, settings: settings, missing: role.missingPermissions()) else { return }
                    showPermissionsWindow(control: control, reason: reason)
                }
                watchPermissions(screen: screen, ax: ax, control: control, role: role)
                if PermissionWindowRule.shouldShow(.startup, settings: HostSettings.load(from: ctx.store.url(HostSettings.fileName)), missing: role.missingPermissions()) {
                    showPermissionsWindow(control: control, reason: .startup)
                }
            }
            if let health, health.onTrial {
                if role.sharing { probeCaptureForHealth(screen: screen, ax: ax, health: health) }
                else { health.passed(.capture("not shared: no capture")) }   // a viewer-only Mac never captures
            }
            scheduleUpdateChecks(paths: paths, ctx: ctx, log: { log($0) })
        }
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
        _ = control
    }
}

/// Re-reads the grants without prompting: every 2 s while one is missing, every 10 s once both are there (a revocation
/// shows too). The Mirage app hears every change. When a grant arrives, a host run by launchd restarts itself once (exit;
/// KeepAlive brings it back) so every grant is in force, quietly (the app's window keeps its rows; phrz's grants on
/// mac-daddy took effect only after `launchctl kickstart`). A revoked grant asks the app to show its window again.
func watchPermissions(screen: Bool, ax: Bool, control: LocalControlServer, role: HostRole) {
    let underLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.paulherz.mirage.host" || getppid() == 1
    Task.detached {
        var s = screen, a = ax
        while true {
            try? await Task.sleep(for: .seconds(s && a ? 10 : 2))
            let s2 = HostPermissions.screenRecordingGrantedNow(), a2 = HostPermissions.accessibilityGranted()
            guard s2 != s || a2 != a else { continue }
            log("permissions now: screen recording \(s2 ? "granted" : "missing"), accessibility \(a2 ? "granted" : "missing")")
            let revoked = (s && !s2) || (a && !a2), arrived = (!s && s2) || (!a && a2)
            s = s2; a = a2
            control.broadcastStatus()
            if revoked, PermissionWindowRule.shouldShow(.revoked, settings: HostSettings.load(from: (try? Store())?.url(HostSettings.fileName) ?? URL(fileURLWithPath: "/nonexistent")), missing: role.missingPermissions()) {
                showPermissionsWindow(control: control, reason: .revoked)
            }
            if arrived, underLaunchd {
                log("restarting to apply the new permissions")
                control.announceRestart()
                try? await Task.sleep(for: .milliseconds(1500))
                exit(0)
            }
        }
    }
}

/// A grant is missing: the Mirage app shows its permissions window. With no app connected yet (a login, or just after
/// install-host.sh), it waits a little, then opens Mirage.app, which shows it; never a system prompt from here.
func showPermissionsWindow(control: LocalControlServer, reason: PermissionWindowRule.Reason) {
    Task.detached {
        for _ in 0..<10 {
            if control.askToShowPermissions(reason: PermissionWindowRule.message(reason)) { log("permissions: asked the Mirage app to show its window (\(reason))"); return }
            try? await Task.sleep(for: .seconds(1))
        }
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { log("permissions: no Mirage app around this host to show the window"); return }
        // At most once per boot (a KeepAlive crash loop, or an app quit on purpose, is not reopened again and again), and
        // without taking the foreground: the app brings its own window up.
        guard let store = try? Store(), PermissionAppOpen.mayOpen(store: store) else { log("permissions: Mirage.app was opened for this once since boot; not again"); return }
        log("permissions: opening \(app.path) to show its window")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--permissions"]
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: config)
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a one-time 6-digit code and wait for a device to pair.")
    @Option(help: "Seconds the code stays valid.") var timeout: Int = 120

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try Store()
        let code = PairingCode.generate()
        let pending = Store.PendingPairing(code: code, expiresAt: Date().addingTimeInterval(TimeInterval(timeout)))
        try store.setPendingPairing(pending)
        print("""

            Pairing code:  \(code.prefix(3)) \(code.suffix(3))

            On the other device:  mirage connect \(DeviceNames.current()) --pair \(code)
            Valid for \(timeout)s, one attempt. Waiting…
            """)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout) + 65)
        while Date() < deadline {
            // The host asks here before it authorizes the device (no menu-bar UI is involved in this path).
            if let q = try store.takePairingConfirmRequest(attemptID: pending.attemptID) {
                print("\n\(q.deviceName) wants to pair with this Mac (key \(q.deviceID.prefix(16))…). Allow? [y/N] ", terminator: "")
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

struct ProbeLayers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "probe-layers", abstract: "Measure per-window (layer) capture against windows whose title matches (default: the test bench).")
    @Option(help: "Title substring of the windows to capture.") var match: String = "Mirage Test Bench"
    @Option(help: "Seconds to capture.") var seconds: Int = 10
    @Option(help: "Stream pixels per window point.") var scale: Double = 1.0
    @Option(help: "Write the first window's last frame as PNG here.") var dump: String?
    @Option(help: "window (one stream per matched window), display (whole display), exclude (display minus the matched windows).") var mode: String = "window"
    func run() async throws {
        stayInvisible()
        // Never prompts (DESIGN §3.7a): without the grant, say so instead of asking ScreenCaptureKit.
        guard HostPermissions.mayCapture else {
            log("probe: this binary has no Screen Recording grant; allow it in Mirage's permissions window first"); throw ExitCode(2)
        }
        try await LayerProbe.run(match: match, seconds: seconds, scale: scale, dump: dump, mode: mode, log: { log($0) })
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List paired devices.")
    func run() throws {
        let store = try Store()
        let list = try store.authorizedDevices()
        if list.isEmpty { print("no paired devices"); return }
        let f = ISO8601DateFormatter()
        for d in list { print("\(d.id.prefix(12))  \(f.string(from: d.pairedAt))  \(d.name)") }
    }
}

struct Revoke: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a paired device by id prefix.")
    @Argument var idPrefix: String
    func run() throws {
        let removed = try Store().revoke(idPrefix: idPrefix)
        if removed.isEmpty { print("no device matches \(idPrefix)"); throw ExitCode(1) }
        for d in removed { print("revoked \(d.name) (\(d.id.prefix(12)))") }
    }
}

/// Unlock with biometry (DESIGN §3.13), for agents: asks phrz's connected viewers to approve unlocking this Mac. The
/// password never passes through here; the exit code says how it went (0 unlocked or not locked, 3 declined, 4 no viewer
/// connected, 5 no answer in time, 6 refused or still locked).
struct Unlock: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Ask a connected viewer to approve unlocking this Mac (for agents).",
        discussion: "An approved unlock opens an agent session: the curtain stays up while you work. Run `miraged unlock --extend` at least every 15 minutes while working, and `miraged unlock --done` when finished (then Lock When Finished applies).")
    @Option(help: "What the unlock is for, shown to the person (at most 120 characters).") var reason: String?
    @Flag(help: "The agent session is still in use (keeps it from ending after 15 idle minutes).") var extend = false
    @Flag(help: "The agent session is over.") var done = false
    func run() throws {
        let client = LocalControlClient(store: try Store())
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: UnlockLogic.RequestOutcome?
        nonisolated(unsafe) var open: Bool?
        client.onEvent = { e in
            if case .unlockOutcome(let o) = e { outcome = o; finished.signal() }
            if case .agentSession(let o) = e { open = o; finished.signal() }
        }
        client.onClose = { finished.signal() }
        try client.connect(client: "miraged unlock")
        if extend || done {
            try client.send(done ? .agentSessionDone : .agentSessionExtend)
            _ = finished.wait(timeout: .now() + 10)
            client.disconnect()
            guard let open else { print("no answer from the host"); throw ExitCode(5) }
            print(open ? (done ? "agent session ended" : "agent session extended") : "no agent session was open")
            return
        }
        guard let reason, !reason.isEmpty else { print("--reason is required"); throw ExitCode.validationFailure }
        let done = finished
        try client.send(.requestUnlock(reason: reason, requester: ""))
        print("asking connected viewers to approve: \(UnlockLogic.clean(reason))")
        _ = done.wait(timeout: .now() + 150)
        client.disconnect()
        guard let o = outcome else { print("no answer from the host (an older host, or it stopped)"); throw ExitCode(5) }
        print(o.rawValue)
        throw ExitCode(o.exitCode)
    }
}

let launchdLabel = "com.paulherz.mirage.host"
var plistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install a standalone LaunchAgent so the host runs at login (superseded by Mirage.app's \"Allow Connections to This Mac\"; same label, so use one or the other).")
    @Option(name: .shortAndLong) var port: UInt16 = Mirage.defaultPort
    func run() throws {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/mirage-host.log").path
        let plist: [String: Any] = [
            "Label": launchdLabel,
            "ProgramArguments": [exe, "serve", "--port", "\(port)"],
            "RunAtLoad": true, "KeepAlive": true,
            "StandardOutPath": logPath, "StandardErrorPath": logPath,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL)
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchdLabel)"])
        let out = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        print("installed \(plistURL.path) → \(exe)\n\(out)log: \(logPath)")
    }
}

struct Uninstall: ParsableCommand {
    func run() throws {
        print(shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchdLabel)"]))
        try? FileManager.default.removeItem(at: plistURL)
        print("removed \(plistURL.path)")
    }
}

func shell(_ tool: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
