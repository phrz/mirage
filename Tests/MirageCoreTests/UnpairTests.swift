import XCTest
import Network
@testable import MirageCore

/// Removing a paired Mac from a device's list (phrz, 2026-10-26): the store, the unpair message over loopback, an older
/// host that never receives it, and that a device can only unpair itself.
final class UnpairTests: XCTestCase {
    final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testForgettingAHost() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-forget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(root: tmp)
        try store.remember(host: .init(hostID: "a", hostName: "mac-daddy", publicKey: Data([1]), endpoint: "mac-daddy", pairedAt: Date()), as: "mac-daddy")
        try store.remember(host: .init(hostID: "b", hostName: "mini", publicKey: Data([2]), endpoint: "mini", pairedAt: Date()), as: "mini")
        XCTAssertTrue(try store.forget(host: "mac-daddy"))
        XCTAssertEqual(Array(try store.knownHosts().keys), ["mini"], "the record and its pinned key are gone; the other stays")
        XCTAssertFalse(try store.forget(host: "mac-daddy"), "already gone")
    }

    struct Rig { let host: QUICHost; let port: UInt16; let hostStore: Store; let viewerStore: Store; let a: DeviceIdentity; let b: DeviceIdentity; let lines: Lines; let tmp: URL }

    func rig(advertises: Bool = true) async throws -> Rig {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-unpair-\(UUID().uuidString)")
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        let lines = Lines()
        var ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { lines.add($0) })
        ctx.advertisesUnpair = advertises
        let a = DeviceIdentity(name: "phone"), b = DeviceIdentity(name: "laptop")
        try hostStore.authorize(a.record); try hostStore.authorize(b.record)
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "test-host", pairedAt: Date()), as: "test-host")
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        return Rig(host: host, port: port, hostStore: hostStore, viewerStore: viewerStore, a: a, b: b, lines: lines, tmp: tmp)
    }

    func connect(_ r: Rig, as device: DeviceIdentity) -> HostUpdateTrigger.Connect {
        let port = r.port, store = r.viewerStore
        return {
            let client = QUICClient(host: "127.0.0.1", port: port)
            try await client.connect(timeout: Loopback.timeout)
            let control = try await client.openStream()
            return (ClientSession(identity: device, store: store, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control), { client.close() })
        }
    }

    /// The device removes itself, and only itself.
    func testAViewerUnpairsItselfOnly() async throws {
        let r = try await rig()
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let outcome = await HostUnpair.unpair(connect: connect(r, as: r.a))
        XCTAssertEqual(outcome, .unpaired)
        let ids = try r.hostStore.authorizedDevices().map(\.id)
        XCTAssertFalse(ids.contains(r.a.id), "the phone is gone from authorized-devices.json")
        XCTAssertTrue(ids.contains(r.b.id), "the laptop stays: nothing names another device")
        XCTAssertTrue(r.lines.all.contains { $0.contains("phone") && $0.contains("unpaired") })
        // The phone can no longer connect.
        let (s, close) = try await connect(r, as: r.a)(); defer { close() }
        do { _ = try await s.authenticate(); XCTFail("an unpaired device must be refused") } catch {}
    }

    /// A host from before the feature never receives the message: the viewer is told, nothing changes there.
    func testAnOlderHostNeverReceivesIt() async throws {
        let r = try await rig(advertises: false)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let outcome = await HostUnpair.unpair(connect: connect(r, as: r.a))
        XCTAssertEqual(outcome, .notSupported)
        XCTAssertTrue(try r.hostStore.authorizedDevices().map(\.id).contains(r.a.id))
        XCTAssertFalse(r.lines.all.contains { $0.contains("unpaired") })
    }

    func testUnreachable() async {
        guard case .unreachable = await HostUnpair.unpair(connect: { throw MirageError.transport("connect timed out after 3 s") }) else {
            return XCTFail("unreachable")
        }
    }
}
