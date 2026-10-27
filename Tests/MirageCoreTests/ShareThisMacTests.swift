import XCTest
@testable import MirageCore
@testable import MirageHost

/// Share This Mac and Later (phrz, 2026-10-27): when the permissions window comes up, and a Mac that is not shared (a
/// viewer-only Mac) never touches TCC: no grant is read or asked for, nothing is captured, no stream or pairing.
final class ShareThisMacTests: XCTestCase {
    final class Calls: @unchecked Sendable {
        let lock = NSLock(); var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    var saved: HostPermissions.System!
    let calls = Calls()

    override func setUp() {
        saved = HostPermissions.system
        let c = calls
        // Every TCC-touching call counts: reads and requests alike.
        HostPermissions.system = .init(preflightScreen: { c.hit(); return false }, windowNamesVisible: { c.hit(); return false }, axTrusted: { c.hit(); return false },
                                       requestScreen: { c.hit() }, requestAX: { c.hit() })
        HostPermissions.resetForTests()
    }
    override func tearDown() { HostPermissions.system = saved; HostPermissions.resetForTests() }

    func testWhenTheWindowComesUp() {
        typealias R = PermissionWindowRule
        let missing = ["accessibility"]
        var s = HostSettings()
        XCTAssertTrue(R.shouldShow(.startup, settings: s, missing: missing))
        XCTAssertFalse(R.shouldShow(.startup, settings: s, missing: []), "nothing missing")
        s.permissionsSnoozed = true
        XCTAssertFalse(R.shouldShow(.startup, settings: s, missing: missing), "Later: not at the next start")
        for r: R.Reason in [.revoked, .pairing(device: "iPhone"), .shareTurnedOn, .connectionRefused(device: "iPad")] {
            XCTAssertTrue(R.shouldShow(r, settings: s, missing: missing), "\(r): someone tries to share this Mac")
        }
        s.shareThisMac = false
        for r: R.Reason in [.startup, .revoked, .pairing(device: nil), .shareTurnedOn, .connectionRefused(device: "iPad")] {
            XCTAssertFalse(R.shouldShow(r, settings: s, missing: missing), "\(r): never while sharing is off")
        }
        XCTAssertEqual(R.message(.connectionRefused(device: "iPad")), "iPad tried to connect.")
        XCTAssertEqual(R.message(.pairing(device: "iPhone")), "iPhone is pairing with this Mac.")
        XCTAssertNil(R.message(.startup)); XCTAssertNil(R.message(.revoked), "the heading says it")
    }

