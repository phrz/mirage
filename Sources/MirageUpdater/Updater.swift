import Foundation
import MirageCore

/// The one updater (DESIGN §3.10): `miraged update` over SSH and the viewer's trigger in the host agent run this, so both
/// share a code path. It checks the feed, verifies, stages, writes pending-update.json and swaps; restarting the host
/// (exit under launchd, or `launchctl kickstart` from a terminal) is the caller's, and committing is the new host's
/// (`HostHealth`).
public final class Updater: @unchecked Sendable {
    public let paths: InstallPaths
    public let feed: Feed
    public let verifier: BundleVerifying
    public let running: MirageVersion
    public var report: @Sendable (UpdatePhase, String) -> Void
    /// The build being installed, as soon as the feed names it (before the download): progress says "updating to …".
    public var learnedTarget: @Sendable (MirageVersion) -> Void = { _ in }

    /// A bundle's signing identity (tests: a stand-in).
    public let identityOf: @Sendable (URL) -> SigningIdentity

    public init(paths: InstallPaths, feed: Feed = Feed(), verifier: BundleVerifying = SystemBundleVerifier(),
                running: MirageVersion = .current, report: @escaping @Sendable (UpdatePhase, String) -> Void = { _, _ in },
                identityOf: @escaping @Sendable (URL) -> SigningIdentity = { SigningIdentity.of(bundle: $0) }) {
        self.paths = paths; self.feed = feed; self.verifier = verifier; self.running = running; self.report = report
        self.identityOf = identityOf
    }

    /// The installed build's signing identity: the one recorded at its commit, else read from the bundle.
    public func runningIdentity() -> SigningIdentity {
        if let r = settings().identity, r.build == running.build { return r }
        return identityOf(paths.app)
    }

    public var installer: Installer { Installer(paths: paths) }
    public func settings() -> UpdateSettings { UpdateSettings.load(paths.settings) }

    /// What the Welcome says about updates: the newest build found, the trigger permission, and the last update's
    /// outcome when it ended within `recent` (so the viewer that triggered it hears how it ended after the restart).
    public static func hostUpdateInfo(paths: InstallPaths, running: MirageVersion = .current, now: Date = Date(), recent: TimeInterval = 15 * 60) -> HostUpdateInfo {
        var info = UpdateSettings.load(paths.settings).hostUpdateInfo
        let installer = Installer(paths: paths)
        if let p = installer.readPending(), p.to.build == running.build {
            // On trial: the viewer that triggered it waits for the commit.
            info.lastResult = .init(phase: .trial, message: "start \(p.attempts), not yet healthy" + (p.waitingFor.map { ": waiting for \($0)" } ?? ""),
                                    from: p.from, to: p.to, at: p.started)
        } else if let r = installer.readResult() {
            let age = now.timeIntervalSince(r.at)
            if age >= 0, age < recent {   // a clock moved backwards makes the record stale, not fresh
                let phase: UpdatePhase = switch r.outcome {
                case .rolledBack: .rolledBack
                case .failed: .failed
                case .committed, .installedUnchecked: .done
                }
                info.lastResult = .init(phase: phase, message: r.message, from: r.from, to: r.to, at: r.at)
            }
        }
        return info
    }

    public struct Check: Sendable {
        public var decision: UpdateDecision
        public var manifest: VerifiedManifest
        public var manifestURL: URL
        public var channel: UpdateChannel
    }

    /// Reads and verifies the channel head, records what it found (the newest build, a newly introduced key) in
    /// updates.json, and decides. `channel` nil: the configured one.
    public func check(channel: UpdateChannel? = nil, now: Date = Date()) async throws -> Check {
        var s = settings()
        let ch = channel ?? s.channel
        do {
            let (v, url) = try await feed.check(ch, trust: s.trust, now: now)
            if let k = v.newKey, !s.learnedKeys.contains(k) { s.learnedKeys.append(k) }
            if ch == s.channel { s.latest = v.manifest.mirageVersion; s.lastCheck = now; s.lastCheckError = nil }
            try? s.save(paths.settings)
            let d = UpdateDecision.decide(running: running, manifest: v.manifest, channel: ch, skipped: s.skippedBuilds)
            return Check(decision: d, manifest: v, manifestURL: url, channel: ch)
        } catch {
            if ch == s.channel { s.lastCheck = now; s.lastCheckError = "\(error)"; try? s.save(paths.settings) }
            if let e = error as? ManifestError { throw UpdateError.manifest(e) }
            if let e = error as? UpdateError { throw e }
            throw UpdateError.feed("\(error)")
        }
    }

