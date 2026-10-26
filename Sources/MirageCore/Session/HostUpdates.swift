import Foundation

/// Who asked the host to update (DESIGN §3.10, the remote trigger): a paired viewer on a connection, or this Mac itself
/// (the Mirage app's menu bar and window bar, over local control).
public struct UpdateRequester: Sendable, Equatable {
    public var name: String
    /// The viewer's connection; nil for this Mac.
    public var connectionID: UUID?
    public init(name: String, connectionID: UUID?) { self.name = name; self.connectionID = connectionID }
    public static let thisMac = UpdateRequester(name: "this Mac", connectionID: nil)
}

/// The host's updater as HostSession and the local control see it: run a command, reporting progress through `reply`.
/// Set by `miraged` (MirageUpdater); nil on a host that cannot update itself (tests, a bare build).
public typealias HostUpdateHandler = @Sendable (UpdateCommand, UpdateRequester, @escaping @Sendable (ControlMessage.UpdateStatus) -> Void) async -> Void

/// Viewers that decode `updateStatus` (their Hello listed `Feature.updateStatus`), by connection: the host tells them
/// before it restarts into an update someone else triggered.
public actor UpdateListeners {
    private var sinks: [UUID: @Sendable (ControlMessage) -> Void] = [:]
    public init() {}
    public func add(_ id: UUID, _ sink: @escaping @Sendable (ControlMessage) -> Void) { sinks[id] = sink }
    public func remove(_ id: UUID) { sinks[id] = nil }
    public var count: Int { sinks.count }
    /// To every listener but `except` (the viewer that triggered it hears from its own reply).
    public func broadcast(_ status: ControlMessage.UpdateStatus, except: UUID?) {
        for (id, send) in sinks where id != except { send(.updateStatus(status)) }
    }
}

/// Control messages to one viewer in the order they were given, beside whatever else uses the stream (each a whole
/// framed message): update progress must not overtake itself ("restarting" before "verifying").
final class OrderedControlSender: @unchecked Sendable {
    private let queue: AsyncStream<ControlMessage>.Continuation
    init(_ stream: MessageStream) {
        let (messages, queue) = AsyncStream.makeStream(of: ControlMessage.self)
        self.queue = queue
        Task { for await m in messages { try? await stream.send(m) } }
    }
    func send(_ m: ControlMessage) { queue.yield(m) }
    func finish() { queue.finish() }
}

/// Status probes (U7): which open connections are probes (their end is not logged), and one log line per device per
/// `logEvery` at most.
public final class ProbeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var open = Set<UUID>()
    private var lastLogged: [String: Date] = [:]
    public var logEvery: TimeInterval = 600
    public init() {}
    public func mark(_ id: UUID) { lock.lock(); open.insert(id); lock.unlock() }
    public func isProbe(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return open.contains(id) }
    public func end(_ id: UUID) { lock.lock(); open.remove(id); lock.unlock() }
    /// Whether to log this device's probe now.
    public func shouldLog(_ deviceID: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let t = lastLogged[deviceID], now.timeIntervalSince(t) < logEvery, now >= t { return false }
        lastLogged[deviceID] = now
        return true
    }
}

/// A viewer's status probe (U7): a short authenticated control-only connection, no stream, that refreshes the known
/// host's record from the host's Welcome (its build, the newest found, trigger and policy, an update running, a stream
/// elsewhere, the protocol range, when it was seen). A host that cannot be reached is marked unreachable since then; one
/// that answers (even refusing this viewer's version) is seen.
public enum HostProbe {
    @discardableResult
    public static func probe(connect: HostUpdateTrigger.Connect, store: Store, alias: String, now: Date = Date()) async -> Bool {
        do {
            let (s, close) = try await connect()
            defer { close() }
            _ = try await s.authenticate(features: [ControlMessage.Feature.updateStatus, ControlMessage.Feature.probe], probe: true)
            return true
        } catch MirageError.transport {
            try? store.updateKnownHost(alias) { h in if h.unreachableSince == nil { h.unreachableSince = now } }
            return false
        } catch {
            // It answered, with a refusal or a protocol it does not share: seen, and the refusal is in the record.
            try? store.updateKnownHost(alias) { h in h.lastSeen = now; h.unreachableSince = nil }
            return true
        }
    }
}

/// The notice a viewer gets when it resumes its session (U6 review): it may have been away (suspended) while the host
/// updated or began to, and missed the notice sent then.
public enum ResumeNotice {
    public static let within: TimeInterval = 10 * 60

    public static func make(lastResult r: ControlMessage.UpdateStatus?, hostName: String, now: Date) -> ControlMessage.UpdateStatus? {
        guard let r, r.phase != .unknown else { return nil }
        var n = r; n.yours = false
        if !r.isFinal && r.phase != .trial { return n }   // under way now
        guard let at = r.at else { return nil }
        let age = now.timeIntervalSince(at)
        guard age >= 0, age < within else { return nil }
        let to = r.to.map { " \($0.display)" } ?? ""
        switch r.phase {
        case .done, .trial: n.message = "\(hostName) was updated to\(to) while you were away"
        case .rolledBack: n.message = "\(hostName) tried to update to\(to) while you were away, and rolled back"
        case .failed: return nil
        default: break
        }
        return n
    }
}

/// Removing a paired host from a device's list (phrz, 2026-10-26): best effort, the host is asked to forget this device
/// too, on a control-only connection like a status probe.
public enum HostUnpair {
    public enum Outcome: Equatable, Sendable {
        /// The host no longer lists this device.
        case unpaired
        /// The host has no `unpairDevice` (an older build): it still lists this device.
        case notSupported
        /// Not reached in time; it still lists this device.
        case unreachable(String)
    }

    public static func unpair(connect: HostUpdateTrigger.Connect, timeout: TimeInterval = 5) async -> Outcome {
        do {
            let (s, close) = try await connect()
            defer { close() }
            let w = try await s.authenticate(features: [ControlMessage.Feature.probe], probe: true)
            guard (w.features ?? []).contains(ControlMessage.Feature.unpair) else { return .notSupported }
            try await s.stream.send(.unpairDevice)
            return try await withThrowingTaskGroup(of: Outcome.self) { g in
                g.addTask {
                    while true { if case .unpaired = try await s.stream.receive() { return .unpaired } }
                }
                g.addTask { try await Task.sleep(for: .seconds(timeout)); close(); return .unreachable("no answer within \(Int(timeout)) s") }   // closing ends the receive
                let first = try await g.next() ?? .unreachable("no answer")
                g.cancelAll()
                return first
            }
        } catch {
            return .unreachable("\(error)")
        }
    }
}
