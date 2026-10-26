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
        subcommands: [Serve.self, Pair.self, Devices.self, Revoke.self, Install.self, Uninstall.self, ProbeLayers.self, Update.self],
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
        // TCC: prompting registers this binary in System Settings → Privacy & Security so it can be ticked once.
        // MIRAGE_NO_PERMISSION_PROMPTS: check only (test runs on a Mac whose grants belong to another binary).
        let prompts = ProcessInfo.processInfo.environment["MIRAGE_NO_PERMISSION_PROMPTS"] == nil
        // A test host (no permission prompts of its own) does not start while a system prompt is on screen: it may be this
        // binary's own consent prompt, which is a person's to answer, and it changes every picture measured.
        if !prompts, !WarmPool.systemPromptWindows().isEmpty {
            log("not starting: system prompt windows on screen \(WarmPool.systemPromptWindows()) (UserNotificationCenter); a person must answer them")
            throw ExitCode(3)
        }
        WarmPool.shared.start(log: { log($0) })   // warm host (M-FIVE): a display snapshot kept while nobody is connected
        let screen = HostPermissions.screenRecordingGranted() || (prompts && HostPermissions.requestScreenRecording())
        let ax = HostPermissions.accessibilityGranted(prompt: prompts)
        log("permissions: screen recording \(screen ? "granted" : "MISSING (\(PrivacyPane.path(PrivacyPane.screenRecording)) → enable miraged)")"
            + ", accessibility \(ax ? "granted" : "MISSING (\(PrivacyPane.path(PrivacyPane.accessibility())) → enable miraged)")")
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
        else {
            do { try control.start(); health?.passed(.control) } catch { log("local control unavailable: \(error)") }
            if !(screen && ax) { watchPermissions(screen: screen, ax: ax, control: control) }
            if let health, health.onTrial { probeCaptureForHealth(screen: screen, ax: ax, health: health) }
            scheduleUpdateChecks(paths: paths, ctx: ctx, log: { log($0) })
        }
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
        _ = control
    }
}

/// While Screen Recording or Accessibility is missing, re-checks every 2 s (Accessibility is live; Screen Recording by a
/// ScreenCaptureKit probe). When a grant arrives, a host run by launchd restarts itself once (exit; KeepAlive brings it
/// back) so every grant is in force, and the Mirage app says "Restarting to apply permissions…" meanwhile. phrz's grants on
/// mac-daddy took effect only after `launchctl kickstart`. Never restarts periodically: each start asks for Screen
/// Recording, and a loop would keep prompting.
func watchPermissions(screen: Bool, ax: Bool, control: LocalControlServer) {
    let underLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.paulherz.mirage.host" || getppid() == 1
    Task.detached {
        var s = screen, a = ax
        while true {
            try? await Task.sleep(for: .seconds(2))
            let s2 = await HostPermissions.probeScreenRecording(), a2 = HostPermissions.accessibilityGranted(prompt: false)
            guard s2 != s || a2 != a else { continue }
            log("permissions now: screen recording \(s2 ? "granted" : "missing"), accessibility \(a2 ? "granted" : "missing")")
            s = s2; a = a2
            if underLaunchd {
                log("restarting to apply the new permissions")
                control.announceRestart()
                try? await Task.sleep(for: .milliseconds(1500))
                exit(0)
            } else if s && a { log("restart miraged to be sure they apply"); return }
        }
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
