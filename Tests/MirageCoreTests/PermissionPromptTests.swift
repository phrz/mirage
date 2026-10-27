import XCTest
@testable import MirageCore
@testable import MirageHost

/// The host never raises a permission prompt by itself (DESIGN §3.7a; phrz, 2026-10-27: on a new host "all the permissions
/// requests just pop up unbridled"). Every check only reads state; the one request is the person's Allow in Mirage.app,
/// over the local control socket. The system calls are injected and counted.
final class PermissionPromptTests: XCTestCase {
    final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var screenRequests = 0, axRequests = 0
        var screen = false, ax = false, names = false
        func bump(_ k: ReferenceWritableKeyPath<Counts, Int>) { lock.lock(); self[keyPath: k] += 1; lock.unlock() }
        var requests: Int { lock.lock(); defer { lock.unlock() }; return screenRequests + axRequests }
    }
    var saved: HostPermissions.System!
    let c = Counts()

    override func setUp() {
        saved = HostPermissions.system
        let c = self.c
        HostPermissions.system = .init(preflightScreen: { c.screen }, windowNamesVisible: { c.names }, axTrusted: { c.ax },
                                       requestScreen: { c.bump(\.screenRequests) }, requestAX: { c.bump(\.axRequests) })
        HostPermissions.resetForTests()
    }
    override func tearDown() { HostPermissions.system = saved; HostPermissions.resetForTests() }

    /// Startup, the watcher, the capture gate and the status read, over and over with nothing granted: no request.
    func testReadingNeverRequests() {
        for _ in 0..<20 {
            _ = HostPermissions.screenRecordingGranted(); _ = HostPermissions.screenRecordingGrantedNow()
            _ = HostPermissions.accessibilityGranted(); _ = HostPermissions.missing(); _ = HostPermissions.mayCapture
        }
        XCTAssertEqual(c.requests, 0)
        XCTAssertEqual(HostPermissions.missing(), [.screenRecording, .accessibility])
        XCTAssertFalse(HostPermissions.mayCapture, "no ScreenCaptureKit call before the grant reads as present")
        // Window names visible (the grant is in force although preflight is stale in this process): capture may run.
        c.names = true
        XCTAssertTrue(HostPermissions.mayCapture)
        c.names = false
        XCTAssertTrue(HostPermissions.mayCapture, "seen once, kept for this process")
        XCTAssertFalse(HostPermissions.screenRecordingGrantedNow(), "the watcher re-reads it and sees a revocation")
        XCTAssertEqual(c.requests, 0)
        HostPermissions.request(.accessibility)
        XCTAssertEqual(c.axRequests, 1, "only an explicit request asks")
    }

    /// Through the local control socket: the status says what is missing without asking; only requestPermission asks,
    /// once per Allow, never for a grant already there; the asked list makes the next Allow open System Settings.
    func testOnlyTheAppsAllowRequests() async throws {
        let tmp = URL(fileURLWithPath: "/tmp/mpp-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(root: tmp)
        let id = try store.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: store)
        var ctx = HostContext(identity: id, store: store, tlsFingerprint: tls.fingerprint, log: { _ in })
        ctx.missingPermissions = { HostPermissions.missing().map(\.rawValue) }
        let server = LocalControlServer(ctx: ctx, port: 7000, log: { _ in })
        try server.start()
        let app = LocalControlClient(store: store)
        let events = LocalControlTests.Events()
        app.onEvent = { events.add($0) }
        try app.connect(client: "test")
        defer { app.disconnect() }
        let s0 = try await events.wait("status") { if case .status = $0 { return true }; return false }
        guard case .status(let st0) = s0 else { return XCTFail() }
        XCTAssertEqual(st0.screenRecording, false); XCTAssertEqual(st0.accessibility, false); XCTAssertNil(st0.permissionsAsked)
        XCTAssertEqual(c.requests, 0, "a status read asks nothing")
        XCTAssertTrue(server.askToShowPermissions())
        _ = try await events.wait("showPermissions") { if case .showPermissions = $0 { return true }; return false }
        XCTAssertEqual(c.requests, 0)

        let before = events.count
        try app.send(.requestPermission("screenRecording"))
        let s1 = try await events.wait("status after the request", after: before) { if case .status = $0 { return true }; return false }
        try await Loopback.eventually("the request on the main queue") { c.screenRequests == 1 }
        guard case .status(let st1) = s1 else { return XCTFail() }
        XCTAssertEqual(st1.permissionsAsked, ["screenRecording"], "a second Allow goes to System Settings")
        XCTAssertEqual(c.axRequests, 0)

        // Asked again (a second Allow, or another client): never a second request in this run.
        try app.send(.requestPermission("screenRecording"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.screenRequests, 1, "once per kind per run")
        c.ax = true
        try app.send(.requestPermission("accessibility"))
        try app.send(.requestPermission("nonsense"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.axRequests, 0, "never for a grant already there")
    }

    /// A viewer learns the host needs permissions (Get Info), and a stream is never started without Screen Recording.
    func testTheWelcomeSaysWhatIsMissing() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-perm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        var ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in })
        ctx.missingPermissions = { HostPermissions.missing().map(\.rawValue) }
        let viewer = DeviceIdentity(name: "phone")
        try hostStore.authorize(viewer.record)
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "test-host", pairedAt: Date()), as: "test-host")
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        defer { host.stop() }
        let client = QUICClient(host: "127.0.0.1", port: port)
        defer { client.close() }
        try await client.connect(timeout: Loopback.timeout)
        let control = try await client.openStream()
        let s = ClientSession(identity: viewer, store: viewerStore, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control)
        let w = try await s.authenticate()
        XCTAssertEqual(w.needsPermissions, ["screenRecording", "accessibility"])
        XCTAssertEqual(try viewerStore.knownHosts()["test-host"]?.hostNeedsPermissions, ["screenRecording", "accessibility"])
        XCTAssertEqual(c.requests, 0)
    }

    /// The window-name heuristic (review, 2026-10-27): only ordinary apps' normal windows count. The Dock's, the window
    /// server's and the menu bar servers' names may be readable without the grant, so they never read as granted.
    /// Recorded window lists, not live: the live behaviour without a grant is checked separately (see the report).
    func testWindowNamesCountOnlyOrdinaryAppWindows() {
        func w(_ owner: String, _ name: String?, layer: Int = 0, pid: Int = 500) -> [String: Any] {
            var d: [String: Any] = [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid]
            if let name { d[kCGWindowName as String] = name }
            return d
        }
        let ungranted: [[String: Any]] = [w("Dock", "Dock", layer: 20), w("Window Server", "Menubar", layer: 24), w("Control Center", "BentoBox", layer: 25),
                                          w("SystemUIServer", "AppleClock", layer: 25), w("Finder", nil), w("Safari", nil), w("Notification Center", "Notification Center", layer: 0)]
        XCTAssertFalse(HostPermissions.namesVisible(in: ungranted, ownPID: 1), "system windows' names say nothing")
        XCTAssertFalse(HostPermissions.namesVisible(in: [w("Dock", "Dock")], ownPID: 1), "the Dock never counts, whatever its layer")
        XCTAssertFalse(HostPermissions.namesVisible(in: [w("miraged", "x", pid: 1)], ownPID: 1), "this process never counts")
        XCTAssertFalse(HostPermissions.namesVisible(in: [w("Safari", "Apple", layer: 3)], ownPID: 1), "only normal windows")
        XCTAssertTrue(HostPermissions.namesVisible(in: ungranted + [w("Safari", "Apple")], ownPID: 1), "an app's window name: granted")
        XCTAssertFalse(HostPermissions.namesVisible(in: [], ownPID: 1), "nothing on screen: says nothing")
        // Only regular apps count: an agent this list does not know (Stage Manager's WindowManager, "Siri AI") says nothing.
        let agent = [w("SomeNewSystemAgent", "Overlay", pid: 600)]
        XCTAssertFalse(HostPermissions.namesVisible(in: agent, ownPID: 1, regularPIDs: [500]))
        XCTAssertTrue(HostPermissions.namesVisible(in: [w("Safari", "Apple", pid: 500)], ownPID: 1, regularPIDs: [500]))
        XCTAssertFalse(HostPermissions.namesVisible(in: [w("WindowManager", "x"), w("Siri AI", "y")], ownPID: 1))
    }

    func testTheAppIsOpenedAtMostOncePerBoot() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(root: tmp)
        XCTAssertTrue(PermissionAppOpen.mayOpen(store: store, boot: 1000))
        XCTAssertFalse(PermissionAppOpen.mayOpen(store: store, boot: 1000), "the same boot: not again")
        XCTAssertTrue(PermissionAppOpen.mayOpen(store: store, boot: 2000), "after a restart of the Mac")
        XCTAssertGreaterThan(PermissionAppOpen.bootTime(), 0)
    }
}
