#if os(Linux)
import Foundation
import Crypto
import CMirageQuic

// The Linux host's transport: msquic (through CMirageQuic) in place of Network.framework. The same `MessageStream` API
// the shared host session uses on macOS, over a QUIC stream or over the connection's DATAGRAM flow. Excluded from the
// Apple build (Package.swift); built by linux/Package.swift.

/// Magic first byte of every datagram on the unreliable flow (QUIC.swift on Apple platforms).
public let datagramMagic: UInt8 = 0xD7

/// Async framed I/O over one QUIC stream, or over the datagram flow (one datagram per `receiveSome`).
public final class MessageStream: @unchecked Sendable {
    enum Kind { case stream(UnsafeMutableRawPointer), datagrams }
    let kind: Kind
    let connection: QUICConnection
    private let lock = NSLock()
    /// Bytes pushed back by `unread` (a whole datagram on the datagram flow).
    private var pushback = Data()
    private var bytes = Data()
    private var datagrams: [Data] = []
    private var datagramHead = 0
    private var finished = false
    /// The msquic handle is gone (stream closed): no call may use it.
    private var handleClosed = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(kind: Kind, connection: QUICConnection) { self.kind = kind; self.connection = connection }

    public func start() async throws {}
    public func adoptStarted() {}

    public var maximumDatagramSize: Int { connection.maxDatagram }
    public var remoteDescription: String? { connection.remote }

    // MARK: From msquic's threads

    /// Unread bytes a stream may hold: two whole frames. A peer that sends more than the host reads (any peer, before it
    /// has paired) would otherwise grow the root service without bound; such a stream is aborted.
    static let maxBuffered = 2 * Frame.maxLength + 4096

    func deliver(_ d: Data) {
        lock.lock()
        switch kind {
        case .stream(let h):
            if bytes.count + d.count > Self.maxBuffered {
                let open = !handleClosed && !finished
                finished = true
                bytes = Data()
                let w = waiter; waiter = nil
                lock.unlock()
                if open { mq_stream_abort(h) }
                w?.resume()
                return
            }
            bytes.append(d)
        case .datagrams:
            datagrams.append(d)
            // A reader that fell behind loses the oldest datagrams, as the network would have.
            if datagrams.count - datagramHead > 4096 { datagramHead += 1 }
        }
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume()
    }
    func finish(closingHandle: Bool) {
        lock.lock()
        finished = true
        if closingHandle { handleClosed = true }
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume()
    }

    // MARK: Lifecycle

    public func cancel() {
        lock.lock()
        let wasFinished = finished
        finished = true
        let w = waiter; waiter = nil
        if case .stream(let h) = kind, !handleClosed, !wasFinished { mq_stream_abort(h) }
        lock.unlock()
        w?.resume()
        if case .datagrams = kind { connection.detachFlow(self) }
    }

    // MARK: Raw