    public enum Outcome: Sendable {
        /// Swapped in; pending-update.json is written. The host must restart onto the new build, which commits.
        /// `identityChange`: it is signed differently (allowed explicitly): the agent must be registered again, and the
        /// grants given again by a person.
        case swapped(PendingUpdate, identityChange: String?)
        /// Nothing to install, and why.
        case nothing(UpdateDecision)
    }

    /// Checks (a fresh read of the feed, never the recorded one), then installs the channel's newest when it is an update.
    /// `targetBuild`: at least this build (what a trigger named): the newest verified build at or above it installs; an
    /// older newest is `notPublished`. A viewer never names code, only a build the signed feed offers.
    /// `gate`: asked again right before the swap (the download can take minutes); a reason defers the update (nothing
    /// replaced, the staging removed: `UpdateError.deferred`).
    public func install(channel: UpdateChannel? = nil, targetBuild: Int? = nil, allowIdentityChange: Bool = false, now: Date = Date(),
                        gate: (@Sendable () async -> String?)? = nil) async throws -> Outcome {
        let fd = try installer.lock()
        defer { flock(fd, LOCK_UN); close(fd) }
        report(.checking, "checking \(channel?.rawValue ?? settings().channel.rawValue)")
        let c = try await check(channel: channel, now: now)
        let m = c.manifest.manifest
        if let t = targetBuild, m.build < t { throw UpdateError.notPublished(build: t, newest: m.build, channel: c.channel) }
        guard case .available(let from, let to) = c.decision else { return .nothing(c.decision) }
        learnedTarget(to)

        report(.downloading, "downloading \(to.display) (\(m.zipSize / 1_000_000) MB)")
        let zip = try await installer.download(m, manifestURL: c.manifestURL)
        report(.verifying, "verifying \(to.display)")
        let staged: URL
        var change: String?
        do {
            let app = try installer.extract(zip)
            try verifier.verify(app: app, expected: to)
            // A different signing identity costs the TCC grants and the agent's registration: never by surprise.
            change = SigningIdentity.change(from: runningIdentity(), to: identityOf(app))
            if let change, !allowIdentityChange { throw UpdateError.refused(SigningIdentity.refusal(change)) }
            if let gate, let why = await gate() { throw UpdateError.deferred(why) }
            staged = try installer.stageOnAppVolume(app)
        } catch {
            try? FileManager.default.removeItem(at: paths.staging(m.build))
            throw error
        }

        report(.installing, "installing \(from.display) → \(to.display)")
        let pending = PendingUpdate(from: from, to: to, deadline: now.addingTimeInterval(UpdateHealth.commitWindow), appPath: paths.app.path, started: now,
                                    reregistered: change != nil ? true : nil)
        try installer.writePending(pending)
        try? FileManager.default.removeItem(at: paths.result)
        do { try installer.swapIn(staged) }
        catch { installer.clearPending(); throw error }
        try? FileManager.default.removeItem(at: paths.staging(m.build))
        return .swapped(pending, identityChange: change)
    }

    /// `miraged update --rollback`: the previous bundle back in place; the replaced build becomes the previous one, and is
    /// skipped until a newer build appears.
    /// `skipReplaced`: a person's rollback (the CLI) skips the replaced build until a newer one; a viewer's does not.
    public func rollback(skipReplaced: Bool = true) throws -> (from: MirageVersion?, to: MirageVersion?) {
        let fd = try installer.lock()
        defer { flock(fd, LOCK_UN); close(fd) }
        let replaced = Installer.version(of: paths.app)
        let restored = Installer.version(of: paths.previous)
        try installer.rollBack(keepReplaced: true)
        installer.clearPending()
        if skipReplaced, let r = replaced {
            var s = settings()
            if !s.skippedBuilds.contains(r.build) { s.skippedBuilds.append(r.build); try? s.save(paths.settings) }
        }
        return (replaced, restored)
    }
}

