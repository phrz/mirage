import Foundation
import Network

/// What a desktop streamer needs from the session: a way to send datagrams and control messages.
public protocol StreamOutput: AnyObject, Sendable {
    /// Fire-and-forget datagram on the connection's unreliable flow.
    func sendDatagram(_ data: Data)
    /// Reliable, ordered control message (cursor shapes, stream info, ...).
    func sendControl(_ message: ControlMessage)
    /// Reliable, ordered bytes on the tile stream (already framed by `TileMessage.encode`).
    /// `fast` = the interactive stream (changed pixels, copy-rects), else the refinement stream.
    func sendTiles(_ data: Data, fast: Bool)
    var maxDatagramSize: Int { get }
}

/// A platform implementation of "stream this display, inject this input" (macOS: MirageHost).
/// MirageCore itself stays free of ScreenCaptureKit/AppKit so it compiles for iOS.
public protocol DesktopStreamer: AnyObject, Sendable {
    func start(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo
    func update(_ request: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo
    func handle(ack: ControlMessage.FrameAck)
    func handle(tileAck: ControlMessage.TileAck)
    func handle(input: ControlMessage)
    func stop() async
}

/// Per-QUIC-connection state shared by its streams: the datagram flow and the streamer.
public final class HostConnection: @unchecked Sendable {
    public let id: UUID
    private let lock = NSLock()
    private var _flow: MessageStream?
    private var _tiles: MessageStream?
    private var _fastTiles: MessageStream?
    private var flowWaiters: [FlowWaiter] = []
    private var tileWaiters: [FlowWaiter] = []
    private var fastWaiters: [FlowWaiter] = []
    public var streamer: DesktopStreamer?

    init(id: UUID) { self.id = id }

    public var flow: MessageStream? { lock.lock(); defer { lock.unlock() }; return _flow }
    public var tiles: MessageStream? { lock.lock(); defer { lock.unlock() }; return _tiles }
    public var fastTiles: MessageStream? { lock.lock(); defer { lock.unlock() }; return _fastTiles }
    func setFastTiles(_ t: MessageStream) {
        lock.lock(); _fastTiles = t; let w = fastWaiters; fastWaiters = []; lock.unlock()
        for x in w { x.resume(t) }
    }
    func clearFastTiles(_ t: MessageStream) { lock.lock(); if _fastTiles === t { _fastTiles = nil }; lock.unlock() }
    public func waitForFastTiles(timeout: Duration) async -> MessageStream? {
        await wait(timeout: timeout, current: { $0._fastTiles }, register: { $0.fastWaiters.append($1) }, unregister: { c, w in c.fastWaiters.removeAll { $0 === w } })
    }

    func setFlow(_ f: MessageStream) {
        lock.lock()
        _flow = f
        let waiters = flowWaiters; flowWaiters = []
        lock.unlock()
        for w in waiters { w.resume(f) }
    }
    func setTiles(_ t: MessageStream) {
        lock.lock()
        _tiles = t
        let waiters = tileWaiters; tileWaiters = []
        lock.unlock()
        for w in waiters { w.resume(t) }
    }

    /// Called when the flow's receive loop ends, so a later streamRequest does not build on a dead flow.
    func clearFlow(_ f: MessageStream) {
        lock.lock(); if _flow === f { _flow = nil }; lock.unlock()
    }
    func clearTiles(_ t: MessageStream) {
        lock.lock(); if _tiles === t { _tiles = nil }; lock.unlock()
    }

    /// Waits for the client to open its datagram flow. Every waiter is resumed exactly once:
    /// by `setFlow`, or with nil by the timeout.
    public func waitForFlow(timeout: Duration) async -> MessageStream? {
        await wait(timeout: timeout, current: { $0._flow }, register: { $0.flowWaiters.append($1) }, unregister: { c, w in c.flowWaiters.removeAll { $0 === w } })
    }
    public func waitForTiles(timeout: Duration) async -> MessageStream? {
        await wait(timeout: timeout, current: { $0._tiles }, register: { $0.tileWaiters.append($1) }, unregister: { c, w in c.tileWaiters.removeAll { $0 === w } })
    }

    private func wait(timeout: Duration, current: @escaping (HostConnection) -> MessageStream?, register: @escaping (HostConnection, FlowWaiter) -> Void,
                      unregister: @escaping (HostConnection, FlowWaiter) -> Void) async -> MessageStream? {
        lock.lock(); let now = current(self); lock.unlock()
        if let now { return now }
        return await withCheckedContinuation { (c: CheckedContinuation<MessageStream?, Never>) in
            let waiter = FlowWaiter(c)
            lock.lock()
            if let f = current(self) { lock.unlock(); waiter.resume(f); return }
            register(self, waiter)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000))) { [self] in
                lock.lock(); unregister(self, waiter); lock.unlock()
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

/// StreamOutput bound to one connection's datagram flow, tile stream and control stream.
final class ConnectionOutput: StreamOutput, @unchecked Sendable {
    let flow: MessageStream
    let tiles: MessageStream?
    let fastTiles: MessageStream?
    let control: ControlSender
    let log: @Sendable (String) -> Void
    let maxDatagramSize: Int

    init(flow: MessageStream, tiles: MessageStream?, fastTiles: MessageStream?, control: MessageStream, log: @escaping @Sendable (String) -> Void) {
        self.flow = flow; self.tiles = tiles; self.fastTiles = fastTiles; self.control = ControlSender(stream: control, log: log); self.log = log
        let m = flow.connection.maximumDatagramSize
        maxDatagramSize = m > 0 ? min(m, VideoFragment.datagramSize) : VideoFragment.datagramSize
    }

    func sendDatagram(_ data: Data) {
        flow.connection.send(content: data, completion: .contentProcessed { [log] err in
            if let err { log("datagram send: \(err)") }
        })
    }

    func sendControl(_ message: ControlMessage) { control.send(message) }

    func sendTiles(_ data: Data, fast: Bool) {
        // Network.framework queues sends in order on one connection; no await needed for ordering.
        ((fast ? fastTiles : nil) ?? tiles)?.connection.send(content: data, completion: .contentProcessed { [log] err in
            if let err { log("tile send: \(err)") }
        })
    }
}
