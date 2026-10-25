import XCTest
import MirageCore
@testable import MirageUpdater

/// A change of signing identity (Apple Development ↔ Developer ID) costs the TCC grants and the agent's registration: the
/// updater refuses it unless asked (mac-daddy, 2026-10-26).
final class IdentityTests: XCTestCase {
    let dev = SigningIdentity(app: #"identifier "com.paulherz.mirage" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Paul Herz (MHU225AX7U)""#,
                              host: #"identifier "com.paulherz.mirage.host" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Paul Herz (MHU225AX7U)""#)
    let devID = SigningIdentity(app: #"identifier "com.paulherz.mirage" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[subject.OU] = M8MME6Q9DA"#,
                                host: #"identifier "com.paulherz.mirage.host" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[subject.OU] = M8MME6Q9DA"#)

    func testComparison() {
        XCTAssertNil(SigningIdentity.change(from: dev, to: dev))
        XCTAssertNil(SigningIdentity.change(from: devID, to: SigningIdentity(app: devID.app, host: devID.host, build: 999)), "the build does not count")
        let c = SigningIdentity.change(from: dev, to: devID)
        XCTAssertTrue(c?.hasPrefix("signing identity change: the app's") ?? false, c ?? "nil")
        XCTAssertTrue(c?.contains("and miraged's") ?? false)
        let hostOnly = SigningIdentity.change(from: dev, to: SigningIdentity(app: dev.app, host: devID.host))
        XCTAssertTrue(hostOnly?.hasPrefix("signing identity change: miraged's") ?? false, hostOnly ?? "nil")
        XCTAssertNotNil(SigningIdentity.change(from: SigningIdentity(app: nil, host: nil), to: dev), "unsigned to signed is a change")
        XCTAssertNil(SigningIdentity.change(from: SigningIdentity(app: nil, host: nil), to: SigningIdentity(app: nil, host: nil)))
        XCTAssertTrue(SigningIdentity.refusal(c!).contains("--allow-identity-change"))
        XCTAssertTrue(SigningIdentity.refusal(c!, osMajor: 27).contains("Device Control and Data Access"), "macOS 27's name (PrivacyPane)")
        XCTAssertTrue(SigningIdentity.tccSteps(osMajor: 26).contains("→ Accessibility"))
        XCTAssertTrue(SigningIdentity.tccSteps(osMajor: 27).contains("Screen & System Audio Recording"))
    }

    func testReadsARealSignature() {
        let id = SigningIdentity.of(bundle: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        XCTAssertTrue(id.app?.contains("com.apple.calculator") ?? false, id.app ?? "nil")
    }
}

extension InstallerTests {
    final class Box: @unchecked Sendable { var running: SigningIdentity; var staged: SigningIdentity; init(_ r: SigningIdentity, _ s: SigningIdentity) { running = r; staged = s } }

    func identityUpdater(_ box: Box) -> Updater {
        let app = paths.app.standardizedFileURL.path
        return Updater(paths: paths, feed: Feed(base: feed), verifier: FakeVerifier(), running: ver(412),
                       identityOf: { $0.standardizedFileURL.path == app ? box.running : box.staged })
    }

    func testAnIdentityChangeIsRefusedUnlessAllowed() async throws {
        let t = IdentityTests()
        try publish(ver(420))
        let box = Box(t.dev, t.devID)
        do { _ = try await identityUpdater(box).install(); XCTFail("refused by default") }
        catch { XCTAssertTrue("\(error)".contains("signing identity change"), "\(error)") }
        XCTAssertEqual(installed(), 412, "nothing replaced")
        XCTAssertNil(Installer(paths: paths).readPending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.staging(420).path), "not left staged")

        guard case .swapped(let p, let change) = try await identityUpdater(box).install(allowIdentityChange: true) else { return XCTFail() }
        XCTAssertNotNil(change)
        XCTAssertEqual(p.reregistered, true, "a rollback must register the old identity again")
        XCTAssertEqual(installed(), 420)
    }

    func testTheSameIdentityUpdatesAndTheCommitRecordsIt() async throws {
        try publish(ver(420))
        let t = IdentityTests()
        guard case .swapped(let p, let change) = try await identityUpdater(Box(t.devID, t.devID)).install() else { return XCTFail() }
        XCTAssertNil(change); XCTAssertNil(p.reregistered)
        let h = HostHealth(paths: paths, running: ver(420), logFile: nil, log: { _ in })
        XCTAssertTrue(h.launch())
        h.passed(.listener); h.passed(.control); h.passed(.capture("frame"))
        let rec = try XCTUnwrap(UpdateSettings.load(paths.settings).identity)
        XCTAssertEqual(rec.build, 420, "recorded at commit, for the next comparison")
        // The record is used for its own build only.
        let u = Updater(paths: paths, feed: Feed(base: feed), verifier: FakeVerifier(), running: ver(420), identityOf: { _ in t.dev })
        XCTAssertEqual(u.runningIdentity(), rec)
        let other = Updater(paths: paths, feed: Feed(base: feed), verifier: FakeVerifier(), running: ver(421), identityOf: { _ in t.dev })
        XCTAssertEqual(other.runningIdentity(), t.dev)
    }
}
