import Foundation
import MirageCore

/// First install on a Mac (DESIGN §3.10, U5: scripts/install-host.sh). The script checks the downloaded bundle with the
/// system's own tools (digest, the pinned code requirement, Gatekeeper's notarization assessment) before it runs
/// anything from it; then the bundle's own miraged, now known to be genuine, verifies the manifest against the keys it
/// was built with and installs itself through this logic.
public enum FreshInstall {
    /// The manifest, verified with the compiled keys only (a new Mac has learned none), for this channel, and describing
    /// exactly this bundle.
    public static func verifyManifest(_ manifest: Data, signatures: Data, channel: UpdateChannel?, bundle: MirageVersion,
                                      trust: ManifestTrust = ManifestTrust(), now: Date = Date()) throws -> Manifest {
        let v: VerifiedManifest
        do { v = try ManifestVerifier.verify(manifest: manifest, signatures: signatures, trust: trust, channel: channel, now: now) }
        catch let e as ManifestError { throw UpdateError.manifest(e) }
        let m = v.manifest.mirageVersion
        guard m.version == bundle.version, m.build == bundle.build, m.commit == bundle.commit else {
            throw UpdateError.verification("the bundle is \(bundle.display) \(bundle.commit), the manifest says \(m.display) \(m.commit)")
        }
        return v.manifest
    }
}

/// What installing a verified bundle at /Applications/Mirage.app means here.
public enum InstallPlan: Equatable, Sendable {
    /// Nothing installed yet.
    case fresh
    /// An older build of the same identity: swapped in (the old one kept as the previous bundle).
    case replace(from: MirageVersion)
    /// This build or a newer one is installed: nothing to do (`--force` reinstalls).
    case current(MirageVersion)
    case refuse(String)

    public static func decide(installed: MirageVersion?, installedIdentity: SigningIdentity?, new: MirageVersion, newIdentity: SigningIdentity,
                              force: Bool, allowIdentityChange: Bool) -> InstallPlan {
        guard let installed else { return .fresh }
        if let id = installedIdentity, let change = SigningIdentity.change(from: id, to: newIdentity), !allowIdentityChange {
            return .refuse("\(change). The grants and the agent registration need a person at this Mac: run install-host.sh here with --allow-identity-change")
        }
        if installed.build >= new.build, !force {
            return .current(installed)
        }
        return .replace(from: installed)
    }

    public var description: String {
        switch self {
        case .fresh: return "install"
        case .replace(let f): return "replace \(f.display)"
        case .current(let v): return "already installed: \(v.display)"
        case .refuse(let why): return "refused: \(why)"
        }
    }
}

/// One line per host for scripts/fleet.sh (DESIGN §3.10):
/// `mac-daddy  0.4.0 (412) nightly  latest 420  agent running  streaming no  grants ok  policy ask  trigger any-device`.
public enum FleetStatus {
    public struct Grants: Equatable, Sendable {
        public var screenRecording: Bool?
        public var accessibility: Bool?
        public init(screenRecording: Bool?, accessibility: Bool?) { self.screenRecording = screenRecording; self.accessibility = accessibility }
    }

    public static func line(host: String, running: MirageVersion, settings: UpdateSettings, agent: AgentStatus,
                            streaming: [String]?, grants: Grants?) -> String {
        let latest: String
        if let l = settings.latest { latest = l.build > running.build ? "latest \(l.build)" : "latest \(l.build) (current)" }
        else { latest = settings.lastCheckError != nil ? "latest ? (check failed)" : "latest ?" }
        let agentText: String
        switch agent {
        case .running: agentText = "agent running"
        case .spawnFailed: agentText = "agent SPAWN FAILED"
        case .notLoaded: agentText = "agent not registered"
        case .notRunning: agentText = "agent not running"
        }
        let stream = streaming.map { $0.isEmpty ? "streaming no" : "streaming \($0.joined(separator: ","))" } ?? "streaming ?"
        let g: String
        if let grants, let s = grants.screenRecording, let a = grants.accessibility {
            g = s && a ? "grants ok" : "grants MISSING \([s ? nil : "screen", a ? nil : "accessibility"].compactMap { $0 }.joined(separator: "+"))"
        } else { g = "grants ?" }
        return [host, "\(running.display) \(running.channelName)", latest, agentText, stream, g,
                "policy \(settings.policy.rawValue)", "trigger \(settings.trigger.rawValue)"].joined(separator: "  ")
    }
}

