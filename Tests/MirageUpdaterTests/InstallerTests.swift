import XCTest
import CryptoKit
import MirageCore
@testable import MirageUpdater

/// The swap, commit and rollback on throwaway bundles (DESIGN §3.10), end to end through the real Updater and HostHealth:
/// a local feed signed by a test key the store has learned, and a verifier that stands in for Developer ID and
/// notarization (which only real release builds pass). Never touches an installed app.
final class InstallerTests: XCTestCase {
    var root: URL!
    var paths: InstallPaths!
    var feed: URL!
    let key = Curve25519.Signing.PrivateKey()

    struct FakeVerifier: BundleVerifying {
        var fail: String?
        func verify(app: URL, expected: MirageVersion) throws {
            if let fail { throw UpdateError.verification(fail) }
            guard Installer.version(of: app) == expected else { throw UpdateError.verification("version mismatch") }
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-updatetest-\(UUID().uuidString)", isDirectory: true)
        paths = InstallPaths(app: root.appendingPathComponent("Applications/Mirage.app", isDirectory: true), support: root.appendingPathComponent("Support", isDirectory: true))
        feed = root.appendingPathComponent("feed", isDirectory: true)
        try makeBundle(at: paths.app, ver(412))
        var s = UpdateSettings(); s.channel = .nightly; s.learnedKeys = [key.publicKey.rawRepresentation.base64EncodedString()]
        try s.save(paths.settings)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func makeBundle(at app: URL, _ v: MirageVersion) throws {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.paulherz.mirage", "CFBundleShortVersionString": v.version, "CFBundleVersion": "\(v.build)",
                                   "MirageCommit": v.commit, "MirageChannel": v.channel?.rawValue ?? ""]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/miraged"))
    }

    /// Publishes build `v` to the local feed's nightly head: zip, manifest (zip URL relative to it), signature.
    @discardableResult
    func publish(_ v: MirageVersion, corruptZip: Bool = false) throws -> Manifest {
        let rel = feed.appendingPathComponent("nightly-\(v.build)", isDirectory: true)
        let src = root.appendingPathComponent("build-\(v.build)/Mirage.app", isDirectory: true)
        try makeBundle(at: src, v)
        try FileManager.default.createDirectory(at: rel, withIntermediateDirectories: true)
        let zip = rel.appendingPathComponent("Mirage-\(v.version)-\(v.build).zip")
        let r = SystemBundleVerifier.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", src.path, zip.path], timeout: 30)
        XCTAssertEqual(r.1, 0, r.0)
        let data = try Data(contentsOf: zip)
        let m = Manifest(channel: .nightly, version: v.version, build: v.build, commit: v.commit, minProtocol: Mirage.minProtocolVersion, protocolVersion: Mirage.protocolVersion,
                         minOS: "15.0", zipURL: "../nightly-\(v.build)/\(zip.lastPathComponent)",
                         zipSHA256: SHA256.hash(data: corruptZip ? data + Data([0]) : data).map { String(format: "%02x", $0) }.joined(),
                         zipSize: data.count, notes: "", published: Date(), expires: Date().addingTimeInterval(86_400))
        let head = feed.appendingPathComponent("channel-nightly", isDirectory: true)
        try FileManager.default.createDirectory(at: head, withIntermediateDirectories: true)
        let md = try m.encoded()
        try md.write(to: head.appendingPathComponent("manifest.json"))
        try ManifestKey.sign(md, with: [key]).write(to: head.appendingPathComponent("manifest.sigs.json"))
        return m
    }

    func updater(running: MirageVersion = ver(412), verifier: BundleVerifying = FakeVerifier()) -> Updater {
        Updater(paths: paths, feed: Feed(base: feed), verifier: verifier, running: running)
    }
    func installed() -> Int? { Installer.version(of: paths.app)?.build }
    func previous() -> Int? { Installer.version(of: paths.previous)?.build }

    final class Exits: @unchecked Sendable { var n = 0 }

