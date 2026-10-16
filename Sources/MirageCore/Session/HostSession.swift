import Foundation
import Network
import CryptoKit

public struct HostContext: Sendable {
    public let identity: DeviceIdentity
    public let store: Store
    public let tlsFingerprint: Data
    public let log: @Sendable (String) -> Void
    /// Creates the platform streamer for an authenticated client that asks for the desktop. nil = refuse.
    public let makeStreamer: (@Sendable () -> DesktopStreamer)?
    public let connections = HostConnections()

    public init(identity: DeviceIdentity, store: Store, tlsFingerprint: Data, log: @escaping @Sendable (String) -> Void,
                makeStreamer: (@Sendable () -> DesktopStreamer)? = nil) {
        self.identity = identity; self.store = store; self.tlsFingerprint = tlsFingerprint; self.log = log; self.makeStreamer = makeStreamer
    }
}

/// Handles one incoming stream or datagram flow on the host.
public enum HostSession {
    public static func handle(connection: NWConnection, connectionID: UUID, remote: String, ctx: HostContext) async {
        let stream = MessageStream(connection: connection, queue: DispatchQueue(label: "mirage.host.stream"))
        stream.adoptStarted()
        let remote = connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? remote
        let conn = await ctx.connections.connection(connectionID)
        var isControl = false
        do {
            // Sniff the first byte: 0xD7 = datagram flow, otherwise a framed stream.
            let first = try await stream.receiveSome()
            stream.unread(first)
            if first.first == datagramMagic {
                conn.setFlow(stream)
                defer { conn.clearFlow(stream) }
                try await serveDatagrams(stream, remote: remote, ctx: ctx)
            } else {
                isControl = true
                try await serveStream(stream, conn: conn, remote: remote, ctx: ctx)
            }
        } catch {
            let text = "\(error)"
            // ECONNREFUSED(61)/ENOTCONN(57)/ETIMEDOUT(60)/cancelled are how QUIC stream closes surface; keep them quiet.
            if text.contains("rawValue: 61") || text.contains("rawValue: 57") || text.contains("rawValue: 60") || text.contains("cancelled") || text.contains("stream closed") {
                ctx.log("[\(remote)] closed")
            } else {
                ctx.log("[\(remote)] closed: \(error)")
            }
        }
        // The control stream owns the session: only its end tears the streamer and the registry entry
        // down. A datagram flow ending on its own just clears itself (see clearFlow), so the next
        // streamRequest waits for a fresh flow instead of sending into a dead one.
        if isControl {
            if let s = conn.streamer { conn.streamer = nil; await s.stop(); ctx.log("[\(remote)] stream stopped") }
            _ = await ctx.connections.remove(connectionID)
        } else if conn.streamer != nil {
            ctx.log("[\(remote)] datagram flow closed while streaming")
        }
        stream.cancel()
    }

    static func serveDatagrams(_ flow: MessageStream, remote: String, ctx: HostContext) async throws {
        ctx.log("[\(remote)] datagram flow open (max datagram \(flow.connection.maximumDatagramSize))")
        while true {
            let d = try await flow.receiveSome()
            guard d.count >= 2, d[d.startIndex] == datagramMagic else { continue }
            if d[d.startIndex + 1] == DatagramType.ping.rawValue {
                try await flow.sendRaw(d)   // echo verbatim; client computes RTT and loss
            }
        }
    }

