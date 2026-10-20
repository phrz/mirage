import XCTest
import Network
@testable import MirageCore

/// A resumed session must leave the viewer with a picture, also when the viewer holds none: the iOS app relaunches with
/// its saved resume token and empty canvases, and the host, believing the viewer kept its picture, sent only a keyframe
/// masked to the tiles it did not hold crisp plus unchanged diffs (grey until the stream size changed).
final class ResumePictureTests: XCTestCase {
    func testPlan() {
        XCTAssertEqual(ResumePicture.plan(sizeChanged: false, viewerHoldsPicture: true, hasEncoder: true), .bringCurrent)
        XCTAssertEqual(ResumePicture.plan(sizeChanged: false, viewerHoldsPicture: nil, hasEncoder: true), .bringCurrent, "older viewers kept their picture")
        XCTAssertEqual(ResumePicture.plan(sizeChanged: false, viewerHoldsPicture: false, hasEncoder: true), .fresh(.viewerEmpty))
        XCTAssertEqual(ResumePicture.plan(sizeChanged: true, viewerHoldsPicture: true, hasEncoder: true), .fresh(.resize))
        XCTAssertEqual(ResumePicture.plan(sizeChanged: false, viewerHoldsPicture: true, hasEncoder: false), .fresh(.streamStart))
        XCTAssertTrue(FreshPictureTrigger.viewerEmpty.restartsWholePicture)
        // No reconnect penalty: a viewer that holds nothing gets a fresh picture from the same controller, tier and rung.
        XCTAssertTrue(ResumePicture.fresh(.viewerEmpty).keepsController)
        XCTAssertFalse(ResumePicture.fresh(.resize).keepsController)
    }