    public func sendRaw(_ data: Data) async throws {
        switch kind {
        case .datagrams:
            sendNoWait(data)
        case .stream(let h):
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let box = Unmanaged.passRetained(SendCompletion { canceled in
                    if canceled { c.resume(throwing: MirageError.transport("send: stream closed")) } else { c.resume() }
                }).toOpaque()
                lock.lock()
                let ok = !handleClosed && data.withUnsafeBytes { mq_stream_send(h, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count), box) } == 0
                lock.unlock()
                if !ok {
                    Unmanaged<SendCompletion>.fromOpaque(box).release()
                    c.resume(throwing: MirageError.transport("send: stream closed"))
                }
            }
        }
    }

    /// Sends without waiting: a datagram, or bytes queued in order on a stream. `failed` hears of a send error.
    public func sendNoWait(_ data: Data, failed: (@Sendable (Error) -> Void)? = nil) {
        switch kind {
        case .datagrams:
            if !connection.sendDatagram(data) { failed?(MirageError.transport("datagram send failed")) }
        case .stream(let h):
            let box = Unmanaged.passRetained(SendCompletion { canceled in
                if canceled { failed?(MirageError.transport("send: stream closed")) }
            }).toOpaque()
            lock.lock()
            let ok = !handleClosed && data.withUnsafeBytes { mq_stream_send(h, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count), box) } == 0
            lock.unlock()
            if !ok {
                Unmanaged<SendCompletion>.fromOpaque(box).release()
                failed?(MirageError.transport("send: stream closed"))
            }
        }
    }

    /// Receives whatever is available (at least one byte; one whole datagram on the datagram flow).
    public func receiveSome(max: Int = 65536) async throws -> Data {
        while true {
            lock.lock()
            if !pushback.isEmpty { let d = pushback; pushback = Data(); lock.unlock(); return d }
            switch kind {
            case .stream:
                if !bytes.isEmpty {
                    let d: Data
                    if bytes.count <= max { d = bytes; bytes = Data() } else { d = Data(bytes.prefix(max)); bytes = Data(bytes.dropFirst(max)) }
                    lock.unlock(); return d
                }
            case .datagrams:
                if datagramHead < datagrams.count {
                    let d = datagrams[datagramHead]; datagramHead += 1
                    if datagramHead > 256, datagramHead * 2 > datagrams.count { datagrams.removeFirst(datagramHead); datagramHead = 0 }
                    lock.unlock(); return d
                }
            }
            if finished { lock.unlock(); throw MirageError.transport("stream closed") }
            lock.unlock()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                let ready = !pushback.isEmpty || finished || {
                    switch kind { case .stream: return !bytes.isEmpty; case .datagrams: return datagramHead < datagrams.count }
                }()
                if ready { lock.unlock(); c.resume() } else { waiter = c; lock.unlock() }
            }
        }
    }

    /// Receives exactly `count` bytes.
    public func receiveExactly(_ count: Int) async throws -> Data {
        var acc = Data()
        while acc.count < count {
            let more = try await receiveSome(max: count - acc.count)
            acc.append(more)
        }
        if acc.count > count { unread(Data(acc.suffix(from: acc.startIndex + count))); acc = Data(acc.prefix(count)) }
        return acc
    }

    /// Pushes bytes back so the next receive sees them first.
    public func unread(_ data: Data) { lock.lock(); pushback = data + pushback; lock.unlock() }

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

final class SendCompletion {
    let done: (Bool) -> Void
    init(_ done: @escaping (Bool) -> Void) { self.done = done }
}

/// One QUIC connection: its handle, the datagram flow (made on the first datagram, as Network.framework surfaces it),
/// and its streams.
public final class QUICConnection: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer
    public let id = UUID()
    public let remote: String
    weak var host: QUICHost?
    private let lock = NSLock()
    private var closed = false
    private var flow: MessageStream?
    private var streams: [ObjectIdentifier: MessageStream] = [:]
    private var _maxDatagram = 1200
    var maxDatagram: Int { lock.lock(); defer { lock.unlock() }; return _maxDatagram }

    init(handle: UnsafeMutableRawPointer, remote: String, host: QUICHost) { self.handle = handle; self.remote = remote; self.host = host }

    func sendDatagram(_ d: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        return d.withUnsafeBytes { mq_datagram_send(handle, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) } == 0
    }
    func detachFlow(_ f: MessageStream) { lock.lock(); if flow === f { flow = nil }; lock.unlock() }

    func datagramState(enabled: Bool, maxSend: Int) { lock.lock(); if maxSend > 0 { _maxDatagram = maxSend }; lock.unlock() }

    func received(datagram d: Data) {
        lock.lock()
        if closed { lock.unlock(); return }
        if let f = flow { lock.unlock(); f.deliver(d); return }
        let f = MessageStream(kind: .datagrams, connection: self)
        flow = f
        lock.unlock()
        f.deliver(d)
        host?.opened(f, on: self)
    }

    func opened(stream handle: UnsafeMutableRawPointer) -> MessageStream {
        let s = MessageStream(kind: .stream(handle), connection: self)
        lock.lock(); streams[ObjectIdentifier(s)] = s; lock.unlock()
        host?.opened(s, on: self)
        return s
    }
    func streamClosed(_ s: MessageStream) {
        s.finish(closingHandle: true)
        lock.lock(); streams[ObjectIdentifier(s)] = nil; lock.unlock()
    }
    func didClose() {
        lock.lock(); closed = true; let f = flow; flow = nil; let all = Array(streams.values); lock.unlock()
        f?.finish(closingHandle: false)
        for s in all { s.finish(closingHandle: false) }
    }
}

/// Host side: a QUIC listener on UDP `port`, every stream and the datagram flow handed to `onStream`.
public final class QUICHost: @unchecked Sendable {
    public let tls: TLSIdentity
    public let port: UInt16?
    public var log: (@Sendable (String) -> Void)?
    private var onStream: (@Sendable (MessageStream, UUID, String) -> Void)?

    public init(port: UInt16, tls: TLSIdentity) { self.port = port; self.tls = tls }

