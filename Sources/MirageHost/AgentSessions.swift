import Foundation
import IOKit
import MirageCore

/// An unlock an agent asked for (`miraged unlock`, DESIGN §3.13) opens an agent session on the host: the curtain up while
/// the agent works (the same rules as a viewer's session: local input locks the Mac), until the agent says it is done
/// (`miraged unlock --done`), a viewer ends it (its banner's End Session), it goes `idle` without a sign of life from the
/// same agent (`miraged unlock --extend`, verified by the host to come from the program that asked), or it reaches the hard
/// `maximum` (then a new approval is needed). Its end is a session's end: Lock When Finished applies. One at a time.
///
/// Its end always locks the Mac (where the usual rules allow: not already locked, nobody signed in at it meanwhile), even
/// with Lock When Finished off: an agent unlock is the exception that setting does not cover.
///
/// miraged stopping (SIGTERM: bootout, uninstall, an update's restart) ends an open agent session at once, through the
/// curtain's state machine. A record of the open session is kept in the store (`agent-session.json`) for the cases where
/// miraged could not (a crash): the next start, in the same boot (a reboot already locks the Mac), ends it through the
/// state machine too, and only if nobody has used the Mac for `recoveryIdle` (they may have unlocked it themselves since).
public final class AgentSessions: @unchecked Sendable {
    public static let shared = AgentSessions()
    public static let idle: TimeInterval = 15 * 60
    public static let maximum: TimeInterval = 60 * 60
    static let recordName = "agent-session.json"
    public static let recoveryIdle: TimeInterval = 120

