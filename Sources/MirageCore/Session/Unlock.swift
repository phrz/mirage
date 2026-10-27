import Foundation

/// Unlock with biometry (DESIGN §3.13): the pieces both sides share, apart from Keychain, LocalAuthentication and CGEvents
/// so they can be tested.
public enum UnlockLogic {
    /// The host's gate in front of typing: one attempt per device per `spacing`, and, host-wide, none after a typed attempt
    /// left the Mac locked (most likely a wrong password) until the Mac has been unlocked some other way or `failurePause`
    /// passed. A wrong saved password must never be typed twice by a machine, from this device or another: the person types
    /// it, and may save the new one.
    public struct Gate: Sendable {
        public var spacing: TimeInterval = 10
        public var failurePause: TimeInterval = 15 * 60
        private var lastAttempt: [String: Date] = [:]
        private var failedAt: Date?
        public init() {}

        /// Why `device` may not try now; nil: go ahead (and the attempt is counted).
        public mutating func admit(_ device: String, now: Date = Date()) -> String? {
            if let f = failedAt, now.timeIntervalSince(f) < failurePause {
                return "the last saved password did not unlock this Mac: type it at the lock screen (Mirage offers to save the new one)"
            }
            if let t = lastAttempt[device], now.timeIntervalSince(t) < spacing, now >= t { return "an unlock was just tried: wait a few seconds" }
            lastAttempt[device] = now
            return nil
        }
        public mutating func record(_ outcome: ControlMessage.UnlockResult.Outcome, now: Date = Date()) {
            if outcome == .stillLocked { failedAt = now } else if outcome == .unlocked { failedAt = nil }
        }
        /// The Mac was unlocked (by anyone, any way): the pause after a failure is over.
        public mutating func macUnlocked() { failedAt = nil }
    }

    /// A reason or a requester as the person will see it: no control or format characters (newlines, bidi overrides,
    /// zero-width marks), runs of spaces as one, at most `limit` characters.
    public static func clean(_ text: String, limit: Int = 120) -> String {
        var out = ""
        for u in text.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: out.unicodeScalars.append(" ")
            default: out.unicodeScalars.append(u)
            }
        }
        let words = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit - 1)) + "…" : words
    }

    /// The viewer's record of what its person types at the host's lock screen, so a password that unlocked it can be offered
    /// for saving ("Save for Unlock with Face ID?"). Fed every key the viewer sends while the host reports its screen locked;
    /// Return ends a candidate. Anything it cannot follow (arrows, a shortcut, a click into the field) spoils the attempt:
    /// better no offer than a wrong password saved.
    public struct Capture: Sendable {
        private var typed: [Character] = []
        private var spoiled = false
        /// The attempt Return ended, waiting for the host to report unlocked (then offered) or to stay locked (dropped).
        public private(set) var candidate: (password: Data, at: Date)?
        public init() {}

        public static let returnKeys: Set<UInt16> = [36, 76]
        static let escape: UInt16 = 53, delete: UInt16 = 51, forwardDelete: UInt16 = 117
        static let cursorKeys: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
        /// Command or Control held: a shortcut, not a character of the password (Option types characters: ø, ß).
        static let shortcutMask: UInt64 = (1 << 20) | (1 << 18)

        public mutating func key(code: UInt16, characters: String?, modifiers: UInt64, now: Date = Date()) {
            if Self.returnKeys.contains(code) {
                candidate = spoiled || typed.isEmpty ? nil : (Data(String(typed).utf8), now)
                reset(); return
            }
            switch code {
            case Self.escape: reset()
            case Self.delete: if !typed.isEmpty { typed.removeLast() }
            case Self.forwardDelete: spoiled = true
            case _ where Self.cursorKeys.contains(code) || modifiers & Self.shortcutMask != 0: spoiled = true
            default:
                guard let c = characters, !c.isEmpty, c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return }
                typed.append(contentsOf: c)
            }
        }
        /// A click or anything else that may move the caret: the attempt can no longer be followed.
        public mutating func spoil() { spoiled = true }
        /// The host's lock state changed. Returns the password to offer when the screen unlocked within `window` of Return.
        public mutating func hostLocked(_ locked: Bool, now: Date = Date(), window: TimeInterval = 10) -> Data? {
            if locked {
                // Still locked after the window: that attempt did not unlock it; never offered later.
                if let c = candidate, now.timeIntervalSince(c.at) > window { candidate = nil }
                return nil
            }
            defer { candidate = nil; reset() }
            guard let c = candidate, now.timeIntervalSince(c.at) <= window else { return nil }
            return c.password
        }
        private mutating func reset() { typed.removeAll(keepingCapacity: false); spoiled = false }
    }

    /// The save offer after a typed password unlocked the host: Save when none is saved for it, Update when the saved one
    /// failed this time, nothing otherwise (or without biometry).
    public enum SaveOffer: Equatable, Sendable { case save, update }
    public static func saveOffer(biometry: Bool, saved: Bool, savedFailed: Bool) -> SaveOffer? {
        guard biometry else { return nil }
        if !saved { return .save }
        return savedFailed ? .update : nil
    }
    /// Whether to raise the biometric prompt by itself: only for a host this device was told to (Always), once per connection,
    /// when the session first sees it locked, and never after the saved password failed. Otherwise the offer waits for a click.
    public static func autoPrompt(nowLocked: Bool, wasLocked: Bool, alreadyPrompted: Bool, savedFailed: Bool, always: Bool, ready: Bool) -> Bool {
        nowLocked && !wasLocked && !alreadyPrompted && !savedFailed && always && ready
    }

    /// What an agent's request came to (`miraged unlock`, the local control's `requestUnlock`).
    public enum RequestOutcome: String, Codable, Sendable {
        case unlocked, stillLocked, notLocked, interrupted, declined, refused, noViewer, timedOut
        public var exitCode: Int32 {
            switch self {
            case .unlocked, .notLocked: return 0
            case .declined: return 3
            case .noViewer: return 4
            case .timedOut: return 5
            case .stillLocked, .refused: return 6
            case .interrupted: return 7
            }
        }
    }
}