/// The host side of commit and rollback (DESIGN §3.10): `miraged serve` calls `launch()` first, then marks each health
/// check as it passes; once all pass it commits, and at the deadline without that it rolls back.
public final class HostHealth: @unchecked Sendable {
    public let paths: InstallPaths
    public let running: MirageVersion
    let log: @Sendable (String) -> Void
    let logFile: URL?
    /// What a rollback at the deadline does after the swap: exit, so launchd starts the previous build (tests: record it).
    let exitProcess: @Sendable () -> Void
    private let lock = NSLock()
    private var checks = UpdateHealth.Checks()
    private var pending: PendingUpdate?
    private var committed = false
    /// Set before a rollback touches anything: nothing rewrites pending-update.json after it.
    private var rollingBack = false

    /// Asks the app to register the agent again (tests: a stand-in).
    let reregisterAgent: @Sendable () -> HostAgent.Registration?

    public init(paths: InstallPaths, running: MirageVersion = .current, logFile: URL?, log: @escaping @Sendable (String) -> Void,
                exitProcess: @escaping @Sendable () -> Void = { exit(0) },
                reregisterAgent: (@Sendable () -> HostAgent.Registration?)? = nil) {
        self.paths = paths; self.running = running; self.logFile = logFile; self.log = log; self.exitProcess = exitProcess
        self.reregisterAgent = reregisterAgent ?? {
            if case .done(let r) = AgentControl(app: paths.app, storeRoot: paths.support).reregister() { return r }
            return nil
        }
    }

    var installer: Installer { Installer(paths: paths) }

