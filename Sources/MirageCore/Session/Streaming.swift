import Foundation
import Network

/// What a desktop streamer needs from the session: a way to send datagrams and control messages.
public protocol StreamOutput: AnyObject, Sendable {
    /// Fire-and-forget datagram on the connection's unreliable flow.
    func sendDatagram(_ data: Data)
    /// Reliable, ordered control message (cursor shapes, stream info, ...).
    func sendControl(_ message: ControlMessage)
    var maxDatagramSize: Int { get }
}

/// A platform implementation of "stream this display, inject this input" (macOS: MirageHost).
/// MirageCore itself stays free of ScreenCaptureKit/AppKit so it compiles for iOS.
public protocol DesktopStreamer: AnyObject, Sendable {
    func start(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo
    func update(_ request: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo
    func handle(ack: ControlMessage.FrameAck)
    func handle(input: ControlMessage)
    func stop() async
}

/// Per-QUIC-connection state shared by its streams: the datagram flow and the streamer.
public final class HostConnection: @unchecked Sendable {
    public let id: UUID
    private let lock = NSLock()
    private var _flow: MessageStream?
    private var flowWaiters: [CheckedContinuation<MessageStream, Never>] = []
    public var streamer: DesktopStreamer?

    init(id: UUID) { self.id = id }

    public var flow: MessageStream? { lock.lock(); defer { lock.unlock() }; return _flow }

    func setFlow(_ f: MessageStream) {
        lock.lock()
        _flow = f
        let waiters = flowWaiters; flowWaiters = []
        lock.unlock()
        for w in waiters { w.resume(returning: f) }
    }

    private func registerWaiter(_ c: CheckedContinuation<MessageStream, Never>) {
        lock.lock()
        if let f = _flow { lock.unlock(); c.resume(returning: f); return }
        flowWaiters.append(c)
        lock.unlock()
    }

    /// Waits for the client to open its datagram flow.
    public func waitForFlow(timeout: Duration) async -> MessageStream? {
        if let f = flow { return f }
        return await withTaskGroup(of: MessageStream?.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { (c: CheckedContinuation<MessageStream, Never>) in registerWaiter(c) }
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Registry of live QUIC connections on the host.
public actor HostConnections {
    private var connections: [UUID: HostConnection] = [:]
    public init() {}
    public func connection(_ id: UUID) -> HostConnection {
        if let c = connections[id] { return c }
        let c = HostConnection(id: id); connections[id] = c; return c
    }
    public func remove(_ id: UUID) -> HostConnection? { connections.removeValue(forKey: id) }
}

/// Serializes control-message sends on one stream so frames never interleave.
public final class ControlSender: @unchecked Sendable {
    public let stream: MessageStream
    private let log: @Sendable (String) -> Void
    private var task: Task<Void, Never>?
    private var pending: [ControlMessage] = []
    private let lock = NSLock()

    public init(stream: MessageStream, log: @escaping @Sendable (String) -> Void) { self.stream = stream; self.log = log }

    public func send(_ message: ControlMessage) {
        lock.lock()
        pending.append(message)
        if task == nil {
            task = Task { [self] in
                while let m = nextPending() {
                    do { try await stream.send(m) } catch { log("control send: \(error)") }
                }
            }
        }
        lock.unlock()
    }

    private func nextPending() -> ControlMessage? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { task = nil; return nil }
        return pending.removeFirst()
    }
}

/// StreamOutput bound to one connection's datagram flow and control stream.
final class ConnectionOutput: StreamOutput, @unchecked Sendable {
    let flow: MessageStream
    let control: ControlSender
    let log: @Sendable (String) -> Void
    let maxDatagramSize: Int

    init(flow: MessageStream, control: MessageStream, log: @escaping @Sendable (String) -> Void) {
        self.flow = flow; self.control = ControlSender(stream: control, log: log); self.log = log
        let m = flow.connection.maximumDatagramSize
        maxDatagramSize = m > 0 ? min(m, VideoFragment.datagramSize) : VideoFragment.datagramSize
    }

    func sendDatagram(_ data: Data) {
        flow.connection.send(content: data, completion: .contentProcessed { [log] err in
            if let err { log("datagram send: \(err)") }
        })
    }

    func sendControl(_ message: ControlMessage) { control.send(message) }
}
