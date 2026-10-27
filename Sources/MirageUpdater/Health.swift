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
    /// The agent was registered again for the new build's signature (launchd refused to spawn it under the old one): a
    /// rollback must register it again for the old build's, or launchd refuses that one in turn.
    public var reregistered: Bool?
    /// Starts of the replaced build after the swap (the old binary restarted before the new one ran): each exits so launchd
    /// starts the installed one.
    public var oldBuildStarts: Int?
    /// The old build kept running past the cap: the new build's next start begins a fresh trial (attempts and deadline
    /// from then), so it is still checked, committed or rolled back.
    public var freshTrial: Bool?
    /// What the trial still waits for ("a screen capture: …"), for the viewer that triggered it.
    public var waitingFor: String?

    public init(from: MirageVersion, to: MirageVersion, attempts: Int = 0, deadline: Date, appPath: String, started: Date, reregistered: Bool? = nil) {
        self.from = from; self.to = to; self.attempts = attempts; self.deadline = deadline; self.appPath = appPath; self.started = started
        self.reregistered = reregistered
    }
}

/// How an update ended: `update-result.json`, read by `miraged update --now` (and, in U4, reported to the viewer that
/// triggered it).
public struct UpdateResult: Codable, Equatable, Sendable {
    /// failed: a triggered update that stopped before the swap (feed, download, verification); `to` is then the build it
    /// was asked for, as far as known.
    public enum Outcome: String, Codable, Sendable { case committed, rolledBack, installedUnchecked, failed }
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

/// Whether a paired viewer may roll the host back (U4 review): only while an update it might regret is fresh (the new
/// build on trial, or committed within the health window), and only to a previous build of the same signing identity.
/// Anything else (an older build, another identity, losing grants and the launch constraint) needs a person at the Mac.
public enum RemoteRollback {
    public static let personNeeded = "rollback needs a person at the Mac: miraged update --rollback"

    public static func refusal(pending: PendingUpdate?, lastResult: UpdateResult?, running: MirageVersion, now: Date,
                               identityChange: String?) -> String? {
        let onTrial = pending.map { $0.to.build == running.build && now < $0.deadline } ?? false
        let justCommitted = lastResult.map { r in
            let age = now.timeIntervalSince(r.at)
            return r.outcome == .committed && r.to.build == running.build && age >= 0 && age < UpdateHealth.commitWindow
        } ?? false
        guard onTrial || justCommitted else { return "\(personNeeded) (no update in its health window)" }
        if let identityChange { return "\(personNeeded) (\(identityChange))" }
        return nil
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
        /// The old build runs, but the installed bundle IS the new one (phrz-mbp-m4, 2026-10-27: a CLI `update --now` raced
        /// the agent, and the old binary restarted after the swap). A successful update: exit, so launchd starts the
        /// installed build, which counts its trial and commits. Never skipped.
        case restartIntoInstalled(PendingUpdate)
        /// Neither build runs (a manual reinstall): the file is stale.
        case discard(PendingUpdate)
    }

    /// How many times the replaced build may start after the swap before the update is left alone (no loop).
    public static let maxOldBuildStarts = 3

    public static func onLaunch(_ pending: PendingUpdate?, running: MirageVersion, appPath: String, now: Date, installed: MirageVersion? = nil) -> LaunchAction {
        guard let p = pending else { return .none }
        guard standardized(p.appPath) == standardized(appPath) else { return .none }
        if running.build == p.to.build {
            var next = p
            if p.freshTrial == true {
                next.freshTrial = nil; next.attempts = 0
                next.deadline = now.addingTimeInterval(commitWindow)
            }
            next.attempts += 1
            if now >= next.deadline { return .rollBack(next, reason: "no commit within \(Int(commitWindow / 60)) min of the swap") }
            if next.attempts >= maxAttempts { return .rollBack(next, reason: "started \(next.attempts) times without becoming healthy") }
            return .trial(next)
        }
        if running.build == p.from.build {
            if installed?.build == p.to.build, (p.oldBuildStarts ?? 0) < maxOldBuildStarts {
                var next = p
                next.oldBuildStarts = (p.oldBuildStarts ?? 0) + 1
                // The new build gets its whole window from now (the old one may start long after the swap).
                next.deadline = now.addingTimeInterval(commitWindow)
                return .restartIntoInstalled(next)
            }
            return .rolledBackOutside(p)
        }
        return .discard(p)
    }

    /// While the new build runs uncommitted: roll back once the deadline passes.
    public static func rollbackDue(_ pending: PendingUpdate, committed: Bool, now: Date) -> Bool {
        !committed && now >= pending.deadline
    }

    /// What a healthy host has shown (DESIGN §3.10): the QUIC listener is ready, the local control socket is up, and a
    /// capture probe returned a frame or said exactly which grant is missing.
    ///
    /// With every display asleep there is nothing to capture (green-machine, 2026-10-27: SCShareableContent listed no
    /// display for 5 min and a good build rolled back; the Automatic policy's night window always meets this). Then the
    /// capture check is deferred (`captureDeferred`), health is listener and control, and the probe runs at the next wake.
    /// With a display awake the capture stays mandatory.
    public struct Checks: Equatable, Sendable {
        public var listener = false
        public var control = false
        public var capture: String?
        public var captureDeferred: String?
        public init() {}
        public var healthy: Bool { listener && control && (capture != nil || captureDeferred != nil) }
    }

    /// What the capture probe does after a failed attempt. Only CoreGraphics decides "asleep" (no online display, or every
    /// online one asleep): then the check is deferred (nothing to capture; never wake one for it). With a display awake the
    /// capture is mandatory, whatever ScreenCaptureKit says: its "no display" then is a failure like any other (review,
    /// 2026-10-27: an SCK or TCC fault that lists no display must not commit a broken build).
    public enum CaptureFailure: Equatable, Sendable { case retry, deferAsleep }
    public static func onCaptureFailure(displaysAsleep: Bool) -> CaptureFailure {
        displaysAsleep ? .deferAsleep : .retry
    }

    /// After a deferred check, once a display is awake: a few tries before a failure is recorded (the first captures after
    /// a wake can fail while the display comes up). Asleep again resets the count.
    public struct AfterWake: Equatable, Sendable {
        public static let attempts = 3
        public private(set) var failures = 0
        public init() {}
        /// One failed try with a display awake: true when it is the last one (record the failure).
        public mutating func failed() -> Bool { failures += 1; return failures >= Self.attempts }
        public mutating func asleepAgain() { failures = 0 }
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
