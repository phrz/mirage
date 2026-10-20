import Foundation
import ArgumentParser
import MirageCore
import MirageHost
import Network

@main
struct Miraged: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "miraged",
        abstract: "Mirage host daemon: serves this Mac to paired devices over QUIC.",
        subcommands: [Serve.self, Pair.self, Devices.self, Revoke.self, Install.self, Uninstall.self, ProbeLayers.self],
        defaultSubcommand: Serve.self)
}

func log(_ s: String) {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    FileHandle.standardError.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the host (foreground).")
    @Option(name: .shortAndLong, help: "UDP port to listen on.") var port: UInt16 = Mirage.defaultPort
    @Option(help: "Host name shown to clients (default: this Mac's computer name).") var name: String?
    @Flag(help: "No menu-bar item (pairing then only through `miraged pair`).") var noMenu = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try Store()
        let identity = try store.identity(role: "host", name: name ?? DeviceNames.current())
        let tls = try TLSIdentity.loadOrCreate(store: store)
        let ctx = HostContext(identity: identity, store: store, tlsFingerprint: tls.fingerprint, log: { log($0) },
                              makeStreamer: { MacDesktopStreamer(log: { log($0) }) })
        let host = try QUICHost(port: port, tls: tls)
        log("mirage host \(identity.name) id=\(identity.id.prefix(12)) tls=\(tls.fingerprint.prefix(6).map { String(format: "%02x", $0) }.joined()) devices=\(try store.authorizedDevices().count)")
        // TCC: prompting registers this binary in System Settings → Privacy & Security so it can be ticked once.
        let quiet = ProcessInfo.processInfo.environment["MIRAGE_TEST_OPEN_PAIRING"] != nil   // a UI test run: no permission prompts
        let screen = HostPermissions.screenRecordingGranted() || (!quiet && HostPermissions.requestScreenRecording())
        let ax = HostPermissions.accessibilityGranted(prompt: !quiet)
        log("permissions: screen recording \(screen ? "granted" : "MISSING (System Settings → Privacy & Security → Screen & System Audio Recording → enable miraged)")"
            + ", accessibility \(ax ? "granted" : "MISSING (System Settings → Privacy & Security → Accessibility → enable miraged)")")
        host.start(onStream: { conn, id, remote in
            Task { await HostSession.handle(connection: conn, connectionID: id, remote: remote, ctx: ctx) }
        }, onState: { state in
            switch state {
            case .ready: log("listening on udp/\(port)")
            case .failed(let e): log("listener failed: \(e)"); Foundation.exit(1)
            default: break
            }
        })
        if noMenu || ProcessInfo.processInfo.environment["MIRAGE_NO_MENU"] != nil {
            try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
        } else {
            // The menu-bar item ("Pair a Device…"): the main thread runs AppKit from here on; the host itself runs on its own queues.
            await MainActor.run { HostMenu.run(ctx: ctx, port: port, log: { log($0) }) }
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
    static let configuration = CommandConfiguration(abstract: "Install a LaunchAgent so the host runs at login.")
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
