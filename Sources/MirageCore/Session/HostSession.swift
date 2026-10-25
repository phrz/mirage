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
    /// The pairing window and the Allow/Deny question, set by the host's UI (DESIGN §3.1 pairing).
    public let pairing = PairingSlot()
    /// What the Welcome says about updates (DESIGN §3.10): the newest build the last feed check found, and the policy.
    /// Set by the host (`miraged`), read at each authentication; nil = nothing to report.
    public var updateInfo: (@Sendable () -> HostUpdateInfo)?

    public init(identity: DeviceIdentity, store: Store, tlsFingerprint: Data, log: @escaping @Sendable (String) -> Void,
                makeStreamer: (@Sendable () -> DesktopStreamer)? = nil) {
        self.identity = identity; self.store = store; self.tlsFingerprint = tlsFingerprint; self.log = log; self.makeStreamer = makeStreamer
    }
}

/// The host's update state for its Welcome.
public struct HostUpdateInfo: Sendable {
    public var latestAvailable: MirageVersion?
    public var permission: UpdatePermission?
    public init(latestAvailable: MirageVersion?, permission: UpdatePermission?) { self.latestAvailable = latestAvailable; self.permission = permission }
}

/// Handles one incoming stream or datagram flow on the host.
public enum HostSession {
    /// The viewer's tunables (Tunables), after every streamInfo, to viewers that asked for them: the defaults overridden by
    /// `tunables.json` in the store directory, read each time (retuned without a restart).
    static func sendTunables(_ out: ConnectionOutput, _ req: ControlMessage.StreamRequest, _ ctx: HostContext) {
        guard req.tunablesVersion != nil else { return }
        let (t, error) = Tunables.load(from: Tunables.hostFileURL(ctx.store))
        if let error { ctx.log(error) }
        out.sendControl(.tunables(t))
    }

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
                try await serveDatagrams(stream, conn: conn, remote: remote, ctx: ctx)
            } else if first.first == tileStreamMagic || first.first == fastTileStreamMagic {
                let fast = first.first == fastTileStreamMagic
                _ = try await stream.receiveExactly(1)
                if fast { conn.setFastTiles(stream) } else { conn.setTiles(stream) }
                defer { if fast { conn.clearFastTiles(stream) } else { conn.clearTiles(stream) } }
                ctx.log("[\(remote)] \(fast ? "interactive" : "refinement") tile stream open")
                while true { _ = try await stream.receiveSome() }   // nothing expected client → host; detects close
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
        // streamRequest waits for a fresh flow instead of sending into a dead one. A streamer whose
        // connection ended is suspended, not stopped: the viewer may be back with the resume token
        // within the window (an outage, an IP change, a laptop lid), and then gets the same session.
        if isControl {
            if let s = conn.streamer {
                conn.streamer = nil
                if let token = conn.resumeToken, let dev = conn.deviceID, !conn.superseded {
                    await ctx.connections.suspend(token: token, deviceID: dev, streamer: s, request: conn.lastRequest)
                    ctx.log("[\(remote)] stream suspended; resumable for \(Mirage.resumeWindowSeconds) s")
                } else {
                    await s.stop(); ctx.log("[\(remote)] stream stopped")
                }
            }
            _ = await ctx.connections.remove(connectionID)
        } else if conn.streamer != nil {
            ctx.log("[\(remote)] datagram flow closed while streaming")
        }
        stream.cancel()
    }

    static func serveDatagrams(_ flow: MessageStream, conn: HostConnection, remote: String, ctx: HostContext) async throws {
        ctx.log("[\(remote)] datagram flow open (max datagram \(flow.connection.maximumDatagramSize))")
        while true {
            let d = try await flow.receiveSome()
            guard d.count >= 2, d[d.startIndex] == datagramMagic else { continue }
            switch d[d.startIndex + 1] {
            case DatagramType.ping.rawValue:
                if let p = DatagramPing.decode(d), p.echoNanos != 0 {
                    conn.streamer?.handle(probeEcho: p.sentNanos, receivedNanos: p.echoNanos)   // the viewer's reply to a host delay probe
                } else if conn.shaper != nil {
                    conn.sendDatagram(DatagramPing.echo(d), on: flow)   // through the simulated link, as everything else
                } else {
                    try await flow.sendRaw(DatagramPing.echo(d))   // the viewer's keepalive: RTT, loss and clock offset
                }
            case DatagramType.input.rawValue:
                // Input with redundancy (see InputPacket): the streamer applies it once and says what to ack.
                guard conn.deviceID != nil, let p = InputPacket.decode(d), let ack = conn.streamer?.handle(inputPacket: p) else { continue }
                if conn.shaper != nil { conn.sendDatagram(ack.encode(), on: flow) } else { try await flow.sendRaw(ack.encode()) }
            default: continue
            }
        }
    }

    static func serveStream(_ stream: MessageStream, conn: HostConnection, remote: String, ctx: HostContext) async throws {
        var authenticated: DeviceRecord?
        var output: ConnectionOutput?
        var pendingInterest: ControlMessage.ViewInterest?
        while true {
            let msg = try await stream.receive()
            switch msg {
            case .hello(let hello):
                authenticated = try await authenticate(hello, stream, conn: conn, remote: remote, ctx: ctx)
            case .pairRequest(let req):
                try await pair(req, stream, remote: remote, ctx: ctx)
            case .ping(var p):
                guard authenticated != nil else { throw MirageError.protocolViolation("ping before auth") }
                p.echoNanos = Clock.nowNanos()
                if let output { output.sendControl(.pong(p)) } else { try await stream.send(.pong(p)) }
            case .streamRequest(let asked):
                guard authenticated != nil else { throw MirageError.protocolViolation("streamRequest before auth") }
                // Automatic bitrate (BitratePolicy): 0, or an older viewer's unchosen 800, becomes the host's ceiling and the
                // controller probes up to it; the streamer sees the resolved request. The throttle shapes this connection.
                let hostMax = Int(Tunables.load(from: Tunables.hostFileURL(ctx.store)).tunables[.autoMaxKbps])
                let req = BitratePolicy.resolved(asked, hostMaxKbps: hostMax)
                let bitrate = BitratePolicy.describe(asked, hostMaxKbps: hostMax)
                if let line = conn.setThrottle(asked.throttle) { ctx.log("[\(remote)] \(line)") }
                conn.lastRequest = req
                if let s = conn.streamer, let out = output, conn.flow === out.flow, conn.tiles === out.tiles {
                    do { out.sendControl(.streamInfo(try await s.update(req))); Self.sendTunables(out, req, ctx) }
                    catch { ctx.log("[\(remote)] stream update failed: \(error)"); out.sendControl(.reject(.init(reason: "cannot reconfigure stream: \(error)"))) }
                } else {
                    let resuming = conn.resumed && conn.streamer != nil && output == nil
                    if let s = conn.streamer, !resuming { conn.streamer = nil; await s.stop(); output = nil }   // flow died; start over
                    guard let make = ctx.makeStreamer else {
                        try await stream.send(.reject(.init(reason: "host cannot stream"))); continue
                    }
                    guard let flow = await conn.waitForFlow(timeout: .seconds(5)) else {
                        try await stream.send(.reject(.init(reason: "no datagram flow"))); continue
                    }
                    let tiles = await conn.waitForTiles(timeout: .seconds(5))
                    if tiles == nil { ctx.log("[\(remote)] no tile stream; lossless tiles disabled") }
                    let fast = await conn.waitForFastTiles(timeout: .seconds(2))
                    let out = ConnectionOutput(flow: flow, tiles: tiles, fastTiles: fast, control: stream, link: conn, log: ctx.log)
                    output = out
                    if resuming, let s = conn.streamer {
                        conn.resumed = false
                        do {
                            let info = try await s.resume(req, output: out)
                            ctx.log("[\(remote)] resumed \(info.displayName) \(info.width)x\(info.height), bitrate \(bitrate)")
                            out.sendControl(.streamInfo(info)); Self.sendTunables(out, req, ctx)
                        } catch {
                            ctx.log("[\(remote)] resume failed: \(error); starting over")
                            conn.streamer = nil; await s.stop()
                            out.sendControl(.reject(.init(reason: "cannot resume stream: \(error)")))
                        }
                        continue
                    }
                    let s = make()
                    do {
                        let info = try await s.start(req, output: out)
                        conn.streamer = s
                        if let v = pendingInterest { s.handle(input: .viewInterest(v)) }
                        ctx.log("[\(remote)] streaming \(info.displayName) \(info.width)x\(info.height), bitrate \(bitrate), datagrams ≤\(out.maxDatagramSize)")
                        out.sendControl(.streamInfo(info)); Self.sendTunables(out, req, ctx)
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
            case .tileAck(let ack):
                conn.streamer?.handle(tileAck: ack)
            case .tileReceived(let ack):
                conn.streamer?.handle(tileReceived: ack)
            case .nack(let n):
                conn.streamer?.handle(nack: n)
            case .viewInterest(let v):
                // What the viewer shows (Unified mode); kept for a streamer started later on this connection.
                guard authenticated != nil else { throw MirageError.protocolViolation("input before auth") }
                pendingInterest = v
                conn.streamer?.handle(input: msg)
            case .mouseMove, .mouseButton, .scroll, .key, .modifiers, .windowCommand, .refreshTiles, .menuRequest, .menuPress, .iconRequest, .appCommand:
                guard authenticated != nil else { throw MirageError.protocolViolation("input before auth") }
                conn.streamer?.handle(input: msg)
            default:
                throw MirageError.protocolViolation("unexpected \(msg)")
            }
        }
    }

    // MARK: Authentication of a paired device

    static func authenticate(_ hello: ControlMessage.Hello, _ stream: MessageStream, conn: HostConnection, remote: String, ctx: HostContext) async throws -> DeviceRecord {
        // Protocol range (DESIGN §3.10): a mixed fleet works; only a viewer too old for this host, or one that needs more
        // than this host speaks, is refused, with a code saying which side to update.
        if let code = ProtocolCompat.check(viewerProtocol: hello.protocolVersion, viewerMinProtocol: hello.minProtocolVersion) {
            let host = MirageVersion.current
            let viewer = hello.viewerVersion.map { " \($0.display)" } ?? ""
            let reason = code == .viewerTooOld
                ? "this viewer\(viewer) (protocol \(hello.protocolVersion)) is too old for \(ctx.identity.name) (Mirage \(host.display), protocol \(Mirage.minProtocolVersion)–\(Mirage.protocolVersion)): update the viewer"
                : "\(ctx.identity.name) (Mirage \(host.display), protocol \(Mirage.protocolVersion)) is too old for this viewer\(viewer) (needs protocol \(hello.minProtocolVersion ?? hello.protocolVersion)): update \(ctx.identity.name)"
            ctx.log("[\(remote)] refused \(hello.deviceName): \(reason)")
            try await stream.send(.reject(.init(reason: reason, code: code, hostVersion: host)))
            throw MirageError.protocolViolation("version")
        }
        // Auth timing (M-FIVE: ~320 ms of a connect is authentication on the viewer's clock): each step, logged with the welcome.
        let a0 = Clock.nowNanos()
        func ms() -> UInt64 { Clock.elapsed(since: a0, now: Clock.nowNanos()) / 1_000_000 }
        let hostNonce = DeviceIdentity.nonce()
        let hostTranscript = DeviceIdentity.hostAuthTranscript(tlsFingerprint: ctx.tlsFingerprint, clientNonce: hello.clientNonce, hostNonce: hostNonce, clientID: hello.deviceID)
        try await stream.send(.challenge(.init(hostID: ctx.identity.id, hostName: ctx.identity.name,
                                               hostPublicKey: ctx.identity.publicKey, hostNonce: hostNonce,
                                               hostSignature: try ctx.identity.sign(hostTranscript))))
        let tChallenge = ms()
        let auth = try await stream.expect("authenticate") { if case .authenticate(let a) = $0 { return a } else { return nil } }
        let tAuth = ms()

        let claimedID = DeviceIdentity.id(forPublicKey: auth.clientPublicKey)
        guard claimedID == hello.deviceID,
              var device = try ctx.store.authorizedDevices().first(where: { $0.id == claimedID && $0.publicKey == auth.clientPublicKey }) else {
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
        // The device's model (its icon in the menu-bar item's list), kept current: older pairings carry none.
        if let m = hello.deviceModel, !m.isEmpty, m != device.model {
            device.model = m
            try? ctx.store.updateAuthorized(device)
        }
        let session = UUID().uuidString
        // Resume: a token from an earlier Welcome names a session whose streamer the host kept (or still
        // holds on a connection the viewer gave up on). Authentication ran in full above regardless.
        var resumed = false
        if let token = hello.resumeToken, let claimed = await ctx.connections.claim(token: token, deviceID: device.id, by: conn.id) {
            conn.streamer = claimed.streamer; conn.resumed = true; conn.lastRequest = claimed.request; resumed = true
        }
        let token = resumed ? conn.resumeToken! : await ctx.connections.issueToken(for: conn.id, deviceID: device.id)
        let updates = ctx.updateInfo?()
        try await stream.send(.welcome(.init(hostName: ctx.identity.name, sessionID: session, resumeToken: token, resumed: resumed, hostBuild: BuildInfo.current,
                                             hostModel: DeviceModel.current, hostFamily: DeviceModel.currentFamily?.rawValue,
                                             hostVersion: .current, latestAvailable: updates?.latestAvailable, updatePolicy: updates?.permission,
                                             protocolVersion: Mirage.protocolVersion)))
        ctx.log("[\(remote)] auth timing: challenge sent at \(tChallenge) ms, authenticate in at \(tAuth) ms, welcome sent at \(ms()) ms (from the hello)")
        ctx.log("[\(remote)] authenticated \(device.name) (\(device.id.prefix(12)))\(resumed ? ", resuming its session" : hello.resumeToken != nil ? " (resume token unknown or expired: new session)" : "")")
        return device
    }

    // MARK: Pairing

    static func pair(_ req: ControlMessage.PairRequest, _ stream: MessageStream, remote: String, ctx: HostContext) async throws {
        ctx.log("[\(remote)] pair request from \(req.deviceName) (\(req.secret ?? false ? "link" : "code"), protocol \(req.protocolVersion), this host \(Mirage.protocolVersion))")
        // The password: from the open "Pair a Device…" window (code or link secret, single use: taking it rotates both), else
        // a code `miraged pair` left (code only).
        let usesSecret = req.secret ?? false
        var password: String? = nil
        var attemptID: String? = nil
        if let w = ctx.pairing.window, w.isOpen() { password = w.takePassword(secret: usesSecret) }
        else if !usesSecret, let pending = try ctx.store.consumePendingPairing() { password = pending.code; attemptID = pending.attemptID }
        guard let password else {
            ctx.log("[\(remote)] pairing attempt by \(req.deviceName) (\(usesSecret ? "link" : "code")) with no pairing open")
            try await stream.send(.reject(.init(reason: usesSecret ? "that pairing code has expired; show a fresh one on the Mac" : "no pairing in progress on host; choose Pair a Device… in its menu bar (or run `miraged pair`)")))
            throw MirageError.pairingFailed("no pairing open")
        }
        func fail(_ why: String) async throws -> Never {
            if let attemptID { try? ctx.store.setPairingResult(attemptID: attemptID, ok: false, message: why) }
            ctx.log("[\(remote)] pairing failed: \(why)")
            try await stream.send(.reject(.init(reason: why)))
            throw MirageError.pairingFailed(why)
        }
        let sid = CPace.newSessionID()
        let channel = lv(ctx.tlsFingerprint) + lv(Data(ctx.identity.name.utf8))
        let cpace = try CPace(password: password, channelID: channel, sid: sid)
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
        // Asked on the host before anything is authorized, code and link alike: the Mirage app's Allow/Deny (local control),
        // else the terminal that ran `miraged pair`, else denied.
        ctx.log("[\(remote)] \(device.name) (\(device.id.prefix(12))) wants to pair; asking on the host")
        var answer: Bool? = nil
        if let confirm = ctx.pairing.confirm { answer = await confirm(device) }
        if answer == nil, let attemptID { answer = await askPairTerminal(ctx.store, attemptID: attemptID, device: device) }
        let allowed = answer ?? false
        guard allowed else { try await fail("denied on the host") }
        device.pairedAt = Date()
        try ctx.store.authorize(device)
        try await stream.send(.pairComplete(.init(sealed: try SealedBox.seal(ctx.identity.record, key: key))))
        if let attemptID { try ctx.store.setPairingResult(attemptID: attemptID, ok: true, message: "paired \(device.name) (\(device.id.prefix(12)))") }
        ctx.pairing.paired?(device)
        ctx.log("[\(remote)] paired \(device.name) (\(device.id.prefix(12)))")
    }

    /// `miraged pair`'s Allow/Deny: the request goes to its terminal through the store; no answer in 60 s is a deny.
    static func askPairTerminal(_ store: Store, attemptID: String, device: DeviceRecord) async -> Bool {
        try? store.setPairingConfirmRequest(.init(attemptID: attemptID, deviceName: device.name, deviceID: device.id))
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let d = try? store.takePairingDecision(attemptID: attemptID) { return d }
            try? await Task.sleep(for: .milliseconds(200))
        }
        _ = try? store.takePairingConfirmRequest(attemptID: attemptID)
        return false
    }
}


/// Turns the usual TCC failures into an instruction the viewer can show.
public enum HostPermissionHint {
    public static func explain(_ error: Error) -> String? {
        let t = "\(error)"
        // SCStream errors: -3801 = user declined / no Screen Recording permission.
        if t.contains("-3801") || t.contains("3801") || t.contains("not authorized") || t.contains("TCC") {
            return "host is missing Screen Recording permission: on the host open \(PrivacyPane.path(PrivacyPane.screenRecording)) and enable miraged, then restart it"
        }
        return nil
    }
}
