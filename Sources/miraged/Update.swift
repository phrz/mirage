import Foundation
import ArgumentParser
import MirageCore
import MirageUpdater
import Network

extension UpdateChannel: ExpressibleByArgument {}

/// `miraged update` (DESIGN §3.10): the same updater the viewer's trigger runs in the host agent (U4).
struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check for, install or roll back a Mirage update (DESIGN §3.10).",
        discussion: """
            With no action: --check. --now installs the channel's newest build when it is newer than this one, restarts the \
            host agent onto it and waits until the new host commits (or rolls itself back). --rollback puts the kept \
            previous build back. --set key=value changes a setting: channel=stable|beta|nightly, policy=ask|automatic, \
            trigger=any-device|this-mac.
            """)

    @Option(help: "Read this channel instead of the configured one (switching channel never downgrades).") var channel: UpdateChannel?
    @Flag(help: "Say whether an update is available.") var check = false
    @Flag(help: "Install the newest build now.") var now = false
    @Flag(help: "Put the previous build back.") var rollback = false
    @Option(name: .customLong("set"), help: "Change a setting (key=value; repeatable).") var assignments: [String] = []
    @Option(help: "Another feed: a directory or URL holding channel-<name>/manifest.json (tests; it must still be signed).") var feed: String?
    @Option(help: ArgumentHelp("The installed bundle to update (default: the one this miraged runs from, else /Applications/Mirage.app).", visibility: .hidden)) var app: String?
    @Option(help: ArgumentHelp("Install only if the feed's newest is this build (what a remote trigger names).", visibility: .hidden)) var targetBuild: Int?
    @Flag(help: "Swap only: do not restart the host agent or wait for its commit.") var noRestart = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try Store()
        let appURL = app.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? InstallPaths.installedApp(support: store.root)
        let paths = InstallPaths(app: appURL, support: store.root)
        let running = Installer.version(of: paths.app) ?? .current
        let updater = Updater(paths: paths, feed: Feed(override: feed ?? ProcessInfo.processInfo.environment["MIRAGE_UPDATE_FEED"]),
                              running: running, report: { phase, msg in print("[\(phase.rawValue)] \(msg)") })

        if !assignments.isEmpty {
            var s = updater.settings()
            for a in assignments { try s.apply(a) }
            try s.save(paths.settings)
            print("channel \(s.channel.rawValue), policy \(s.policy.rawValue), trigger \(s.trigger.rawValue)")
            if !(check || now || rollback) { return }
        }
        let s = updater.settings()
        print("\(DeviceNames.current()): Mirage \(running.display) \(running.commit) (built for \(running.channelName)), following \(channel?.rawValue ?? s.channel.rawValue) at \(paths.app.path)")

        if rollback {
            let (from, to) = try updater.rollback()
            print("rolled back \(from?.display ?? "?") → \(to?.display ?? "?"); \(from?.display ?? "the replaced build") is skipped until a newer build appears")
            restartAgent(paths: paths)
            return
        }
        if now {
            do {
                switch try await updater.install(channel: channel, targetBuild: targetBuild) {
                case .nothing(let d):
                    print(d.message)
                case .swapped(let p):
                    try await afterSwap(p, paths: paths)
                }
            } catch {
                print("[failed] \(error)")
                throw ExitCode(1)
            }
            return
        }
        do {
            let c = try await updater.check(channel: channel)
            print(c.decision.message)
            if c.decision.isAvailable { print("install: miraged update --now\(channel.map { " --channel \($0.rawValue)" } ?? "")") }
        } catch {
            print("check failed: \(error)")
            throw ExitCode(1)
        }
    }

    /// The host agent restarts onto the new build, which commits once healthy; this waits for that (or its rollback).
    func afterSwap(_ p: PendingUpdate, paths: InstallPaths) async throws {
        let installer = Installer(paths: paths)
        guard !noRestart, agentProgram(inside: paths.app) else {
            // No agent runs from this bundle: nobody would start the new build to commit it, and its deadline would pass.
            installer.clearPending()
            try? installer.writeResult(UpdateResult(outcome: .installedUnchecked, from: p.from, to: p.to, at: Date(),
                                                    message: "installed without a health check: no host agent runs from \(paths.app.path)"))
            print("[done] installed \(p.from.display) → \(p.to.display); no host agent runs from \(paths.app.path), so no health check (verified and self-tested only)")
            return
        }
        print("[restarting] the host agent")
        restartAgent(paths: paths)
        let deadline = p.deadline.addingTimeInterval(30)
        while Date() < deadline {
            if let r = installer.readResult(), r.to.build == p.to.build {
                let secs = String(format: "%.1f", r.at.timeIntervalSince(p.started))
                switch r.outcome {
                case .committed, .installedUnchecked:
                    print("[done] update committed \(p.from.build) → \(p.to.build) (\(p.to.display)) in \(secs) s")
                    return
                case .rolledBack:
                    print("[rolledBack] \(p.to.display) rolled back after \(secs) s: \(r.message)")
                    for l in r.logTail ?? [] { print("    \(l)") }
                    throw ExitCode(2)
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        print("[failed] no commit or rollback by the deadline; see ~/Library/Logs/mirage-host.log")
        throw ExitCode(1)
    }

    /// Whether the login-item agent (com.paulherz.mirage.host) runs its program from inside `app`.
    func agentProgram(inside app: URL) -> Bool {
        let out = shell("/bin/launchctl", ["print", "gui/\(getuid())/\(launchdLabel)"])
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("program = ") { return String(t.dropFirst("program = ".count)).hasPrefix(app.path + "/") }
        }
        return false
    }

    func restartAgent(paths: InstallPaths) {
        guard agentProgram(inside: paths.app) else { print("no host agent runs from \(paths.app.path): start it to use the new build"); return }
        _ = shell("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(launchdLabel)"])
    }
}