    static func serveStream(_ stream: MessageStream, conn: HostConnection, remote: String, ctx: HostContext) async throws {
        var authenticated: DeviceRecord?
        var output: ConnectionOutput?
        while true {
            let msg = try await stream.receive()
            switch msg {
            case .hello(let hello):
                authenticated = try await authenticate(hello, stream, remote: remote, ctx: ctx)
            case .pairRequest(let req):
                try await pair(req, stream, remote: remote, ctx: ctx)
            case .ping(var p):
                guard authenticated != nil else { throw MirageError.protocolViolation("ping before auth") }
                p.echoNanos = Clock.nowNanos()
                if let output { output.sendControl(.pong(p)) } else { try await stream.send(.pong(p)) }
            case .streamRequest(let req):
                guard authenticated != nil else { throw MirageError.protocolViolation("streamRequest before auth") }
                if let s = conn.streamer, let out = output, conn.flow === out.flow {
                    do { out.sendControl(.streamInfo(try await s.update(req))) }
                    catch { ctx.log("[\(remote)] stream update failed: \(error)"); out.sendControl(.reject(.init(reason: "cannot reconfigure stream: \(error)"))) }
                } else {
                    if let s = conn.streamer { conn.streamer = nil; await s.stop(); output = nil }   // flow died; start over
                    guard let make = ctx.makeStreamer else {
                        try await stream.send(.reject(.init(reason: "host cannot stream"))); continue
                    }
                    guard let flow = await conn.waitForFlow(timeout: .seconds(5)) else {
                        try await stream.send(.reject(.init(reason: "no datagram flow"))); continue
                    }
                    let out = ConnectionOutput(flow: flow, control: stream, log: ctx.log)
                    output = out
                    let s = make()
                    do {
                        let info = try await s.start(req, output: out)
                        conn.streamer = s
                        ctx.log("[\(remote)] streaming \(info.displayName) \(info.width)x\(info.height) @ \(req.bitrateKbps) kbps, datagrams ≤\(out.maxDatagramSize)")
                        out.sendControl(.streamInfo(info))
                    } catch {
                        await s.stop()
                        let why = HostPermissionHint.explain(error)
                        ctx.log("[\(remote)] stream failed: \(error)\(why.map { " — \($0)" } ?? "")")
                        out.sendControl(.reject(.init(reason: "cannot stream: \(why ?? "\(error)")")))
                    }
                }
            case .streamStop:
                if let s = conn.streamer { conn.streamer = nil; await s.stop() }
            case .frameAck(let ack):
                conn.streamer?.handle(ack: ack)
            case .mouseMove, .mouseButton, .scroll, .key, .modifiers:
                guard authenticated != nil else { throw MirageError.protocolViolation("input before auth") }
                conn.streamer?.handle(input: msg)
            default:
                throw MirageError.protocolViolation("unexpected \(msg)")
            }
        }
    }

    // MARK: Authentication of a paired device

    static func authenticate(_ hello: ControlMessage.Hello, _ stream: MessageStream, remote: String, ctx: HostContext) async throws -> DeviceRecord {
        guard hello.protocolVersion == Mirage.protocolVersion else {
            try await stream.send(.reject(.init(reason: "protocol version \(hello.protocolVersion) unsupported")))
            throw MirageError.protocolViolation("version")
        }
        let hostNonce = DeviceIdentity.nonce()
        let hostTranscript = DeviceIdentity.hostAuthTranscript(tlsFingerprint: ctx.tlsFingerprint, clientNonce: hello.clientNonce, hostNonce: hostNonce, clientID: hello.deviceID)
        try await stream.send(.challenge(.init(hostID: ctx.identity.id, hostName: ctx.identity.name,
                                               hostPublicKey: ctx.identity.publicKey, hostNonce: hostNonce,
                                               hostSignature: try ctx.identity.sign(hostTranscript))))
        let auth = try await stream.expect("authenticate") { if case .authenticate(let a) = $0 { return a } else { return nil } }

        let claimedID = DeviceIdentity.id(forPublicKey: auth.clientPublicKey)
        guard claimedID == hello.deviceID,
              let device = try ctx.store.authorizedDevices().first(where: { $0.id == claimedID && $0.publicKey == auth.clientPublicKey }) else {
            ctx.log("[\(remote)] rejected unknown device \(hello.deviceID.prefix(12)) (\(hello.deviceName))")
            try await stream.send(.reject(.init(reason: "device not paired")))
            throw MirageError.authenticationFailed("unknown device")
        }
        let clientTranscript = DeviceIdentity.clientAuthTranscript(tlsFingerprint: ctx.tlsFingerprint, clientNonce: hello.clientNonce, hostNonce: hostNonce, hostID: ctx.identity.id)
        guard DeviceIdentity.verify(signature: auth.clientSignature, message: clientTranscript, publicKey: device.publicKey) else {
            ctx.log("[\(remote)] bad signature from \(device.name)")
            try await stream.send(.reject(.init(reason: "bad signature")))
            throw MirageError.authenticationFailed("signature")
        }
        let session = UUID().uuidString
        try await stream.send(.welcome(.init(hostName: ctx.identity.name, sessionID: session)))
        ctx.log("[\(remote)] authenticated \(device.name) (\(device.id.prefix(12)))")
        return device
    }