    func testStreamRequestWire() throws {
        let r = ControlMessage.StreamRequest(width: 100, height: 50, snapNative: true, holdsPicture: false)
        let back = try JSONDecoder().decode(ControlMessage.StreamRequest.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.holdsPicture, false)
        // A request from an older viewer has no such field: it decodes as nil (held).
        let old = try JSONDecoder().decode(ControlMessage.StreamRequest.self, from: Data(#"{"width":100,"height":50,"bitrateKbps":800,"maxFPS":30}"#.utf8))
        XCTAssertNil(old.holdsPicture)
        let framed = try Frame.encode(ControlMessage.streamRequest(r))
        XCTAssertGreaterThan(framed.count, 0)
    }

    /// The host side of a picture, as `MacDesktopStreamer` keeps it: which tiles the viewer holds crisp, and what a start
    /// or a resume sends (decided by the same `ResumePicture.plan`). The viewer's canvas is the shared `viewer` set.
    final class PictureStreamer: DesktopStreamer, @unchecked Sendable {
        let tiles = 48
        let lock = NSLock()
        private(set) var viewerCrisp = Set<Int>()   // the host's belief
        var viewer = Set<Int>()                     // what the viewer actually holds
        private(set) var resumes: [ControlMessage.StreamRequest] = []
        private(set) var plans: [ResumePicture] = []
        let info = ControlMessage.StreamInfo(width: 512, height: 384, displayID: 1, displayWidth: 256, displayHeight: 192, displayScale: 2, displayName: "test")
        private func send(_ t: Set<Int>) { viewer.formUnion(t); viewerCrisp.formUnion(t) }
        func start(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
            lock.lock(); defer { lock.unlock() }
            viewerCrisp = []; send(Set(0..<tiles)); return info
        }
        func resume(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
            lock.lock(); defer { lock.unlock() }
            resumes.append(request)
            let plan = ResumePicture.plan(sizeChanged: false, viewerHoldsPicture: request.holdsPicture, hasEncoder: true)
            plans.append(plan)
            switch plan {
            case .bringCurrent: send(Set(0..<tiles).subtracting(viewerCrisp))   // masked keyframe; the diffs are empty (nothing changed)
            case .fresh: viewerCrisp = []; send(Set(0..<tiles))
            }
            return info
        }
        func update(_ request: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo { info }
        func handle(ack: ControlMessage.FrameAck) {}
        func handle(tileAck: ControlMessage.TileAck) {}
        func handle(nack: ControlMessage.Nack) {}
        func handle(input: ControlMessage) {}
        func handle(inputPacket: InputPacket) -> InputAck? { nil }
        func handle(probeEcho sentNanos: UInt64, receivedNanos: UInt64) {}
        func suspend() async {}
        func stop() async {}
        func cachedBytes() async -> Int { 0 }
        func shedCaches() async {}
        func relaunchViewer() { lock.lock(); viewer = []; lock.unlock() }
        var viewerTiles: Int { lock.lock(); defer { lock.unlock() }; return viewer.count }
        var lastPlan: ResumePicture? { lock.lock(); defer { lock.unlock() }; return plans.last }
        var lastResume: ControlMessage.StreamRequest? { lock.lock(); defer { lock.unlock() }; return resumes.last }
    }

    /// Loopback QUIC, the real host session and handshake: connect, stream, drop the connection, come back with the token.
    func testResumeAfterRelaunchSendsAFreshPicture() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        let viewerID = DeviceIdentity(name: "test-phone")
        try hostStore.authorize(viewerID.record)
        let streamer = PictureStreamer()
        let ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in }, makeStreamer: { streamer })
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        defer { host.stop() }
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "127.0.0.1", pairedAt: Date()), as: "127.0.0.1")

        /// One viewer connection, as ViewerSession makes it: authenticate (with the token), streams, flow, stream request.
        func connect(token: Data?, holdsPicture: Bool?) async throws -> (QUICClient, ControlMessage.Welcome) {
            let client = QUICClient(host: "127.0.0.1", port: port)
            try await client.connect(timeout: Loopback.timeout)
            let control = try await client.openStream()
            let session = ClientSession(identity: viewerID, store: viewerStore, alias: "127.0.0.1", tlsFingerprint: client.tlsFingerprint!, stream: control)
            let welcome = try await session.authenticate(resumeToken: token)
            let tiles = try await client.openStream(); try await tiles.sendRaw(Data([tileStreamMagic]))
            let fast = try await client.openStream(); try await fast.sendRaw(Data([fastTileStreamMagic]))
            let flow = try await client.openDatagramFlow(); try await flow.sendRaw(DatagramPing.encode(seq: 1))
            try await control.send(.streamRequest(.init(width: 512, height: 384, snapNative: true, holdsPicture: holdsPicture)))
            _ = try await control.expect("streamInfo") { if case .streamInfo(let i) = $0 { return i } else { return nil } }
            return (client, welcome)
        }

        // 1. A new session: the whole picture.
        let (c1, w1) = try await connect(token: nil, holdsPicture: false)
        XCTAssertNotEqual(w1.resumed, true)
        XCTAssertEqual(streamer.viewerTiles, 48)
        let token = try XCTUnwrap(w1.resumeToken)
        // No wait for the host to notice: a token claims the session whether the host has suspended it already or still
        // holds it for the old connection (HostConnections.claim). A fixed 300 ms sleep here was a wall-clock guess.
        c1.close()

        // 2. The bug: the app relaunched (empty canvases) and resumed with a request that did not say so. The host
        // brought a "kept" picture current: nothing to send, the viewer stays empty (grey).
        streamer.relaunchViewer()
        let (c2, w2) = try await connect(token: token, holdsPicture: nil)
        XCTAssertEqual(w2.resumed, true)
        XCTAssertEqual(streamer.lastPlan, .bringCurrent)
        XCTAssertEqual(streamer.viewerTiles, 0, "reproduces the grey resume: a relaunched viewer that says nothing gets nothing")
        c2.close()

        // 3. The fix: the relaunched viewer says it holds no picture; the same session resumes with a fresh one.
        streamer.relaunchViewer()
        let (c3, w3) = try await connect(token: token, holdsPicture: false)
        XCTAssertEqual(w3.resumed, true, "the session itself resumes (no reconnect penalty)")
        XCTAssertEqual(streamer.lastResume?.holdsPicture, false, "the flag reaches the streamer through the host session")
        XCTAssertEqual(streamer.lastPlan, .fresh(.viewerEmpty))
        XCTAssertEqual(streamer.viewerTiles, 48)
        c3.close()

        // 4. An outage with the picture kept (the Mac viewer's sleep/wake or network change): brought current, nothing resent.
        let (c4, w4) = try await connect(token: token, holdsPicture: true)
        XCTAssertEqual(w4.resumed, true)
        XCTAssertEqual(streamer.lastPlan, .bringCurrent)
        XCTAssertEqual(streamer.viewerTiles, 48)
        c4.close()
    }
}
