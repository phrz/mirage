import XCTest
import MirageCore
@testable import MirageUpdater

/// U6 review: the gate asked again before the swap and the restart, suspended sessions, a losing trigger, the try kept
/// or given back.
extension InstallerTests {
    final class Steps: @unchecked Sendable {
        private let lock = NSLock(); private var items: [ControlMessage.UpdateStatus] = []; private(set) var handOffs = 0
        func add(_ s: ControlMessage.UpdateStatus) { lock.lock(); items.append(s); lock.unlock() }
        func handedOff() { lock.lock(); handOffs += 1; lock.unlock() }
        var all: [ControlMessage.UpdateStatus] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func agent(_ steps: Steps, inProgress: UpdateInProgress = UpdateInProgress()) -> AgentUpdater {
        AgentUpdater(paths: paths, hostName: "test-host", listeners: UpdateListeners(), inProgress: inProgress, feed: Feed(base: feed),
                     verifier: FakeVerifier(), handOff: { _ in steps.handedOff() }, log: { _ in })
    }

    /// 1: the moment ends during the download: nothing is replaced, nothing staged or pending, no failure recorded.
    func testTheGateBeforeTheSwapDefers() async throws {
        try publish(ver(420))
        let steps = Steps()
        let ending = await agent(steps).update(target: 420, requester: .thisMac, gate: { "1 viewer is streaming" }, replyTo: { steps.add($0) })
        XCTAssertEqual(ending, .deferred)
        XCTAssertFalse(ending.consumesTry, "a deferral gives the automatic try back")
        XCTAssertEqual(installed(), 412); XCTAssertNil(previous())
        XCTAssertNil(Installer(paths: paths).readPending())
        XCTAssertNil(Installer(paths: paths).readResult(), "no failed update-result.json for a deferral")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.staging(420).path))
        XCTAssertEqual(steps.handOffs, 0)
        XCTAssertTrue(steps.all.last?.message.hasPrefix("deferred") ?? false)
    }

    /// 1: quiet before the swap, not before the restart: the swap is undone and nothing restarts.
    func testTheGateBeforeTheRestartUndoesTheSwap() async throws {
        try publish(ver(420))
        let steps = Steps()
        final class Count: @unchecked Sendable { var n = 0 }
        let asked = Count()
        let ending = await agent(steps).update(target: 420, requester: .thisMac, gate: {
            asked.n += 1
            return asked.n >= 2 ? "this Mac was used 3 s ago" : nil   // quiet before the swap, not before the restart
        }, replyTo: { steps.add($0) })
        XCTAssertEqual(ending, .deferred)
        XCTAssertEqual(asked.n, 2)
        XCTAssertEqual(installed(), 412, "the old build back")
        XCTAssertNil(previous()); XCTAssertNil(Installer(paths: paths).readPending())
        XCTAssertEqual(steps.handOffs, 0, "no restart")
    }

    func testAQuietUpdateHandsOffWithFromAndTo() async throws {
        try publish(ver(420))
        let steps = Steps()
        let inProgress = UpdateInProgress()
        let ending = await agent(steps, inProgress: inProgress).update(target: 420, requester: .thisMac, gate: { nil }, replyTo: { steps.add($0) })
        XCTAssertEqual(ending, .swapped); XCTAssertTrue(ending.consumesTry)
        XCTAssertEqual(steps.handOffs, 1)
        // 7: every step after the feed named the build carries from and to.
        let downloading = try XCTUnwrap(steps.all.first { $0.phase == .downloading })
        XCTAssertEqual(downloading.from?.build, 412); XCTAssertEqual(downloading.to?.build, 420)
        XCTAssertEqual(inProgress.current?.to?.build, 420, "the in-progress state says updating to 420")
    }

    /// 3: a trigger that loses the race writes nothing and leaves the running update's state alone.
    func testALosingTriggerLeavesTheRunningUpdateAlone() async throws {
        try publish(ver(420))
        let inProgress = UpdateInProgress()
        let running = ControlMessage.UpdateStatus(phase: .downloading, message: "downloading 0.4.0 (420)", from: ver(412), to: ver(420), yours: true)
        inProgress.set(running)
        let fd = try Installer(paths: paths).lock()   // the running update holds the lock
        defer { flock(fd, LOCK_UN); close(fd) }
        let steps = Steps()
        let ending = await agent(steps, inProgress: inProgress).update(target: 420, requester: UpdateRequester(name: "phone", connectionID: UUID()), replyTo: { steps.add($0) })
        XCTAssertEqual(ending, .busy); XCTAssertFalse(ending.consumesTry)
        XCTAssertEqual(inProgress.current, running, "untouched")
        XCTAssertNil(Installer(paths: paths).readResult(), "no failed update-result.json")
        let reply = try XCTUnwrap(steps.all.last)
        XCTAssertEqual(reply.phase, .downloading); XCTAssertEqual(reply.yours, false); XCTAssertEqual(reply.to?.build, 420)
        XCTAssertTrue(reply.message.contains("already updating"))
    }

    /// 5: transient failures give the try back; a real failure keeps it used.
    func testTransientFailuresDoNotUseTheTry() async throws {
        let steps = Steps()
        // No feed at all: a network-class failure.
        let gone = AgentUpdater(paths: paths, hostName: "h", listeners: UpdateListeners(), inProgress: UpdateInProgress(),
                                feed: Feed(base: root.appendingPathComponent("no-feed", isDirectory: true)), verifier: FakeVerifier(),
                                handOff: { _ in }, log: { _ in })
        let e1 = await gone.update(target: nil, requester: .thisMac, replyTo: { steps.add($0) })
        XCTAssertEqual(e1, .failed(transient: true)); XCTAssertFalse(e1.consumesTry)
        // A build that fails verification: a real failure.
        try publish(ver(420))
        let bad = AgentUpdater(paths: paths, hostName: "h", listeners: UpdateListeners(), inProgress: UpdateInProgress(), feed: Feed(base: feed),
                               verifier: FakeVerifier(fail: "Gatekeeper rejects Mirage.app"), handOff: { _ in }, log: { _ in })
        let e2 = await bad.update(target: 420, requester: .thisMac, replyTo: { steps.add($0) })
        XCTAssertEqual(e2, .failed(transient: false)); XCTAssertTrue(e2.consumesTry)
        XCTAssertEqual(Installer(paths: paths).readResult()?.outcome, .failed)
    }

    /// 5: the attempt record: saved before, given back on a transient end, and skipped when it cannot be saved.
    func testTheAttemptRecord() throws {
        XCTAssertTrue(AutomaticUpdate.recordAttempt(450, settings: paths.settings))
        XCTAssertEqual(UpdateSettings.load(paths.settings).automaticTried, [450])
        AutomaticUpdate.releaseAttempt(450, settings: paths.settings)
        XCTAssertEqual(UpdateSettings.load(paths.settings).automaticTried, [])
        // A settings file that cannot be written: no attempt.
        let ro = root.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        XCTAssertFalse(AutomaticUpdate.recordAttempt(450, settings: ro.appendingPathComponent("updates.json")))
    }
}