/// Who may run an install (U5 review): the person logged in at the Mac, not root. The settings, the kept previous build
/// and the host agent (gui/<uid>) are that person's.
public enum InstallUser {
    public static func refusal(uid: uid_t, user: String, consoleUser: String?) -> String? {
        if uid == 0 { return "do not run this as root (sudo): run it as the person logged in at this Mac" }
        guard let c = consoleUser else { return "cannot tell who is logged in at this Mac" }
        if c == "root" || c.isEmpty { return "nobody is logged in at this Mac: a person must log in first (the host runs in their session)" }
        if c != user { return "this runs as \(user), but \(c) is logged in at this Mac: run it as \(c) (the settings and the host agent are theirs)" }
        return nil
    }

    /// The owner of /dev/console: who is logged in at the screen.
    public static func consoleUser() -> String? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, let pw = getpwuid(st.st_uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }
}

/// What the install needs from the host agent (tests: a stand-in).
public protocol InstallAgent: Sendable {
    /// The agent job is registered (for this app).
    var registered: Bool { get }
    /// Turn the host on (`--allow-connections`), or make sure the registered agent runs.
    func turnOn() -> String
    func ensureRunning() -> String
}

public struct SystemInstallAgent: InstallAgent {
    let control: AgentControl
    public init(app: URL, storeRoot: URL) { control = AgentControl(app: app, storeRoot: storeRoot) }
    public var registered: Bool { control.belongsToApp() }
    public func turnOn() -> String {
        let (v, how) = control.allowConnections()
        return "\(how); \(Self.describe(v))"
    }
    public func ensureRunning() -> String { Self.describe(control.ensureRunning(restart: false, log: { print($0) })) }
    public static func describe(_ v: AgentWatch.Verdict) -> String {
        switch v {
        case .started: return "host agent running"
        case .cannotSpawn(let why): return "host agent not running (\(why))"
        case .keepWaiting: return "host agent starting"
        }
    }
}

/// install-host.sh's summary lines (phrz, 2026-10-26: "dry run: nothing changed" landed on the settings line in his
/// terminal): each one ends with exactly one newline of its own and goes out in a single write, after whatever stdout
/// still buffers, so nothing else can land inside it or after it on the same line.
public enum InstallOutput {
    /// The bytes for one line: trailing newlines and carriage returns become one "\n".
    public static func line(_ s: String) -> Data {
        var t = Substring(s)
        while let last = t.last, last == "\n" || last == "\r" || last == "\r\n" { t = t.dropLast() }
        return Data((t + "\n").utf8)
    }

    public static func say(_ s: String, fd: Int32 = STDOUT_FILENO) {
        fflush(stdout)
        let data = line(s)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return }
                off += n
            }
        }
    }
}

/// install-host.sh's Swift half, after the manifest and the bundle are verified: decide, then install (fresh: one
/// rename; over an older build: the updater's own lock, pending update, swap, trial and commit), with the settings saved
/// only once the bundle is in place and nothing left staged on a failure.
public struct BundleInstaller {
    public var paths: InstallPaths
    public var agent: InstallAgent
    public var identityOf: (URL) -> SigningIdentity
    public var say: (String) -> Void

    public init(paths: InstallPaths, agent: InstallAgent, identityOf: @escaping (URL) -> SigningIdentity = { SigningIdentity.of(bundle: $0) },
                say: @escaping (String) -> Void = { InstallOutput.say($0) }) {
        self.paths = paths; self.agent = agent; self.identityOf = identityOf; self.say = say
    }