    // MARK: Pairing

    static func pair(_ req: ControlMessage.PairRequest, _ stream: MessageStream, remote: String, ctx: HostContext) async throws {
        guard let pending = try ctx.store.consumePendingPairing() else {
            ctx.log("[\(remote)] pairing attempt by \(req.deviceName) with no code pending")
            try await stream.send(.reject(.init(reason: "no pairing in progress on host; run `miraged pair`")))
            throw MirageError.pairingFailed("no pending code")
        }
        func fail(_ why: String) async throws -> Never {
            try? ctx.store.setPairingResult(attemptID: pending.attemptID, ok: false, message: why)
            ctx.log("[\(remote)] pairing failed: \(why)")
            try await stream.send(.reject(.init(reason: why)))
            throw MirageError.pairingFailed(why)
        }
        let sid = CPace.newSessionID()
        let channel = lv(ctx.tlsFingerprint) + lv(Data(ctx.identity.name.utf8))
        let cpace = try CPace(password: pending.code, channelID: channel, sid: sid)
        let mine = try cpace.makeShare()
        try await stream.send(.pairChallenge(.init(sid: sid, hostName: ctx.identity.name, share: mine.publicShare)))

        let confirm = try await stream.expect("pairConfirm") { if case .pairConfirm(let c) = $0 { return c } else { return nil } }
        let isk: SymmetricKey
        do { isk = try cpace.sessionKey(own: mine, peer: confirm.share, initiatorShare: confirm.share, responderShare: mine.publicShare) }
        catch { try await fail("invalid share") }
        guard CPace.verifyTag(confirm.tag, isk: isk, role: "A", initiatorShare: confirm.share, responderShare: mine.publicShare) else {
            try await fail("wrong code")
        }
        try await stream.send(.pairAccept(.init(tag: CPace.confirmationTag(isk: isk, role: "B", initiatorShare: confirm.share, responderShare: mine.publicShare))))

        let key = CPace.pairingKey(isk: isk)
        let sealed = try await stream.expect("pairIdentity") { if case .pairIdentity(let p) = $0 { return p } else { return nil } }
        var device = try SealedBox.open(DeviceRecord.self, sealed.sealed, key: key)
        guard device.id == DeviceIdentity.id(forPublicKey: device.publicKey), device.publicKey.count == 32 else {
            try await fail("malformed identity")
        }
        device.pairedAt = Date()
        try ctx.store.authorize(device)
        try await stream.send(.pairComplete(.init(sealed: try SealedBox.seal(ctx.identity.record, key: key))))
        try ctx.store.setPairingResult(attemptID: pending.attemptID, ok: true, message: "paired \(device.name) (\(device.id.prefix(12)))")
        ctx.log("[\(remote)] paired \(device.name) (\(device.id.prefix(12)))")
    }
}


/// Turns the usual TCC failures into an instruction the viewer can show.
public enum HostPermissionHint {
    public static func explain(_ error: Error) -> String? {
        let t = "\(error)"
        // SCStream errors: -3801 = user declined / no Screen Recording permission.
        if t.contains("-3801") || t.contains("3801") || t.contains("not authorized") || t.contains("TCC") {
            return "host is missing Screen Recording permission: on the host open System Settings → Privacy & Security → Screen & System Audio Recording and enable miraged, then restart it"
        }
        return nil
    }
}