final class SuspendedGateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// 2: a session suspended less than 10 min ago counts as streaming; an older one does not.
    func testSuspendedSessionsBlockTheGate() {
        var s = UpdateSettings(); s.policy = .automatic; s.latest = ver(450)
        let recent = AutomaticUpdate.Moment.recent([now.addingTimeInterval(-120), now.addingTimeInterval(-3600)], now: now)
        XCTAssertEqual(recent, 1)
        let m = AutomaticUpdate.Moment(streaming: 0, lastStreamEnded: nil, systemPrompt: false, idleSeconds: 3600, now: now, suspendedRecently: recent)
        guard case .wait(let why) = AutomaticUpdate.decide(settings: s, running: ver(449), moment: m) else { return XCTFail() }
        XCTAssertTrue(why.contains("suspended"), why)
        let old = AutomaticUpdate.Moment(streaming: 0, lastStreamEnded: nil, systemPrompt: false, idleSeconds: 3600, now: now,
                                         suspendedRecently: AutomaticUpdate.Moment.recent([now.addingTimeInterval(-3600)], now: now))
        XCTAssertEqual(AutomaticUpdate.decide(settings: s, running: ver(449), moment: old), .install(ver(450)))
        XCTAssertNotNil(AutomaticUpdate.gateReason(m))
        XCTAssertNil(AutomaticUpdate.gateReason(old))
    }
}

/// U6 review 8: the cask's preflight refuses to replace a newer build (the installed bundle's, or the one the host
/// committed last), so a greedy upgrade or a reinstall never downgrades a self-updated host.
final class CaskPreflightTests: XCTestCase {
    func testThePreflightRefusesANewerInstall() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cask = try String(contentsOf: repo.appendingPathComponent("homebrew/Casks/mirage.rb"), encoding: .utf8)
        let start = try XCTUnwrap(cask.range(of: "<<~SH, \"sh\", version, \"{{user}}\"]\n"))
        let end = try XCTUnwrap(cask.range(of: "\n    SH\n", range: start.upperBound..<cask.endIndex))
        let script = cask[start.upperBound..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("      ") ? String($0.dropFirst(6)) : String($0) }.joined(separator: "\n")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-cask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Mirage.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Mirage"), withIntermediateDirectories: true)
        func installed(_ build: Int?) throws {
            let plist = app.appendingPathComponent("Contents/Info.plist")
            if let build { try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "\(build)"], format: .xml, options: 0).write(to: plist) }
            else { try? FileManager.default.removeItem(at: plist) }
        }
        func committed(_ build: Int?) throws {
            let f = home.appendingPathComponent("Library/Application Support/Mirage/updates.json")
            if let build { try Data(#"{"identity":{"build":\#(build)}}"#.utf8).write(to: f) } else { try? FileManager.default.removeItem(at: f) }
        }
        func run(_ caskVersion: String) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "sh", caskVersion, "nobody", app.path]
            p.environment = ["HOME": home.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        try installed(nil); try committed(nil)
        XCTAssertEqual(run("0.2.0,470"), 0, "nothing installed")
        try installed(460)
        XCTAssertEqual(run("0.2.0,470"), 0, "an older install is replaced")
        try installed(480)
        XCTAssertNotEqual(run("0.2.0,470"), 0, "a newer installed bundle is kept")
        try installed(460); try committed(480)
        XCTAssertNotEqual(run("0.2.0,470"), 0, "the host committed a newer build (the bundle may be moved aside during an upgrade)")
        XCTAssertEqual(run("0.2.0,480"), 0, "the same build reinstalls")
    }
}