    func testOlderSettingsShareAndAreNotSnoozed() throws {
        let s = try JSONDecoder().decode(HostSettings.self, from: Data(#"{"curtain":false}"#.utf8))
        XCTAssertTrue(s.shareThisMac, "a host from before the switch keeps sharing")
        XCTAssertFalse(s.permissionsSnoozed)
        XCTAssertFalse(s.curtain)
    }

    /// The agent's role with sharing off: none of the shared parts, and its grants are never read.
    func testTheViewerOnlyAgentNeverTouchesTCC() {
        let off = HostRole(sharing: false)
        XCTAssertFalse(off.warmCaptures); XCTAssertFalse(off.curtain); XCTAssertFalse(off.stayReachable); XCTAssertFalse(off.watchesPermissions)
        XCTAssertEqual(off.missingPermissions(), [])
        XCTAssertTrue(off.grantsAtStart() == (false, false))
        let before = calls.count
        _ = off.missingPermissions(); _ = off.grantsAtStart()
        XCTAssertEqual(calls.count, before, "sharing off: no TCC call at all")
        let on = HostRole(sharing: true)
        XCTAssertEqual(on.missingPermissions(), ["screenRecording", "accessibility"])
        XCTAssertTrue(on.warmCaptures && on.curtain && on.watchesPermissions)
    }

    /// Over loopback and the control socket: a Mac that is not shared says so in its Welcome, refuses a pairing, never
    /// reports or asks for a grant, and reads none.
    func testANotSharedHostRefusesAndAsksNothing() async throws {
        let tmp = URL(fileURLWithPath: "/tmp/mst-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostStore = try Store(root: tmp.appendingPathComponent("h"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("v"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        var ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in })
        let role = HostRole(sharing: false)
        ctx.sharing = { role.sharing }
        // An unlock handler and agent sessions wired as on a shared Mac: sharing off must still refuse them.
        final class Typed: @unchecked Sendable { var n = 0 }
        let typed = Typed()
        ctx.unlockHandler = { _ in typed.n += 1; return .unlocked }
        ctx.endAgentSession = { _ in typed.n += 1 }
        ctx.missingPermissions = { role.missingPermissions() }
        final class Attempts: @unchecked Sendable { var n = 0 }
        let attempts = Attempts()
        ctx.onShareAttempt = { _ in attempts.n += 1 }
        ctx.pairing.window = PairingWindow()
        let viewer = DeviceIdentity(name: "phone")
        try hostStore.authorize(viewer.record)
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "test-host", pairedAt: Date()), as: "test-host")
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        defer { host.stop() }
        func session(_ id: DeviceIdentity, _ store: Store) async throws -> (ClientSession, QUICClient) {
            let client = QUICClient(host: "127.0.0.1", port: port)
            try await client.connect(timeout: Loopback.timeout)
            let control = try await client.openStream()
            return (ClientSession(identity: id, store: store, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control), client)
        }
        let (s, c1) = try await session(viewer, viewerStore)
        defer { c1.close() }
        let w = try await s.authenticate()
        XCTAssertEqual(w.shared, false)
        XCTAssertNil(w.needsPermissions)
        XCTAssertFalse((w.features ?? []).contains(ControlMessage.Feature.unlock), "no unlock offered")
        XCTAssertFalse((w.features ?? []).contains(ControlMessage.Feature.agentSession), "no agent sessions offered")
        try await s.stream.send(.endAgentSession)
        XCTAssertEqual(try viewerStore.knownHosts()["test-host"]?.hostShared, false)
        let (p, c2) = try await session(DeviceIdentity(name: "new-phone"), try Store(root: tmp.appendingPathComponent("v2")))
        defer { c2.close() }
        do { _ = try await p.pair(code: ctx.pairing.window!.current().code); XCTFail("a Mac that is not shared does not pair") }
        catch { XCTAssertTrue("\(error)".contains("not shared"), "\(error)") }
        // The control socket: no grants in the status, no request, no pairing window.
        let server = LocalControlServer(ctx: ctx, port: port, log: { _ in })
        try server.start()
        let app = LocalControlClient(store: hostStore)
        let events = LocalControlTests.Events()
        app.onEvent = { events.add($0) }
        try app.connect(client: "test")
        defer { app.disconnect() }
        let st = try await events.wait("status") { if case .status = $0 { return true }; return false }
        guard case .status(let status) = st else { return XCTFail() }
        XCTAssertNil(status.screenRecording); XCTAssertNil(status.accessibility)
        try app.send(.requestPermission("screenRecording"))
        try app.send(.openPairing)
        _ = try await events.wait("pairing refused") { if case .pairingClosed = $0 { return true }; return false }
        try app.send(.requestUnlock(reason: "test", requester: "test"))
        let u = try await events.wait("unlock refused") { if case .unlockOutcome = $0 { return true }; return false }
        XCTAssertEqual(u, .unlockOutcome(.refused))
        try app.send(.agentSessionExtend)
        let a = try await events.wait("no agent session") { if case .agentSession = $0 { return true }; return false }
        XCTAssertEqual(a, .agentSession(open: false))
        XCTAssertEqual(typed.n, 0, "nothing typed at the lock screen, no agent session touched")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.count, 0, "not one TCC call: no read, no request")
        XCTAssertEqual(attempts.n, 0)
    }

    /// An older Mirage.app's setHostSettings leaves out shareThisMac and permissionsSnoozed: the stored values stay.
    func testAnOlderAppsSettingsKeepSharingOff() throws {
        let stored = HostSettings(curtain: true, shareThisMac: false, permissionsSnoozed: true)
        let old = Data(#"{"curtain":false,"lockWhenFinished":true,"stayReachable":true}"#.utf8)
        let m = HostSettings.merged(message: old, over: stored)
        XCTAssertFalse(m.shareThisMac, "not turned back on by a default")
        XCTAssertTrue(m.permissionsSnoozed)
        XCTAssertFalse(m.curtain, "what it did send applies")
        let line = try LocalControl.encodeLine(LocalControl.Request.setHostSettings(HostSettings(shareThisMac: true)))
        let sent = try XCTUnwrap(LocalControlServer.sentSettings(line.dropLast()))
        XCTAssertTrue(HostSettings.merged(message: sent, over: stored).shareThisMac, "a new app's explicit value applies")
    }
}
