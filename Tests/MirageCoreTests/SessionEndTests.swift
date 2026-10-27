import XCTest
@testable import MirageCore

/// Closing a session ends it; only a dropped connection suspends it (phrz, 2026-10-28: closing the Mac viewer left
/// big-mac's session suspended for a day, the curtain up over his other remote tool). The viewer's close sends
/// `streamStop` through `ControlSender.finish` and only then closes the connection, as ViewerSession.stop does.
final class SessionEndTests: XCTestCase {
    final class CountingStreamer: DesktopStreamer, @unchecked Sendable {
        private let lock = NSLock()
        private var _stops = 0, _suspends = 0
        var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
        var suspends: Int { lock.lock(); defer { lock.unlock() }; return _suspends }
        let info = ControlMessage.StreamInfo(width: 512, height: 384, displayID: 1, displayWidth: 256, displayHeight: 192, displayScale: 2, displayName: "test")
        private var _grace: Int?
        var grace: Int? { lock.lock(); defer { lock.unlock() }; return _grace }
        func start(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo { lock.lock(); _grace = request.suspendGraceSeconds; lock.unlock(); return info }
        func resume(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo { info }
        func update(_ request: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo { info }
        func handle(ack: ControlMessage.FrameAck) {}
        func handle(tileAck: ControlMessage.TileAck) {}
        func handle(nack: ControlMessage.Nack) {}
        func handle(input: ControlMessage) {}
        func handle(inputPacket: InputPacket) -> InputAck? { nil }
        func handle(probeEcho sentNanos: UInt64, receivedNanos: UInt64) {}
        func suspend() async { lock.lock(); _suspends += 1; lock.unlock() }
        func stop() async { lock.lock(); _stops += 1; lock.unlock() }
        func cachedBytes() async -> Int { 0 }
        func shedCaches() async {}
    }

    private func setUp(_ streamer: CountingStreamer, grace: Int? = nil) async throws -> (HostContext, QUICHost, () async throws -> (QUICClient, MessageStream)) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-end-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        let viewerID = DeviceIdentity(name: "test-mac")
        try hostStore.authorize(viewerID.record)
        let ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in }, makeStreamer: { streamer })
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "127.0.0.1", pairedAt: Date()), as: "127.0.0.1")
        let connect = { () async throws -> (QUICClient, MessageStream) in
            let client = QUICClient(host: "127.0.0.1", port: port)
            try await client.connect(timeout: Loopback.timeout)
            let control = try await client.openStream()
            let session = ClientSession(identity: viewerID, store: viewerStore, alias: "127.0.0.1", tlsFingerprint: client.tlsFingerprint!, stream: control)
            _ = try await session.authenticate(suspendGraceSeconds: grace)
            let tiles = try await client.openStream(); try await tiles.sendRaw(Data([tileStreamMagic]))
            let fast = try await client.openStream(); try await fast.sendRaw(Data([fastTileStreamMagic]))
            let flow = try await client.openDatagramFlow(); try await flow.sendRaw(DatagramPing.encode(seq: 1))
            try await control.send(.streamRequest(.init(width: 512, height: 384, snapNative: true)))
            _ = try await control.expect("streamInfo") { if case .streamInfo(let i) = $0 { return i } else { return nil } }
            return (client, control)
        }
        return (ctx, host, connect)
    }

    func testClosingTheViewerEndsTheSession() async throws {
        let streamer = CountingStreamer()
        let (ctx, host, connect) = try await setUp(streamer)
        defer { host.stop() }
        let (client, control) = try await connect()
        // The close, as the viewer does it: streamStop handed to the stream, then the connection closed at once.
        let sent = await ControlSender(stream: control, log: { _ in }).finish(with: .streamStop)
        XCTAssertTrue(sent)
        control.cancel(); client.close()   // ViewerSession.dropConnection
        try await Loopback.eventually("the host stopping the stream") { streamer.stops == 1 }
        try await Task.sleep(for: .milliseconds(300))   // the connection's end, after the stop
        XCTAssertEqual(streamer.suspends, 0, "ended, not suspended")
        let suspended = await ctx.connections.suspendedCount
        XCTAssertEqual(suspended, 0, "nothing kept for a resume")
    }

    /// The viewer's "Lock After Suspending" reaches the streamer (for the curtain), clamped; an older viewer's absence is 600 s.
    func testTheSuspendGraceTravelsFromTheHello() async throws {
        for (sent, expected) in [(60, 60), (100_000, 86_400), (-5, 0)] as [(Int, Int)] {
            let s = CountingStreamer()
            let (_, host, connect) = try await setUp(s, grace: sent)
            let (client, control) = try await connect()
            XCTAssertEqual(s.grace, expected)
            control.cancel(); client.close(); host.stop()
        }
        let old = CountingStreamer()
        let (_, host, connect) = try await setUp(old, grace: nil)
        let (client, control) = try await connect()
        XCTAssertEqual(old.grace, 600, "an older viewer: 10 minutes")
        control.cancel(); client.close(); host.stop()
    }

    func testADroppedConnectionSuspends() async throws {
        let streamer = CountingStreamer()
        let (ctx, host, connect) = try await setUp(streamer)
        defer { host.stop() }
        let (client, control) = try await connect()
        control.cancel(); client.close()   // no streamStop: a lost connection, a backgrounded phone (as the viewer's drop)
        try await Loopback.eventually("the host suspending the stream") { streamer.suspends == 1 }
        XCTAssertEqual(streamer.stops, 0)
        let suspended = await ctx.connections.suspendedCount
        XCTAssertEqual(suspended, 1, "kept for the resume window, the curtain up")
    }
}