    func testUpdateSwapsAndTheNewHostCommits() async throws {
        let m = try publish(ver(420, "0.4.1"))
        guard case .swapped(let p) = try await updater().install() else { return XCTFail("expected a swap") }
        XCTAssertEqual(installed(), 420); XCTAssertEqual(previous(), 412, "exactly one previous bundle, outside /Applications")
        XCTAssertEqual(p.from.build, 412); XCTAssertEqual(p.to, m.mirageVersion); XCTAssertEqual(p.attempts, 0)
        XCTAssertEqual(Installer(paths: paths).readPending()?.to, p.to)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.staging(420).path), "staging cleaned up")
        XCTAssertEqual(UpdateSettings.load(paths.settings).latest, m.mirageVersion, "the check recorded the newest")

        // The new host starts, counts the attempt, passes its checks and commits.
        let exits = Exits()
        let h = HostHealth(paths: paths, running: m.mirageVersion, logFile: nil, log: { _ in }, exitProcess: { exits.n += 1 })
        XCTAssertTrue(h.launch())
        XCTAssertTrue(h.onTrial)
        XCTAssertEqual(Installer(paths: paths).readPending()?.attempts, 1)
        h.passed(.listener); h.passed(.control)
        XCTAssertNotNil(Installer(paths: paths).readPending(), "not yet: the capture probe has not reported")
        h.passed(.capture("frame 64×36"))
        XCTAssertNil(Installer(paths: paths).readPending(), "committed: the file is gone")
        XCTAssertEqual(Installer(paths: paths).readResult()?.outcome, .committed)
        XCTAssertFalse(h.onTrial)
        h.checkDeadline(p, now: p.deadline.addingTimeInterval(1))
        XCTAssertEqual(exits.n, 0, "a committed build is not rolled back at the deadline")
        XCTAssertEqual(installed(), 420)