    /// A new build on trial: its health checks decide whether it stays.
    public var onTrial: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil && !committed }

    /// What to do at start. Returns false when this process must exit now (it rolled back: launchd starts the old host).
    public func launch(now: Date = Date()) -> Bool {
        let action = UpdateHealth.onLaunch(installer.readPending(), running: running, appPath: paths.app.path, now: now)
        switch action {
        case .none: return true
        case .trial(let p):
            try? installer.writePending(p)
            lock.lock(); pending = p; lock.unlock()
            log("update \(p.from.display) → \(p.to.display): start \(p.attempts) of at most \(UpdateHealth.maxAttempts - 1), commit by \(ISO8601DateFormatter().string(from: p.deadline))")
            scheduleDeadline(p)
            return true
        case .rollBack(let p, let reason):
            rollBack(p, reason: reason)
            return false
        case .rolledBackOutside(let p):
            log("update \(p.from.display) → \(p.to.display) was undone outside the updater; \(p.to.display) is skipped")
            finish(p, outcome: .rolledBack, message: "undone outside the updater (rollback-host.sh)", skip: true)
            return true
        case .discard(let p):
            log("discarding a stale pending update \(p.from.display) → \(p.to.display) (this is \(running.display))")
            installer.clearPending()
            return true
        }
    }

    /// `captureDeferred`: every display asleep; the capture probe runs at the next wake (`capturedAfterWake`).
    public enum Check: Sendable { case listener, control, capture(String), captureDeferred(String) }

    /// One health check passed; the last one commits.
    public func passed(_ c: Check) {
        lock.lock()
        switch c {
        case .listener: checks.listener = true
        case .control: checks.control = true
        case .capture(let detail): checks.capture = detail
        case .captureDeferred(let why): checks.captureDeferred = why
        }
        let commit = checks.healthy && !committed && pending != nil
        if commit { committed = true }
        let p = pending
        lock.unlock()
        if commit, let p {
            let secs = Date().timeIntervalSince(p.started)
            let capture = checks.capture ?? "check deferred: \(checks.captureDeferred ?? "")"
            log("update committed \(p.from.build) → \(p.to.build) (\(p.from.display) → \(p.to.display), \(String(format: "%.1f", secs)) s after the swap; capture: \(capture))")
            // A grant the probe found missing is said in the record: the viewer asks for it at the Mac.
            let note = checks.capture.map { $0.hasPrefix("frame") ? "" : "; \($0)" } ?? "; capture check deferred: \(checks.captureDeferred ?? "")"
            finish(p, outcome: .committed, message: "committed \(String(format: "%.1f", secs)) s after the swap" + note, skip: false)
            var s = UpdateSettings.load(paths.settings)
            s.identity = SigningIdentity.of(bundle: paths.app)
            try? s.save(paths.settings)
        }
    }

    /// A check still failing on trial: said in the trial status (the viewer that triggered the update shows it).
    /// Under the lock, and only while on trial (not committed, not rolling back): a rollback in between must not find the
    /// file written again (the next start would report it "undone outside the updater").
    public func waiting(for why: String) {
        lock.lock(); defer { lock.unlock() }
        guard var p = pending, !committed, !rollingBack, var onDisk = installer.readPending(), onDisk.to.build == p.to.build,
              onDisk.waitingFor != why else { return }
        onDisk.waitingFor = why; p.waitingFor = why
        try? installer.writePending(onDisk)
        pending = p
    }

    /// The deferred capture probe ran (the display woke, or a session started): its result goes into the update's record,
    /// which the Welcome reports. A committed build is never rolled back for it.
    /// A failure moves the record's time to now: the Welcome reports it (records show for 15 min from their time), and a
    /// paired viewer may roll the build back for the next 5 min, as right after a commit.
    public func capturedAfterWake(_ detail: String, ok: Bool, now: Date = Date()) {
        log("update health: capture check after wake \(ok ? "passed" : "FAILED"): \(detail)")
        let installer = self.installer
        guard var r = installer.readResult(), r.outcome == .committed, r.to.build == running.build else { return }
        r.message += ok ? "; capture after wake: \(detail)" : "; capture FAILED after wake: \(detail)"
        if !ok { r.at = now }
        try? installer.writeResult(r)
    }

    func scheduleDeadline(_ p: PendingUpdate) {
        let delay = max(0, p.deadline.timeIntervalSinceNow)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            checkDeadline(p, now: Date())
        }
    }

    /// At the deadline: roll back unless committed (or the update is no longer this one's).
    func checkDeadline(_ p: PendingUpdate, now: Date) {
        lock.lock(); let due = UpdateHealth.rollbackDue(p, committed: committed, now: now); let c = checks; lock.unlock()
        guard due, installer.readPending()?.to.build == p.to.build else { return }
        rollBack(p, reason: "not healthy within \(Int(UpdateHealth.commitWindow / 60)) min (listener \(c.listener), control \(c.control), capture \(c.capture ?? "no report"))")
        exitProcess()
    }

    /// Swaps the previous bundle back, records why with this build's last log lines, skips this build, and leaves the exit
    /// to the caller.
    func rollBack(_ p: PendingUpdate, reason: String) {
        lock.lock(); rollingBack = true; lock.unlock()
        log("update \(p.from.display) → \(p.to.display) failed: \(reason); rolling back")
        do { try installer.rollBack(keepReplaced: false) }
        catch { log("rollback failed: \(error); scripts/rollback-host.sh is the last resort") }
        finish(p, outcome: .rolledBack, message: reason, skip: true)
        // The agent was registered for this build's signature: register it again for the old build's, or launchd refuses
        // to spawn that one ("Launch Constraint Violation"). Unregistering ends this process; registering starts the old.
        if p.reregistered == true {
            log("registering the host agent again for \(p.from.display)")
            let r = reregisterAgent()
            log("registration: \(r.map { "\($0.status)\($0.error.map { ", \($0)" } ?? "")" } ?? "not done: \(AgentControl.openOnce)")")
        }
    }

    func finish(_ p: PendingUpdate, outcome: UpdateResult.Outcome, message: String, skip: Bool) {
        let tail = outcome == .rolledBack ? logFile.flatMap { Self.tail($0, lines: 20) } : nil
        try? installer.writeResult(UpdateResult(outcome: outcome, from: p.from, to: p.to, at: Date(), message: message, logTail: tail))
        if skip {
            var s = UpdateSettings.load(paths.settings)
            if !s.skippedBuilds.contains(p.to.build) { s.skippedBuilds.append(p.to.build); try? s.save(paths.settings) }
        }
        installer.clearPending()
    }

    static func tail(_ url: URL, lines: Int) -> [String]? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        return Array(text.split(whereSeparator: \.isNewline).suffix(lines).map(String.init))
    }
}
