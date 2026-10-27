import XCTest
@testable import MirageCore
@testable import MirageHost

/// The host's own icon in the device lists (phrz, 2026-10-26: "a green iMac" rather than a generic one): rendered by the
/// host within the budget, sent in the Welcome to a viewer that asks and does not hold it already, kept per host, and
/// never sent to an older viewer.
final class HostIconTests: XCTestCase {
    struct Rig { let host: QUICHost; let port: UInt16; let hostStore: Store; let viewerStore: Store; let viewer: DeviceIdentity; let hostID: DeviceIdentity; let tmp: URL }

    func rig(icon: HostIcon?) async throws -> Rig {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-icon-\(UUID().uuidString)")
        let hostStore = try Store(root: tmp.appendingPathComponent("host"))
        let viewerStore = try Store(root: tmp.appendingPathComponent("viewer"))
        let hostID = try hostStore.identity(role: "host", name: "test-host")
        let tls = try TLSIdentity.loadOrCreate(store: hostStore)
        var ctx = HostContext(identity: hostID, store: hostStore, tlsFingerprint: tls.fingerprint, log: { _ in })
        ctx.hostIcon = icon
        let viewer = DeviceIdentity(name: "phone")
        try hostStore.authorize(viewer.record)
        try viewerStore.remember(host: .init(hostID: hostID.id, hostName: hostID.name, publicKey: hostID.publicKey, endpoint: "test-host", pairedAt: Date()), as: "test-host")
        let (host, port) = try await Loopback.host(tls: tls, ctx: ctx)
        return Rig(host: host, port: port, hostStore: hostStore, viewerStore: viewerStore, viewer: viewer, hostID: hostID, tmp: tmp)
    }

