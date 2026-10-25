import XCTest
import Network
@testable import MirageCore

/// DESIGN §3.10 U4: the remote trigger's message flow over the real handshake, and the policy gate.
final class UpdateTriggerTests: XCTestCase {
    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    struct Rig { let host: QUICHost; let port: UInt16; let viewerStore: Store; let viewer: DeviceIdentity; let ctx: HostContext; let tmp: URL }

    func rig(permission: UpdatePermission?, lastResult: ControlMessage.UpdateStatus? = nil, handler: HostUpdateHandler?) async throws -> Rig {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-trigger-\(UUID().uuidString)")
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        var ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in })
        ctx.updateInfo = { HostUpdateInfo(latestAvailable: nil, permission: permission, lastResult: lastResult) }
        ctx.updateHandler = handler
        let viewer = DeviceIdentity(name: "test-phone")
        try hostStore.authorize(viewer.record)
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "test-host", pairedAt: Date()), as: "test-host")
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        return Rig(host: host, port: port, viewerStore: viewerStore, viewer: viewer, ctx: ctx, tmp: tmp)
    }

    func connect(_ r: Rig) -> HostUpdateTrigger.Connect {
        let port = r.port, store = r.viewerStore, viewer = r.viewer
        return {
            let client = QUICClient(host: "127.0.0.1", port: port)
            try await client.connect(timeout: Loopback.timeout)
            let control = try await client.openStream()
            return (ClientSession(identity: viewer, store: store, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control), { client.close() })
        }
    }

    let fast = HostUpdateTrigger.Timing(reconnectFor: 15, pollEvery: 0.2)
    let anyDevice = UpdatePermission(policy: .ask, viewerMayTrigger: true)

    func testTheGate() {
        XCTAssertNil(UpdateGate.refusal(permission: anyDevice, canUpdate: true, hostName: "m"))
        XCTAssertNil(UpdateGate.refusal(permission: .init(policy: .automatic, viewerMayTrigger: true), canUpdate: true, hostName: "m"), "Automatic takes triggers too")
        XCTAssertTrue(UpdateGate.refusal(permission: .init(policy: .ask, viewerMayTrigger: false), canUpdate: true, hostName: "m")?.contains("restricted to that Mac") ?? false)
        XCTAssertTrue(UpdateGate.refusal(permission: anyDevice, canUpdate: false, hostName: "m")?.contains("cannot update itself") ?? false)
        XCTAssertNotNil(UpdateGate.refusal(permission: nil, canUpdate: true, hostName: "m"))
    }

    func testMessagesRoundTripAndOlderPeersDecode() throws {
        let st = ControlMessage.UpdateStatus(phase: .downloading, progress: 0.5, message: "m", from: MirageVersion(version: "0.1", build: 448, commit: "a", channel: .nightly), yours: true)
        for m in [ControlMessage.updateHost(.init(targetBuild: 449)), .rollbackHost, .updateStatus(st)] {
            XCTAssertEqual(try Frame.decode(ControlMessage.self, from: try JSONEncoder().encode(m)), m)
        }
        let w = try JSONDecoder().decode(ControlMessage.Welcome.self, from: Data(#"{"hostName":"h","sessionID":"s","updatePolicy":{"policy":"ask","viewerMayTrigger":true}}"#.utf8))
        XCTAssertFalse(w.acceptsUpdateTrigger, "a host from before U4 lists no updateTrigger feature: it would not decode updateHost")
        XCTAssertNil(try JSONDecoder().decode(ControlMessage.Hello.self, from: try JSONEncoder().encode(ControlMessage.Hello(protocolVersion: 6, deviceID: "d", deviceName: "n", clientNonce: Data()))).features)
    }

    /// Allowed: the host runs the updater, the viewer hears each step, and after the restart the host answers with the
    /// target build: done.
    func testATriggeredUpdateEndsDone() async throws {
        let got = Log()
        let target = MirageVersion.current.build   // the loopback host is this test binary: "the new build" once it restarts
        let r = try await rig(permission: anyDevice, handler: { cmd, who, reply in
            got.add("\(cmd) by \(who.name)")
            reply(.init(phase: .downloading, message: "downloading", yours: true))
            reply(.init(phase: .verifying, message: "verifying", yours: true))
            reply(.init(phase: .restarting, message: "restarting", yours: true))
        })
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let seen = Log()
        let end = await HostUpdateTrigger.run(connect: connect(r), command: .update(targetBuild: target), hostName: "test-host", timing: fast) { seen.add($0.phase.rawValue) }
        XCTAssertEqual(end.phase, .done, end.message)
        XCTAssertEqual(got.all, ["update(targetBuild: Optional(\(target))) by test-phone"])
        XCTAssertEqual(seen.all, ["checking", "downloading", "verifying", "restarting", "restarting", "done"])
    }

    func testAFailureFromTheUpdaterReachesTheViewer() async throws {
        let r = try await rig(permission: anyDevice, handler: { _, _, reply in
            reply(.init(phase: .failed, message: "verification failed: Gatekeeper rejects Mirage.app", yours: true))
        })
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let end = await HostUpdateTrigger.run(connect: connect(r), command: .update(targetBuild: 999), hostName: "test-host", timing: fast) { _ in }
        XCTAssertEqual(end.phase, .failed)
        XCTAssertTrue(end.message.contains("Gatekeeper"))
    }

    /// The host restricts updates to itself: the viewer is told so, and the updater never runs, even for a viewer that
    /// sends the trigger anyway.
    func testTheHostsGateRefusesWhenRestrictedToThatMac() async throws {
        let calls = Log()
        let r = try await rig(permission: .init(policy: .ask, viewerMayTrigger: false), handler: { _, _, _ in calls.add("ran") })
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let end = await HostUpdateTrigger.run(connect: connect(r), command: .update(targetBuild: 1), hostName: "test-host", timing: fast) { _ in }
        XCTAssertEqual(end.phase, .failed)
        XCTAssertTrue(end.message.contains("restricted to that Mac"), end.message)
        // A viewer that ignores the Welcome and sends it anyway.
        let (s, close) = try await connect(r)()
        defer { close() }
        _ = try await s.authenticate()
        try await s.stream.send(.updateHost(.init(targetBuild: 1)))
        guard case .updateStatus(let st) = try await s.stream.receive() else { return XCTFail("expected a refusal") }
        XCTAssertEqual(st.phase, .failed)
        XCTAssertTrue(st.message.contains("restricted"))
        XCTAssertEqual(calls.all, [], "the updater never ran")
        XCTAssertEqual(try r.viewerStore.knownHosts()["test-host"]?.updateTrigger, false, "the row knows not to offer Update")
    }

    func testAHostThatCannotUpdateItselfSaysSo() async throws {
        let r = try await rig(permission: anyDevice, handler: nil)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let end = await HostUpdateTrigger.run(connect: connect(r), command: .update(targetBuild: 1), hostName: "test-host", timing: fast) { _ in }
        XCTAssertEqual(end.phase, .failed)
        XCTAssertTrue(end.message.contains("cannot update itself"), end.message)
    }

    /// After the restart the old build answers and its Welcome says the update rolled back: the viewer reports that.
    func testARollbackIsReportedAfterTheRestart() async throws {
        let rolled = ControlMessage.UpdateStatus(phase: .rolledBack, message: "started 3 times without becoming healthy",
                                                 from: .current, to: MirageVersion(version: "0.1", build: 9999, commit: "b", channel: .nightly), at: Date())
        let r = try await rig(permission: anyDevice, lastResult: rolled, handler: { _, _, reply in
            reply(.init(phase: .restarting, message: "restarting", yours: true))
        })
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let end = await HostUpdateTrigger.run(connect: connect(r), command: .update(targetBuild: 9999), hostName: "test-host", timing: fast) { _ in }
        XCTAssertEqual(end.phase, .rolledBack)
        XCTAssertTrue(end.message.contains("3 times"))
    }

    /// Other viewers that listen hear before the host restarts; the triggering viewer hears only its own replies.
    func testOtherViewersGetANotice() async throws {
        var rr: Rig?
        let r = try await rig(permission: anyDevice, handler: { _, who, reply in
            await rr?.ctx.updateListeners.broadcast(.init(phase: .restarting, message: "test-host is restarting into an update from \(who.name)", yours: false), except: who.connectionID)
            reply(.init(phase: .failed, message: "stop here", yours: true))
        })
        rr = r
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        // A second viewer, streaming-or-not, that decodes updateStatus.
        let (other, closeOther) = try await connect(r)()
        defer { closeOther() }
        _ = try await other.authenticate(features: [ControlMessage.Feature.updateStatus])
        for _ in 0..<500 where await r.ctx.updateListeners.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
        // A third that does not (an older viewer): it gets nothing it could not decode.
        let (old, closeOld) = try await connect(r)()
        defer { closeOld() }
        _ = try await old.authenticate()
        let listeners = await r.ctx.updateListeners.count
        XCTAssertEqual(listeners, 1, "only the viewer that asked for notices")
        let end = await HostUpdateTrigger.run(connect: connect(r), command: .update(targetBuild: 1), hostName: "test-host", timing: fast) { _ in }
        XCTAssertEqual(end.message, "stop here", "the trigger's own connection got its reply, not the notice")
        guard case .updateStatus(let notice) = try await other.stream.receive() else { return XCTFail() }
        XCTAssertEqual(notice.yours, false)
        XCTAssertTrue(notice.message.contains("from test-phone"))
    }

    func testOutcomeAfterTheRestart() {
        let was = MirageVersion(version: "0.1", build: 448, commit: "a", channel: .nightly)
        let now = MirageVersion(version: "0.1", build: 449, commit: "b", channel: .nightly)
        func w(_ v: MirageVersion, result: ControlMessage.UpdateStatus? = nil) -> ControlMessage.Welcome {
            .init(hostName: "m", sessionID: "s", hostVersion: v, updateResult: result)
        }
        XCTAssertNil(HostUpdateTrigger.outcome(welcome: w(was), command: .update(targetBuild: 449), from: was), "the old build still answers: keep waiting")
        XCTAssertEqual(HostUpdateTrigger.outcome(welcome: w(now), command: .update(targetBuild: 449), from: was)?.phase, .done)
        let rb = ControlMessage.UpdateStatus(phase: .rolledBack, message: "x", from: was, to: now)
        XCTAssertEqual(HostUpdateTrigger.outcome(welcome: w(was, result: rb), command: .update(targetBuild: 449), from: was)?.phase, .rolledBack)
        XCTAssertNil(HostUpdateTrigger.outcome(welcome: w(was, result: rb), command: .update(targetBuild: 450), from: was), "an earlier update's rollback")
        XCTAssertEqual(HostUpdateTrigger.outcome(welcome: w(was), command: .rollback, from: now)?.phase, .done)
    }
}