    /// Whether a recorded session is ended (and maybe locked) at a new start: same boot, and nobody at the Mac lately.
    /// Pure, for tests.
    public static func recover(recordedBoot: Double?, boot: Double, hidIdle: TimeInterval) -> Bool {
        guard let recordedBoot, abs(recordedBoot - boot) < 1 else { return false }
        return hidIdle >= recoveryIdle
    }
    /// When this boot began (kern.boottime), seconds since 1970.
    static func bootTime() -> Double {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }
    /// Seconds since the last hardware input (IOHIDSystem's HIDIdleTime).
    static func hidIdle() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return 0 }
        return v.doubleValue / 1e9
    }

    /// Whether a session begun at `began`, last active at `last`, is over by `now`, and why. Pure, for tests.
    public static func over(began: Date, last: Date, now: Date, idle: TimeInterval = AgentSessions.idle, maximum: TimeInterval = AgentSessions.maximum) -> String? {
        if now.timeIntervalSince(began) >= maximum { return "its hour is up (a new approval is needed)" }
        if now.timeIntervalSince(last) >= idle { return "idle for \(Int(idle / 60)) min" }
        return nil
    }

    struct Record: Codable { var id: String; var requester: String; var began: Date; var boot: Double? }
    private var current: (id: String, requester: String, anchor: String, began: Date, last: Date)?
    private var timer: DispatchSourceTimer?
    private var log: @Sendable (String) -> Void = { _ in }
    private var notify: @Sendable (ControlMessage.AgentSessionInfo) -> Void = { _ in }
    private var store: Store?

    /// miraged at start: what to log with, how to tell viewers, and where the record lives. A record left by an earlier run
    /// means a session that never ended: see the type's notes.
    public func start(store: Store?, log: @escaping @Sendable (String) -> Void, notify: @escaping @Sendable (ControlMessage.AgentSessionInfo) -> Void) {
        DispatchQueue.main.async {
            self.store = store; self.log = log; self.notify = notify
            guard let url = store?.url(Self.recordName), let d = try? Data(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)
            let r = try? JSONDecoder().decode(Record.self, from: d)
            let name = "agent session \(r?.id ?? "?") for \(r?.requester ?? "an agent")"
            let idle = Self.hidIdle()
            guard Self.recover(recordedBoot: r?.boot, boot: Self.bootTime(), hidIdle: idle) else {
                log("\(name) was open when miraged stopped: \(r?.boot == nil || abs((r?.boot ?? 0) - Self.bootTime()) >= 1 ? "the Mac restarted since (that locked it)" : "someone used this Mac \(Int(idle)) s ago") — not locking")
                return
            }
            log("\(name) was open when miraged stopped: ending it now (the curtain's rules decide the lock)")
            Curtain.shared.endRecoveredAgentSession(r?.id ?? "agent-recovered")
        }
    }

    public func begin(requester: String, anchor: String) {
        DispatchQueue.main.async {
            if self.current != nil {
                if self.current!.anchor == anchor { self.current!.last = Date() }
                self.log("agent session: \(requester) unlocked again\(self.current!.anchor == anchor ? "; extended" : "")")
                return
            }
            let id = "agent-\(UUID().uuidString.prefix(8))", now = Date()
            self.current = (id, requester, anchor, now, now)
            if let url = self.store?.url(Self.recordName), let d = try? JSONEncoder().encode(Record(id: id, requester: requester, began: now, boot: Self.bootTime())) {
                try? d.write(to: url, options: .atomic)
            }
            let settings = self.store.map { HostSettings.load(from: $0.url(HostSettings.fileName)) } ?? HostSettings()
            Curtain.shared.agentSessionBegan(id, curtain: settings.curtain, lockWhenFinished: true)   // always, whatever the setting
            self.notify(.init(open: true, requester: requester, endsBy: now.addingTimeInterval(Self.maximum)))
            self.log("agent session \(id) for \(requester): open (curtain \(settings.curtain ? "on" : "off")); ends at `miraged unlock --done`, after \(Int(Self.idle / 60)) min idle or in \(Int(Self.maximum / 60)) min")
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 30, repeating: 30)
            t.setEventHandler { [weak self] in
                guard let self, let c = self.current, let why = Self.over(began: c.began, last: c.last, now: Date()) else { return }
                self.end(why)
            }
            t.resume()
            self.timer = t
        }
    }
    /// The agent's sign of life: counted only from the program that asked (`anchor`). Answers (on main) whether a session is
    /// open and whether this extended it.
    public func extend(anchor: String, _ done: @escaping @Sendable (_ open: Bool, _ extended: Bool) -> Void) {
        DispatchQueue.main.async {
            guard self.current != nil else { done(false, false); return }
            let mine = self.current!.anchor == anchor
            if mine { self.current!.last = Date() } else { self.log("agent session: an extend from another program was ignored") }
            done(true, mine)
        }
    }
    /// The agent is done, or a viewer ended it: ending is allowed to anyone (it only locks).
    public func end(by who: String, _ finished: (@Sendable (Bool) -> Void)? = nil) {
        DispatchQueue.main.async { let had = self.current != nil; self.end("ended by \(who)"); finished?(had) }
    }
    /// miraged is stopping (SIGTERM): an open session ends now, its lock decided at once; `done` runs when that is posted.
    public func endForShutdown(_ done: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            guard let c = self.current else { done(); return }
            self.current = nil; self.timer?.cancel(); self.timer = nil
            self.log("agent session \(c.id) for \(c.requester): ended (miraged is stopping)")
            Curtain.shared.endAgentSessionNow(c.id) {
                if let url = self.store?.url(Self.recordName) { try? FileManager.default.removeItem(at: url) }
                done()
            }
        }
    }
    private func end(_ why: String) {
        guard let c = current else { return }
        current = nil; timer?.cancel(); timer = nil
        if let url = store?.url(Self.recordName) { try? FileManager.default.removeItem(at: url) }
        Curtain.shared.sessionEnded(c.id, stopped: true)
        notify(.init(open: false, requester: c.requester))
        log("agent session \(c.id) for \(c.requester): ended (\(why)); Lock When Finished applies")
    }
}
