import Foundation
import MirageCore

/// `pending-update.json` (DESIGN §3.10, atomic swap with rollback): written before the swap, deleted by the new host's
/// commit. Until then each start of the new build counts an attempt, and too many, or the deadline, roll it back.
public struct PendingUpdate: Codable, Equatable, Sendable {
    public var from: MirageVersion
    public var to: MirageVersion
    public var attempts: Int
    public var deadline: Date
    /// The installed bundle the swap replaced: only a host running from there acts on this file (a test copy elsewhere
    /// never rolls back the real app).
    public var appPath: String
    public var started: Date

    public init(from: MirageVersion, to: MirageVersion, attempts: Int = 0, deadline: Date, appPath: String, started: Date) {
        self.from = from; self.to = to; self.attempts = attempts; self.deadline = deadline; self.appPath = appPath; self.started = started
    }
}

/// How an update ended: `update-result.json`, read by `miraged update --now` (and, in U4, reported to the viewer that
/// triggered it).
public struct UpdateResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case committed, rolledBack, installedUnchecked }
    public var outcome: Outcome
    public var from: MirageVersion
    public var to: MirageVersion
    public var at: Date
    public var message: String
    /// The new build's last log lines, for a rollback.
    public var logTail: [String]?

    public init(outcome: Outcome, from: MirageVersion, to: MirageVersion, at: Date, message: String, logTail: [String]? = nil) {
        self.outcome = outcome; self.from = from; self.to = to; self.at = at; self.message = message; self.logTail = logTail
    }
}

/// The pending-update state machine as pure logic (DESIGN §3.10, commit and rollback).
public enum UpdateHealth {
    /// The start at which an uncommitted build has been started this many times rolls back instead of serving.
    public static let maxAttempts = 3
    /// How long a new build has to commit after the swap.
    public static let commitWindow: TimeInterval = 5 * 60

    public enum LaunchAction: Equatable, Sendable {
        /// No update in flight (or one for another copy of the app): start normally.
        case none
        /// The new build on trial: save this (attempts counted), start, and commit once healthy.
        case trial(PendingUpdate)
        /// Swap the previous bundle back and exit; launchd starts the old host.
        case rollBack(PendingUpdate, reason: String)
        /// The old build runs while the file is still there: the swap was undone outside the updater
        /// (`rollback-host.sh`) or a rollback stopped half way. Record it as rolled back.
        case rolledBackOutside(PendingUpdate)
        /// Neither build runs (a manual reinstall): the file is stale.
        case discard(PendingUpdate)
    }

    public static func onLaunch(_ pending: PendingUpdate?, running: MirageVersion, appPath: String, now: Date) -> LaunchAction {
        guard let p = pending else { return .none }
        guard standardized(p.appPath) == standardized(appPath) else { return .none }
        if running.build == p.to.build {
            var next = p
            next.attempts += 1
            if now >= p.deadline { return .rollBack(next, reason: "no commit within \(Int(commitWindow / 60)) min of the swap") }
            if next.attempts >= maxAttempts { return .rollBack(next, reason: "started \(next.attempts) times without becoming healthy") }
            return .trial(next)
        }
        if running.build == p.from.build { return .rolledBackOutside(p) }
        return .discard(p)
    }

    /// While the new build runs uncommitted: roll back once the deadline passes.
    public static func rollbackDue(_ pending: PendingUpdate, committed: Bool, now: Date) -> Bool {
        !committed && now >= pending.deadline
    }

    /// What a healthy host has shown (DESIGN §3.10): the QUIC listener is ready, the local control socket is up, and a
    /// capture probe returned a frame or said exactly which grant is missing.
    public struct Checks: Equatable, Sendable {
        public var listener = false
        public var control = false
        public var capture: String?
        public init() {}
        public var healthy: Bool { listener && control && capture != nil }
    }

    static func standardized(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
}

/// `miraged --self-test` (DESIGN §3.10, verification step 5): the staged binary loads, opens its stores read-only, binds no
/// port, and prints its version on one line, which must match the manifest.
public enum SelfTest {
    public static let prefix = "MIRAGE-SELF-TEST "
    public static let timeout: TimeInterval = 10

    /// The line the self-test prints.
    public static func line(_ v: MirageVersion) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return prefix + String(decoding: (try? e.encode(v)) ?? Data(), as: UTF8.self)
    }

    /// The version in a self-test's output: its last line with the prefix.
    public static func parse(_ output: String) -> MirageVersion? {
        for l in output.split(whereSeparator: \.isNewline).reversed() {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(prefix) else { continue }
            return try? JSONDecoder().decode(MirageVersion.self, from: Data(t.dropFirst(prefix.count).utf8))
        }
        return nil
    }

    /// The verdict on a run: nil = passed, else why not.
    public static func judge(output: String, exitCode: Int32?, timedOut: Bool, expected: MirageVersion) -> String? {
        if timedOut { return "the self-test did not finish within \(Int(timeout)) s" }
        guard let code = exitCode else { return "the self-test did not run" }
        if code != 0 { return "the self-test exited \(code)\(lastLine(output).map { ": \($0)" } ?? "")" }
        guard let v = parse(output) else { return "the self-test printed no version" }
        guard v.version == expected.version, v.build == expected.build, v.commit == expected.commit else {
            return "the bundle is \(v.display) \(v.commit), the manifest says \(expected.display) \(expected.commit)"
        }
        return nil
    }

    static func lastLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).last.map(String.init)
    }
}