        // Now up to date.
        if case .nothing(.upToDate) = try await updater(running: m.mirageVersion).install() {} else { XCTFail("up to date") }
    }

    /// The broken-build test as pure files: a build that exits in main is started three times, the third start swaps the
    /// previous bundle back, and the build is skipped from then on.
    func testABuildThatNeverCommitsRollsBackOnItsThirdStart() async throws {
        let m = try publish(ver(420))
        guard case .swapped = try await updater().install() else { return XCTFail() }
        let new = m.mirageVersion
        for start in 1...2 {
            let h = HostHealth(paths: paths, running: new, logFile: nil, log: { _ in })
            XCTAssertTrue(h.launch(), "start \(start) runs")   // …and exits in main
        }
        let h = HostHealth(paths: paths, running: new, logFile: nil, log: { _ in })
        XCTAssertFalse(h.launch(), "the third start rolls back and exits")
        XCTAssertEqual(installed(), 412)
        XCTAssertNil(previous(), "the failed build is not kept")
        XCTAssertNil(Installer(paths: paths).readPending())
        let r = try XCTUnwrap(Installer(paths: paths).readResult())
        XCTAssertEqual(r.outcome, .rolledBack); XCTAssertEqual(r.to.build, 420)
        XCTAssertEqual(UpdateSettings.load(paths.settings).skippedBuilds, [420])
        // The old host starts normally, and is not offered 420 again.
        XCTAssertTrue(HostHealth(paths: paths, running: ver(412), logFile: nil, log: { _ in }).launch())
        if case .nothing(.skipped) = try await updater().install() {} else { XCTFail("420 is skipped") }
        try publish(ver(421))
        if case .swapped = try await updater().install() {} else { XCTFail("a newer build is offered again") }
    }

    func testTheDeadlineRollsBackARunningButUnhealthyBuild() async throws {
        let m = try publish(ver(420))
        guard case .swapped(let p) = try await updater().install() else { return XCTFail() }
        let exits = Exits()
        let h = HostHealth(paths: paths, running: m.mirageVersion, logFile: nil, log: { _ in }, exitProcess: { exits.n += 1 })
        XCTAssertTrue(h.launch())
        h.passed(.listener)   // never the control socket
        h.checkDeadline(p, now: p.deadline.addingTimeInterval(-1))
        XCTAssertEqual(exits.n, 0)
        h.checkDeadline(p, now: p.deadline)
        XCTAssertEqual(exits.n, 1, "rolled back and exited")
        XCTAssertEqual(installed(), 412)
        XCTAssertEqual(Installer(paths: paths).readResult()?.outcome, .rolledBack)
        XCTAssertTrue(Installer(paths: paths).readResult()?.message.contains("control false") ?? false)
    }

    func testNothingIsReplacedWhenVerificationFails() async throws {
        try publish(ver(420), corruptZip: true)
        do { _ = try await updater().install(); XCTFail("a zip whose digest differs from the manifest must be refused") }
        catch { XCTAssertTrue("\(error)".contains("SHA-256"), "\(error)") }
        XCTAssertEqual(installed(), 412); XCTAssertNil(Installer(paths: paths).readPending())

        try publish(ver(421))
        do { _ = try await updater(verifier: FakeVerifier(fail: "Gatekeeper rejects Mirage.app")).install(); XCTFail("refused") }
        catch { XCTAssertTrue("\(error)".contains("Gatekeeper"), "\(error)") }
        XCTAssertEqual(installed(), 412); XCTAssertNil(previous()); XCTAssertNil(Installer(paths: paths).readPending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.staging(421).path), "the refused build is not left staged")
    }

    func testAManifestSignedByAnUntrustedKeyInstallsNothing() async throws {
        try publish(ver(420))
        var s = UpdateSettings.load(paths.settings); s.learnedKeys = []; try s.save(paths.settings)
        do { _ = try await updater().install(); XCTFail("refused") } catch {}
        XCTAssertEqual(installed(), 412)
    }

    func testATriggerNamesOnlyTheBuildTheFeedLists() async throws {
        try publish(ver(420))
        do { _ = try await updater().install(targetBuild: 999); XCTFail("refused") }
        catch { XCTAssertEqual(error as? UpdateError, .refused("the feed lists build 420, not 999")) }
        if case .swapped = try await updater().install(targetBuild: 420) {} else { XCTFail() }
    }

    func testManualRollbackAndOneUpdateAtATime() async throws {
        try publish(ver(420))
        let installer = Installer(paths: paths)
        let fd = try installer.lock()
        do { _ = try await updater().install(); XCTFail("busy") } catch { XCTAssertEqual(error as? UpdateError, .busy) }
        flock(fd, LOCK_UN); close(fd)
        guard case .swapped = try await updater().install() else { return XCTFail() }
        let (from, to) = try updater(running: ver(420)).rollback()
        XCTAssertEqual(from?.build, 420); XCTAssertEqual(to?.build, 412)
        XCTAssertEqual(installed(), 412); XCTAssertEqual(previous(), 420, "a manual rollback keeps the replaced build as the previous one")
        XCTAssertNil(installer.readPending())
        XCTAssertEqual(UpdateSettings.load(paths.settings).skippedBuilds, [420])
    }

    func testTheOldBuildFindingThePendingFileRecordsARollback() async throws {
        try publish(ver(420))
        guard case .swapped = try await updater().install() else { return XCTFail() }
        try Installer.swap(paths.previous, paths.app)   // what rollback-host.sh does
        XCTAssertTrue(HostHealth(paths: paths, running: ver(412), logFile: nil, log: { _ in }).launch())
        XCTAssertNil(Installer(paths: paths).readPending())
        XCTAssertEqual(Installer(paths: paths).readResult()?.outcome, .rolledBack)
        XCTAssertEqual(UpdateSettings.load(paths.settings).skippedBuilds, [420])
    }

    func testInstalledAppPath() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support/Mirage")
        XCTAssertEqual(InstallPaths.installedApp(executable: URL(fileURLWithPath: "/Applications/Mirage.app"), support: support).path, "/Applications/Mirage.app")
        XCTAssertEqual(InstallPaths.installedApp(executable: URL(fileURLWithPath: "/Users/x/Repos/mirage/.build/updatetest/Mirage.app"), support: support).path,
                       "/Users/x/Repos/mirage/.build/updatetest/Mirage.app")
        XCTAssertEqual(InstallPaths.installedApp(executable: support.appendingPathComponent("Previous/Mirage.app"), support: support).path, "/Applications/Mirage.app",
                       "the previous copy (rollback-host.sh) updates the installed app")
        XCTAssertEqual(InstallPaths.installedApp(executable: URL(fileURLWithPath: "/Users/x/Repos/mirage/.build/release"), support: support).path, "/Applications/Mirage.app")
    }
}