/// `miraged --self-test` (DESIGN §3.10, verification step 5): loads, reads its stores without creating or changing
/// anything, binds no port, touches no window server, and prints its version for the updater to compare with the manifest.
func runSelfTest() throws {
    let v = MirageVersion.current
    let fm = FileManager.default
    var notes: [String] = []
    if let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
        let root = ProcessInfo.processInfo.environment["MIRAGE_TEST_STORE"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? base.appendingPathComponent("Mirage", isDirectory: true)
        let devices = root.appendingPathComponent("authorized-devices.json")
        if let d = try? Data(contentsOf: devices) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            guard let list = try? dec.decode([DeviceRecord].self, from: d) else {
                FileHandle.standardError.write(Data("self-test: authorized-devices.json does not decode\n".utf8)); throw ExitCode(1)
            }
            notes.append("\(list.count) paired devices")
        }
        let settings = UpdateSettings.load(root.appendingPathComponent("updates.json"))
        notes.append("channel \(settings.channel.rawValue)")
    }
    print("self-test ok: Mirage \(v.display) \(v.commit) \(v.channelName); protocol \(Mirage.minProtocolVersion)–\(Mirage.protocolVersion); \(notes.joined(separator: ", "))")
    print(SelfTest.line(v))
}

/// The host agent's feed checks (DESIGN §3.10): at start, then every 6 h, with jitter; skipped on a metered or constrained
/// uplink (the host's own). Checking only: installing is a trigger's (Ask) or the Automatic policy's (U6).
func scheduleUpdateChecks(paths: InstallPaths, log: @escaping @Sendable (String) -> Void) {
    Task.detached {
        try? await Task.sleep(for: .seconds(Double.random(in: 30...120)))
        while true {
            if await uplinkIsMetered() {
                log("update check skipped: metered or constrained network")
            } else {
                let updater = Updater(paths: paths, feed: Feed(override: ProcessInfo.processInfo.environment["MIRAGE_UPDATE_FEED"]),
                                      running: Installer.version(of: paths.app) ?? .current)
                do { log("update check: \(try await updater.check().decision.message)") }
                catch { log("update check failed: \(error)") }
            }
            try? await Task.sleep(for: .seconds(6 * 3600 + Double.random(in: -600...600)))
        }
    }
}

func uplinkIsMetered() async -> Bool {
    await withCheckedContinuation { c in
        let m = NWPathMonitor()
        let once = NSLock(); var done = false
        m.pathUpdateHandler = { path in
            once.lock(); defer { once.unlock() }
            guard !done else { return }
            done = true
            m.cancel()
            c.resume(returning: path.isExpensive || path.isConstrained)
        }
        m.start(queue: DispatchQueue(label: "mirage.update.path"))
    }
}
