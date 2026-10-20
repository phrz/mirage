import Foundation
import Network
import Security

/// Magic first byte of every datagram on the unreliable flow, so a host can tell a
/// datagram flow from a stream even when the per-stream options are not surfaced.
public let datagramMagic: UInt8 = 0xD7

/// Client side: one QUIC connection (an NWConnectionGroup) to a host, from which
/// streams and the datagram flow are extracted.
public final class QUICClient: @unchecked Sendable {
    public let endpoint: NWEndpoint
    public let queue = DispatchQueue(label: "mirage.quic.client")
    private let group: NWConnectionGroup
    private let fingerprintLock = NSLock()
    private var _tlsFingerprint: Data?

    /// SHA-256 of the host's TLS leaf certificate, available once connected.
    public var tlsFingerprint: Data? { fingerprintLock.lock(); defer { fingerprintLock.unlock() }; return _tlsFingerprint }

    public init(host: String, port: UInt16 = Mirage.defaultPort) {
        endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let quic = NWProtocolQUIC.Options(alpn: [Mirage.alpn])
        quic.idleTimeout = Mirage.idleTimeoutMs   // a 30 s outage is not a close (DESIGN §4a); the viewer's stall watchdog acts sooner
        quic.initialMaxStreamsBidirectional = 64
        quic.maxDatagramFrameSize = 1350
        let box = FingerprintBox()
        // Accept any certificate at the TLS layer; record its fingerprint for the
        // channel-bound Ed25519 handshake that follows.
        sec_protocol_options_set_verify_block(quic.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first {
                box.value = TLSIdentity.fingerprint(of: leaf)
            }
            complete(true)
        }, queue)
        let params = NWParameters(quic: quic)
        group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: params)
        // A multiplex group never dials until this handler is set (observed on macOS 27).
        // Host-initiated streams are not part of the protocol yet; refuse them.
        group.newConnectionHandler = { conn in conn.cancel() }
        self.box = box
    }
    private let box: FingerprintBox

    /// `timeout`: a dial that has not completed by then fails. While a session is resumable the viewer
    /// dials with a short timeout and little sleep, so a fresh Initial goes out every couple of seconds
    /// and the path's return is noticed within ~2 s (DESIGN §4a) whatever QUIC's own probe backoff is.
    public func connect(timeout: Double = 15) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var resumed = false
            group.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.fingerprintLock.lock(); self._tlsFingerprint = self.box.value; self.fingerprintLock.unlock()
                    if !resumed { resumed = true; c.resume() }
                case .failed(let e):
                    if !resumed { resumed = true; c.resume(throwing: MirageError.transport("connect failed: \(e)")) }
                case .cancelled:
                    if !resumed { resumed = true; c.resume(throwing: MirageError.transport("connect cancelled")) }
                default: break
                }
            }
            group.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if !resumed { resumed = true; c.resume(throwing: MirageError.transport("connect timed out after \(Int(timeout)) s")) }
            }
        }
    }

    public func openStream() async throws -> MessageStream {
        guard let conn = group.extract() else { throw MirageError.transport("could not open stream") }
        let s = MessageStream(connection: conn, queue: queue)
        try await s.start()
        return s
    }

    /// The single unreliable datagram flow of this connection.
    public func openDatagramFlow() async throws -> MessageStream {
        let opts = NWProtocolQUIC.Options()
        opts.isDatagram = true
        opts.maxDatagramFrameSize = 1350
        guard let conn = group.extract(using: opts) else { throw MirageError.transport("could not open datagram flow") }
        let s = MessageStream(connection: conn, queue: queue)
        try await s.start()
        return s
    }

    public func close() { group.cancel() }
}

final class FingerprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: Data?
    var value: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}

/// Host side: a QUIC listener. Each incoming QUIC connection arrives as a group;
/// each stream (and the datagram flow) on it arrives as an NWConnection.
public final class QUICHost: @unchecked Sendable {
    public let queue = DispatchQueue(label: "mirage.quic.host")
    private let listener: NWListener
    public let tls: TLSIdentity

    public init(port: UInt16, tls: TLSIdentity) throws {
        self.tls = tls
        let quic = NWProtocolQUIC.Options(alpn: [Mirage.alpn])
        quic.idleTimeout = Mirage.idleTimeoutMs   // a 30 s outage is not a close (DESIGN §4a); the viewer's stall watchdog acts sooner
        quic.initialMaxStreamsBidirectional = 64
        quic.maxDatagramFrameSize = 1350
        guard let secIdentity = sec_identity_create(tls.identity) else {
            throw MirageError.storage("sec_identity_create failed")
        }
        sec_protocol_options_set_local_identity(quic.securityProtocolOptions, secIdentity)
        let params = NWParameters(quic: quic)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    /// `onStream` is called on the host queue for every new stream/flow, already started.
    public func start(onStream: @escaping @Sendable (NWConnection, _ connectionID: UUID, _ remote: String) -> Void,
                      onState: @escaping @Sendable (NWListener.State) -> Void) {
        listener.stateUpdateHandler = onState
        listener.newConnectionGroupHandler = { [queue] group in
            let remote = "\(group.descriptor)"
            let id = UUID()   // one per QUIC connection; its streams and datagram flow share it
            group.stateUpdateHandler = { _ in }
            group.newConnectionHandler = { conn in
                conn.start(queue: queue)
                onStream(conn, id, remote)
            }
            group.start(queue: queue)
        }
        // Note: setting newConnectionHandler as well makes the QUIC listener fail with EINVAL.
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }
    /// The port listened on (once ready): the one asked for, or the one the system chose for port 0.
    public var port: UInt16? { listener.port?.rawValue }
}
