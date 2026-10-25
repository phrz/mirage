import XCTest
import CryptoKit
import MirageCore
@testable import MirageUpdater

func ver(_ build: Int, _ version: String = "0.4.0", _ channel: UpdateChannel? = .nightly) -> MirageVersion {
    MirageVersion(version: version, build: build, commit: "c\(build)", channel: channel)
}

/// DESIGN §3.10: version comparison and the channel rules (switching channel never downgrades).
final class UpdateDecisionTests: XCTestCase {
    func manifest(_ build: Int, channel: UpdateChannel = .nightly, minOS: String = "15.0", minProtocol: Int = 5) -> Manifest {
        Manifest(channel: channel, version: "0.4.1", build: build, commit: "c\(build)", minProtocol: minProtocol, protocolVersion: 5, minOS: minOS,
                 zipURL: "z.zip", zipSHA256: "", zipSize: 0, notes: "", published: Date(), expires: Date().addingTimeInterval(1000))
    }
    let os = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)

    func testNewerBuildIsAnUpdate() {
        let d = UpdateDecision.decide(running: ver(412), manifest: manifest(420), channel: .nightly, skipped: [], os: os, runningProtocol: 5)
        XCTAssertEqual(d, .available(from: ver(412), to: manifest(420).mirageVersion))
        XCTAssertTrue(d.isAvailable)
        XCTAssertEqual(d.message, "Update available: 0.4.0 (412) → 0.4.1 (420) (nightly)")
    }

    func testTheSameBuildIsUpToDate() {
        XCTAssertEqual(UpdateDecision.decide(running: ver(420), manifest: manifest(420), channel: .nightly, skipped: [], os: os), .upToDate(ver(420)))
    }

    /// Moving a nightly host to stable changes the feed, not what runs: it stays until stable passes it.
    func testSwitchingChannelNeverDowngrades() {
        let d = UpdateDecision.decide(running: ver(412, "0.4.1", .nightly), manifest: manifest(400, channel: .stable), channel: .stable, skipped: [], os: os)
        XCTAssertEqual(d, .channelBehind(running: ver(412, "0.4.1", .nightly), channelHead: manifest(400, channel: .stable).mirageVersion, channel: .stable))
        XCTAssertFalse(d.isAvailable)
        XCTAssertEqual(d.message, "Stable catches up at build ≥ 413 (its newest is 0.4.1 (400)); staying on nightly 0.4.1 (412) until then.")
        // Once stable publishes a greater build, it is an ordinary update.
        XCTAssertTrue(UpdateDecision.decide(running: ver(412), manifest: manifest(413, channel: .stable), channel: .stable, skipped: [], os: os).isAvailable)
    }

    func testARolledBackBuildIsSkippedUntilANewerOne() {
        XCTAssertEqual(UpdateDecision.decide(running: ver(412), manifest: manifest(420), channel: .nightly, skipped: [420], os: os), .skipped(manifest(420).mirageVersion))
        XCTAssertTrue(UpdateDecision.decide(running: ver(412), manifest: manifest(421), channel: .nightly, skipped: [420], os: os).isAvailable)
    }

    func testMinOSAndMinProtocol() {
        if case .incompatible = UpdateDecision.decide(running: ver(412), manifest: manifest(420, minOS: "27.1"), channel: .nightly, skipped: [], os: os) {} else { XCTFail("needs a newer macOS") }
        XCTAssertTrue(UpdateDecision.decide(running: ver(412), manifest: manifest(420, minOS: "27.0.1"), channel: .nightly, skipped: [], os: os).isAvailable)
        XCTAssertTrue(UpdateDecision.decide(running: ver(412), manifest: manifest(420, minOS: "15"), channel: .nightly, skipped: [], os: os).isAvailable)
        if case .incompatible = UpdateDecision.decide(running: ver(412), manifest: manifest(420, minProtocol: 6), channel: .nightly, skipped: [], os: os, runningProtocol: 5) {} else {
            XCTFail("a build that drops the protocol this host's viewers speak is not installed")
        }
    }
}

