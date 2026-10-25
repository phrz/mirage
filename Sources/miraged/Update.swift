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
    @Flag(help: "Install even a build signed with another identity (Apple Development ↔ Developer ID): the agent is registered again, and a person must give the Screen Recording and Device Control (Accessibility) grants again.") var allowIdentityChange = false
    @Flag(help: ArgumentHelp("Print what a person must do at this Mac after a signing identity change (deploy-host.sh).", visibility: .hidden)) var grantSteps = false
    @Flag(help: ArgumentHelp("After the agent swapped in an update (a remote trigger): restart it onto the new build and watch it start, as --now does.", visibility: .hidden)) var supervise = false
    @Flag(help: "Restart the host agent and make sure it runs: if launchd refuses to start it (a launch constraint from another signature), register it again through Mirage.app (deploy and install scripts).") var ensureAgent = false

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

        if grantSteps { print(SigningIdentity.tccSteps()); return }
        if supervise {
            guard let p = Installer(paths: paths).readPending() else { print("supervise: no pending update"); return }
            print("supervising the update \(p.from.display) → \(p.to.display)")
            try await afterSwap(p, paths: paths, identityChanged: false)
            return
        }
        if ensureAgent {
            let agent = AgentControl(app: paths.app, storeRoot: paths.support)
            let v = agent.ensureRunning(restart: true, log: { print($0) })
            print("host agent: \(agent.status())")
            if case .cannotSpawn = v { throw ExitCode(1) }
            return
        }
        if rollback {
            let (from, to) = try updater.rollback()
            print("rolled back \(from?.display ?? "?") → \(to?.display ?? "?"); \(from?.display ?? "the replaced build") is skipped until a newer build appears")
            restartAgent(paths: paths)
            return
        }
        if now {
            do {
                switch try await updater.install(channel: channel, targetBuild: targetBuild, allowIdentityChange: allowIdentityChange) {
                case .nothing(let d):
                    print(d.message)
                case .swapped(let p, let change):
                    if let change { print("[installing] \(change): allowed (--allow-identity-change)") }
                    try await afterSwap(p, paths: paths, identityChanged: change != nil)
                    if change != nil { print(SigningIdentity.tccSteps()) }
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
    /// launchd may refuse to spawn the new build at all (a launch constraint from the old signature: "spawn failed",
    /// EX_CONFIG); it then never counts an attempt, so this process notices, registers the agent again through the app,
    /// and if it still cannot start, swaps the previous build back itself.
    func afterSwap(_ p: PendingUpdate, paths: InstallPaths, identityChanged: Bool) async throws {
        let installer = Installer(paths: paths)
        let agent = AgentControl(app: paths.app, storeRoot: paths.support)
        let kick = "launchctl kickstart -k gui/\(getuid())/\(HostAgent.label)"
        switch noRestart ? nil : agent.ownership() {
        case .ours?, .probablyOurs?:
            break
        case .notLoaded?:
            // The host is not turned on here (a viewer-only Mac): nothing to restart, nobody to commit it.
            installer.clearPending()
            try? installer.writeResult(UpdateResult(outcome: .installedUnchecked, from: p.from, to: p.to, at: Date(),
                                                    message: "installed without a health check: the host is not turned on on this Mac"))
            print("[installed] \(p.from.display) → \(p.to.display) at \(paths.app.path); the host is not turned on on this Mac (no agent registered), so there was no restart and no health check")
            return
        case .elsewhere(let program)?:
            // Never "done": the swap happened, and the agent that should restart into it is not this bundle's.
            print("[failed] swapped in \(p.to.display) at \(paths.app.path), but the host agent runs \(program), not this bundle: it was not restarted")
            print("         restart it onto the new build yourself: \(kick) (within \(Int(UpdateHealth.commitWindow / 60)) min, or the new build rolls back at its next start)")
            throw ExitCode(1)
        case nil:
            print("[installed] \(p.from.display) → \(p.to.display) swapped in (--no-restart). Restart the host onto it: \(kick)")
            return
        }
        if identityChanged {
            // launchd's constraint is the old identity's: register the agent for the new one straight away.
            print("[restarting] registering the host agent again for the new signing identity")
            let r = agent.reregister()
            print("[restarting] registration: \(AgentControl.describe(r))")
            if case .unreachable = r, var q = Installer(paths: paths).readPending() { q.reregistered = nil; try? Installer(paths: paths).writePending(q) }
        }
        print("[restarting] the host agent")
        agent.kickstart()
        let attempts = { installer.readPending()?.attempts ?? (installer.readResult()?.to.build == p.to.build ? 1 : 0) }
        if case .cannotSpawn(let why) = agent.watch(attempts: attempts) {
            print("[restarting] launchd cannot start \(p.to.display) (\(why)); registering the agent again through Mirage.app")
            // Marked first: the new build may start (and roll back) as soon as it is registered.
            if var q = installer.readPending() { q.reregistered = true; try? installer.writePending(q) }
            let r = agent.reregister()
            print("[restarting] registration: \(AgentControl.describe(r))")
            let done: Bool
            if case .done = r { done = true } else { done = false }
            if !done, var q = installer.readPending() { q.reregistered = nil; try? installer.writePending(q) }
            if case .cannotSpawn(let why2) = agent.watch(attempts: attempts) {
                try rollBackUnstartable(p, why: why2, paths: paths, agent: agent, reregistered: done)
            }
        }
        let deadline = p.deadline.addingTimeInterval(30)
        while Date() < deadline {
            if let r = installer.readResult(), r.to.build == p.to.build {
                let secs = String(format: "%.1f", r.at.timeIntervalSince(p.started))
                switch r.outcome {
                case .committed, .installedUnchecked:
                    print("[done] update committed \(p.from.build) → \(p.to.build) (\(p.to.display)) in \(secs) s")
                    return
                case .failed:
                    print("[failed] \(r.message)")
                    throw ExitCode(1)
                case .rolledBack:
                    print("[rolledBack] \(p.to.display) rolled back after \(secs) s: \(r.message)")
                    for l in r.logTail ?? [] { print("    \(l)") }
                    reportAgent(agent.ensureRunning(restart: false, log: { print("[rolledBack] \($0)") }), build: p.from)
                    throw ExitCode(2)
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        print("[failed] no commit or rollback by the deadline; see ~/Library/Logs/mirage-host.log")
        throw ExitCode(1)
    }

    /// The new build cannot be started even after registering again: the previous bundle goes back from here (the new
    /// build never ran, so it cannot roll itself back), is registered again too, and must start.
    func rollBackUnstartable(_ p: PendingUpdate, why: String, paths: InstallPaths, agent: AgentControl, reregistered: Bool) throws {
        let installer = Installer(paths: paths)
        print("[rolledBack] \(p.to.display) cannot be started by launchd (\(why)); putting \(p.from.display) back")
        do { try installer.rollBack(keepReplaced: false) }
        catch { print("[failed] rollback: \(error); scripts/rollback-host.sh is the last resort"); throw ExitCode(1) }
        try? installer.writeResult(UpdateResult(outcome: .rolledBack, from: p.from, to: p.to, at: Date(), message: "launchd cannot start it: \(why)"))
        var s = UpdateSettings.load(paths.settings)
        if !s.skippedBuilds.contains(p.to.build) { s.skippedBuilds.append(p.to.build); try? s.save(paths.settings) }
        installer.clearPending()
        // Registered for the new build's signature a moment ago: register the old one again before starting it.
        if reregistered { print("[rolledBack] registration: \(AgentControl.describe(agent.reregister()))") }
        reportAgent(agent.ensureRunning(restart: false, log: { print("[rolledBack] \($0)") }), build: p.from)
        throw ExitCode(2)
    }

    func reportAgent(_ v: AgentWatch.Verdict, build: MirageVersion) {
        switch v {
        case .started: print("[done] the host agent runs \(build.display)")
        case .cannotSpawn(let why): print("[failed] the host agent does not start (\(why)): launchctl print gui/$UID/\(HostAgent.label); scripts/rollback-host.sh")
        case .keepWaiting: break
        }
    }

    /// After `--rollback` (or a deploy): the agent running from this bundle, registered again if launchd refuses it.
    func restartAgent(paths: InstallPaths) {
        let agent = AgentControl(app: paths.app, storeRoot: paths.support)
        guard agent.belongsToApp() else {
            print("the host agent is not this bundle's (or not registered): restart it yourself: launchctl kickstart -k gui/\(getuid())/\(HostAgent.label)")
            return
        }
        reportAgent(agent.ensureRunning(restart: true, log: { print($0) }), build: Installer.version(of: paths.app) ?? .current)
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
