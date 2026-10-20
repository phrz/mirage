import XCTest
import Network
@testable import MirageCore
import MirageHost

/// The host's local control socket: what the Mirage app on the host Mac uses to pair devices.
final class LocalControlTests: XCTestCase {
    func testLineCodecRoundTrip() throws {
        let e = LocalControl.Event.pairing(.init(code: "123456", link: "miragerd://pair?x", rotatesAt: Date(timeIntervalSince1970: 100), closesAt: Date(timeIntervalSince1970: 400), hostName: "h", address: "100.1.2.3"))
        var buf = try LocalControl.encodeLine(e) + LocalControl.encodeLine(LocalControl.Event.paired(deviceName: "p"))
        buf.append(contentsOf: Array("{\"partial".utf8))
        let lines = LocalControl.takeLines(&buf)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try LocalControl.decode(LocalControl.Event.self, line: lines[0]), e)
        XCTAssertEqual(String(decoding: buf, as: UTF8.self), "{\"partial", "an incomplete line stays buffered")
        let r = LocalControl.Request.decide(requestID: "x", allow: true)
        var rb = try LocalControl.encodeLine(r)
        XCTAssertEqual(try LocalControl.decode(LocalControl.Request.self, line: LocalControl.takeLines(&rb)[0]), r)
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock(); private var list: [LocalControl.Event] = []
        func add(_ e: LocalControl.Event) { lock.lock(); list.append(e); lock.unlock() }
        var all: [LocalControl.Event] { lock.lock(); defer { lock.unlock() }; return list }
        func wait(_ what: String, timeout: TimeInterval = 5, _ match: (LocalControl.Event) -> Bool) async throws -> LocalControl.Event {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if let e = all.first(where: match) { return e }; try await Task.sleep(for: .milliseconds(20)) }
            throw MirageError.transport("no \(what) event: \(all)")
        }
    }

    func testPairingThroughTheAppWithAllowAndDeny() async throws {
        // A short root: Unix socket paths are limited to 103 bytes.
        let tmp = URL(fileURLWithPath: "/tmp/mlc-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostStore = try Store(root: tmp.appendingPathComponent("h"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("v"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        let ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in })
        let port = UInt16.random(in: 40_000...60_000)
        let server = LocalControlServer(ctx: ctx, port: port, log: { _ in })
        try server.start()
        var st = stat(); XCTAssertEqual(stat(hostStore.url(LocalControl.socketName).path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "owner-only socket")

        let app = LocalControlClient(store: hostStore)
        let events = Events()
        app.onEvent = { e in events.add(e) }
        try app.connect(client: "test")
        _ = try await events.wait("hello") { if case .hello = $0 { return true }; return false }
        try app.send(.openPairing)
        let first = try await events.wait("pairing") { if case .pairing = $0 { return true }; return false }
        guard case .pairing(let p) = first, let link = PairingLink(string: p.link) else { return XCTFail("no pairing link") }
        XCTAssertEqual(p.code.count, 6)
        XCTAssertTrue(link.pins(publicKey: hostID.publicKey))
        XCTAssertEqual(link.port, port)

        let host = try QUICHost(port: port, tls: tls)
        let ready = expectation(description: "listening")
        host.start(onStream: { conn, id, remote in Task { await HostSession.handle(connection: conn, connectionID: id, remote: remote, ctx: ctx) } },
                   onState: { if case .ready = $0 { ready.fulfill() } })
        await fulfillment(of: [ready], timeout: 5)
        defer { host.stop() }
        var dialLink = link; dialLink.address = "127.0.0.1"

        func pair(_ name: String, answer: Bool) async throws {
            let client = QUICClient(host: "127.0.0.1", port: port)
            try await client.connect(timeout: 5)
            defer { client.close() }
            let control = try await client.openStream()
            let session = ClientSession(identity: DeviceIdentity(name: name), store: viewerStore, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control)
            // The app answers the host's question as a person would.
            let answering = Task {
                let q = try await events.wait("confirm for \(name)") { if case .confirm(let c) = $0 { return c.deviceName == name }; return false }
                guard case .confirm(let c) = q else { return }
                try app.send(.decide(requestID: c.requestID, allow: answer))
            }
            defer { answering.cancel() }
            _ = try await session.pair(link: dialLink)
        }

        // Deny first: nothing authorized, and the window stays open (with a fresh secret: the attempt took the old one).
        do { try await pair("intruder", answer: false); XCTFail("denied pairing must fail") } catch { XCTAssertTrue("\(error)".contains("denied"), "\(error)") }
        XCTAssertTrue(try hostStore.authorizedDevices().isEmpty)
        let fresh = try await events.wait("a fresh code") { if case .pairing(let q) = $0 { return q.link != p.link }; return false }
        guard case .pairing(let p2) = fresh, var link2 = PairingLink(string: p2.link) else { return XCTFail() }
        link2.address = "127.0.0.1"; dialLink = link2

        try await pair("test-phone", answer: true)
        XCTAssertEqual(try hostStore.authorizedDevices().map(\.name), ["test-phone"])
        _ = try await events.wait("paired") { if case .paired(let n) = $0 { return n == "test-phone" }; return false }
        _ = try await events.wait("pairingClosed") { if case .pairingClosed = $0 { return true }; return false }
        app.disconnect()
    }
}
