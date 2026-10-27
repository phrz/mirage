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

    final class Results: @unchecked Sendable {
        private let lock = NSLock(); private var queue: [ControlMessage.UpdateStatus?]; private var last: ControlMessage.UpdateStatus?
        init(_ q: [ControlMessage.UpdateStatus?]) { queue = q; last = q.last ?? nil }
        /// Each Welcome takes the next; the last one stays.
        func next() -> ControlMessage.UpdateStatus? { lock.lock(); defer { lock.unlock() }; return queue.isEmpty ? last : queue.removeFirst() }
    }

    func rig(permission: UpdatePermission?, lastResult: ControlMessage.UpdateStatus? = nil, results: Results? = nil, handler: HostUpdateHandler?) async throws -> Rig {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-trigger-\(UUID().uuidString)")
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        var ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in })
        ctx.updateInfo = { HostUpdateInfo(latestAvailable: nil, permission: permission, lastResult: results?.next() ?? lastResult) }
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

    /// "At least build N" keeps older peers working: an older host reads only `targetBuild` (N, installed exactly, as
    /// before); an older viewer sends only `targetBuild`, which a newer host reads as the minimum.
    func testAtLeastIsCompatibleBothWays() throws {
        struct OldUpdateHost: Codable { var targetBuild: Int }   // a host from before minimumBuild
        let sent = ControlMessage.UpdateHost(targetBuild: 479, minimumBuild: 479)
        XCTAssertEqual(try JSONDecoder().decode(OldUpdateHost.self, from: try JSONEncoder().encode(sent)).targetBuild, 479)
        let fromOldViewer = try JSONDecoder().decode(ControlMessage.UpdateHost.self, from: Data(#"{"targetBuild":479}"#.utf8))
        XCTAssertNil(fromOldViewer.minimumBuild)
        XCTAssertEqual(fromOldViewer.atLeast, 479)
        let st = try JSONDecoder().decode(ControlMessage.UpdateStatus.self, from: Data(#"{"phase":"failed","message":"m"}"#.utf8))
        XCTAssertNil(st.notPublished, "an older host's failure is a failure")
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
        // At least the build asked for: a newer one arriving is this update done.
        XCTAssertEqual(HostUpdateTrigger.outcome(welcome: w(now), command: .update(targetBuild: was.build + 1), from: was)?.phase, .done)
        XCTAssertNil(HostUpdateTrigger.outcome(welcome: w(now), command: .update(targetBuild: now.build + 1), from: was), "older than asked: not yet")
        XCTAssertEqual(HostUpdateTrigger.outcome(welcome: w(was), command: .rollback, from: now)?.phase, .done)
    }

    // MARK: Review fixes (U4)

    /// The new build answers but is on trial: "trial", and polling goes on until the Welcome says it committed.
    func testDoneOnlyOnceCommitted() async throws {
        let target = MirageVersion.current.build
        let trial = ControlMessage.UpdateStatus(phase: .trial, message: "start 1", from: MirageVersion(version: "0.1", build: target - 1, commit: "a", channel: nil), to: .current, at: Date())
        let done = ControlMessage.UpdateStatus(phase: .done, message: "committed", from: trial.from, to: .current, at: Date())
        // Welcomes: the trigger's own, then two on trial, then committed.
        let r = try await rig(permission: anyDevice, results: Results([nil, trial, trial, done]), handler: { _, _, reply in
            reply(.init(phase: .restarting, message: "restarting", yours: true))
        })
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let seen = Log()
        let end = await HostUpdateTrigger.run(connect: connect(r), command: .update(targetBuild: target), hostName: "test-host", timing: fast) { seen.add($0.phase.rawValue) }
        XCTAssertEqual(end.phase, .done)
        XCTAssertEqual(seen.all.filter { $0 == "trial" }.count, 1, "reported once while it lasts: \(seen.all)")
        XCTAssertEqual(Array(seen.all.suffix(2)), ["trial", "done"])
    }

    func testATrialThatNeverCommitsIsNotDone() async throws {
        let target = MirageVersion.current.build
        let trial = ControlMessage.UpdateStatus(phase: .trial, message: "start 1", from: nil, to: .current, at: Date())
        let r = try await rig(permission: anyDevice, results: Results([nil, trial]), handler: { _, _, reply in
            reply(.init(phase: .restarting, message: "restarting", yours: true))
        })
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let end = await HostUpdateTrigger.run(connect: connect(r), command: .update(targetBuild: target), hostName: "test-host",
                                              timing: .init(reconnectFor: 1.5, pollEvery: 0.2)) { _ in }
        XCTAssertEqual(end.phase, .failed)
        XCTAssertTrue(end.message.contains("has not passed its health checks"), end.message)
    }

    /// The connection is lost before "restarting": the viewer does not claim a restart; the host's record (a failed
    /// install) read from the next Welcome is the answer.
    func testALostConnectionReadsTheOutcomeFromTheNextWelcome() async throws {
        let failed = ControlMessage.UpdateStatus(phase: .failed, message: "verification failed: the zip's SHA-256 differs",
                                                 from: .current, to: MirageVersion(version: "", build: 9999, commit: "", channel: nil), at: Date())
        let r = try await rig(permission: anyDevice, lastResult: failed, handler: nil)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let seen = Log()
        let end = await HostUpdateTrigger.awaitRestart(connect: connect(r), command: .update(targetBuild: 9999), from: .current, hostName: "test-host",
                                                       timing: fast, lost: true) { seen.add($0.phase.rawValue) }
        XCTAssertEqual(end.phase, .failed)
        XCTAssertTrue(end.message.contains("SHA-256"), end.message)
        XCTAssertFalse(seen.all.contains("restarting"), "no restart is claimed")
        // Nothing recorded: after the time, "lost the connection", not "did not come back".
        let r2 = try await rig(permission: anyDevice, handler: nil)
        defer { r2.host.stop(); try? FileManager.default.removeItem(at: r2.tmp) }
        let end2 = await HostUpdateTrigger.awaitRestart(connect: connect(r2), command: .update(targetBuild: 9999), from: .current, hostName: "test-host",
                                                        timing: .init(reconnectFor: 0.8, pollEvery: 0.2), lost: true) { _ in }
        XCTAssertTrue(end2.message.hasPrefix("lost the connection"), end2.message)
    }

    /// A phase from a later build decodes (as unknown) instead of failing the Welcome; the outcome goes only to viewers that
    /// listed updateStatus.
    func testTolerantPhaseAndUpdateResultOnlyForListeners() async throws {
        let w = try JSONDecoder().decode(ControlMessage.Welcome.self, from: Data(#"{"hostName":"h","sessionID":"s","updateResult":{"phase":"teleporting","message":"m"}}"#.utf8))
        XCTAssertEqual(w.updateResult?.phase, .unknown)
        XCTAssertFalse(w.updateResult?.isFinal ?? true)
        let rolled = ControlMessage.UpdateStatus(phase: .rolledBack, message: "x", from: .current, to: .current, at: Date())
        let r = try await rig(permission: anyDevice, lastResult: rolled, handler: nil)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let (a, closeA) = try await connect(r)(); defer { closeA() }
        let plain = try await a.authenticate()
        XCTAssertNil(plain.updateResult, "a viewer that did not list updateStatus never gets it")
        let (b, closeB) = try await connect(r)(); defer { closeB() }
        let listening = try await b.authenticate(features: [ControlMessage.Feature.updateStatus])
        XCTAssertEqual(listening.updateResult?.phase, .rolledBack)
    }

    func testARevokedDeviceCannotTriggerOnItsOpenConnection() async throws {
        let calls = Log()
        let r = try await rig(permission: anyDevice, handler: { _, _, _ in calls.add("ran") })
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let (s, close) = try await connect(r)(); defer { close() }
        _ = try await s.authenticate()
        _ = try r.ctx.store.revoke(idPrefix: r.viewer.id)
        try await s.stream.send(.updateHost(.init(targetBuild: 1)))
        guard case .updateStatus(let st) = try await s.stream.receive() else { return XCTFail() }
        XCTAssertEqual(st.phase, .failed)
        XCTAssertTrue(st.message.contains("no longer paired"), st.message)
        XCTAssertEqual(calls.all, [])
    }

    /// U6: a host installing an update on its own (Automatic) says so in its Welcome; the row shows "updating", not Update.
    func testAHostUpdatingOnItsOwnShowsUpdating() async throws {
        let running = ControlMessage.UpdateStatus(phase: .downloading, message: "downloading 0.1 (9999)", from: .current,
                                                  to: MirageVersion(version: "0.1", build: 9999, commit: "b", channel: .nightly))
        let r = try await rig(permission: anyDevice, lastResult: running, handler: nil)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let (s, close) = try await connect(r)(); defer { close() }
        _ = try await s.authenticate(features: [ControlMessage.Feature.updateStatus])
        XCTAssertEqual(try r.viewerStore.knownHosts()["test-host"]?.updateState, .updating(to: running.to))
    }

    // MARK: Status probes (U7)

    /// A probe fills the record from the Welcome, as "seen", not "connected".
    func testAProbeFillsTheRecord() async throws {
        let latest = MirageVersion(version: "0.1", build: 9999, commit: "b", channel: .nightly)
        let running = ControlMessage.UpdateStatus(phase: .downloading, message: "downloading", to: latest)
        let r = try await rig(permission: .init(policy: .automatic, viewerMayTrigger: true), lastResult: running, handler: { _, _, _ in })
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        try r.viewerStore.updateKnownHost("test-host") { $0.unreachableSince = Date(timeIntervalSince1970: 0) }
        let ok = await HostProbe.probe(connect: connect(r), store: r.viewerStore, alias: "test-host")
        XCTAssertTrue(ok)
        let k = try XCTUnwrap(r.viewerStore.knownHosts()["test-host"])
        XCTAssertEqual(k.hostVersion, .current)
        XCTAssertEqual(k.updateTrigger, true); XCTAssertEqual(k.triggerFeature, true)
        XCTAssertEqual(k.hostPolicy, UpdatePermission(policy: .automatic, viewerMayTrigger: true))
        XCTAssertEqual(k.updating?.phase, .downloading, "an update running there")
        XCTAssertEqual(k.updateState, .updating(to: latest))
        XCTAssertEqual(k.hostStreaming, false)
        XCTAssertEqual(k.hostProtocol, Mirage.protocolVersion); XCTAssertEqual(k.hostMinProtocol, Mirage.minProtocolVersion)
        XCTAssertNotNil(k.lastSeen); XCTAssertNil(k.unreachableSince)
        XCTAssertNil(k.lastConnected, "a probe is not a connection: the list's order and \"Connected\" stay")
    }

    func testAnUnreachableHostIsMarked() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(root: tmp)
        try store.remember(host: .init(hostID: "h", hostName: "gone", publicKey: Data(), endpoint: "gone", pairedAt: Date()), as: "gone")
        let ok = await HostProbe.probe(connect: { throw MirageError.transport("connect timed out after 3 s") }, store: store, alias: "gone")
        XCTAssertFalse(ok)
        let since = try XCTUnwrap(store.knownHosts()["gone"]?.unreachableSince)
        _ = await HostProbe.probe(connect: { throw MirageError.transport("again") }, store: store, alias: "gone")
        XCTAssertEqual(try store.knownHosts()["gone"]?.unreachableSince, since, "since the first failure")
    }

    /// A probe is never a stream (the Automatic gate counts streams), never a listener for notices, and is logged once
    /// per device per 10 min at most, its end not at all.
    func testAProbeIsQuietAndNotAStream() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-quiet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        let lines = Log()
        var ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { lines.add($0) })
        ctx.updateInfo = { HostUpdateInfo(latestAvailable: nil, permission: self.anyDevice) }
        ctx.updateHandler = { _, _, _ in }
        let viewer = DeviceIdentity(name: "test-phone")
        try hostStore.authorize(viewer.record)
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "test-host", pairedAt: Date()), as: "test-host")
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        defer { host.stop() }
        let r = Rig(host: host, port: port, viewerStore: viewerStore, viewer: viewer, ctx: ctx, tmp: tmp)
        for _ in 0..<3 { _ = await HostProbe.probe(connect: connect(r), store: viewerStore, alias: "test-host") }
        try await Task.sleep(for: .milliseconds(300))
        let streaming = await ctx.connections.streamingDeviceIDs(), listeners = await ctx.updateListeners.count
        XCTAssertEqual(streaming, [], "no stream for the Automatic gate or the host's menu")
        XCTAssertEqual(listeners, 0, "not kept for notices")
        XCTAssertEqual(lines.all.filter { $0.contains("status probe") }.count, 1, lines.all.joined(separator: "\n"))
        XCTAssertTrue(lines.all.filter { $0.contains("authenticated") || $0.contains("auth timing") || $0.contains("closed") }.isEmpty, lines.all.joined(separator: "\n"))
    }

    func testProbeLogRateLimit() {
        let p = ProbeRegistry()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(p.shouldLog("d", now: t0))
        XCTAssertFalse(p.shouldLog("d", now: t0.addingTimeInterval(599)))
        XCTAssertTrue(p.shouldLog("e", now: t0), "per device")
        XCTAssertTrue(p.shouldLog("d", now: t0.addingTimeInterval(600)))
        XCTAssertTrue(p.shouldLog("d", now: t0.addingTimeInterval(-10)), "a clock set back logs rather than going quiet")
    }

    // MARK: U6 review

    /// 2: a viewer that resumes its session hears what happened while it was away; a trigger or probe (no resume token)
    /// does not.
    func testAResumingViewerGetsTheNotice() async throws {
        let rolled = ControlMessage.UpdateStatus(phase: .rolledBack, message: "started 3 times", from: .current,
                                                 to: MirageVersion(version: "0.1", build: 9999, commit: "b", channel: .nightly), at: Date())
        let r = try await rig(permission: anyDevice, lastResult: rolled, handler: nil)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let (s, close) = try await connect(r)(); defer { close() }
        _ = try await s.authenticate(resumeToken: Data(repeating: 7, count: 32), features: [ControlMessage.Feature.updateStatus])
        guard case .updateStatus(let n) = try await s.stream.receive() else { return XCTFail("expected the notice") }
        XCTAssertEqual(n.yours, false)
        XCTAssertTrue(n.message.contains("while you were away, and rolled back"), n.message)
    }

    func testResumeNoticeRules() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let to = MirageVersion(version: "0.1", build: 457, commit: "b", channel: .nightly)
        XCTAssertEqual(ResumeNotice.make(lastResult: .init(phase: .downloading, message: "downloading", to: to), hostName: "m", now: now)?.phase, .downloading,
                       "an update under way: as it is")
        XCTAssertEqual(ResumeNotice.make(lastResult: .init(phase: .done, message: "x", to: to, at: now.addingTimeInterval(-60)), hostName: "m", now: now)?.message,
                       "m was updated to 0.1 (457) while you were away")
        XCTAssertNil(ResumeNotice.make(lastResult: .init(phase: .done, message: "x", to: to, at: now.addingTimeInterval(-700)), hostName: "m", now: now), "too old")
        XCTAssertNil(ResumeNotice.make(lastResult: .init(phase: .done, message: "x", to: to, at: now.addingTimeInterval(60)), hostName: "m", now: now), "from the future")
        XCTAssertNil(ResumeNotice.make(lastResult: .init(phase: .failed, message: "x", to: to, at: now), hostName: "m", now: now))
        XCTAssertNil(ResumeNotice.make(lastResult: nil, hostName: "m", now: now))
    }

    /// 4: a persisted "updating" goes stale 10 min after the last Welcome or probe: the Update offer comes back.
    func testAStaleUpdatingExpires() {
        var k = Store.KnownHost(hostID: "h", hostName: "m", publicKey: Data(), endpoint: "m", pairedAt: Date(timeIntervalSince1970: 0))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        k.hostVersion = MirageVersion(version: "0.1", build: 456, commit: "a", channel: .nightly)
        k.latestAvailable = MirageVersion(version: "0.1", build: 457, commit: "b", channel: .nightly)
        k.updating = .init(phase: .trial, message: "start 1", to: k.latestAvailable)
        k.lastSeen = now.addingTimeInterval(-60)
        XCTAssertEqual(k.updateState(now: now), .updating(to: k.latestAvailable))
        k.lastSeen = now.addingTimeInterval(-601)
        XCTAssertEqual(k.updateState(now: now), .updateAvailable(from: k.hostVersion!, to: k.latestAvailable!), "stale: the offer is back")
        k.lastSeen = nil
        XCTAssertEqual(k.updateState(now: now), .updateAvailable(from: k.hostVersion!, to: k.latestAvailable!), "never seen since: stale")
    }
}
