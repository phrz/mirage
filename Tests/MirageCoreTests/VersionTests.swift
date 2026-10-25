import XCTest
import Network
@testable import MirageCore

/// DESIGN §3.10 U1: version identity, the protocol range, the structured reject and the device list's update state.
final class VersionTests: XCTestCase {
    private func v(_ build: Int, _ version: String = "0.4.0", channel: UpdateChannel? = .nightly) -> MirageVersion {
        MirageVersion(version: version, build: build, commit: "c\(build)", channel: channel)
    }

    func testVersionFromInfoPlistAndOrder() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.4.1", "CFBundleVersion": "420", "MirageCommit": "69bb8ba", "MirageChannel": "nightly"]
        XCTAssertEqual(MirageVersion.from(infoDictionary: info), MirageVersion(version: "0.4.1", build: 420, commit: "69bb8ba", channel: .nightly))
        let local = MirageVersion.from(infoDictionary: ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "1", "MirageChannel": ""])
        XCTAssertNil(local.channel, "a local build was never published"); XCTAssertEqual(local.channelName, "local"); XCTAssertEqual(local.commit, "unknown")
        XCTAssertEqual(MirageVersion.from(infoDictionary: [:]).build, 0, "a bare SwiftPM binary")
        XCTAssertLessThan(v(412, "0.4.1"), v(420, "0.4.0"), "builds compare by the monotonic build number, not the marketing version")
        XCTAssertEqual(v(412).display, "0.4.0 (412)")
    }

    func testUnknownChannelAndCodeDecodeAsNil() throws {
        let ver = try JSONDecoder().decode(MirageVersion.self, from: Data(#"{"version":"1.0","build":9,"commit":"x","channel":"canary"}"#.utf8))
        XCTAssertNil(ver.channel)
        let rej = try JSONDecoder().decode(ControlMessage.Reject.self, from: Data(#"{"reason":"r","code":"somethingNew"}"#.utf8))
        XCTAssertEqual(rej.reason, "r"); XCTAssertNil(rej.code)
        let old = try JSONDecoder().decode(ControlMessage.Reject.self, from: Data(#"{"reason":"device not paired"}"#.utf8))
        XCTAssertNil(old.code, "a reject from an older host")
        let coded = ControlMessage.reject(.init(reason: "x", code: .hostTooOld, hostVersion: v(3)))
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: try JSONEncoder().encode(coded)), coded)
    }

    func testOlderPeersStillDecode() throws {
        // A Hello and a Welcome from builds before versions decode with the new fields nil.
        let hello = ControlMessage.Hello(protocolVersion: 5, deviceID: "d", deviceName: "n", clientNonce: Data([1]))
        let h = try JSONDecoder().decode(ControlMessage.Hello.self, from: try JSONEncoder().encode(hello))
        XCTAssertNil(h.viewerVersion); XCTAssertNil(h.minProtocolVersion)
        let w = try JSONDecoder().decode(ControlMessage.Welcome.self, from: Data(#"{"hostName":"h","sessionID":"s"}"#.utf8))
        XCTAssertNil(w.hostVersion); XCTAssertNil(w.latestAvailable); XCTAssertNil(w.protocolVersion); XCTAssertNil(w.updatePolicy)
        // A known-hosts file from before versions.
        let known = try JSONDecoder().decode(Store.KnownHost.self, from: Data(#"{"hostID":"i","hostName":"h","publicKey":"","endpoint":"h","pairedAt":0}"#.utf8))
        XCTAssertEqual(known.updateState, .current)
    }

    func testProtocolRangeAcceptance() {
        let range = 5...7
        XCTAssertNil(ProtocolCompat.check(viewerProtocol: 5, viewerMinProtocol: nil, hostRange: range), "the oldest supported viewer")
        XCTAssertNil(ProtocolCompat.check(viewerProtocol: 7, viewerMinProtocol: 5, hostRange: range))
        XCTAssertNil(ProtocolCompat.check(viewerProtocol: 9, viewerMinProtocol: 6, hostRange: range), "a newer viewer that can speak down to 7")
        XCTAssertNil(ProtocolCompat.check(viewerProtocol: 9, viewerMinProtocol: nil, hostRange: range))
        XCTAssertEqual(ProtocolCompat.check(viewerProtocol: 4, viewerMinProtocol: nil, hostRange: range), .viewerTooOld)
        XCTAssertEqual(ProtocolCompat.check(viewerProtocol: 9, viewerMinProtocol: 8, hostRange: range), .hostTooOld, "the viewer needs more than this host speaks")
        XCTAssertEqual(ProtocolCompat.negotiated(viewerProtocol: 9, hostProtocol: 7), 7)
        XCTAssertEqual(ProtocolCompat.negotiated(viewerProtocol: 5, hostProtocol: 7), 5)
        XCTAssertNil(ProtocolCompat.viewerCheck(hostProtocol: nil, viewerRange: 6...8), "a host from before ranges accepted our exact version")
        XCTAssertNil(ProtocolCompat.viewerCheck(hostProtocol: 6, viewerRange: 6...8))
        XCTAssertEqual(ProtocolCompat.viewerCheck(hostProtocol: 5, viewerRange: 6...8), .hostTooOld)
        XCTAssertEqual(ProtocolCompat.legacyCode(reason: "protocol version 6 unsupported"), .hostTooOld)
        XCTAssertNil(ProtocolCompat.legacyCode(reason: "device not paired"))
        XCTAssertTrue(Mirage.minProtocolVersion <= Mirage.protocolVersion)
    }

    func testUpdateState() {
        XCTAssertEqual(HostUpdateState.evaluate(hostVersion: v(412), latestAvailable: v(420), incompatibility: nil), .updateAvailable(from: v(412), to: v(420)))
        XCTAssertEqual(HostUpdateState.evaluate(hostVersion: v(420), latestAvailable: v(420), incompatibility: nil), .current)
        XCTAssertEqual(HostUpdateState.evaluate(hostVersion: v(420), latestAvailable: v(412), incompatibility: nil), .current, "never an arrow down")
        XCTAssertEqual(HostUpdateState.evaluate(hostVersion: nil, latestAvailable: v(420), incompatibility: nil), .current)
        XCTAssertEqual(HostUpdateState.evaluate(hostVersion: v(412), latestAvailable: v(420), incompatibility: .viewerTooOld), .viewerTooOld, "a refusal says which side, in place of the arrow")
        XCTAssertEqual(HostUpdateState.hostTooOld.note(hostName: "mac-daddy"), "Mirage on mac-daddy is too old for this device: update mac-daddy")
        XCTAssertEqual(HostUpdateState.updateAvailable(from: v(412), to: v(420, "0.4.1")).note(hostName: "m"), "Update available: 0.4.0 (412) → 0.4.1 (420)")
    }

    // MARK: Loopback: the real handshake

    private func rig(updates: HostUpdateInfo?) async throws -> (QUICHost, UInt16, Store, Store, DeviceIdentity, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-version-\(UUID().uuidString)")
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        var ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in })
        if let updates { ctx.updateInfo = { updates } }
        let viewer = DeviceIdentity(name: "test-phone")
        try hostStore.authorize(viewer.record)
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "test-host", pairedAt: Date()), as: "test-host")
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        return (host, port, hostStore, viewerStore, viewer, tmp)
    }

    private func session(port: UInt16, viewer: DeviceIdentity, store: Store) async throws -> (QUICClient, ClientSession) {
        let client = QUICClient(host: "127.0.0.1", port: port)
        try await client.connect(timeout: Loopback.timeout)
        let control = try await client.openStream()
        return (client, ClientSession(identity: viewer, store: store, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control))
    }

    func testWelcomeCarriesVersionsAndTheViewerRecordsThem() async throws {
        let latest = v(Int.max / 2, "9.9.9")
        let (host, port, _, viewerStore, viewer, tmp) = try await rig(updates: .init(latestAvailable: latest, permission: .init(policy: .ask, viewerMayTrigger: true)))
        defer { host.stop(); try? FileManager.default.removeItem(at: tmp) }
        try viewerStore.updateKnownHost("test-host") { $0.incompatibility = "hostTooOld" }   // a refusal earlier: cleared now
        let (client, s) = try await session(port: port, viewer: viewer, store: viewerStore); defer { client.close() }
        let w = try await s.authenticate()
        XCTAssertEqual(w.hostVersion, .current)
        XCTAssertEqual(w.protocolVersion, Mirage.protocolVersion)
        XCTAssertEqual(w.latestAvailable, latest)
        XCTAssertEqual(w.updatePolicy, .init(policy: .ask, viewerMayTrigger: true))
        XCTAssertNotNil(w.hostBuild, "kept for older viewers")
        let known = try XCTUnwrap(viewerStore.knownHosts()["test-host"])
        XCTAssertNil(known.incompatibility)
        XCTAssertEqual(known.updateState, .updateAvailable(from: .current, to: latest))
    }

    func testAnOlderViewerIsToldToUpdateItself() async throws {
        let (host, port, _, viewerStore, viewer, tmp) = try await rig(updates: nil)
        defer { host.stop(); try? FileManager.default.removeItem(at: tmp) }
        let (client, s) = try await session(port: port, viewer: viewer, store: viewerStore); defer { client.close() }
        try await s.stream.send(.hello(.init(protocolVersion: Mirage.minProtocolVersion - 1, deviceID: viewer.id, deviceName: viewer.name, clientNonce: DeviceIdentity.nonce())))
        guard case .reject(let r) = try await s.stream.receive() else { return XCTFail("expected a reject") }
        XCTAssertEqual(r.code, .viewerTooOld)
        XCTAssertEqual(r.hostVersion, .current)
        XCTAssertTrue(r.reason.contains("update the viewer"), r.reason)
    }

    func testANewerViewerThatNeedsMoreIsToldToUpdateTheHost() async throws {
        let (host, port, _, viewerStore, viewer, tmp) = try await rig(updates: nil)
        defer { host.stop(); try? FileManager.default.removeItem(at: tmp) }
        // A viewer from the future: it speaks protocol +3 and needs at least +2.
        let (client, s) = try await session(port: port, viewer: viewer, store: viewerStore); defer { client.close() }
        try await s.stream.send(.hello(.init(protocolVersion: Mirage.protocolVersion + 3, deviceID: viewer.id, deviceName: viewer.name, clientNonce: DeviceIdentity.nonce(),
                                             minProtocolVersion: Mirage.protocolVersion + 2)))
        guard case .reject(let r) = try await s.stream.receive() else { return XCTFail("expected a reject") }
        XCTAssertEqual(r.code, .hostTooOld)

        // A newer viewer that can still speak this host's version is accepted.
        let (client2, s2) = try await session(port: port, viewer: viewer, store: viewerStore); defer { client2.close() }
        try await s2.stream.send(.hello(.init(protocolVersion: Mirage.protocolVersion + 3, deviceID: viewer.id, deviceName: viewer.name, clientNonce: DeviceIdentity.nonce(),
                                              minProtocolVersion: Mirage.minProtocolVersion)))
        guard case .challenge = try await s2.stream.receive() else { return XCTFail("a newer viewer within range must get the challenge") }
    }

    /// The real client flow against a host that refuses with a code (and an older one that refuses with only a string): the
    /// known host records which side to update, which the device list shows.
    func testTheViewerRecordsARefusalForItsRow() async throws {
        for (reject, expected) in [(ControlMessage.Reject(reason: "too old", code: .viewerTooOld, hostVersion: v(900)), HostUpdateState.viewerTooOld),
                                   (ControlMessage.Reject(reason: "protocol version 6 unsupported"), HostUpdateState.hostTooOld)] {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-refuse-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let hostStore = try Store(root: tmp.appendingPathComponent("host"))
            let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
            let hostID = try hostStore.identity(role: "host", name: "old-host")
            let tls = try TLSIdentity.loadOrCreate(store: hostStore)
            try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "test-host", pairedAt: Date()), as: "test-host")
            let refusing = try QUICHost(port: 0, tls: tls)
            let st = Loopback.ListenerState()
            refusing.start(onStream: { conn, _, _ in
                Task {
                    let stream = MessageStream(connection: conn, queue: DispatchQueue(label: "refuse"))
                    stream.adoptStarted()
                    _ = try? await stream.receive()
                    try? await stream.send(.reject(reject))
                    try? await Task.sleep(for: .seconds(2))
                }
            }, onState: { st.set($0) })
            defer { refusing.stop() }
            try await Loopback.eventually("the refusing host listening") { if case .ready = st.state { return refusing.port != nil }; return false }
            let (client, s) = try await session(port: refusing.port!, viewer: DeviceIdentity(name: "test-phone"), store: viewerStore); defer { client.close() }
            do { _ = try await s.authenticate(); XCTFail("must be refused") }
            catch { XCTAssertTrue("\(error)".contains("host rejected"), "\(error)") }
            XCTAssertEqual(try viewerStore.knownHosts()["test-host"]?.updateState, expected)
            if reject.hostVersion != nil { XCTAssertEqual(try viewerStore.knownHosts()["test-host"]?.hostVersion, v(900)) }
        }
    }
}

/// macOS 27 renamed the Accessibility pane; the host's hints name it as that Mac's System Settings does.
final class PrivacyPaneTests: XCTestCase {
    func testPaneNamesByOS() {
        XCTAssertEqual(PrivacyPane.accessibility(osMajor: 27), "Device Control and Data Access")
        XCTAssertEqual(PrivacyPane.accessibility(osMajor: 26), "Accessibility")
        XCTAssertEqual(PrivacyPane.path(PrivacyPane.screenRecording), "System Settings → Privacy & Security → Screen & System Audio Recording")
    }
}
