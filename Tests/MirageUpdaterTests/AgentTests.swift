import XCTest
import MirageCore
@testable import MirageUpdater

/// The login-item agent's state from `launchctl print`, and what the swapping process does when launchd refuses to spawn
/// the new build (mac-daddy, 2026-10-26: "Launch Constraint Violation", EX_CONFIG, after the switch to Developer ID).
final class AgentTests: XCTestCase {
    // Shapes from launchctl print on macOS 27 (the Finder's job here; the failure as mac-daddy reported it).
    let running = """
        gui/501/com.paulherz.mirage.host = {
        \tactive count = 1
        \tpath = /Applications/Mirage.app/Contents/Library/LaunchAgents/com.paulherz.mirage.host.plist
        \tstate = running
        \tprogram = /Applications/Mirage.app/Contents/MacOS/miraged
        \truns = 2
        \tpid = 91970
        \tlast exit code = 0
        \tendpoints = {
        \t\t"com.example" = {
        \t\t\tstate = active
        \t\t}
        \t}
        \tjob state = running
        \tproperties = needs LWCR update | has LWCR
        }
        """
    let spawnFailed = """
        gui/501/com.paulherz.mirage.host = {
        \tstate = not running
        \tprogram = /Applications/Mirage.app/Contents/MacOS/miraged
        \truns = 143
        \tlast exit code = 78: EX_CONFIG
        \tjob state = spawn failed
        \tproperties = needs LWCR update | has LWCR
        }
        """
    let between = """
        gui/501/com.paulherz.mirage.host = {
        \tstate = not running
        \tprogram = /Applications/Mirage.app/Contents/MacOS/miraged
        \tlast exit code = 1
        \tjob state = exited
        }
        """

    func testParse() {
        XCTAssertEqual(HostAgent.Status.parse(running), .running(pid: 91970, program: "/Applications/Mirage.app/Contents/MacOS/miraged"))
        XCTAssertEqual(HostAgent.Status.parse(spawnFailed), .spawnFailed("job state spawn failed, last exit code 78: EX_CONFIG"))
        XCTAssertEqual(HostAgent.Status.parse(between), .notRunning("state not running, last exit code 1"))
        XCTAssertEqual(HostAgent.Status.parse("Bad request.\nCould not find service \"com.paulherz.mirage.host\" in domain for user gui: 501\n"), .notLoaded)
        XCTAssertEqual(HostAgent.Status.fields(running)["state"], "running", "a nested block's state does not count")
        XCTAssertEqual(HostAgent.Status.fields(spawnFailed)["program"], "/Applications/Mirage.app/Contents/MacOS/miraged")
    }

    func testVerdict() {
        XCTAssertEqual(AgentWatch.verdict(.spawnFailed("x"), attempts: 0, elapsed: 0.5), .cannotSpawn("x"), "at once: it will never run")
        XCTAssertEqual(AgentWatch.verdict(.running(pid: 1, program: nil), attempts: 0, elapsed: 1), .started)
        XCTAssertEqual(AgentWatch.verdict(.notRunning("between runs"), attempts: 1, elapsed: 1), .started,
                       "it ran and counted an attempt: a crash in main is its own to roll back")
        XCTAssertEqual(AgentWatch.verdict(.notRunning("s"), attempts: 0, elapsed: 5), .keepWaiting)
        XCTAssertEqual(AgentWatch.verdict(.notRunning("s"), attempts: 0, elapsed: 20), .cannotSpawn("not started after 20 s (s)"))
        XCTAssertEqual(AgentWatch.verdict(.notLoaded, attempts: 0, elapsed: 20), .cannotSpawn("the agent is not loaded"))
        XCTAssertEqual(AgentWatch.verdict(.spawnFailed("x"), attempts: 1, elapsed: 0), .started, "an attempt counted means it did start once")
    }

