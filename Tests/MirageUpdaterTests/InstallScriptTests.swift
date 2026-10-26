import XCTest
import CryptoKit
import MirageCore
@testable import MirageUpdater

/// U5 review: install-host.sh verifies the channel head itself, before it downloads anything (Ed25519 with macOS's own
/// perl, the keys embedded in the script, the channel, the expiry, the floor). Runs the real script with --verify-only on
/// a local feed of manifests signed here with CryptoKit.
final class InstallScriptTests: XCTestCase {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/install-host.sh")
    let key = Curve25519.Signing.PrivateKey()
    var feed: URL!

    override func setUpWithError() throws {
        feed = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-feed-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: feed) }

    func publish(build: Int, channel: UpdateChannel = .nightly, expires: Date = Date().addingTimeInterval(86_400), signer: Curve25519.Signing.PrivateKey? = nil,
                 tamper: Bool = false) throws {
        let m = Manifest(channel: channel, version: "0.1", build: build, commit: "abc1234", minProtocol: 5, protocolVersion: 6, minOS: "15.0",
                         zipURL: "Mirage.zip", zipSHA256: String(repeating: "0", count: 64), zipSize: 1, notes: "", published: Date(), expires: expires)
        var d = try m.encoded()
        let sigs = try ManifestKey.sign(d, with: [signer ?? key])
        if tamper { d = Data(String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\"build\" : \(build)", with: "\"build\" : \(build + 1)").utf8) }
        let head = feed.appendingPathComponent("channel-\(channel.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: head, withIntermediateDirectories: true)
        try d.write(to: head.appendingPathComponent("manifest.json"))
        try sigs.write(to: head.appendingPathComponent("manifest.sigs.json"))
    }

    func run(channel: String = "nightly", keys: [Curve25519.Signing.PrivateKey]? = nil, floor: Int = 0) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, "--channel", channel, "--verify-only", "--feed", feed.absoluteString]
        var env = ProcessInfo.processInfo.environment
        env["MIRAGE_INSTALL_TEST_KEYS"] = (keys ?? [key]).map { $0.publicKey.rawRepresentation.base64EncodedString() }.joined(separator: " ")
        env["MIRAGE_INSTALL_TEST_MIN_BUILD"] = "\(floor)"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testAGoodHeadVerifies() throws {
        try publish(build: 450)
        let (rc, out) = run(floor: 449)
        XCTAssertEqual(rc, 0, out)
        XCTAssertTrue(out.contains("signed by \(ManifestKey.keyID(publicKey: key.publicKey.rawRepresentation))"), out)
        XCTAssertTrue(out.contains("manifest ok"), out)
        // Two trusted keys (current and next): either one's signature is enough.
        let next = Curve25519.Signing.PrivateKey()
        try publish(build: 450, signer: next)
        XCTAssertEqual(run(keys: [key, next]).0, 0)
    }

    func testAWrongKeyIsRefused() throws {
        try publish(build: 450, signer: Curve25519.Signing.PrivateKey())
        let (rc, out) = run()
        XCTAssertNotEqual(rc, 0)
        XCTAssertTrue(out.contains("not signed by a key this script trusts"), out)
    }

    func testATamperedHeadIsRefused() throws {
        try publish(build: 450, tamper: true)
        let (rc, out) = run()
        XCTAssertNotEqual(rc, 0)
        XCTAssertTrue(out.contains("not signed by a key this script trusts"), out)
    }

    func testAnExpiredHeadIsRefused() throws {
        try publish(build: 450, expires: Date().addingTimeInterval(-60))
        let (rc, out) = run()
        XCTAssertNotEqual(rc, 0)
        XCTAssertTrue(out.contains("expired"), out)
    }

    func testABuildUnderTheFloorIsRefused() throws {
        try publish(build: 440)
        let (rc, out) = run(floor: 449)
        XCTAssertNotEqual(rc, 0)
        XCTAssertTrue(out.contains("below this script's floor 449"), out)
        XCTAssertEqual(run(floor: 440).0, 0, "at the floor is fine")
    }

    func testAnotherChannelsHeadIsRefused() throws {
        try publish(build: 450, channel: .nightly)
        let head = feed.appendingPathComponent("channel-nightly")
        let stable = feed.appendingPathComponent("channel-stable")
        try FileManager.default.copyItem(at: head, to: stable)   // a nightly manifest served as stable
        let (rc, out) = run(channel: "stable")
        XCTAssertNotEqual(rc, 0)
        XCTAssertTrue(out.contains("is for nightly, not stable"), out)
    }

    func testTheScriptsKeysAreTheApps() throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("TRUSTED_KEYS=") })
        let keys = Set(line.dropFirst("TRUSTED_KEYS=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: " ").map(String.init))
        XCTAssertEqual(keys, Set(TrustedKeys.compiled), "release.sh --check keeps them equal; so does this test")
    }
}