final class UpdateSettingsTests: XCTestCase {
    func testDefaultsAndSet() throws {
        var s = UpdateSettings()
        XCTAssertEqual(s.channel, .stable); XCTAssertEqual(s.policy, .ask); XCTAssertEqual(s.trigger, .anyDevice)
        s.latest = ver(400, "0.4.0", .stable)
        try s.apply("channel=nightly"); try s.apply("policy = automatic"); try s.apply("trigger=this-mac")
        XCTAssertEqual(s.channel, .nightly); XCTAssertEqual(s.policy, .automatic); XCTAssertEqual(s.trigger, .thisMac)
        XCTAssertNil(s.latest, "the newest found was another channel's")
        XCTAssertThrowsError(try s.apply("channel=canary"))
        XCTAssertThrowsError(try s.apply("colour=red"))
        XCTAssertThrowsError(try s.apply("policy"))
        XCTAssertEqual(s.hostUpdateInfo.permission, UpdatePermission(policy: .automatic, viewerMayTrigger: false))
    }

    /// The trigger gate fails closed: an unreadable trigger value, or a file that does not parse, means this Mac only.
    func testTheTriggerSettingFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-trigger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("updates.json")
        try Data(#"{"trigger":"everyone"}"#.utf8).write(to: url)
        XCTAssertEqual(UpdateSettings.load(url).trigger, .thisMac)
        try Data(#"{"channel":"nightly"}"#.utf8).write(to: url)
        XCTAssertEqual(UpdateSettings.load(url).trigger, .anyDevice, "absent: phrz's default")
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(UpdateSettings.load(url).trigger, .thisMac)
        XCTAssertEqual(UpdateSettings.load(dir.appendingPathComponent("none.json")).trigger, .anyDevice, "no file yet: the default")
    }

    func testFileRoundTripToleratesUnknownValuesAndDropsRevokedKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("updates.json")
        var s = UpdateSettings(); s.channel = .beta; s.skippedBuilds = [3]
        try s.save(url)
        XCTAssertEqual(UpdateSettings.load(url), s)
        try Data(#"{"channel":"canary","policy":"automatic","skippedBuilds":[9]}"#.utf8).write(to: url)
        let t = UpdateSettings.load(url)
        XCTAssertEqual(t.channel, .stable, "a channel this build does not know falls back"); XCTAssertEqual(t.policy, .automatic); XCTAssertEqual(t.skippedBuilds, [9])
        XCTAssertEqual(UpdateSettings.load(dir.appendingPathComponent("none.json")), UpdateSettings())
        // Revoked keys leave the learned set when loaded.
        let k = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        var u = UpdateSettings(); u.learnedKeys = [k.base64EncodedString()]
        XCTAssertEqual(ManifestTrust(compiled: [], learned: u.learnedKeys, revoked: [ManifestKey.keyID(publicKey: k)]).prunedLearned(), [])
    }
}

/// DESIGN §3.10: the pending-update, attempts and rollback state machine.
final class UpdateHealthTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    var pending: PendingUpdate { PendingUpdate(from: ver(412), to: ver(420), deadline: t0.addingTimeInterval(300), appPath: "/Applications/Mirage.app", started: t0) }

    func testNoPendingUpdateStartsNormally() {
        XCTAssertEqual(UpdateHealth.onLaunch(nil, running: ver(420), appPath: "/Applications/Mirage.app", now: t0), .none)
    }

    func testTheNewBuildCountsItsStartsAndTheThirdRollsBack() {
        var p = pending
        guard case .trial(let a) = UpdateHealth.onLaunch(p, running: ver(420), appPath: "/Applications/Mirage.app", now: t0.addingTimeInterval(1)) else { return XCTFail() }
        XCTAssertEqual(a.attempts, 1)
        p = a
        guard case .trial(let b) = UpdateHealth.onLaunch(p, running: ver(420), appPath: "/Applications/Mirage.app", now: t0.addingTimeInterval(11)) else { return XCTFail() }
        XCTAssertEqual(b.attempts, 2)
        guard case .rollBack(let c, let why) = UpdateHealth.onLaunch(b, running: ver(420), appPath: "/Applications/Mirage.app", now: t0.addingTimeInterval(21)) else {
            return XCTFail("attempts reached 3: roll back")
        }
        XCTAssertEqual(c.attempts, 3)
        XCTAssertTrue(why.contains("3 times"), why)
    }

