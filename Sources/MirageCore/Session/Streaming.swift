import Foundation
import Network
import Security

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
    /// The paired device on the other end (its id), for state kept per pairing (the last delivery estimate).
    var peerID: String? { get }
}
public extension StreamOutput { var peerID: String? { nil } }
public extension DesktopStreamer { func handle(tileReceived: ControlMessage.TileAck) {} }

/// A platform implementation of "stream this display, inject this input" (macOS: MirageHost).
/// MirageCore itself stays free of ScreenCaptureKit/AppKit so it compiles for iOS.
public protocol DesktopStreamer: AnyObject, Sendable {
    func start(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo
    func update(_ request: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo
    func handle(ack: ControlMessage.FrameAck)
    func handle(tileAck: ControlMessage.TileAck)
    /// Protocol 6: a tile message read by the viewer, not yet applied (`tileAck` follows once it is).
    func handle(tileReceived: ControlMessage.TileAck)
    func handle(nack: ControlMessage.Nack)
    func handle(input: ControlMessage)
    /// Input datagram with redundancy; returns what to acknowledge (nil = not ready, the viewer will repeat).
    func handle(inputPacket: InputPacket) -> InputAck?
    /// The viewer echoed a host delay probe: host send clock, viewer receive clock.
    func handle(probeEcho sentNanos: UInt64, receivedNanos: UInt64)
    /// The connection went away: stop capturing and sending but keep every piece of state a resumed
    /// connection needs (tracker, rate controller and tier, encoder rung, sequence numbers, input state).
    func suspend() async
    /// A new connection presented this session's token: rebind the output, restart capture, bring the
    /// viewer's kept picture current with a masked keyframe and the diff against the last frame it saw.
    func resume(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo
    func stop() async
    /// Bytes of pixel caches a suspended session holds (last frames, encoder canvases).
    func cachedBytes() async -> Int
    /// Memory pressure among suspended sessions: drop the pixel caches, keep everything else (tier, rate controller,
    /// sequences, input state). A resumed session then sends each layer's picture again instead of a diff.
    func shedCaches() async
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
    /// Resume token issued to (or presented by) this connection's device.
    public var resumeToken: Data?
    public var deviceID: String?
    /// The streamer was adopted from a suspended or superseded session; the next streamRequest resumes it.
    public var resumed = false
    /// A newer connection took this session over: do not stop the streamer when this one ends.
    public var superseded = false
    public var lastRequest: ControlMessage.StreamRequest?
    /// The viewer's suspend grace, from its Hello (DESIGN §3.12).
    public var suspendGraceSeconds: Int?
    /// The viewer's simulated link (`StreamRequest.throttle`): everything this connection sends goes through it. nil = the real link.
    public var shaper: LinkShaper? { lock.lock(); defer { lock.unlock() }; return _shaper }
    private var _shaper: LinkShaper?
    /// Applies a request's throttle: a new or updated downstream shaper, or none. Returns a line to log when it changed.
    @discardableResult
    public func setThrottle(_ t: NetworkThrottle?) -> String? {
        lock.lock(); defer { lock.unlock() }
        switch (t, _shaper) {
        case (nil, nil): return nil
        case (nil, .some): _shaper = nil; return "network throttle off"
        case (.some(let t), nil): _shaper = LinkShaper(profile: t, upstream: false, label: "mirage.host.shaper"); return "network throttle \(t.name): \(t.summary) (downstream shaped here)"
        case (.some(let t), .some(let s)):
            guard s.profile != t else { return nil }
            s.update(t, upstream: false); return "network throttle \(t.name): \(t.summary) (downstream shaped here)"
        }
    }
    /// A datagram to the viewer from the session itself (ping echoes, input acks), through the throttle when there is one.
    public func sendDatagram(_ d: Data, on flow: MessageStream) {
        let send = { flow.connection.send(content: d, completion: .contentProcessed { _ in }) }
        if let s = shaper { s.send(bytes: d.count, channel: LinkShaper.Channel.datagrams, reliable: false, send) } else { send() }
    }

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

/// Registry of live QUIC connections on the host, and of sessions whose connection went away but
/// whose streamer is kept for a resume (DESIGN §4a: a 30 s outage comes back to the same session).
public actor HostConnections {
    private var connections: [UUID: HostConnection] = [:]
    /// Resume token → the live connection holding that session.
    private var active: [Data: UUID] = [:]
    public struct Suspended {
        public let deviceID: String
        public let streamer: DesktopStreamer
        public let request: ControlMessage.StreamRequest?
        public let since: Date
        /// The streamer's own suspend, in progress: a claim waits for it before resuming the streamer.
        public let suspending: Task<Void, Never>
    }
    private var suspended: [Data: Suspended] = [:]
    private var reapers: [Data: Task<Void, Never>] = [:]
    /// How long a suspended session waits for its viewer before the streamer is stopped for good.
    public var resumeWindow: Duration = .seconds(Mirage.resumeWindowSeconds)
    /// Pixel caches all suspended sessions may hold together; beyond it the oldest shed theirs (MIRAGE_SUSPENDED_MB).
    public var suspendedBytesBudget = (ProcessInfo.processInfo.environment["MIRAGE_SUSPENDED_MB"].flatMap { Int($0) } ?? 1536) << 20
    /// Suspended sessions kept at all; beyond it the oldest is stopped.
    public var maxSuspended = 16
    private var shed = Set<Data>()
    public func setBudget(bytes: Int, maxSessions: Int) { suspendedBytesBudget = bytes; maxSuspended = maxSessions }
    public private(set) var shedCount = 0

    public init() {}
    /// Devices with a stream right now (the host's status for the Mirage app's menu).
    public func streamingDeviceIDs() -> [String] { connections.values.compactMap { $0.streamer != nil ? $0.deviceID : nil } }
    /// When each suspended session was suspended (the Automatic update gate: a viewer that just dropped comes back).
    public func suspendedSince() -> [Date] { suspended.values.map(\.since) }

    public func connection(_ id: UUID) -> HostConnection {
        if let c = connections[id] { return c }
        let c = HostConnection(id: id); connections[id] = c; return c
    }
    public func remove(_ id: UUID) -> HostConnection? {
        let c = connections.removeValue(forKey: id)
        if let t = c?.resumeToken, active[t] == id { active[t] = nil }
        return c
    }

    /// A fresh token for an authenticated connection's session.
    public func issueToken(for id: UUID, deviceID: String) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes)
        active[token] = id
        if let c = connections[id] { c.resumeToken = token; c.deviceID = deviceID }
        return token
    }

    /// A connection presents a token: hands it the suspended session's streamer, or takes the streamer
    /// away from the still-registered connection that held it (the viewer gave up on that path before
    /// the host noticed). nil if the token is unknown, expired, or belongs to another device.
    public func claim(token: Data, deviceID: String, by id: UUID) async -> (streamer: DesktopStreamer, request: ControlMessage.StreamRequest?)? {
        guard let me = connections[id] else { return nil }
        if let s = suspended.removeValue(forKey: token) {
            reapers.removeValue(forKey: token)?.cancel(); shed.remove(token)
            guard s.deviceID == deviceID else { Task { await s.streamer.stop() }; return nil }
            active[token] = id; me.resumeToken = token; me.deviceID = deviceID
            await s.suspending.value
            return (s.streamer, s.request)
        }
        if let otherID = active[token], otherID != id, let other = connections[otherID], other.deviceID == deviceID, let s = other.streamer {
            other.streamer = nil; other.superseded = true
            active[token] = id; me.resumeToken = token; me.deviceID = deviceID
            return (s, other.lastRequest)
        }
        return nil
    }

    /// Keeps a streamer whose connection ended and suspends it; stopped for good when the window passes
    /// unclaimed. Registered *before* the suspend runs: on loopback the viewer's next Hello was processed
    /// 7 ms before the old connection's suspend finished and found no session to resume.
    public func suspend(token: Data, deviceID: String, streamer: DesktopStreamer, request: ControlMessage.StreamRequest?) {
        let suspending = Task { await streamer.suspend() }
        suspended[token] = Suspended(deviceID: deviceID, streamer: streamer, request: request, since: Date(), suspending: suspending)
        active[token] = nil
        let window = resumeWindow
        reapers[token] = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self else { return }
            if let s = await self.expire(token) { await s.streamer.stop() }
        }
        Task { [weak self] in await suspending.value; await self?.enforceBudget() }
    }
    /// Oldest first: beyond `maxSuspended` sessions are stopped, beyond the byte budget their pixel caches are shed.
    public func enforceBudget() async {
        let byAge = suspended.sorted { $0.value.since < $1.value.since }
        if byAge.count > maxSuspended {
            for (token, _) in byAge.prefix(byAge.count - maxSuspended) { if let s = expire(token) { await s.streamer.stop() } }
        }
        var entries: [(token: Data, bytes: Int)] = []
        for (token, s) in suspended.sorted(by: { $0.value.since < $1.value.since }) where !shed.contains(token) { entries.append((token, await s.streamer.cachedBytes())) }
        var total = entries.reduce(0) { $0 + $1.bytes }
        for e in entries where total > suspendedBytesBudget {
            guard let s = suspended[e.token] else { continue }
            await s.streamer.shedCaches()
            shed.insert(e.token); shedCount += 1
            total -= e.bytes
        }
    }
    private func expire(_ token: Data) -> Suspended? { reapers[token] = nil; shed.remove(token); return suspended.removeValue(forKey: token) }
    public var suspendedCount: Int { suspended.count }
}

/// Serializes control-message sends on one stream so frames never interleave.
public final class ControlSender: @unchecked Sendable {
    public let stream: MessageStream
    private let log: @Sendable (String) -> Void
    private var task: Task<Void, Never>?
    private var pending: [ControlMessage] = []
    private let lock = NSLock()