    /// When the app registers the agent again at launch: launchd refuses it, or miraged's signature is not the one
    /// registered (mac-daddy's case: registered under Developer ID, then redeployed, LWCR stale).
    func testWhenToRegisterAgain() {
        let dev = #"identifier "com.paulherz.mirage.host" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Paul Herz (MHU225AX7U)""#
        let devID = #"identifier "com.paulherz.mirage.host" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[subject.OU] = M8MME6Q9DA"#
        let rec = HostAgent.Registration(requestID: "allow", at: Date(), status: "enabled", error: nil, requirement: dev)
        let up = HostAgent.Status.running(pid: 1, program: nil)
        XCTAssertNil(HostAgent.reregistrationReason(status: up, recorded: rec, currentRequirement: dev), "same signature, running: nothing to do")
        XCTAssertEqual(HostAgent.reregistrationReason(status: up, recorded: rec, currentRequirement: devID), "miraged's signature changed since it was registered")
        XCTAssertEqual(HostAgent.reregistrationReason(status: .spawnFailed("job state spawn failed"), recorded: rec, currentRequirement: dev),
                       "launchd cannot start it (job state spawn failed)", "a refused agent, whatever the record says")
        XCTAssertEqual(HostAgent.reregistrationReason(status: up, recorded: nil, currentRequirement: dev), "no record of the signature it was registered with")
        XCTAssertNil(HostAgent.reregistrationReason(status: up, recorded: nil, currentRequirement: nil), "an unsigned build: nothing to compare")
    }

    func testDesignatedRequirementOfASignedBinary() {
        let r = HostAgent.designatedRequirement(of: URL(fileURLWithPath: "/bin/ls"))
        XCTAssertTrue(r?.contains("com.apple.ls") ?? false, r ?? "nil")
        XCTAssertNil(HostAgent.designatedRequirement(of: URL(fileURLWithPath: "/nonexistent")))
    }

    func testPendingFromBeforeReregistrationDecodes() throws {
        let json = #"{"from":{"version":"0.1","build":1,"commit":"a"},"to":{"version":"0.1","build":2,"commit":"b"},"attempts":0,"deadline":"2026-10-26T00:00:00Z","appPath":"/Applications/Mirage.app","started":"2026-10-26T00:00:00Z"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        XCTAssertNil(try d.decode(PendingUpdate.self, from: Data(json.utf8)).reregistered)
    }

    func testRegistrationRecord() throws {
        let r = HostAgent.Registration(requestID: "id", at: Date(timeIntervalSince1970: 0), status: "enabled", error: nil)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try d.decode(HostAgent.Registration.self, from: try e.encode(r)), r)
        XCTAssertEqual(HostAgent.registrationURL(storeRoot: URL(fileURLWithPath: "/s")).path, "/s/host-registration.json")
    }
}

extension InstallerTests {
    final class Calls: @unchecked Sendable { var n = 0 }

    /// A rollback by the bad build itself registers the agent again for the old build when the update had registered it
    /// for the new one; otherwise launchd's constraint still matches the old build and nothing is registered.
    func testAnInBinaryRollbackRegistersAgainOnlyWhenTheUpdateDid() async throws {
        for reregistered in [false, true] {
            try? FileManager.default.removeItem(at: root); try setUpWithError()
            try publish(ver(420))
            guard case .swapped = try await updater().install() else { return XCTFail() }
            if reregistered, var p = Installer(paths: paths).readPending() { p.reregistered = true; try Installer(paths: paths).writePending(p) }
            let calls = Calls()
            let make = { HostHealth(paths: self.paths, running: ver(420), logFile: nil, log: { _ in },
                                    reregisterAgent: { calls.n += 1; return HostAgent.Registration(requestID: "t", at: Date(), status: "enabled", error: nil) }) }
            XCTAssertTrue(make().launch()); XCTAssertTrue(make().launch())
            XCTAssertFalse(make().launch(), "the third start rolls back")
            XCTAssertEqual(installed(), 412)
            XCTAssertEqual(calls.n, reregistered ? 1 : 0)
        }
    }
}