/// U5 review: the user check, and the install's own path over an older build (the updater's lock, pending update,
/// swap and trial), with the settings saved only once the bundle is in place.
final class InstallUserTests: XCTestCase {
    func testWhoMayInstall() {
        XCTAssertNil(InstallUser.refusal(uid: 501, user: "phrz", consoleUser: "phrz"))
        XCTAssertTrue(InstallUser.refusal(uid: 0, user: "root", consoleUser: "phrz")?.contains("not run this as root") ?? false)
        XCTAssertTrue(InstallUser.refusal(uid: 502, user: "admin", consoleUser: "phrz")?.contains("run it as phrz") ?? false, "an SSH user who is not at the screen")
        XCTAssertTrue(InstallUser.refusal(uid: 501, user: "phrz", consoleUser: "root")?.contains("nobody is logged in") ?? false, "the login window")
        XCTAssertNotNil(InstallUser.refusal(uid: 501, user: "phrz", consoleUser: nil))
        XCTAssertNotNil(InstallUser.consoleUser(), "this Mac's console has an owner")
    }
}

extension InstallerTests {
    final class FakeAgent: InstallAgent, @unchecked Sendable {
        var registered: Bool
        var calls: [String] = []
        init(registered: Bool) { self.registered = registered }
        func turnOn() -> String { calls.append("turnOn"); return "on" }
        func ensureRunning() -> String { calls.append("ensureRunning"); return "running" }
    }

    func newBundle(_ v: MirageVersion) throws -> URL {
        let b = root.appendingPathComponent("download-\(v.build)/Mirage.app", isDirectory: true)
        try makeBundle(at: b, v)
        return b
    }

    func bundleInstaller(_ agent: FakeAgent, identity: @escaping (URL) -> SigningIdentity = { _ in SigningIdentity(app: "a", host: "h") }) -> BundleInstaller {
        BundleInstaller(paths: paths, agent: agent, identityOf: identity, say: { _ in })
    }