/// A secret's bytes in one owned buffer, zeroed when done (`wipe`, and at the latest on deinit). Taking it from a `Data`
/// zeroes that `Data` (best effort: a copy sharing its storage keeps the bytes, a small `Data` keeps them inline in each
/// copy, and the decoder's and TLS layer's buffers are beyond reach).
public final class SecretBytes: @unchecked Sendable {
    public private(set) var bytes: [UInt8]
    public init(taking data: inout Data) { bytes = [UInt8](data); Self.wipe(&data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    /// Zeroes `data`'s bytes in place. Only storage this value owns alone is reached (a buffer another copy shares is
    /// copied first, by `Data`'s own rules): keep one owner, as the host does with the message's password.
    public static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { p in if let b = p.baseAddress, p.count > 0 { memset(b, 0, p.count) } }
    }
    public func wipe() { for i in bytes.indices { bytes[i] = 0 } }
    deinit { wipe() }
}

/// The host's single unlock at a time: the gate, and one attempt in flight host-wide (two viewers, or a request's answer and
/// a banner tap, never type interleaved).
public actor UnlockCoordinator {
    private var gate = UnlockLogic.Gate()
    private var inFlight = false
    public init() {}
    /// Why `device` may not unlock now; nil: it holds the one slot until `end` or `cancel`.
    public func begin(_ device: String, now: Date = Date()) -> String? {
        if inFlight { return "an unlock is already in progress" }
        if let why = gate.admit(device, now: now) { return why }
        inFlight = true
        return nil
    }
    public func end(_ outcome: ControlMessage.UnlockResult.Outcome, now: Date = Date()) { gate.record(outcome, now: now); inFlight = false }
    public func cancel() { inFlight = false }
    public func macUnlocked() { gate.macUnlocked() }
}

/// Viewers that show agent sessions (their Hello listed `Feature.agentSession`), and the session's state for those that
/// connect while one is open.
public actor AgentSessionNotices {
    private var sinks: [UUID: @Sendable (ControlMessage) -> Void] = [:]
    public private(set) var current: ControlMessage.AgentSessionInfo?
    public init() {}
    public func add(_ id: UUID, _ sink: @escaping @Sendable (ControlMessage) -> Void) { sinks[id] = sink; if let c = current, c.open { sink(.agentSession(c)) } }
    public func remove(_ id: UUID) { sinks[id] = nil }
    public func set(_ info: ControlMessage.AgentSessionInfo) {
        current = info.open ? info : nil
        for send in sinks.values { send(.agentSession(info)) }
    }
}

/// The host's side of agent requests (DESIGN §3.13): viewers that answer them (their Hello listed `Feature.unlock`), and
/// the requests waiting for an answer. A request goes to every such viewer; the first answer settles it, and the others are
/// told (an `unlockResult` with its id) so their prompts close.
public actor UnlockRequests {
    private var sinks: [UUID: @Sendable (ControlMessage) -> Void] = [:]
    private var pending: [String: (request: ControlMessage.UnlockRequest, done: CheckedContinuation<UnlockLogic.RequestOutcome, Never>)] = [:]
    /// Requests an `unlock` has taken (typing under way): no other answer, decline included, counts any more.
    private var claimed = Set<String>()
    private var lastRequest: Date?
    /// Host-only: who may extend the agent session an approved request opens (`PeerIdentity` anchor), never sent.
    private var anchors: [String: String] = [:]
    /// The least time between two requests (a flood of prompts is refused).
    public var spacing: TimeInterval = 10
    public init() {}
    public func add(_ id: UUID, _ sink: @escaping @Sendable (ControlMessage) -> Void) {
        sinks[id] = sink
        // A viewer that connects while a request waits is asked too.
        for p in pending.values { sink(.unlockRequest(p.request)) }
    }
    public func remove(_ id: UUID) { sinks[id] = nil }
    public var listeners: Int { sinks.count }

    /// Asks every listening viewer; returns when one answers, or after `timeout`. One request at a time, and not within
    /// `spacing` of the last: otherwise refused. The reason and requester are cleaned (`UnlockLogic.clean`).
    public func request(reason: String, requester: String, anchor: String = "", timeout: TimeInterval = 120, now: Date = Date()) async -> UnlockLogic.RequestOutcome {
        guard !sinks.isEmpty else { return .noViewer }
        guard pending.isEmpty else { return .refused }
        if let t = lastRequest, now.timeIntervalSince(t) < spacing, now >= t { return .refused }
        lastRequest = now
        let r = ControlMessage.UnlockRequest(id: UUID().uuidString, reason: UnlockLogic.clean(reason), requester: UnlockLogic.clean(requester),
                                             expiresAt: now.addingTimeInterval(timeout))
        anchors[r.id] = anchor
        return await withCheckedContinuation { c in
            pending[r.id] = (r, c)
            for send in sinks.values { send(.unlockRequest(r)) }
            Task { try? await Task.sleep(for: .seconds(timeout)); self.expire(r.id) }
        }
    }
    /// Who asked for `id` (as shown, and the anchor that may extend its session), while it waits.
    public func requester(_ id: String) -> (label: String, anchor: String)? { pending[id].map { ($0.request.requester, anchors[id] ?? "") } }
    /// Whether `id` is a request still waiting (an `unlock` naming another id is refused).
    public func isPending(_ id: String) -> Bool { pending[id] != nil }
    /// An `unlock` answering `id` takes it before typing: false if it is not waiting, or another answer took it.
    public func claim(_ id: String) -> Bool {
        guard pending[id] != nil, !claimed.contains(id) else { return false }
        claimed.insert(id); return true
    }
    /// The claim given back (the unlock was refused before typing): another answer may come.
    public func unclaim(_ id: String) { claimed.remove(id) }
    /// No answer in time: settled as timed out, unless an unlock is typing for it (that settles it).
    private func expire(_ id: String) { if !claimed.contains(id) { settle(id, .timedOut) } }
    /// A viewer's person declined: settles it unless an unlock already took it.
    public func decline(_ id: String) { if !claimed.contains(id) { settle(id, .declined) } }
    /// An answer: the outcome of the unlock typed for it, or a decline.
    public func settle(_ id: String, _ outcome: UnlockLogic.RequestOutcome) {
        claimed.remove(id); anchors[id] = nil
        guard let p = pending.removeValue(forKey: id) else { return }
        p.done.resume(returning: outcome)
        let close = ControlMessage.UnlockResult(outcome: outcome == .unlocked ? .unlocked : .refused, message: "settled: \(outcome.rawValue)", requestID: id)
        for send in sinks.values { send(.unlockResult(close)) }
    }
}
