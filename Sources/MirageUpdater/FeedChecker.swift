import Foundation

/// When the host checks its feed (U7 follow-up, after mac-daddy's first live run: a new nightly waited up to 6 h to be
/// noticed). Every hour with jitter; at the first quiet moment of a new day; and when a viewer's Welcome (a session's or
/// a status probe's) finds the record older than 10 min. Never more than one check in flight, and never two
/// Welcome-driven checks within 10 min. Metered or constrained uplinks still skip it (the agent's side).
public final class FeedChecker: @unchecked Sendable {
    public static let every: TimeInterval = 3600
    /// A record this old is stale for a viewer's Welcome.
    public static let staleAfter: TimeInterval = 10 * 60
    /// Welcome-driven checks at most this often.
    public static let minGap: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var inFlight = false
    private var lastWelcomeCheck: Date?
    public init() {}

    /// The last check is missing, older than `staleAfter`, or from the future (a clock set back).
    public static func isStale(lastCheck: Date?, now: Date) -> Bool {
        guard let t = lastCheck else { return true }
        let age = now.timeIntervalSince(t)
        return age >= staleAfter || age < -60
    }

    /// The last check was on an earlier local day.
    public static func isNewDay(lastCheck: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let t = lastCheck else { return true }
        return !calendar.isDate(t, inSameDayAs: now) && now > t
    }

    /// The hourly check is due (with the jitter the caller drew for this round).
    public static func isDue(lastCheck: Date?, now: Date, jitter: TimeInterval = 0) -> Bool {
        guard let t = lastCheck else { return true }
        let age = now.timeIntervalSince(t)
        return age >= every + jitter || age < -60
    }

    /// Starts a check if none is in flight; a Welcome-driven one also needs the record stale and the last Welcome-driven
    /// check `minGap` ago. True: the caller runs the check and calls `end()`.
    public func begin(welcome: Bool, lastCheck: Date?, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight { return false }
        if welcome {
            guard Self.isStale(lastCheck: lastCheck, now: now) else { return false }
            if let w = lastWelcomeCheck, now.timeIntervalSince(w) < Self.minGap, now >= w { return false }
            lastWelcomeCheck = now
        }
        inFlight = true
        return true
    }

    public func end() { lock.lock(); inFlight = false; lock.unlock() }
    public var running: Bool { lock.lock(); defer { lock.unlock() }; return inFlight }
}
