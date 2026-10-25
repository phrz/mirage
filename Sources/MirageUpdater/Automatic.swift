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
        /// Sessions suspended (their viewer gone, resumable for a day) within the last `quietFor`: a viewer that dropped
        /// a moment ago comes back to its session, so they count as streaming.
        public var suspendedRecently: Int = 0
        /// When the last stream ended (nil: none since the agent started).
        public var lastStreamEnded: Date?
        /// A system prompt (a consent or permission dialog) is on screen: a person's to answer, and the restart would
        /// leave it orphaned.
        public var systemPrompt: Bool
        /// Seconds since the last keyboard, mouse or trackpad event on this Mac.
        public var idleSeconds: TimeInterval
        public var now: Date
        public init(streaming: Int, lastStreamEnded: Date?, systemPrompt: Bool, idleSeconds: TimeInterval, now: Date, suspendedRecently: Int = 0) {
            self.streaming = streaming; self.lastStreamEnded = lastStreamEnded; self.systemPrompt = systemPrompt; self.idleSeconds = idleSeconds; self.now = now
            self.suspendedRecently = suspendedRecently
        }

        /// Suspended sessions that count: those suspended less than `quietFor` ago.
        public static func recent(_ suspendedSince: [Date], now: Date) -> Int {
            suspendedSince.filter { let a = now.timeIntervalSince($0); return a < AutomaticUpdate.quietFor && a >= -60 }.count
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
        if m.suspendedRecently > 0 { return .wait("\(m.suspendedRecently) session\(m.suspendedRecently == 1 ? " was" : "s were") suspended less than \(Int(quietFor / 60)) min ago (its viewer may be back)") }
        if let e = m.lastStreamEnded, m.now.timeIntervalSince(e) < quietFor {
            return .wait("a stream ended \(Int(m.now.timeIntervalSince(e))) s ago")
        }
        if m.systemPrompt { return .wait("a system prompt is on screen") }
        if m.idleSeconds < quietFor { return .wait("this Mac was used \(Int(m.idleSeconds)) s ago") }
        return .install(latest)
    }

    /// The quiet moment as a gate, asked again before the swap and before the restart: nil, or why not now.
    public static func gateReason(_ m: Moment) -> String? {
        var s = UpdateSettings(); s.policy = .automatic; s.latest = MirageVersion(version: "", build: 1, commit: "", channel: nil)
        if case .wait(let why) = decide(settings: s, running: MirageVersion(version: "", build: 0, commit: "", channel: nil), moment: m) { return why }
        return nil
    }

    /// Before installing: remember the build, so whatever happens (a failure, a rollback, a crash) it is not tried again
    /// on its own. Saved before the attempt starts; false when it cannot be saved (then the attempt is skipped: an
    /// unrecorded try could repeat forever).
    @discardableResult
    public static func recordAttempt(_ build: Int, settings url: URL) -> Bool {
        var s = UpdateSettings.load(url)
        if s.automaticTried.contains(build) { return true }
        s.automaticTried.append(build)
        do { try s.save(url) } catch { return false }
        return UpdateSettings.load(url).automaticTried.contains(build)
    }

    /// A transient failure (the network, another update, the moment ending) gives the try back.
    public static func releaseAttempt(_ build: Int, settings url: URL) {
        var s = UpdateSettings.load(url)
        guard s.automaticTried.contains(build) else { return }
        s.automaticTried.removeAll { $0 == build }
        try? s.save(url)
    }

    /// How an automatic attempt ended, for its record: nil keeps the try used, else the try is given back.
    public enum Ending: Equatable, Sendable {
        case swapped
        case nothingToDo
        case failed(transient: Bool)
        case deferred
        case busy
        /// The build's one automatic try stays used.
        public var consumesTry: Bool {
            switch self {
            case .swapped, .failed(transient: false): return true
            case .nothingToDo, .failed(transient: true), .deferred, .busy: return false
            }
        }
    }
}