    public func start(onStream: @escaping @Sendable (MessageStream, _ connectionID: UUID, _ remote: String) -> Void) throws {
        self.onStream = onStream
        let callbacks = UnsafeMutablePointer<mq_callbacks>.allocate(capacity: 1)   // msquic's for the process lifetime
        callbacks.initialize(to: mq_callbacks(
            conn_open: { hostCtx, conn, remote in
                let host = Unmanaged<QUICHost>.fromOpaque(hostCtx!).takeUnretainedValue()
                let c = QUICConnection(handle: conn!, remote: remote.map { String(cString: $0) } ?? "?", host: host)
                host.log?("inbound QUIC connection from \(c.remote)")
                return Unmanaged.passRetained(c).toOpaque()
            },
            conn_ready: { ctx in
                let c = Unmanaged<QUICConnection>.fromOpaque(ctx!).takeUnretainedValue()
                c.host?.log?("QUIC handshake complete with \(c.remote)")
            },
            conn_closed: { ctx, why in
                let c = Unmanaged<QUICConnection>.fromOpaque(ctx!).takeRetainedValue()
                c.didClose()
            },
            stream_open: { ctx, stream in
                let c = Unmanaged<QUICConnection>.fromOpaque(ctx!).takeUnretainedValue()
                return Unmanaged.passRetained(c.opened(stream: stream!)).toOpaque()
            },
            stream_data: { ctx, data, len in
                let s = Unmanaged<MessageStream>.fromOpaque(ctx!).takeUnretainedValue()
                s.deliver(Data(bytes: data!, count: Int(len)))
            },
            stream_fin: { ctx in
                Unmanaged<MessageStream>.fromOpaque(ctx!).takeUnretainedValue().finish(closingHandle: false)
            },
            stream_closed: { ctx in
                let s = Unmanaged<MessageStream>.fromOpaque(ctx!).takeRetainedValue()
                s.connection.streamClosed(s)
            },
            send_done: { ctx, canceled in
                Unmanaged<SendCompletion>.fromOpaque(ctx!).takeRetainedValue().done(canceled != 0)
            },
            datagram: { ctx, data, len in
                let c = Unmanaged<QUICConnection>.fromOpaque(ctx!).takeUnretainedValue()
                c.received(datagram: Data(bytes: data!, count: Int(len)))
            },
            datagram_state: { ctx, enabled, maxSend in
                Unmanaged<QUICConnection>.fromOpaque(ctx!).takeUnretainedValue().datagramState(enabled: enabled != 0, maxSend: Int(maxSend))
            },
            log: { hostCtx, line in
                Unmanaged<QUICHost>.fromOpaque(hostCtx!).takeUnretainedValue().log?(String(cString: line!))
            }))
        var err = [CChar](repeating: 0, count: 256)
        let ctx = Unmanaged.passRetained(self).toOpaque()
        let rc = mq_host_start(port ?? Mirage.defaultPort, tls.certificatePath, tls.keyPath, Mirage.alpn, UInt32(Mirage.idleTimeoutMs),
                               callbacks, ctx, &err, err.count)
        guard rc == 0 else { throw MirageError.transport(String(cString: err)) }
    }

    func opened(_ s: MessageStream, on c: QUICConnection) { onStream?(s, c.id, c.remote) }
}

/// The host's TLS identity for QUIC: a self-signed P-256 certificate made once with the system openssl, kept as PEM
/// files in the store. Clients never pin it; its SHA-256 fingerprint is a channel binding in the Ed25519 handshake,
/// which is what authenticates both sides.
public struct TLSIdentity {
    public let certificatePath: String
    public let keyPath: String
    public let fingerprint: Data

    public static func loadOrCreate(store: Store) throws -> TLSIdentity {
        let crt = store.url("host-tls-cert.pem").path, key = store.url("host-tls-key.pem").path
        let fm = FileManager.default
        if !(fm.fileExists(atPath: crt) && fm.fileExists(atPath: key)) {
            let host = ProcessInfo.processInfo.hostName
            try run("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                                "-keyout", key, "-out", crt, "-days", "3650", "-subj", "/CN=\(host)/O=Mirage"])
            for f in [key, crt] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f) }
        }
        let pem = try String(contentsOfFile: crt, encoding: .utf8)
        let b64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: b64) else { throw MirageError.storage("unreadable certificate \(crt)") }
        return TLSIdentity(certificatePath: crt, keyPath: key, fingerprint: Data(SHA256.hash(data: der)))
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MirageError.storage("\(tool) \(args.first ?? "") failed: \(msg)")
        }
    }
}
#endif