    public var staged: URL { paths.app.deletingLastPathComponent().appendingPathComponent(".Mirage-staged.app", isDirectory: true) }

    /// `afterSwap`: the updater's restart, trial and commit (or rollback), with the pending update and whether the signing
    /// identity changed.
    @discardableResult
    public func install(bundle: URL, version: MirageVersion, manifestChannel: UpdateChannel, assignments: [String], force: Bool, allowIdentityChange: Bool,
                        dryRun: Bool, now: Date = Date(), afterSwap: (PendingUpdate, Bool) async throws -> Void) async throws -> InstallPlan {
        let installer = Installer(paths: paths)
        let fd = try installer.lock()   // one update at a time, the updater's own lock
        defer { flock(fd, LOCK_UN); close(fd) }
        let installed = Installer.version(of: paths.app)
        if let p = installer.readPending(), let i = installed, p.to.build == i.build {
            throw UpdateError.refused("an update to \(p.to.display) is on trial on this Mac: wait a few minutes for it to commit, or roll it back (miraged update --rollback)")
        }
        let installedIdentity = installed != nil ? identityOf(paths.app) : nil
        let newIdentity = identityOf(bundle)
        let plan = InstallPlan.decide(installed: installed, installedIdentity: installedIdentity, new: version, newIdentity: newIdentity,
                                      force: force, allowIdentityChange: allowIdentityChange)
        say("plan: \(plan.description) → \(paths.app.path)")
        var settings = UpdateSettings.load(paths.settings)
        if !assignments.contains(where: { $0.lowercased().hasPrefix("channel") }) { try settings.apply("channel=\(manifestChannel.rawValue)") }
        for a in assignments { try settings.apply(a) }
        say("settings: channel \(settings.channel.rawValue), policy \(settings.policy.rawValue), trigger \(settings.trigger.rawValue)")
        if case .refuse(let why) = plan { throw UpdateError.refused(why) }
        if dryRun { say("dry run: nothing changed"); return plan }

        switch plan {
        case .current:
            try settings.save(paths.settings)
            say("nothing to install; \(agent.registered ? agent.ensureRunning() : agent.turnOn())")
            return plan
        case .refuse:
            return plan
        case .fresh, .replace:
            break
        }
        // Staged beside the app path (same volume), then one rename; nothing stays staged on a failure.
        try? FileManager.default.removeItem(at: staged)
        do {
            let copy = SystemBundleVerifier.run(URL(fileURLWithPath: "/usr/bin/ditto"), [bundle.path, staged.path], timeout: 300)
            guard copy.1 == 0 else { throw UpdateError.install("copying to \(staged.path): \(copy.0.trimmingCharacters(in: .whitespacesAndNewlines))") }
            switch plan {
            case .fresh:
                guard rename(staged.path, paths.app.path) == 0 else { throw UpdateError.install("installing \(paths.app.path): \(String(cString: strerror(errno)))") }
                try settings.save(paths.settings)
                say("installed \(version.display) at \(paths.app.path)")
                say("host: \(agent.turnOn())")
            case .replace(let from):
                // The updater's path: pending first, then the swap; the new build's start counts, commits or rolls back.
                let changed = installedIdentity.map { SigningIdentity.change(from: $0, to: newIdentity) != nil } ?? false
                let pending = PendingUpdate(from: from, to: version, deadline: now.addingTimeInterval(UpdateHealth.commitWindow), appPath: paths.app.path,
                                            started: now, reregistered: changed ? true : nil)
                try installer.writePending(pending)
                do { try installer.swapIn(staged) } catch { installer.clearPending(); throw error }
                try settings.save(paths.settings)
                say("replaced \(from.display) with \(version.display) (the old build is kept as the previous one)")
                try await afterSwap(pending, changed)
            case .current, .refuse:
                break
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return plan
    }
}