    public init(stream: MessageStream, log: @escaping @Sendable (String) -> Void) { self.stream = stream; self.log = log }
    /// A simulated link (`NetworkThrottle`): each message is sent when it would have arrived. Read on every send.
    public var shaper: (() -> LinkShaper?)?

    public func send(_ message: ControlMessage) {
        if let s = shaper?() {
            let bytes = (try? Frame.encode(message).count) ?? 64
            s.send(bytes: bytes, channel: LinkShaper.Channel.control, reliable: true) { [self] in enqueue(message) }
            return
        }
        enqueue(message)
    }

    private func enqueue(_ message: ControlMessage) {
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

    /// The last message of a session (`streamStop`: the person closed it), after everything queued, past any simulated
    /// link, and returns once it has been handed to the stream (or `timeout` passed). Closing the connection only after
    /// this is what makes the host end the session instead of suspending it as a dropped connection.
    @discardableResult
    public func finish(with message: ControlMessage, timeout: Duration = .seconds(1)) async -> Bool {
        enqueue(message)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            lock.lock(); let idle = pending.isEmpty && task == nil; lock.unlock()
            if idle { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
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

    /// The connection whose throttle (`HostConnection.shaper`) every send goes through.
    weak var link: HostConnection?
    var peerID: String? { link?.deviceID }

    init(flow: MessageStream, tiles: MessageStream?, fastTiles: MessageStream?, control: MessageStream, link: HostConnection? = nil, log: @escaping @Sendable (String) -> Void) {
        self.flow = flow; self.tiles = tiles; self.fastTiles = fastTiles; self.control = ControlSender(stream: control, log: log); self.log = log
        self.link = link
        self.control.shaper = { [weak link] in link?.shaper }
        let m = flow.connection.maximumDatagramSize
        maxDatagramSize = m > 0 ? min(m, VideoFragment.datagramSize) : VideoFragment.datagramSize
        if LossInjector.shared.isActive { log("TEST: dropping datagrams on purpose: \(LossInjector.shared.description)") }
    }

    func sendDatagram(_ data: Data) {
        if LossInjector.shared.shouldDrop() { return }   // test-only (MIRAGE_TEST_LOSS / MIRAGE_TEST_BURST_MS)
        let send = { [flow, log] in
            flow.connection.send(content: data, completion: .contentProcessed { err in
                if let err { log("datagram send: \(err)") }
            })
        }
        if let s = link?.shaper { s.send(bytes: data.count, channel: LinkShaper.Channel.datagrams, reliable: false, send) } else { send() }
    }

    func sendControl(_ message: ControlMessage) { control.send(message) }

    func sendTiles(_ data: Data, fast: Bool) {
        // Network.framework queues sends in order on one connection; no await needed for ordering.
        guard let stream = (fast ? fastTiles : nil) ?? tiles else { return }
        let send = { [log] in
            stream.connection.send(content: data, completion: .contentProcessed { err in
                if let err { log("tile send: \(err)") }
            })
        }
        if let s = link?.shaper { s.send(bytes: data.count, channel: stream === fastTiles ? LinkShaper.Channel.fastTiles : LinkShaper.Channel.tiles, reliable: true, send) } else { send() }
    }
}
