import XCTest
@testable import mirage_viewer
@testable import MirageCore

/// Adding a Mac pairs without connecting (phrz, 2026-10-26): the row waits for the Mac's Allow with no Connect, a status
/// probe then checks that it takes this device, and only then is it a normal row; a refusal records nothing.
@MainActor
final class AddMacPairingTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var saved: ((String) -> @Sendable () async -> Bool, Duration, TimeInterval, UserDefaults)!

    override func setUp() {
        suite = "mirage-pairing-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        let c = HostPairingCenter.shared
        saved = (c.check, c.checkEvery, c.checkWindow, c.defaults)
        c.defaults = defaults
        c.checkEvery = .milliseconds(10)
        ListNotices.shared.reset()
    }
    override func tearDown() {
        let c = HostPairingCenter.shared
        (c.check, c.checkEvery, c.checkWindow, c.defaults) = saved
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testPhases() {
        let p = PairingPhase.pending(hostName: "mac-daddy.local")
        XCTAssertEqual(p.next(.awaiting("mac-daddy")), .pending(hostName: "mac-daddy"), "the host's own name, once its challenge came")
        XCTAssertEqual(p.line, "Waiting for mac-daddy.local to accept…")
        let a = p.next(.awaiting("mac-daddy")).next(.allowed("mac-daddy"))
        XCTAssertEqual(a, .accepted(hostName: "mac-daddy"))
        XCTAssertTrue(a.inProgress)
        XCTAssertEqual(a.next(.awaiting("x")), a, "a late event changes nothing")
        XCTAssertEqual(a.next(.answered), .connectable(hostName: "mac-daddy", answered: true))
        XCTAssertEqual(a.next(.gaveUp), .connectable(hostName: "mac-daddy", answered: false))
        XCTAssertEqual(a.next(.answered).note(connectHint: "Double-click it to connect."), "mac-daddy is ready. Double-click it to connect.")
        let r = p.next(.awaiting("mac-daddy")).next(.failed("denied on the host"))
        XCTAssertEqual(r, .refused(hostName: "mac-daddy", reason: "denied on the host"))
        XCTAssertFalse(r.inProgress)
        XCTAssertEqual(r.next(.allowed("mac-daddy")), r, "refused is final")
        XCTAssertEqual(HostPairing.reason(MirageError.authenticationFailed("host rejected: denied on the host")), "denied on the host")
        XCTAssertEqual(HostPairing.reason(MirageError.pairingFailed("wrong code")), "wrong code")
    }

    /// pending → accepted → connectable: no Connect until the Mac allowed it and a probe got through; the new row is
    /// selected, first in the list, and the note says it is ready.
    func testPendingThenAcceptedThenConnectable() async throws {
        let c = HostPairingCenter.shared
        final class Gate: @unchecked Sendable {
            let allow = AsyncStream<Void>.makeStream()
            let lock = NSLock(); var checks = 0
        }
        let gate = Gate()
        c.check = { alias in
            XCTAssertEqual(alias, "studio.local")
            return { gate.lock.withLock { gate.checks += 1; return gate.checks >= 3 } }   // answers on the third try
        }
        let existing = [PairedHost(alias: "mac-daddy", name: "mac-daddy")]
        let task = c.pair(alias: "studio.local", hostName: nil) { awaiting in
            awaiting("studio")
            for await _ in gate.allow.stream { break }   // the Mac's user has not answered yet
            return DeviceRecord(id: "s", name: "studio", publicKey: Data(), pairedAt: Date())
        }
        XCTAssertEqual(c.takeSelection(), "studio.local", "the new row is selected at once")
        try await waitFor { if case .pending("studio") = c.phases["studio.local"] { return true }; return false }
        var rows = c.rows(existing)
        XCTAssertEqual(rows.map(\.alias), ["studio.local", "mac-daddy"], "the new Mac first")
        XCTAssertFalse(rows[0].canConnect, "no Connect while the Mac has to allow it")
        XCTAssertEqual(rows[0].detail(), "Waiting for studio to accept…")
        XCTAssertTrue(rows[1].canConnect)
        XCTAssertNil(ListNotices.shared.note)

        gate.allow.continuation.yield()
        await task.value
        XCTAssertEqual(c.phases["studio.local"], .connectable(hostName: "studio", answered: true))
        XCTAssertEqual(gate.checks, 3, "checked until it answered")
        rows = c.rows(existing)
        XCTAssertEqual(rows.map(\.alias), ["mac-daddy"], "a normal row now: the list shows it from known-hosts")
        XCTAssertEqual(c.takeSelection(), "studio.local", "selected again once ready")
        XCTAssertEqual(ListNotices.shared.note, "studio is ready. \(HostPairingCenter.connectHint)", "a passing note")
        XCTAssertTrue(ListNotices.shared.alerts.isEmpty, "nothing to acknowledge")
        XCTAssertEqual(ViewerSettings.recentHosts(defaults).first, "studio.local", "first in the list")
    }

    /// pending → refused: the reason shows, the row goes, nothing is checked.
    func testPendingThenRefused() async throws {
        let c = HostPairingCenter.shared
        final class Count: @unchecked Sendable { var n = 0 }
        let checks = Count()
        c.check = { _ in { checks.n += 1; return true } }
        let task = c.pair(alias: "studio.local", hostName: "studio") { awaiting in
            awaiting("studio")
            throw MirageError.authenticationFailed("host rejected: denied on the host")
        }
        await task.value
        XCTAssertEqual(c.phases["studio.local"], .refused(hostName: "studio", reason: "denied on the host"))
        XCTAssertEqual(c.rows([]).count, 0, "no row for a Mac that refused")
        XCTAssertEqual(ListNotices.shared.current, ListAlert(title: "Not paired with studio", message: "Denied on the host."), "an alert, not a footer")
        XCTAssertNil(ListNotices.shared.note)
        XCTAssertEqual(checks.n, 0)
        XCTAssertEqual(ViewerSettings.recentHosts(defaults), [])
    }

    /// The Mac allowed it but never answers a probe in the minute: a normal row anyway (it is paired), and the note says so.
    func testAcceptedButSilentBecomesConnectableAfterTheWindow() async throws {
        let c = HostPairingCenter.shared
        c.checkWindow = 0.05
        c.check = { _ in { false } }
        await c.pair(alias: "studio.local", hostName: nil) { _ in DeviceRecord(id: "s", name: "studio", publicKey: Data(), pairedAt: Date()) }.value
        XCTAssertEqual(c.phases["studio.local"], .connectable(hostName: "studio", answered: false))
        XCTAssertTrue(ListNotices.shared.note?.hasPrefix("Paired with studio.") ?? false, ListNotices.shared.note ?? "nil")
    }

    /// A Mac that is recorded already (pairing again from a link) keeps its row and carries the phase.
    func testRepairingARecordedMacKeepsItsRow() {
        let c = HostPairingCenter.shared
        let t = c.pair(alias: "mac-daddy", hostName: "mac-daddy") { _ in try await Task.sleep(for: .seconds(30)); throw CancellationError() }
        defer { t.cancel() }
        let rows = c.rows([PairedHost(alias: "mac-daddy", name: "mac-daddy", model: "Mac15,14")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].model, "Mac15,14")
        XCTAssertFalse(rows[0].canConnect)
    }

    private func waitFor(_ cond: @MainActor () -> Bool, seconds: Double = 5) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !cond() {
            guard Date() < end else { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