    /// One authentication as today's viewer: its Welcome.
    func authenticate(_ r: Rig) async throws -> ControlMessage.Welcome {
        let client = QUICClient(host: "127.0.0.1", port: r.port)
        defer { client.close() }
        try await client.connect(timeout: Loopback.timeout)
        let control = try await client.openStream()
        let s = ClientSession(identity: r.viewer, store: r.viewerStore, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control)
        return try await s.authenticate(features: [ControlMessage.Feature.updateStatus, ControlMessage.Feature.probe], probe: true)
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func testTheIconRoundTripsAndIsCached() async throws {
        let icon = HostIcon.make(png128: Self.png + Data(repeating: 1, count: 6_000), png256: Self.png + Data(repeating: 2, count: 20_000))!
        let r = try await rig(icon: icon)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let first = try await authenticate(r)
        XCTAssertEqual(first.hostIcon, icon, "a viewer without it gets it")
        XCTAssertEqual(r.viewerStore.hostIcon(hostID: r.hostID.id), icon, "kept per host")
        let second = try await authenticate(r)
        XCTAssertNil(second.hostIcon, "the viewer holds the same one: not sent again")
        XCTAssertEqual(r.viewerStore.hostIcon(hostID: r.hostID.id), icon)
        // Removing the Mac forgets its icon too.
        try r.viewerStore.forget(host: "test-host")
        XCTAssertNil(r.viewerStore.hostIcon(hostID: r.hostID.id))
    }

    /// A viewer from before the icon (no feature in its Hello) never receives it.
    func testAnOlderViewerNeverReceivesIt() async throws {
        let r = try await rig(icon: HostIcon.make(png128: Self.png + Data(count: 100), png256: nil)!)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        let client = QUICClient(host: "127.0.0.1", port: r.port)
        defer { client.close() }
        try await client.connect(timeout: Loopback.timeout)
        let control = try await client.openStream()
        let fp = client.tlsFingerprint!
        let nonce = DeviceIdentity.nonce()
        // Its Hello, as builds before this one sent it.
        try await control.send(.hello(.init(protocolVersion: Mirage.protocolVersion, deviceID: r.viewer.id, deviceName: r.viewer.name, clientNonce: nonce,
                                            viewerVersion: .current, minProtocolVersion: Mirage.minProtocolVersion, features: [ControlMessage.Feature.updateStatus])))
        let ch = try await control.expect("challenge") { if case .challenge(let c) = $0 { return c } else { return nil } }
        let transcript = DeviceIdentity.clientAuthTranscript(tlsFingerprint: fp, clientNonce: nonce, hostNonce: ch.hostNonce, hostID: ch.hostID)
        try await control.send(.authenticate(.init(clientPublicKey: r.viewer.publicKey, clientSignature: try r.viewer.sign(transcript))))
        let welcome = try await control.expect("welcome") { if case .welcome(let w) = $0 { return w } else { return nil } }
        XCTAssertNil(welcome.hostIcon)
        XCTAssertEqual(welcome.hostModel, DeviceModel.current, "hw.model still travels, for Get Info")
        XCTAssertNil(HostIcon.forViewer(features: nil, cachedHash: nil, icon: HostIcon.make(png128: Self.png, png256: nil)))
    }

    func testBudget() {
        let small = Self.png + Data(count: 7_000), big = Self.png + Data(count: 22_000)
        XCTAssertNotNil(HostIcon.make(png128: small, png256: big)?.png256, "28 KB: both")
        let tooBig = Self.png + Data(count: 25_000)
        let i = HostIcon.make(png128: small, png256: tooBig)
        XCTAssertNotNil(i)
        XCTAssertNil(i?.png256, "over 30 KB: the small one only")
        XCTAssertNil(HostIcon.make(png128: Self.png + Data(count: 31_000), png256: nil))
        var forged = HostIcon.make(png128: small, png256: nil)!
        forged.png128 = Self.png + Data(count: 10)
        XCTAssertFalse(forged.isValid, "a hash that does not match is not kept")
    }

    /// This Mac's own icon, as miraged renders it at start: PNGs within the budget.
    func testTheHostRendersItsOwnIcon() throws {
        let icon = try XCTUnwrap(HostIconRenderer.make())
        XCTAssertTrue(icon.isValid)
        XCTAssertLessThanOrEqual(icon.png128.count + (icon.png256?.count ?? 0), HostIcon.budget)
    }

    /// A status probe (U7) carries the icon too: a host that gained one after the viewer's last session is drawn with it
    /// at the next probe, no session needed (green-machine, 2026-10-27).
    func testAStatusProbeDeliversTheIcon() async throws {
        let icon = HostIcon.make(png128: Self.png + Data(repeating: 3, count: 4_000), png256: nil)!
        let r = try await rig(icon: icon)
        defer { r.host.stop(); try? FileManager.default.removeItem(at: r.tmp) }
        XCTAssertNil(r.viewerStore.hostIcon(hostID: r.hostID.id))
        let port = r.port, store = r.viewerStore, viewer = r.viewer
        let connect: HostUpdateTrigger.Connect = {
            let client = QUICClient(host: "127.0.0.1", port: port)
            try await client.connect(timeout: Loopback.timeout)
            let control = try await client.openStream()
            return (ClientSession(identity: viewer, store: store, alias: "test-host", tlsFingerprint: client.tlsFingerprint!, stream: control), { client.close() })
        }
        let answered = await HostProbe.probe(connect: connect, store: r.viewerStore, alias: "test-host")
        XCTAssertTrue(answered)
        XCTAssertEqual(r.viewerStore.hostIcon(hostID: r.hostID.id), icon, "kept from the probe's answer")
    }

    /// A heavy picture still fits: 128 and 256 px, else 128 alone, else smaller; nothing only past 64 px.
    func testTheIconFitsTheBudgetBySize() {
        var lines: [String] = []
        let light = HostIconRenderer.fit(small: { Self.png + Data(count: $0 * 50) }, big: Self.png + Data(count: 20_000), log: { lines.append($0) })
        XCTAssertNotNil(light?.png256, "both sizes when they fit")
        let heavy = HostIconRenderer.fit(small: { Self.png + Data(count: $0 == 128 ? 34_000 : $0 == 96 ? 20_000 : 9_000) }, big: Self.png + Data(count: 60_000),
                                         log: { lines.append($0) })
        XCTAssertEqual(heavy?.png128.count, 20_008, "128 px over the budget: 96 px")
        XCTAssertNil(heavy?.png256)
        XCTAssertNil(HostIconRenderer.fit(small: { _ in Self.png + Data(count: 40_000) }, big: nil, log: { lines.append($0) }))
        XCTAssertTrue(lines.last?.contains("none") ?? false, "the log says why")
    }
}

/// The host's metadata record (DESIGN §3.10, U7): one record from a probe or a session, one cache path.
final class HostMetadataTests: XCTestCase {
    func testOneRecordOneCachePath() {
        var w = ControlMessage.Welcome(hostName: "green-machine", sessionID: "s", hostModel: "iMac21,1",
                                       hostVersion: MirageVersion(version: "0.1", build: 510, commit: "c", channel: .nightly),
                                       updatePolicy: .init(policy: .automatic, viewerMayTrigger: true), protocolVersion: 6,
                                       features: [ControlMessage.Feature.updateTrigger, ControlMessage.Feature.unlock],
                                       hostSettings: HostSettings(curtain: false), hostOS: "26.1", updateChannel: .nightly, shared: false)
        w.hostIcon = HostIcon.make(png128: Data([0x89, 0x50, 0x4E, 0x47, 1]), png256: nil)
        let m = HostMetadata(welcome: w)
        var h = Store.KnownHost(hostID: "g", hostName: "old-name", publicKey: Data(), endpoint: "g", pairedAt: Date())
        h.unreachableSince = Date(timeIntervalSince1970: 1); h.failedProbes = 3; h.refusal = "device not paired"
        let now = Date(timeIntervalSince1970: 1_000)
        m.apply(to: &h, seenAt: now, incompatibility: nil, connected: false)
        XCTAssertEqual(h.hostName, "green-machine")
        XCTAssertEqual(h.model, "iMac21,1"); XCTAssertEqual(h.family, "iMac")
        XCTAssertEqual(h.hostOS, "26.1"); XCTAssertEqual(h.hostChannel, .nightly)
        XCTAssertEqual(h.hostVersion?.build, 510); XCTAssertEqual(h.hostPolicy?.policy, .automatic)
        XCTAssertEqual(h.triggerFeature, true); XCTAssertEqual(h.hostUnlock, true)
        XCTAssertEqual(h.hostSettings?.curtain, false); XCTAssertEqual(h.hostShared, false)
        XCTAssertEqual(h.lastSeen, now); XCTAssertNil(h.unreachableSince); XCTAssertNil(h.failedProbes); XCTAssertNil(h.refusal)
        XCTAssertNil(h.lastConnected, "a probe is not a connection")
        m.apply(to: &h, seenAt: now, incompatibility: nil, connected: true)
        XCTAssertEqual(h.lastConnected, now)
        // An older host's record says less: what it leaves out stays known.
        let old = HostMetadata(welcome: .init(hostName: "green-machine", sessionID: "s"))
        old.apply(to: &h, seenAt: now, incompatibility: nil, connected: false)
        XCTAssertEqual(h.model, "iMac21,1"); XCTAssertEqual(h.hostOS, "26.1"); XCTAssertEqual(h.hostChannel, .nightly)
        XCTAssertNil(h.hostSettings, "unknown from an older host")
    }
}