extension InstallerTests {
    /// The Welcome carries the last update's outcome for a few minutes (U4: the triggering viewer learns how it ended).
    func testTheWelcomeCarriesARecentOutcome() throws {
        let installer = Installer(paths: paths)
        XCTAssertNil(Updater.hostUpdateInfo(paths: paths).lastResult)
        try installer.writeResult(UpdateResult(outcome: .rolledBack, from: ver(412), to: ver(420), at: Date(), message: "started 3 times"))
        let r = try XCTUnwrap(Updater.hostUpdateInfo(paths: paths).lastResult)
        XCTAssertEqual(r.phase, .rolledBack); XCTAssertEqual(r.to?.build, 420); XCTAssertEqual(r.message, "started 3 times")
        try installer.writeResult(UpdateResult(outcome: .committed, from: ver(412), to: ver(420), at: Date(), message: "committed"))
        XCTAssertEqual(Updater.hostUpdateInfo(paths: paths).lastResult?.phase, .done)
        XCTAssertNil(Updater.hostUpdateInfo(paths: paths, now: Date().addingTimeInterval(16 * 60)).lastResult, "only a recent one")
        XCTAssertEqual(Updater.hostUpdateInfo(paths: paths).permission, UpdatePermission(policy: .ask, viewerMayTrigger: true))
    }
}

/// U4 review: a viewer's rollback only right after an update, only to the same signing identity, and never skipping.
final class RemoteRollbackTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let running = ver(420)
    var trial: PendingUpdate { PendingUpdate(from: ver(412), to: ver(420), attempts: 1, deadline: now.addingTimeInterval(60), appPath: "/Applications/Mirage.app", started: now.addingTimeInterval(-240)) }

    func testOnlyInTheHealthWindow() {
        XCTAssertNil(RemoteRollback.refusal(pending: trial, lastResult: nil, running: running, now: now, identityChange: nil), "the new build on trial")
        let committed = UpdateResult(outcome: .committed, from: ver(412), to: ver(420), at: now.addingTimeInterval(-60), message: "")
        XCTAssertNil(RemoteRollback.refusal(pending: nil, lastResult: committed, running: running, now: now, identityChange: nil), "just committed")
        XCTAssertNotNil(RemoteRollback.refusal(pending: nil, lastResult: committed, running: running, now: now.addingTimeInterval(UpdateHealth.commitWindow), identityChange: nil),
                        "committed long ago: a person's call")
        XCTAssertNotNil(RemoteRollback.refusal(pending: nil, lastResult: nil, running: running, now: now, identityChange: nil), "no update at all")
        XCTAssertNotNil(RemoteRollback.refusal(pending: nil, lastResult: committed, running: ver(500), now: now, identityChange: nil), "another build runs now")
        let future = UpdateResult(outcome: .committed, from: ver(412), to: ver(420), at: now.addingTimeInterval(3600), message: "")
        XCTAssertNotNil(RemoteRollback.refusal(pending: nil, lastResult: future, running: running, now: now, identityChange: nil), "a clock moved backwards")
        let rolled = UpdateResult(outcome: .rolledBack, from: ver(412), to: ver(420), at: now, message: "")
        XCTAssertNotNil(RemoteRollback.refusal(pending: nil, lastResult: rolled, running: running, now: now, identityChange: nil))
        let why = RemoteRollback.refusal(pending: trial, lastResult: nil, running: running, now: now, identityChange: "signing identity change: x")
        XCTAssertTrue(why?.hasPrefix("rollback needs a person at the Mac: miraged update --rollback") ?? false, why ?? "nil")
        XCTAssertTrue(why?.contains("signing identity change") ?? false)
    }
}

extension InstallerTests {
    func testAViewersRollbackDoesNotSkipTheBuild() async throws {
        try publish(ver(420))
        guard case .swapped = try await updater().install() else { return XCTFail() }
        _ = try updater(running: ver(420)).rollback(skipReplaced: false)
        XCTAssertEqual(installed(), 412)
        XCTAssertEqual(UpdateSettings.load(paths.settings).skippedBuilds, [], "a viewer's rollback skips nothing")
    }

    /// The Welcome's outcome while the new build is on trial, and a record from the future (a clock set back) is stale.
    func testTrialAndClockSkewInTheWelcome() async throws {
        try publish(ver(420))
        guard case .swapped = try await updater().install() else { return XCTFail() }
        XCTAssertEqual(Updater.hostUpdateInfo(paths: paths, running: ver(420)).lastResult?.phase, .trial)
        XCTAssertNil(Updater.hostUpdateInfo(paths: paths, running: ver(412)).lastResult, "the old build still answers: nothing yet")
        Installer(paths: paths).clearPending()
        try Installer(paths: paths).writeResult(UpdateResult(outcome: .committed, from: ver(412), to: ver(420), at: Date().addingTimeInterval(3600), message: ""))
        XCTAssertNil(Updater.hostUpdateInfo(paths: paths, running: ver(420)).lastResult)
        try Installer(paths: paths).writeResult(UpdateResult(outcome: .failed, from: ver(412), to: ver(420), at: Date(), message: "bad zip"))
        XCTAssertEqual(Updater.hostUpdateInfo(paths: paths, running: ver(412)).lastResult?.phase, .failed)
    }
}

