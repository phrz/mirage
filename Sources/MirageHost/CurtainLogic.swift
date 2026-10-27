import Foundation
import CoreGraphics

/// The curtain's decisions, apart from AppKit so they can be tested (DESIGN §3.12).
public enum CurtainLogic {
    /// Every event miraged injects carries this in `kCGEventSourceUserData` (its CGEventSource's `userData`): the curtain's
    /// event tap tells the remote person's input from a local one by it. ASCII "MIRAGE!!".
    public static let injectedTag: Int64 = 0x4D49_5241_4745_2121

    /// The events that count as someone at the Mac: a click, a key, a modifier, a scroll from the hardware. Pointer motion
    /// alone does not (a nudged table, a mouse settling), nor anything a program posts: miraged's own (tagged, and its pid),
    /// or another app's synthetic input (1Password autofill, Keyboard Maestro, BetterTouchTool, TextExpander, Raycast, Voice
    /// Control, the Accessibility Keyboard), which carries the poster's pid in `kCGEventSourceUnixProcessID`; hardware events
    /// carry 0 there.
    public static func isLocalInput(type: CGEventType, userData: Int64, sourcePID: Int64) -> Bool {
        guard userData != injectedTag, sourcePID == 0 else { return false }
        return isTriggerType(type)
    }
    /// A down-type event (and modifiers, scroll): what can trigger the lock.
    public static func isTriggerType(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel: return true
        default: return false
        }
    }
    /// What the active tap swallows while the lock it triggered takes hold (about 2.5 s or until locked): the hardware's
    /// downs and their matching ups, modifiers and scrolls; pointer motion passes.
    public static func isSwallowedType(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .flagsChanged, .scrollWheel,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return true
        default: return false
        }
    }

    /// The text over the blurred wallpaper: black on a light picture, white on a dark one, slightly transparent either way (as
    /// the lock screen's message reads). `luminance` is the mean relative luminance (0...1) behind the text block.
    public struct TextStyle: Equatable { public var white: Bool; public var alpha: Double }
    public static func textStyle(luminance: Double) -> TextStyle {
        luminance > 0.55 ? TextStyle(white: false, alpha: 0.85) : TextStyle(white: true, alpha: 0.9)
    }

    /// Mean relative luminance (Rec. 709 on sRGB-ish 8-bit values, linearised) of premultiplied BGRA pixels in `rect`.
    public static func meanLuminance(bgra: UnsafeRawBufferPointer, width: Int, height: Int, stride: Int, rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX)), y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return 0.5 }
        func lin(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var sum = 0.0, n = 0
        let step = max(1, (x1 - x0) * (y1 - y0) / 20_000)   // ~20k samples are plenty for a blurred picture
        var i = 0
        for y in y0..<y1 { for x in x0..<x1 {
            i += 1; if i % step != 0 { continue }
            let o = y * stride + x * 4
            sum += 0.0722 * lin(bgra[o]) + 0.7152 * lin(bgra[o + 1]) + 0.2126 * lin(bgra[o + 2]); n += 1
        } }
        return n > 0 ? sum / Double(n) : 0.5
    }

    /// Whose lock is it, and should the curtain show: sessions, the lock, and who unlocked (DESIGN §3.12). Pure: Curtain feeds
    /// it events (with the time, in nanos) and does what it says.
    public struct Machine: Equatable {
        /// A session's settings, taken when it began (DESIGN: they apply from the next session) and kept through a suspend and
        /// resume: its own decide its end.
        public struct Snapshot: Equatable, Sendable {
            public var curtain: Bool, lockWhenFinished: Bool
            public init(curtain: Bool = true, lockWhenFinished: Bool = true) { self.curtain = curtain; self.lockWhenFinished = lockWhenFinished }
        }
        public struct Session: Equatable {
            public var snapshot: Snapshot
            /// Its stream started: a connect that failed before streaming never locks the Mac.
            public var streamed = false
            /// Beginning (a start or a resume) and not yet streaming: a pending end waits for it to stream (which cancels the
            /// end) or fail.
            public var starting = true
            /// Suspended (its viewer went away: a backgrounded phone, a roam, a dropped viewer) since this time. The curtain stays
            /// up until it resumes or its streamer is stopped for good (the resume window, eviction, another device's claim).
            public var suspendedAt: UInt64?
            /// When it last began (a start or a resume): a begin that has not streamed within `beginWaitNanos` no longer holds
            /// the end.
            public var beganAt: UInt64 = 0
        }
        /// The decision at the end of the sessions, waiting out the debounce after the last one stopped (a stream stopped to
        /// start over is followed at once by a new one, which holds it).
        public struct PendingEnd: Equatable {
            public var at: UInt64
            public var lockWhenFinished: Bool
            /// The curtain was not protecting the Mac (Curtain off for that session, or it could not show or lock): input from
            /// someone at the Mac shortly before the decision skips the lock.
            public var checkPresence: Bool
            /// The ending session had been suspended since then: any presence since counts (someone reading for an hour before
            /// the resume window passed), not only the last minute's.
            public var presenceSince: UInt64? = nil
        }
        /// Live sessions: streaming, starting, or suspended.
        public private(set) var sessions: [String: Session] = [:]
        public private(set) var pendingEnd: PendingEnd?
        public private(set) var locked = false
        /// A person at the Mac signed in (an unlock with no remote key or click while locked): no curtain until a remote unlock
        /// or the end of the sessions. Kept across a suspend and resume.
        public private(set) var ownedLocally = false
        /// The last hardware input while no curtain was protecting the Mac (Curtain off, or it could not show or lock). Within
        /// `presenceWindowNanos` of the end's decision, someone is at the Mac, so "Lock when finished" leaves it unlocked (one
        /// stray click long before does not). Forgotten when the Mac locks (they left and locked it) and at the end.
        public private(set) var lastLocalInput: UInt64?
        public var presenceWindowNanos: UInt64 = 60_000_000_000
        public func presentLocally(at now: UInt64) -> Bool { lastLocalInput.map { now &- $0 <= presenceWindowNanos } ?? false }
        /// Injected key-downs and clicks since the Mac locked: the remote person typing a password through Mirage. Pointer
        /// motion and input refused before the lock do not count.
        public private(set) var remoteDownsWhileLocked = 0
        /// The curtain is up on the screens (opaque).
        public var visible = false
        /// A lock the curtain asked for did not land (⌃⌘Q remapped or grabbed by a VM or remote-desktop app, and no password
        /// after display sleep): a curtain that cannot lock would only swallow the Mac's own input, so it stays off until the
        /// sessions end.
        public private(set) var lockUnavailable = false
        /// The curtain could not show at all (no event tap: neither Accessibility nor Input Monitoring).
        public private(set) var curtainUnavailable = false
        /// The debounce after the last session stopped; the longest a begin that has not streamed holds the end.
        public var debounceNanos: UInt64 = 5_000_000_000
        public var beginWaitNanos: UInt64 = 30_000_000_000
        public init(locked: Bool = false) { self.locked = locked }

        private func beginning(at now: UInt64) -> Bool {
            sessions.values.contains { $0.suspendedAt == nil && $0.starting && now &- $0.beganAt < beginWaitNanos }
        }
        /// The curtain should be on the screens: a live session (suspended ones included) with the Curtain setting on, the Mac
        /// unlocked and nobody at it signed in.
        public var wantsCurtain: Bool {
            sessions.values.contains { $0.snapshot.curtain } && !locked && !ownedLocally && !lockUnavailable && !curtainUnavailable
        }
        /// Sessions exist but none streams (every one suspended): nothing needs the display awake, so it sleeps per the Mac's
        /// own Energy settings (the captures, which held it awake, are stopped); the curtain stays up.
        public var allSuspended: Bool { !sessions.isEmpty && sessions.values.allSatisfy { $0.suspendedAt != nil } }
        /// The lock and local input are watched: while any session is live, and until the end is decided.
        public var needsWatching: Bool { !sessions.isEmpty || pendingEnd != nil }
        /// The curtain is not protecting the Mac for this session.
        private func unprotected(_ s: Snapshot) -> Bool { !s.curtain || lockUnavailable || curtainUnavailable }
        /// Hardware input is watched for presence: only where the curtain is not protecting the Mac, with "Lock when finished"
        /// on (where it is, local input locks instead).
        public var watchesPresence: Bool {
            sessions.values.contains { $0.snapshot.lockWhenFinished && unprotected($0.snapshot) } || pendingEnd.map { $0.lockWhenFinished && $0.checkPresence } == true
        }
        public mutating func lockFailed() { lockUnavailable = true; visible = false }
        public mutating func curtainFailed() { curtainUnavailable = true; visible = false }

        /// A stream starts, or a suspended one resumes (keeping its snapshot). A pending end waits for it: off once it streams,
        /// back on its course if it fails.
        public mutating func sessionBegan(_ id: String, _ snapshot: Snapshot = Snapshot(), now: UInt64 = 0) {
            if sessions[id] != nil { sessions[id]!.suspendedAt = nil; sessions[id]!.starting = true } else { sessions[id] = Session(snapshot: snapshot) }
            sessions[id]!.beganAt = now
        }
        /// Its stream started: any pending end is off.
        public mutating func sessionStreamed(_ id: String) {
            guard sessions[id] != nil else { return }
            sessions[id]!.streamed = true; sessions[id]!.starting = false
            pendingEnd = nil
        }
        /// Its viewer went away (or a resume failed). Not an end: the curtain stays up, local input still locks.
        public mutating func sessionSuspended(_ id: String, now: UInt64) {
            guard let s = sessions[id], s.suspendedAt == nil else { return }
            guard s.streamed else { sessions.removeValue(forKey: id); settle(); return }
            sessions[id]!.suspendedAt = now; sessions[id]!.starting = false
        }
        /// It ended for good: a clean stop, or a suspended session's streamer stopped (the resume window passed, eviction,
        /// another device's claim). The last one that streamed starts the debounce; one that never streamed never locks.
        public mutating func sessionStopped(_ id: String, now: UInt64) {
            guard let s = sessions.removeValue(forKey: id) else { return }
            guard s.streamed else { settle(); return }
            guard !sessions.values.contains(where: { $0.streamed }) else { return }
            pendingEnd = PendingEnd(at: now + debounceNanos, lockWhenFinished: s.snapshot.lockWhenFinished, checkPresence: unprotected(s.snapshot),
                                    presenceSince: s.suspendedAt)
        }
        /// After a session that never streamed went: a pending end stays on its course; with none and no session left, the
        /// sessions are over (nothing stale carries into the next one).
        private mutating func settle() { if pendingEnd == nil, sessions.isEmpty { endSessions() } }
        /// Once a second: whether to lock now ("Lock when finished": the end reached, the Mac unlocked, nobody at it signed in,
        /// and, where the curtain was not protecting it, nobody using it).
        public mutating func tick(now: UInt64) -> Bool {
            guard let p = pendingEnd, now >= p.at else { return false }
            guard !sessions.values.contains(where: { $0.streamed && !$0.starting }) else { pendingEnd = nil; return false }
            guard !beginning(at: now) else { return false }   // a stream on its way: it streams (no end) or fails (settles), within 30 s
            let present = p.presenceSince.map { since in lastLocalInput.map { $0 >= since } ?? false } ?? presentLocally(at: now)
            let lock = p.lockWhenFinished && !ownedLocally && !locked && !(p.checkPresence && present)
            sessions = sessions.filter { $0.value.starting && $0.value.suspendedAt == nil }   // a hung begin stays: if it ever streams, it is tracked
            endSessions()
            return lock
        }
        private mutating func endSessions() {
            pendingEnd = nil; ownedLocally = false; lastLocalInput = nil; lockUnavailable = false; curtainUnavailable = false
        }

        public mutating func injectedDown() { if locked { remoteDownsWhileLocked += 1 } }
        /// The lock state changed: an unlock is remote (Mirage typed the password) when injected downs came in while locked,
        /// local otherwise.
        public mutating func lockChanged(_ nowLocked: Bool) {
            guard nowLocked != locked else { return }
            locked = nowLocked
            if nowLocked { remoteDownsWhileLocked = 0; visible = false; lastLocalInput = nil; return }
            ownedLocally = remoteDownsWhileLocked == 0
            remoteDownsWhileLocked = 0
        }
        /// Local input arrived: lock whenever the curtain is wanted, opaque or not (still invisible while the sessions'
        /// filters catch up, rebuilt after a display change, or shown again after a resume): the trigger is the curtain's.
        public func lockOnLocalInput() -> Bool { wantsCurtain }
        /// Local input arrived where no curtain is wanted, the Mac unlocked, while presence is watched: someone is at the Mac.
        public mutating func localInputUncurtained(now: UInt64) {
            if watchesPresence, !locked, !wantsCurtain { lastLocalInput = now }
        }
    }
}