    func testReplacingGoesThroughTheUpdatersTrial() async throws {
        let agent = FakeAgent(registered: true)
        let b = try newBundle(ver(450))
        var trial: PendingUpdate?
        let plan = try await bundleInstaller(agent).install(bundle: b, version: ver(450), manifestChannel: .nightly, assignments: ["policy=automatic"],
                                                            force: false, allowIdentityChange: false, dryRun: false) { p, changed in
            trial = p
            XCTAssertFalse(changed)
            XCTAssertEqual(Installer(paths: self.paths).readPending()?.to.build, 450, "pending written before the restart: the new build's start counts")
        }
        XCTAssertEqual(plan, .replace(from: ver(412)))
        XCTAssertEqual(trial?.from.build, 412)
        XCTAssertEqual(installed(), 450); XCTAssertEqual(previous(), 412)
        XCTAssertEqual(UpdateSettings.load(paths.settings).policy, .automatic)
        XCTAssertEqual(UpdateSettings.load(paths.settings).channel, .nightly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleInstaller(agent).staged.path))
    }

    func testNoInstallWhileATrialIsPendingOrAnUpdateRuns() async throws {
        let b = try newBundle(ver(450))
        try Installer(paths: paths).writePending(PendingUpdate(from: ver(400), to: ver(412), deadline: Date().addingTimeInterval(300), appPath: paths.app.path, started: Date()))
        do {
            _ = try await bundleInstaller(FakeAgent(registered: true)).install(bundle: b, version: ver(450), manifestChannel: .nightly, assignments: [],
                                                                               force: false, allowIdentityChange: false, dryRun: false) { _, _ in }
            XCTFail("refused while 412 is on trial")
        } catch { XCTAssertTrue("\(error)".contains("on trial"), "\(error)") }
        Installer(paths: paths).clearPending()
        let fd = try Installer(paths: paths).lock()
        do {
            _ = try await bundleInstaller(FakeAgent(registered: true)).install(bundle: b, version: ver(450), manifestChannel: .nightly, assignments: [],
                                                                               force: false, allowIdentityChange: false, dryRun: false) { _, _ in }
            XCTFail("refused while another update holds the lock")
        } catch { XCTAssertEqual(error as? UpdateError, .busy) }
        flock(fd, LOCK_UN); close(fd)
        XCTAssertEqual(installed(), 412)
    }

    /// phrz, 2026-10-26: "dry run: nothing changed" landed on the settings line. Every summary line ends with its own
    /// newline, written whole, after what stdout buffered before it.
    func testEverySummaryLineEndsWithItsOwnNewline() async throws {
        XCTAssertEqual(InstallOutput.line("settings: channel nightly"), Data("settings: channel nightly\n".utf8))
        XCTAssertEqual(InstallOutput.line("dry run: nothing changed\n"), Data("dry run: nothing changed\n".utf8))
        XCTAssertEqual(InstallOutput.line("a\r\n\n"), Data("a\n".utf8))
        XCTAssertEqual(InstallOutput.line(""), Data("\n".utf8))
        // Through a pipe, as install-host.sh's terminal gets it: the installer's own lines from a dry run.
        let pipe = Pipe()
        let fd = pipe.fileHandleForWriting.fileDescriptor
        let b = try newBundle(ver(450))
        let i = BundleInstaller(paths: paths, agent: FakeAgent(registered: true), identityOf: { _ in SigningIdentity(app: "a", host: "h") },
                                say: { InstallOutput.say($0, fd: fd) })
        _ = try await i.install(bundle: b, version: ver(450), manifestChannel: .nightly, assignments: ["policy=ask"],
                                force: false, allowIdentityChange: false, dryRun: true) { _, _ in }
        try pipe.fileHandleForWriting.close()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4, out)
        XCTAssertTrue(lines[0].hasPrefix("plan: replace "), out)
        XCTAssertEqual(lines[1], "settings: channel nightly, policy ask, trigger \(UpdateSettings.load(paths.settings).trigger.rawValue)")
        XCTAssertEqual(lines[2], "dry run: nothing changed")
        XCTAssertEqual(lines[3], "", "the output ends with a newline")
    }

    func testSettingsOnlyAfterTheBundleIsInPlaceAndNothingLeftStaged() async throws {
        let b = try newBundle(ver(450))
        let before = UpdateSettings.load(paths.settings)
        // Dry run, and a refused plan: nothing saved.
        _ = try await bundleInstaller(FakeAgent(registered: true)).install(bundle: b, version: ver(450), manifestChannel: .beta, assignments: ["policy=automatic"],
                                                                           force: false, allowIdentityChange: false, dryRun: true) { _, _ in }
        XCTAssertEqual(UpdateSettings.load(paths.settings), before)
        // A copy that fails (the app's folder is read-only): no settings, nothing staged.
        let apps = paths.app.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path) }
        do {
            _ = try await bundleInstaller(FakeAgent(registered: true)).install(bundle: b, version: ver(450), manifestChannel: .beta, assignments: ["policy=automatic"],
                                                                               force: false, allowIdentityChange: false, dryRun: false) { _, _ in }
            XCTFail("the copy must fail")
        } catch {}
        XCTAssertEqual(UpdateSettings.load(paths.settings), before, "settings untouched by a failed install")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleInstaller(FakeAgent(registered: true)).staged.path))
        XCTAssertEqual(installed(), 412)
        XCTAssertNil(Installer(paths: paths).readPending())
    }

    func testAlreadyCurrentStillTurnsTheHostOn() async throws {
        let b = try newBundle(ver(412))
        let off = FakeAgent(registered: false)
        let plan = try await bundleInstaller(off).install(bundle: b, version: ver(412), manifestChannel: .nightly, assignments: [], force: false,
                                                          allowIdentityChange: false, dryRun: false) { _, _ in XCTFail("no swap") }
        XCTAssertEqual(plan, .current(ver(412)))
        XCTAssertEqual(off.calls, ["turnOn"])
        let on = FakeAgent(registered: true)
        _ = try await bundleInstaller(on).install(bundle: b, version: ver(412), manifestChannel: .nightly, assignments: [], force: false,
                                                  allowIdentityChange: false, dryRun: false) { _, _ in }
        XCTAssertEqual(on.calls, ["ensureRunning"])
    }

    func testAFreshInstallTurnsTheHostOnAndAnIdentityChangeMarksTheTrial() async throws {
        try FileManager.default.removeItem(at: paths.app)
        let agent = FakeAgent(registered: false)
        let b = try newBundle(ver(450))
        let plan = try await bundleInstaller(agent).install(bundle: b, version: ver(450), manifestChannel: .nightly, assignments: [], force: false,
                                                            allowIdentityChange: false, dryRun: false) { _, _ in XCTFail("no swap") }
        XCTAssertEqual(plan, .fresh)
        XCTAssertEqual(installed(), 450); XCTAssertEqual(agent.calls, ["turnOn"])
        // Over it, a build of another identity, allowed: the pending update says the agent will need registering again.
        let b2 = try newBundle(ver(460))
        let other = { (u: URL) -> SigningIdentity in u.path.contains("download-460") ? SigningIdentity(app: "devid", host: "devid") : SigningIdentity(app: "a", host: "h") }
        var marked: Bool?
        _ = try await bundleInstaller(agent, identity: other).install(bundle: b2, version: ver(460), manifestChannel: .nightly, assignments: [], force: false,
                                                                      allowIdentityChange: true, dryRun: false) { p, changed in marked = changed && p.reregistered == true }
        XCTAssertEqual(marked, true)
    }
}