    func testThePassedDeadlineRollsBack() {
        guard case .rollBack(_, let why) = UpdateHealth.onLaunch(pending, running: ver(420), appPath: "/Applications/Mirage.app", now: t0.addingTimeInterval(300)) else { return XCTFail() }
        XCTAssertTrue(why.contains("5 min"), why)
        XCTAssertFalse(UpdateHealth.rollbackDue(pending, committed: false, now: t0.addingTimeInterval(299)))
        XCTAssertTrue(UpdateHealth.rollbackDue(pending, committed: false, now: t0.addingTimeInterval(300)))
        XCTAssertFalse(UpdateHealth.rollbackDue(pending, committed: true, now: t0.addingTimeInterval(9999)), "a committed build stays")
    }

    func testTheOldBuildRunningMeansItWasUndoneOutside() {
        XCTAssertEqual(UpdateHealth.onLaunch(pending, running: ver(412), appPath: "/Applications/Mirage.app", now: t0), .rolledBackOutside(pending))
        XCTAssertEqual(UpdateHealth.onLaunch(pending, running: ver(500), appPath: "/Applications/Mirage.app", now: t0), .discard(pending), "a manual reinstall")
    }

    func testAnotherCopyOfTheAppLeavesItAlone() {
        XCTAssertEqual(UpdateHealth.onLaunch(pending, running: ver(420), appPath: "/Users/x/Repos/mirage/.build/Mirage.app", now: t0), .none)
        guard case .trial = UpdateHealth.onLaunch(pending, running: ver(420), appPath: "/Applications/./Mirage.app", now: t0) else { return XCTFail("the same path, spelled differently") }
    }

    func testHealthyNeedsAllThree() {
        var c = UpdateHealth.Checks()
        XCTAssertFalse(c.healthy)
        c.listener = true; c.control = true
        XCTAssertFalse(c.healthy, "the capture probe has not reported")
        c.capture = "Screen Recording missing (no frame)"
        XCTAssertTrue(c.healthy, "a probe that names the missing grant counts")
    }
}

/// DESIGN §3.10 step 5: the self-test's output.
final class SelfTestTests: XCTestCase {
    func testParseTheVersionLine() {
        let v = ver(420, "0.4.1")
        let out = "self-test ok: Mirage 0.4.1 (420)\n\(SelfTest.line(v))\n"
        XCTAssertEqual(SelfTest.parse(out), v)
        XCTAssertTrue(SelfTest.line(v).hasPrefix("MIRAGE-SELF-TEST {\"build\":420,"), "release.sh greps for this")
        XCTAssertNil(SelfTest.parse("dyld: Library not loaded\n"))
        XCTAssertNil(SelfTest.parse("MIRAGE-SELF-TEST {broken"))
        XCTAssertEqual(SelfTest.parse("\(SelfTest.line(ver(1)))\n\(SelfTest.line(v))"), v, "the last line wins")
    }

    func testJudge() {
        let v = ver(420, "0.4.1")
        XCTAssertNil(SelfTest.judge(output: SelfTest.line(v), exitCode: 0, timedOut: false, expected: v))
        XCTAssertEqual(SelfTest.judge(output: "", exitCode: nil, timedOut: true, expected: v), "the self-test did not finish within 10 s")
        XCTAssertEqual(SelfTest.judge(output: "dyld[1]: Symbol not found", exitCode: 134, timedOut: false, expected: v), "the self-test exited 134: dyld[1]: Symbol not found")
        XCTAssertEqual(SelfTest.judge(output: "hello", exitCode: 0, timedOut: false, expected: v), "the self-test printed no version")
        XCTAssertEqual(SelfTest.judge(output: SelfTest.line(ver(419, "0.4.1")), exitCode: 0, timedOut: false, expected: v),
                       "the bundle is 0.4.1 (419) c419, the manifest says 0.4.1 (420) c420")
    }
}
