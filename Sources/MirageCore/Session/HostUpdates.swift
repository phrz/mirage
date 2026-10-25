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
