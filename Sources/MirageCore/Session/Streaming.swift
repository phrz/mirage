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
    private var flowWaiters: [FlowWaiter] = []
    public var streamer: DesktopStreamer?

    init(id: UUID) { self.id = id }

    public var flow: MessageStream? { lock.lock(); defer { lock.unlock() }; return _flow }

    func setFlow(_ f: MessageStream) {
        lock.lock()
        _flow = f
        let waiters = flowWaiters; flowWaiters = []
        lock.unlock()
        for w in waiters { w.resume(f) }
    }

    /// Called when the flow's receive loop ends, so a later streamRequest does not build on a dead flow.
    func clearFlow(_ f: MessageStream) {
        lock.lock(); if _flow === f { _flow = nil }; lock.unlock()
    }

    /// Waits for the client to open its datagram flow. Every waiter is resumed exactly once:
    /// by `setFlow`, or with nil by the timeout.
    public func waitForFlow(timeout: Duration) async -> MessageStream? {
        if let f = flow { return f }
        return await withCheckedContinuation { (c: CheckedContinuation<MessageStream?, Never>) in
            let waiter = FlowWaiter(c)
            lock.lock()
            if let f = _flow { lock.unlock(); waiter.resume(f); return }
            flowWaiters.append(waiter)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000))) { [self] in
                lock.lock(); flowWaiters.removeAll { $0 === waiter }; lock.unlock()
                waiter.resume(nil)
            }
        }
    }
}

/// A single-shot continuation wrapper (resume at most once from any thread).
final class FlowWaiter: @unchecked Sendable {
    private var c: CheckedContinuation<MessageStream?, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<MessageStream?, Never>) { self.c = c }
    func resume(_ v: MessageStream?) {
        lock.lock(); let cc = c; c = nil; lock.unlock()
        cc?.resume(returning: v)
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
