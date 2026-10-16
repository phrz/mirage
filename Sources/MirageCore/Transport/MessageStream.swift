import Foundation
import Network

/// Async framed I/O over one QUIC stream (an NWConnection extracted from a group).
public final class MessageStream: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var started = false

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the stream and waits for `.ready`.
    public func start() async throws {
        guard !started else { return }
        started = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; c.resume()
                case .failed(let e): resumed = true; c.resume(throwing: MirageError.transport("stream failed: \(e)"))
                case .cancelled: resumed = true; c.resume(throwing: MirageError.transport("stream cancelled"))
                case .waiting(let e): _ = e // keep waiting; QUIC will retry
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
    }

    /// Marks an already-started connection (from a listener's handler) as started.
    public func adoptStarted() { started = true }

    public func cancel() { connection.cancel() }

    // MARK: Raw

    public func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { c.resume(throwing: MirageError.transport("send: \(err)")) } else { c.resume() }
            })
        }
    }

    /// Receives whatever is available (at least one byte), honouring a local prefetch buffer.
    public func receiveSome(max: Int = 65536) async throws -> Data {
        if !buffer.isEmpty { let d = buffer; buffer.removeAll(); return d }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, complete, err in
                if let err { c.resume(throwing: MirageError.transport("receive: \(err)")); return }
                if let data, !data.isEmpty { c.resume(returning: data); return }
                c.resume(throwing: MirageError.transport(complete ? "stream closed" : "empty receive"))
            }
        }
    }

    /// Receives exactly `count` bytes.
    public func receiveExactly(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let more = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(count - buffer.count, 1)) { data, _, complete, err in
                    if let err { c.resume(throwing: MirageError.transport("receive: \(err)")); return }
                    if let data, !data.isEmpty { c.resume(returning: data); return }
                    c.resume(throwing: MirageError.transport(complete ? "stream closed" : "empty receive"))
                }
            }
            buffer.append(more)
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    /// Pushes bytes back so the next receive sees them first.
    public func unread(_ data: Data) { buffer = data + buffer }

    // MARK: Framed control messages

    public func send(_ message: ControlMessage) async throws {
        try await sendRaw(try Frame.encode(message))
    }

    public func receive() async throws -> ControlMessage {
        let header = try await receiveExactly(4)
        let len = Frame.length(from: header)
        guard len > 0, len <= Frame.maxLength else { throw MirageError.protocolViolation("frame length \(len)") }
        let body = try await receiveExactly(len)
        return try Frame.decode(ControlMessage.self, from: body)
    }

    /// Receives a message and requires it to match; otherwise reports what arrived.
    public func expect<T>(_ what: String, _ extract: (ControlMessage) -> T?) async throws -> T {
        let m = try await receive()
        if let v = extract(m) { return v }
        if case .reject(let r) = m { throw MirageError.authenticationFailed("host rejected: \(r.reason)") }
        throw MirageError.protocolViolation("expected \(what), got \(m)")
    }
}
