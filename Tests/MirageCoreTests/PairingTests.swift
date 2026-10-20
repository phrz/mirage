import XCTest
import Network
@testable import MirageCore

final class PairingLinkTests: XCTestCase {
    private func link(exp: Date = Date(timeIntervalSince1970: 2_000_000_000)) -> PairingLink {
        PairingLink(hostName: "mac-daddy", address: "100.80.102.7", port: 7799, keyHash: Data((0..<32).map { UInt8($0) }), secret: Data((0..<16).map { UInt8(200 + $0) }), expires: exp)
    }

    func testRoundTripThroughTheURL() throws {
        let l = link()
        let s = l.url.absoluteString
        XCTAssertTrue(s.hasPrefix("miragerd://pair?host=mac-daddy&addr=100.80.102.7&port=7799&key="), s)
        XCTAssertFalse(s.contains("=="), "base64url without padding")
        XCTAssertEqual(PairingLink(url: l.url), l)
        XCTAssertEqual(PairingLink(string: "  \(s)\n"), l)
    }

    func testMalformedLinksAreRefused() {
        let good = link().url.absoluteString
        XCTAssertNil(PairingLink(string: good.replacingOccurrences(of: "miragerd://", with: "https://")))
        XCTAssertNil(PairingLink(string: good.replacingOccurrences(of: "port=7799", with: "port=0")))
        XCTAssertNil(PairingLink(string: good.replacingOccurrences(of: "&secret=", with: "&secretx=")))
        XCTAssertNil(PairingLink(string: "miragerd://pair?host=a&addr=b&port=1&key=AAAA&secret=AAAA&exp=1"), "key and secret must be 32 and 16 bytes")
    }

    func testExpiry() {
        let l = link(exp: Date(timeIntervalSince1970: 1000))
        XCTAssertFalse(l.isExpired(now: Date(timeIntervalSince1970: 999)))
        XCTAssertTrue(l.isExpired(now: Date(timeIntervalSince1970: 1000)))
    }

    func testKeyPin() {
        let host = DeviceIdentity(name: "h")
        var l = link(); l.keyHash = PairingLink.keyHash(forPublicKey: host.publicKey)
        XCTAssertTrue(l.pins(publicKey: host.publicKey))
        XCTAssertFalse(l.pins(publicKey: DeviceIdentity(name: "other").publicKey))
        XCTAssertEqual(PairingLink.fingerprintText(Data((0..<32).map { UInt8($0) })), "0001 0203 0405 0607 0809 0a0b 0c0d 0e0f")
    }
}

final class PairingWindowTests: XCTestCase {
    func testRotatesEvery30SecondsAndClosesAfter5Minutes() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        let w = PairingWindow(now: t0)
        let a = w.current(now: t0)
        XCTAssertEqual(w.current(now: t0.addingTimeInterval(29)), a)
        let b = w.current(now: t0.addingTimeInterval(30))
        XCTAssertNotEqual(b.secret, a.secret); XCTAssertEqual(b.issued, t0.addingTimeInterval(30))
        XCTAssertTrue(w.isOpen(now: t0.addingTimeInterval(299)))
        XCTAssertFalse(w.isOpen(now: t0.addingTimeInterval(300)))
        XCTAssertNil(w.takePassword(secret: false, now: t0.addingTimeInterval(300)))
    }

    func testTakingAPasswordRotatesBothSoNothingIsReused() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        let w = PairingWindow(now: t0)
        let a = w.current(now: t0)
        XCTAssertEqual(w.takePassword(secret: false, now: t0), a.code)
        let b = w.current(now: t0)
        XCTAssertNotEqual(b.secret, a.secret, "single use: the code's attempt burned the secret too")
        XCTAssertEqual(w.takePassword(secret: true, now: t0), Base64URL.encode(b.secret))
        XCTAssertNotEqual(w.current(now: t0).secret, b.secret)
        w.close()
        XCTAssertNil(w.takePassword(secret: true, now: t0))
    }

    func testTheLinkCarriesTheCurrentSecretAndExpiresAtTheRotation() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        let w = PairingWindow(now: t0)
        let host = DeviceIdentity(name: "h")
        let l = w.link(hostName: "h", address: "100.1.2.3", port: 7799, hostPublicKey: host.publicKey, now: t0)
        XCTAssertEqual(l.secret, w.current(now: t0).secret)
        XCTAssertEqual(l.expires, t0.addingTimeInterval(30))
        XCTAssertTrue(l.pins(publicKey: host.publicKey))
    }
}