/// Whose the agent job is, from `launchctl print` (mac-daddy, 2026-10-26: the first self-update reported "no host agent
/// runs from /Applications/Mirage.app" while the agent ran, because an SMAppService agent prints no `program`).
final class AgentOwnershipTests: XCTestCase {
    let app = URL(fileURLWithPath: "/Applications/Mirage.app")
    let previous = URL(fileURLWithPath: "/Users/phrz/Library/Application Support/Mirage/Previous/Mirage.app")
    /// As mac-daddy printed it (SMAppService registration).
    let smAppService = """
        gui/501/com.paulherz.mirage.host = {
        \tactive count = 1
        \tpath = (submitted by smd.601)
        \ttype = LaunchAgent
        \tstate = running
        \tprogram identifier = Contents/MacOS/miraged (mode: 2)
        \tinherited environment = {
        \t\tSSH_AUTH_SOCK => /private/tmp/com.apple.launchd.x/Listeners
        \t}
        \tpid = 73163
        \tjob state = running
        \tproperties = needs LWCR update | has LWCR
        }
        """
    /// A plist agent (miraged install, the old LaunchAgent): an absolute program.
    let plist = """
        gui/501/com.paulherz.mirage.host = {
        \tpath = /Users/phrz/Library/LaunchAgents/com.paulherz.mirage.host.plist
        \tstate = not running
        \tprogram = /Applications/Mirage.app/Contents/MacOS/miraged
        \tlast exit code = 0
        }
        """

    func own(_ out: String, pid: String?) -> HostAgent.Ownership {
        HostAgent.ownership(launchctlOutput: out, bundles: [app, previous], pidPath: { _ in pid })
    }

    func testSMAppServiceAgentIsFoundByItsProcess() {
        XCTAssertEqual(HostAgent.Status.parse(smAppService), .running(pid: 73163, program: nil))
        XCTAssertEqual(own(smAppService, pid: "/Applications/Mirage.app/Contents/MacOS/miraged"), .ours(pid: 73163))
        XCTAssertEqual(own(smAppService, pid: previous.path + "/Contents/MacOS/miraged"), .ours(pid: 73163),
                       "after the swap the running code sits in the kept previous bundle: still ours, and it must be restarted")
        XCTAssertEqual(own(smAppService, pid: "/Users/phrz/Repos/mirage/.build/Mirage.app/Contents/MacOS/miraged"),
                       .elsewhere("/Users/phrz/Repos/mirage/.build/Mirage.app/Contents/MacOS/miraged"))
        let stopped = smAppService.replacingOccurrences(of: "\tstate = running", with: "\tstate = not running").replacingOccurrences(of: "\tpid = 73163\n", with: "")
        XCTAssertEqual(own(stopped, pid: nil), .probablyOurs, "registered from a bundle launchctl does not name: restart it")
    }

    func testPlistAgentByItsProgram() {
        XCTAssertEqual(own(plist, pid: nil), .ours(pid: nil))
        XCTAssertEqual(own(plist.replacingOccurrences(of: "/Applications/Mirage.app", with: "/Users/x/old/Mirage.app"), pid: nil),
                       .elsewhere("/Users/x/old/Mirage.app/Contents/MacOS/miraged"))
        XCTAssertEqual(own("Bad request.\nCould not find service \"com.paulherz.mirage.host\" in domain for user gui: 501\n", pid: nil), .notLoaded)
    }

    func testThisProcessExecutablePath() {
        XCTAssertNotNil(HostAgent.executablePath(pid: Int(getpid())))
        XCTAssertNil(HostAgent.executablePath(pid: 999_999_999))
    }
}
