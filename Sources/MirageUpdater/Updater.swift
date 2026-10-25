import Foundation
import MirageCore

/// The phases an update reports (DESIGN §3.10): `miraged update` prints them, and in U4 the host sends them to the viewer
/// that triggered it as `updateStatus`.
public enum UpdatePhase: String, Codable, Sendable {
    case checking, downloading, verifying, installing, restarting, done, failed, rolledBack
}

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

    public init(paths: InstallPaths, feed: Feed = Feed(), verifier: BundleVerifying = SystemBundleVerifier(),
                running: MirageVersion = .current, report: @escaping @Sendable (UpdatePhase, String) -> Void = { _, _ in }) {
        self.paths = paths; self.feed = feed; self.verifier = verifier; self.running = running; self.report = report
    }

    public var installer: Installer { Installer(paths: paths) }
    public func settings() -> UpdateSettings { UpdateSettings.load(paths.settings) }

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
        case swapped(PendingUpdate)
        /// Nothing to install, and why.
        case nothing(UpdateDecision)
    }

    /// Checks, then installs the channel's newest when it is an update. `targetBuild`: the build the trigger named, which
    /// must be the one the feed lists now (a viewer never names code, only a build the signed feed already offers).
    public func install(channel: UpdateChannel? = nil, targetBuild: Int? = nil, now: Date = Date()) async throws -> Outcome {
        let fd = try installer.lock()
        defer { flock(fd, LOCK_UN); close(fd) }
        report(.checking, "checking \(channel?.rawValue ?? settings().channel.rawValue)")
        let c = try await check(channel: channel, now: now)
        let m = c.manifest.manifest
        if let t = targetBuild, t != m.build { throw UpdateError.refused("the feed lists build \(m.build), not \(t)") }
        guard case .available(let from, let to) = c.decision else { return .nothing(c.decision) }

        report(.downloading, "downloading \(to.display) (\(m.zipSize / 1_000_000) MB)")
        let zip = try await installer.download(m, manifestURL: c.manifestURL)
        report(.verifying, "verifying \(to.display)")
        let staged: URL
        do {
            let app = try installer.extract(zip)
            try verifier.verify(app: app, expected: to)
            staged = try installer.stageOnAppVolume(app)
        } catch {
            try? FileManager.default.removeItem(at: paths.staging(m.build))
            throw error
        }

        report(.installing, "installing \(from.display) → \(to.display)")
        let pending = PendingUpdate(from: from, to: to, deadline: now.addingTimeInterval(UpdateHealth.commitWindow), appPath: paths.app.path, started: now)
        try installer.writePending(pending)
        try? FileManager.default.removeItem(at: paths.result)
        do { try installer.swapIn(staged) }
        catch { installer.clearPending(); throw error }
        try? FileManager.default.removeItem(at: paths.staging(m.build))
        return .swapped(pending)
    }

    /// `miraged update --rollback`: the previous bundle back in place; the replaced build becomes the previous one, and is
    /// skipped until a newer build appears.
    public func rollback() throws -> (from: MirageVersion?, to: MirageVersion?) {
        let fd = try installer.lock()
        defer { flock(fd, LOCK_UN); close(fd) }
        let replaced = Installer.version(of: paths.app)
        let restored = Installer.version(of: paths.previous)
        try installer.rollBack(keepReplaced: true)
        installer.clearPending()
        if let r = replaced {
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

    public init(paths: InstallPaths, running: MirageVersion = .current, logFile: URL?, log: @escaping @Sendable (String) -> Void,
                exitProcess: @escaping @Sendable () -> Void = { exit(0) }) {
        self.paths = paths; self.running = running; self.logFile = logFile; self.log = log; self.exitProcess = exitProcess
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

    public enum Check: Sendable { case listener, control, capture(String) }

    /// One health check passed; the last one commits.
    public func passed(_ c: Check) {
        lock.lock()
        switch c {
        case .listener: checks.listener = true
        case .control: checks.control = true
        case .capture(let detail): checks.capture = detail
        }
        let commit = checks.healthy && !committed && pending != nil
        if commit { committed = true }
        let p = pending
        lock.unlock()
        if commit, let p {
            let secs = Date().timeIntervalSince(p.started)
            log("update committed \(p.from.build) → \(p.to.build) (\(p.from.display) → \(p.to.display), \(String(format: "%.1f", secs)) s after the swap; capture: \(checks.capture ?? ""))")
            finish(p, outcome: .committed, message: "committed \(String(format: "%.1f", secs)) s after the swap", skip: false)
        }
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
        log("update \(p.from.display) → \(p.to.display) failed: \(reason); rolling back")
        do { try installer.rollBack(keepReplaced: false) }
        catch { log("rollback failed: \(error); scripts/rollback-host.sh is the last resort") }
        finish(p, outcome: .rolledBack, message: reason, skip: true)
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
