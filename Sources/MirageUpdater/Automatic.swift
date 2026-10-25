import Foundation
import MirageCore

/// The Automatic policy (DESIGN §3.10, U6): the host installs an available update on its own, at a quiet moment, through
/// the same trial, commit and rollback as any update; each build is tried once on its own.
public enum AutomaticUpdate {
    /// How long the Mac and its viewers must have been quiet.
    public static let quietFor: TimeInterval = 10 * 60
    /// How often the agent looks.
    public static let every: TimeInterval = 60

    /// What the agent sees at a moment.
    public struct Moment: Equatable, Sendable {
        /// Viewers streaming now.
        public var streaming: Int
        /// When the last stream ended (nil: none since the agent started).
        public var lastStreamEnded: Date?
        /// A system prompt (a consent or permission dialog) is on screen: a person's to answer, and the restart would
        /// leave it orphaned.
        public var systemPrompt: Bool
        /// Seconds since the last keyboard, mouse or trackpad event on this Mac.
        public var idleSeconds: TimeInterval
        public var now: Date
        public init(streaming: Int, lastStreamEnded: Date?, systemPrompt: Bool, idleSeconds: TimeInterval, now: Date) {
            self.streaming = streaming; self.lastStreamEnded = lastStreamEnded; self.systemPrompt = systemPrompt; self.idleSeconds = idleSeconds; self.now = now
        }
    }

    public enum Decision: Equatable, Sendable {
        case install(MirageVersion)
        case wait(String)
    }

    public static func decide(settings s: UpdateSettings, running: MirageVersion, moment m: Moment) -> Decision {
        guard s.policy == .automatic else { return .wait("the policy is ask") }
        guard let latest = s.latest, latest.build > running.build else { return .wait("up to date") }
        if s.skippedBuilds.contains(latest.build) { return .wait("\(latest.display) rolled back here: skipped") }
        if s.automaticTried.contains(latest.build) { return .wait("\(latest.display) was tried automatically once: not again on its own") }
        if m.streaming > 0 { return .wait("\(m.streaming) viewer\(m.streaming == 1 ? " is" : "s are") streaming") }
        if let e = m.lastStreamEnded, m.now.timeIntervalSince(e) < quietFor {
            return .wait("a stream ended \(Int(m.now.timeIntervalSince(e))) s ago")
        }
        if m.systemPrompt { return .wait("a system prompt is on screen") }
        if m.idleSeconds < quietFor { return .wait("this Mac was used \(Int(m.idleSeconds)) s ago") }
        return .install(latest)
    }

    /// Before installing: remember the build, so whatever happens (a failure, a rollback, a crash) it is not tried again
    /// on its own. Saved before the attempt starts.
    public static func recordAttempt(_ build: Int, settings url: URL) {
        var s = UpdateSettings.load(url)
        if !s.automaticTried.contains(build) { s.automaticTried.append(build); try? s.save(url) }
    }
}