/// Loopback QUIC with the real host and client pairing flows.
final class PairingFlowTests: XCTestCase {
    private struct Rig {
        let host: QUICHost, port: UInt16, ctx: HostContext, hostID: DeviceIdentity, hostStore: Store, viewerStore: Store, tmp: URL
    }
    private func rig() async throws -> Rig {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-pair-\(UUID().uuidString)")
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        let ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in })
        let port = UInt16.random(in: 40_000...60_000)
        let host = try QUICHost(port: port, tls: tls)
        let ready = expectation(description: "listening")
        host.start(onStream: { conn, id, remote in Task { await HostSession.handle(connection: conn, connectionID: id, remote: remote, ctx: ctx) } },
                   onState: { if case .ready = $0 { ready.fulfill() } })
        await fulfillment(of: [ready], timeout: 5)
        return Rig(host: host, port: port, ctx: ctx, hostID: hostID, hostStore: hostStore, viewerStore: viewerStore, tmp: tmp)
    }
    private func pair(_ r: Rig, viewer: DeviceIdentity, _ body: (ClientSession) async throws -> DeviceRecord) async throws -> DeviceRecord {
        let client = QUICClient(host: "127.0.0.1", port: r.port)
        try await client.connect(timeout: 5)
        defer { client.close() }
        let control = try await client.openStream()
        let session = ClientSession(identity: viewer, store: r.viewerStore, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control)
        return try await body(session)
    }

    func testLinkPairingAskedAndAllowedOnTheHost() async throws {
        let r = try await rig(); defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let w = PairingWindow(); r.ctx.pairing.window = w
        let asked = Asked(); r.ctx.pairing.confirm = { d in asked.add(d.name); return true }
        let link = w.link(hostName: "test-host", address: "127.0.0.1", port: r.port, hostPublicKey: r.hostID.publicKey)
        let viewer = DeviceIdentity(name: "test-phone")
        let host = try await pair(r, viewer: viewer) { try await $0.pair(link: link) }
        XCTAssertEqual(host.id, r.hostID.id)
        XCTAssertEqual(asked.names, ["test-phone"], "the host asked before authorizing")
        XCTAssertEqual(try r.hostStore.authorizedDevices().map(\.id), [viewer.id])
        XCTAssertEqual(try r.viewerStore.knownHosts()["test-host"]?.hostID, r.hostID.id)
    }

    func testDenyOnTheHostAuthorizesNothing() async throws {
        let r = try await rig(); defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let w = PairingWindow(); r.ctx.pairing.window = w
        r.ctx.pairing.confirm = { _ in false }
        let code = w.current().code
        do {
            _ = try await pair(r, viewer: DeviceIdentity(name: "intruder")) { try await $0.pair(code: code) }
            XCTFail("a denied pairing must fail")
        } catch { XCTAssertTrue("\(error)".contains("denied"), "\(error)") }
        XCTAssertTrue(try r.hostStore.authorizedDevices().isEmpty)
        XCTAssertNil(try r.viewerStore.knownHosts()["test-host"])
    }

    func testALinkPinningAnotherKeyIsRefusedByTheViewer() async throws {
        let r = try await rig(); defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let w = PairingWindow(); r.ctx.pairing.window = w
        r.ctx.pairing.confirm = { _ in true }
        var link = w.link(hostName: "test-host", address: "127.0.0.1", port: r.port, hostPublicKey: r.hostID.publicKey)
        link.keyHash = PairingLink.keyHash(forPublicKey: DeviceIdentity(name: "the real host").publicKey)
        do {
            _ = try await pair(r, viewer: DeviceIdentity(name: "test-phone")) { try await $0.pair(link: link) }
            XCTFail("a host whose key does not match the link must be refused")
        } catch { XCTAssertTrue("\(error)".contains("does not match"), "\(error)") }
        XCTAssertNil(try r.viewerStore.knownHosts()["test-host"], "nothing recorded for a mismatching host")
    }

    func testARotatedSecretNoLongerPairs() async throws {
        let r = try await rig(); defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let w = PairingWindow(); r.ctx.pairing.window = w
        r.ctx.pairing.confirm = { _ in true }
        let old = w.link(hostName: "test-host", address: "127.0.0.1", port: r.port, hostPublicKey: r.hostID.publicKey)
        _ = w.takePassword(secret: false)   // an attempt (or the 30 s rotation) moved the window on
        do {
            _ = try await pair(r, viewer: DeviceIdentity(name: "late")) { try await $0.pair(link: old) }
            XCTFail("an old secret must not pair")
        } catch {}
        XCTAssertTrue(try r.hostStore.authorizedDevices().isEmpty)
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock(); private var n: [String] = []
        func add(_ s: String) { lock.lock(); n.append(s); lock.unlock() }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return n }
    }
}

final class ScrollShaperTests: XCTestCase {
    func testOneAxisPerGestureWholePointsAndANewGestureAfterAPause() {
        var s = ScrollShaper()
        // An iPhone pan: mostly vertical with a sideways part, fractional.
        XCTAssertEqual(s.shape(dx: 19.5, dy: -57.25, nanos: 1_000_000_000).map { [$0.dx, $0.dy] }, [0, -57])
        XCTAssertEqual(s.axis, .vertical)
        XCTAssertEqual(s.shape(dx: 8, dy: -31.5, nanos: 1_016_000_000).map { [$0.dx, $0.dy] }, [0, -31], "the remainder carries: -0.25 - 31.5")
        XCTAssertEqual(s.shape(dx: 40, dy: -0.75, nanos: 1_032_000_000).map { [$0.dx, $0.dy] }, [0, -1], "sideways stays locked out in this gesture")
        XCTAssertNil(s.shape(dx: 0, dy: -0.4, nanos: 1_048_000_000), "under a point: carried, nothing posted")
        // A pause: a new gesture, decided again.
        XCTAssertEqual(s.shape(dx: 30, dy: 5, nanos: 2_000_000_000).map { [$0.dx, $0.dy] }, [30, 0])
        XCTAssertEqual(s.axis, .horizontal)
    }
}
