import XCTest
@testable import MirageCore
@testable import MirageHost

/// Unlock with biometry (DESIGN §3.13): the wire, the host's gate and typing, the viewer's capture, agents' requests.
final class UnlockTests: XCTestCase {
    func testTheWireCarriesItAndNeverPrintsThePassword() throws {
        let m = ControlMessage.unlock(.init(password: Data("hunter2-secret".utf8), requestID: "r1"))
        let back = try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        for text in ["\(m)", String(describing: m), String(reflecting: m), "unexpected \(m)"] {
            XCTAssertFalse(text.contains("hunter2"), "printed: \(text)")
        }
        let res = ControlMessage.unlockResult(.init(outcome: .stillLocked, message: "x", requestID: "r1"))
        XCTAssertEqual(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(res)), res)
        let req = ControlMessage.unlockRequest(.init(id: "r1", reason: "the nightly build", requester: "agent", expiresAt: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(req)), req)
    }

    func testTheGate() {
        var g = UnlockLogic.Gate(); let t = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(g.admit("a", now: t))
        XCTAssertNotNil(g.admit("a", now: t.addingTimeInterval(3)), "one attempt per 10 s")
        XCTAssertNil(g.admit("b", now: t.addingTimeInterval(3)), "per device")
        XCTAssertNil(g.admit("a", now: t.addingTimeInterval(11)))
        g.record(.stillLocked, now: t.addingTimeInterval(12))
        XCTAssertNotNil(g.admit("a", now: t.addingTimeInterval(60)), "never twice after a failure")
        XCTAssertNotNil(g.admit("b", now: t.addingTimeInterval(60)), "from no device: the pause is host-wide")
        XCTAssertNotNil(g.admit("a", now: t.addingTimeInterval(14 * 60)))
        XCTAssertNil(g.admit("a", now: t.addingTimeInterval(16 * 60)), "after the pause")
        g.record(.stillLocked, now: t.addingTimeInterval(17 * 60))
        g.macUnlocked()
        XCTAssertNil(g.admit("a", now: t.addingTimeInterval(17 * 60 + 11)), "the Mac was unlocked meanwhile: over")
    }

    func testOneUnlockAtATimeHostWide() async {
        let c = UnlockCoordinator()
        let first = await c.begin("a")
        XCTAssertNil(first)
        let second = await c.begin("b")
        XCTAssertEqual(second, "an unlock is already in progress", "another device waits")
        await c.end(.stillLocked)
        let afterFailure = await c.begin("b", now: Date().addingTimeInterval(20))
        XCTAssertNotNil(afterFailure, "a failure pauses every device")
        let d = UnlockCoordinator(); _ = await d.begin("a"); await d.cancel()
        let again = await d.begin("b")
        XCTAssertNil(again, "a cancelled slot is free")
    }

    func testStrictLockFailsClosed() {
        typealias S = LockScreenUnlocker.StrictLock
        XCTAssertTrue(S.confirmed(sessionLocked: true, consoleLocked: true, secureInputHolder: nil))
        XCTAssertTrue(S.confirmed(sessionLocked: true, consoleLocked: true, secureInputHolder: S.loginwindow))
        XCTAssertFalse(S.confirmed(sessionLocked: true, consoleLocked: true, secureInputHolder: "/Users/x/fake/loginwindow"), "a fake lock screen holding secure input")
        XCTAssertFalse(S.confirmed(sessionLocked: true, consoleLocked: nil, secureInputHolder: nil), "one signal is not enough")
        XCTAssertFalse(S.confirmed(sessionLocked: nil, consoleLocked: true, secureInputHolder: nil))
        XCTAssertFalse(S.confirmed(sessionLocked: false, consoleLocked: false, secureInputHolder: nil))
    }

    func testCleaningWhatThePersonSees() {
        XCTAssertEqual(UnlockLogic.clean("run\nthe   nightly\u{202E}build\u{200B}"), "run the nightly build")
        XCTAssertEqual(UnlockLogic.clean(String(repeating: "a", count: 500)).count, 120)
    }

    func testSecretBytesWipe() {
        var d = Data(repeating: 0x41, count: 64)
        let s = SecretBytes(taking: &d)
        XCTAssertEqual(s.bytes.count, 64)
        XCTAssertTrue(d.allSatisfy { $0 == 0 }, "the owned Data is zeroed")
        s.wipe(); XCTAssertTrue(s.bytes.allSatisfy { $0 == 0 })
    }

    /// The hardened-runtime check reads the code directory's flags: the installed Developer ID miraged has the runtime
    /// (when this Mac has it), the test runner does not.
    func testHardenedRuntimeCheck() throws {
        XCTAssertFalse(LockScreenUnlocker.hardenedRuntime(), "the test runner is not hardened")
        let installed = ["/Applications/Mirage.app", NSHomeDirectory() + "/Applications/Mirage.app"].map { $0 + "/Contents/MacOS/miraged" }
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let installed else { throw XCTSkip("no installed Mirage.app") }
        XCTAssertTrue(LockScreenUnlocker.hardenedRuntime(path: installed), "a Developer ID miraged has flags=0x10000(runtime)")
    }
    func testAgentSessionEnds() {
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertNil(AgentSessions.over(began: t, last: t, now: t.addingTimeInterval(14 * 60)))
        XCTAssertNotNil(AgentSessions.over(began: t, last: t, now: t.addingTimeInterval(15 * 60)), "idle")
        // Kept alive every few minutes, it still ends at the hour: a new approval is needed.
        XCTAssertNil(AgentSessions.over(began: t, last: t.addingTimeInterval(55 * 60), now: t.addingTimeInterval(59 * 60)))
        XCTAssertEqual(AgentSessions.over(began: t, last: t.addingTimeInterval(59 * 60), now: t.addingTimeInterval(60 * 60)), "its hour is up (a new approval is needed)")
    }

    /// Viewers hear an agent session open and close, and one that connects while it is open hears it at once.
    func testAgentSessionNotices() async {
        let n = AgentSessionNotices(), early = Box(), late = Box()
        await n.add(UUID()) { early.append($0) }
        await n.set(.init(open: true, requester: "claude (team X)"))
        await n.add(UUID()) { late.append($0) }
        XCTAssertEqual(late.items, [.agentSession(.init(open: true, requester: "claude (team X)"))])
        await n.set(.init(open: false, requester: "claude (team X)"))
        XCTAssertEqual(early.items.count, 2)
        let none = Box(); await n.add(UUID()) { none.append($0) }
        XCTAssertTrue(none.items.isEmpty, "closed: nothing to tell")
    }

    /// The requester the host shows: carriers (miraged, shells) and interpreters are never the program shown; a signer
    /// is named only against a requirement.
    func testRequesterIdentity() throws {
        for c in ["miraged", "zsh", "bash", "sh", "env", "sudo", "tmux"] { XCTAssertTrue(PeerIdentity.carriers.contains(c)) }
        for i in ["python3", "node", "osascript", "perl", "ruby"] { XCTAssertTrue(PeerIdentity.interpreters.contains(i)) }
        XCTAssertFalse(PeerIdentity.carriers.contains("claude"))
        // This test runner (ad hoc): unsigned, never "Apple" or a team.
        let me = try XCTUnwrap(PeerIdentity.auditToken(of: getpid()))
        XCTAssertEqual(PeerIdentity.signer(of: me).label, "unsigned")
        // launchd's child chain ends in Apple code: this process's ancestors include an Apple-signed one (the shell or
        // launchd's direct children), which `anchor apple` names "Apple".
        var p = PeerIdentity.parent(of: getpid()), apple = false
        for _ in 0..<6 where p > 1 { if let t = PeerIdentity.auditToken(of: p), PeerIdentity.signer(of: t).label == "Apple" { apple = true; break }; p = PeerIdentity.parent(of: p) }
        XCTAssertTrue(apple, "an Apple-signed ancestor reads as Apple")
    }
    /// A recorded agent session is ended at a new start only in the same boot and with nobody at the Mac lately.
    func testAgentSessionRecovery() {
        XCTAssertTrue(AgentSessions.recover(recordedBoot: 1000, boot: 1000.2, hidIdle: 300))
        XCTAssertFalse(AgentSessions.recover(recordedBoot: 1000, boot: 5000, hidIdle: 300), "rebooted: that locked it")
        XCTAssertFalse(AgentSessions.recover(recordedBoot: nil, boot: 1000, hidIdle: 300), "an older record: no boot, no lock")
        XCTAssertFalse(AgentSessions.recover(recordedBoot: 1000, boot: 1000, hidIdle: 30), "someone used the Mac just now")
    }

    func testTheCaptureFollowsWhatWasTyped() {
        var c = UnlockLogic.Capture(); let t = Date(timeIntervalSince1970: 0)
        for ch in "pass" { c.key(code: 0, characters: String(ch), modifiers: 0) }
        c.key(code: 51, characters: nil, modifiers: 0)            // delete: "pas"
        c.key(code: 0, characters: "ø", modifiers: 1 << 19)       // Option types characters
        c.key(code: 36, characters: "\r", modifiers: 0, now: t)
        XCTAssertNil(c.hostLocked(true, now: t))
        XCTAssertEqual(c.hostLocked(false, now: t.addingTimeInterval(2)), Data("pasø".utf8), "unlocked soon after Return: offered")
        XCTAssertNil(c.hostLocked(false, now: t.addingTimeInterval(3)), "once")

        var late = UnlockLogic.Capture()
        late.key(code: 0, characters: "x", modifiers: 0); late.key(code: 36, characters: "\r", modifiers: 0, now: t)
        XCTAssertNil(late.hostLocked(false, now: t.addingTimeInterval(30)), "too long after Return: not this password")
        var stale = UnlockLogic.Capture()
        stale.key(code: 0, characters: "x", modifiers: 0); stale.key(code: 36, characters: "\r", modifiers: 0, now: t)
        XCTAssertNil(stale.hostLocked(true, now: t.addingTimeInterval(11)), "still locked past the window")
        XCTAssertNil(stale.candidate, "dropped then, not kept for a later unlock")

        var spoiled = UnlockLogic.Capture()
        spoiled.key(code: 0, characters: "ab", modifiers: 0); spoiled.key(code: 123, characters: nil, modifiers: 0)   // ←
        spoiled.key(code: 36, characters: "\r", modifiers: 0, now: t)
        XCTAssertNil(spoiled.hostLocked(false, now: t), "a moved caret: never offered")
        var shortcut = UnlockLogic.Capture()
        shortcut.key(code: 9, characters: "v", modifiers: 1 << 20); shortcut.key(code: 36, characters: "\r", modifiers: 0, now: t)
        XCTAssertNil(shortcut.hostLocked(false, now: t), "⌘V: a paste we cannot see")
        var esc = UnlockLogic.Capture()
        esc.key(code: 0, characters: "wrong", modifiers: 0); esc.key(code: 53, characters: nil, modifiers: 0)
        esc.key(code: 0, characters: "right", modifiers: 0); esc.key(code: 36, characters: "\r", modifiers: 0, now: t)
        XCTAssertEqual(esc.hostLocked(false, now: t), Data("right".utf8), "Escape clears the field")
        var clicked = UnlockLogic.Capture()
        clicked.key(code: 0, characters: "ab", modifiers: 0); clicked.spoil(); clicked.key(code: 36, characters: "\r", modifiers: 0, now: t)
        XCTAssertNil(clicked.hostLocked(false, now: t))
    }

    func testAgentRequests() async {
        let r = UnlockRequests()
        let none = await r.request(reason: "x", requester: "y")
        XCTAssertEqual(none, .noViewer)
        let seen = Box()
        await r.add(UUID()) { m in seen.append(m) }
        let task = Task { await r.request(reason: "the nightly build", requester: "agent", timeout: 30) }
        var id: String?
        for _ in 0..<100 { if case .unlockRequest(let q)? = seen.items.first { id = q.id; break }; try? await Task.sleep(for: .milliseconds(10)) }
        guard let id else { return XCTFail("no request reached the viewer") }
        let pending = await r.isPending(id)
        XCTAssertTrue(pending)
        let busy = await r.request(reason: "another", requester: "agent")
        XCTAssertEqual(busy, .refused, "one request at a time")
        // An unlock takes it before typing: a decline, or a second unlock, no longer counts.
        let claimed = await r.claim(id), twice = await r.claim(id)
        XCTAssertTrue(claimed); XCTAssertFalse(twice)
        await r.decline(id)
        let stillThere = await r.isPending(id)
        XCTAssertTrue(stillThere, "a decline after the claim is ignored")
        // A viewer that connects meanwhile is asked too.
        let late = Box(); await r.add(UUID()) { m in late.append(m) }
        if case .unlockRequest(let q)? = late.items.first { XCTAssertEqual(q.id, id) } else { XCTFail("late viewer not asked") }
        await r.settle(id, .unlocked)
        let outcome = await task.value
        XCTAssertEqual(outcome, .unlocked)
        XCTAssertTrue(late.items.contains { if case .unlockResult(let x) = $0 { return x.requestID == id } else { return false } }, "others' prompts close")
        let stillPending = await r.isPending(id)
        XCTAssertFalse(stillPending)
        let soon = await r.request(reason: "x", requester: "y", timeout: 0.05)
        XCTAssertEqual(soon, .refused, "within 10 s of the last request")
        let timedOut = await r.request(reason: "x", requester: "y", timeout: 0.05, now: Date().addingTimeInterval(11))
        XCTAssertEqual(timedOut, .timedOut)
        XCTAssertEqual(UnlockLogic.RequestOutcome.declined.exitCode, 3)
    }

    func testTheHostTypesOnlyAtTheLockScreen() async {
        XCTAssertEqual(LockScreenUnlocker.strokes(for: Array("aé".utf8))?.count, 6, "two characters down and up, then Return")
        XCTAssertNil(LockScreenUnlocker.strokes(for: []))
        XCTAssertNil(LockScreenUnlocker.strokes(for: Array("a\nb".utf8)), "never a password with a line break")

        let posted = Box()
        // Not locked: nothing typed, not even the wake.
        let notLocked = await LockScreenUnlocker.unlock(SecretBytes(Array("pw".utf8)), locked: { false }, post: { posted.append(.key(.init(keyCode: $0.keyCode, down: $0.down, isRepeat: false, modifiers: 0, characters: nil))) }, wake: .zero, settle: .milliseconds(10))
        XCTAssertEqual(notLocked, .notLocked); XCTAssertTrue(posted.items.isEmpty)

        // Locked until Return goes up: typed, then unlocked.
        let state = Flag(true)
        let typed = Box()
        let ok = await LockScreenUnlocker.unlock(SecretBytes(Array("pw".utf8)), locked: { state.value }, post: { s in
            typed.append(.key(.init(keyCode: s.keyCode, down: s.down, isRepeat: false, modifiers: 0, characters: String(utf16CodeUnits: s.utf16, count: s.utf16.count))))
            if s.keyCode == 36, !s.down { state.value = false }
        }, wake: .zero, settle: .seconds(2))
        XCTAssertEqual(ok, .unlocked)
        let chars = typed.items.compactMap { if case .key(let k) = $0, k.down, k.keyCode == 0 { return k.characters } else { return nil } }
        XCTAssertEqual(chars.joined(), "pw", "the wake, then each character")

        // Locked throughout: still locked (the wrong password).
        let wrong = await LockScreenUnlocker.unlock(SecretBytes(Array("pw".utf8)), locked: { true }, post: { _ in }, wake: .zero, settle: .milliseconds(300))
        XCTAssertEqual(wrong, .stillLocked)

        // Unlocked some other way mid-typing (Touch ID, a Watch): the rest is not typed, and Return never sent.
        let flip = Flag(true), sent = Box()
        let gone = await LockScreenUnlocker.unlock(SecretBytes(Array("secret".utf8)), locked: { flip.value }, post: { s in
            sent.append(.key(.init(keyCode: s.keyCode, down: s.down, isRepeat: false, modifiers: 0, characters: nil)))
            if s.keyCode == 0, !s.down { flip.value = false }   // after the first character
        }, wake: .zero, settle: .milliseconds(300))
        XCTAssertEqual(gone, .interrupted)
        XCTAssertFalse(sent.items.contains { if case .key(let k) = $0 { return k.keyCode == 36 } else { return false } }, "no Return")
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var _items: [ControlMessage] = []
    var items: [ControlMessage] { lock.lock(); defer { lock.unlock() }; return _items }
    func append(_ m: ControlMessage) { lock.lock(); _items.append(m); lock.unlock() }
}
private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

/// The unlock offer (phrz, 2026-10-27: Touch ID came up by itself on connecting, so he could not test typing): a click, or
/// Always per host; the save offer after a typed unlock; what unlocked the Mac, for the log.
final class UnlockOfferTests: XCTestCase {
    func testNoPromptUnlessAlways() {
        XCTAssertFalse(UnlockLogic.autoPrompt(nowLocked: true, wasLocked: false, alreadyPrompted: false, savedFailed: false, always: false, ready: true), "by default: the offer, never the prompt")
        XCTAssertTrue(UnlockLogic.autoPrompt(nowLocked: true, wasLocked: false, alreadyPrompted: false, savedFailed: false, always: true, ready: true), "Always")
        XCTAssertFalse(UnlockLogic.autoPrompt(nowLocked: true, wasLocked: false, alreadyPrompted: true, savedFailed: false, always: true, ready: true), "once per connection")
        XCTAssertFalse(UnlockLogic.autoPrompt(nowLocked: true, wasLocked: false, alreadyPrompted: false, savedFailed: true, always: true, ready: true), "never after a failure")
        XCTAssertFalse(UnlockLogic.autoPrompt(nowLocked: true, wasLocked: true, alreadyPrompted: false, savedFailed: false, always: true, ready: true), "only when it first shows locked")
        XCTAssertFalse(UnlockLogic.autoPrompt(nowLocked: true, wasLocked: false, alreadyPrompted: false, savedFailed: false, always: true, ready: false), "nothing saved, or no biometry")
    }
    func testSaveOffer() {
        XCTAssertEqual(UnlockLogic.saveOffer(biometry: true, saved: false, savedFailed: false), .save, "none saved: offered")
        XCTAssertNil(UnlockLogic.saveOffer(biometry: true, saved: true, savedFailed: false), "one saved (and it works): not offered")
        XCTAssertEqual(UnlockLogic.saveOffer(biometry: true, saved: true, savedFailed: true), .update, "the saved one failed: update")
        XCTAssertNil(UnlockLogic.saveOffer(biometry: false, saved: false, savedFailed: false), "no biometry")
    }
    func testUnlockCause() {
        XCTAssertTrue(CurtainLogic.unlockCause(remoteDownsWhileLocked: 14, biometryTypingRecently: true).hasPrefix("Unlock with biometry"))
        XCTAssertEqual(CurtainLogic.unlockCause(remoteDownsWhileLocked: 9, biometryTypingRecently: false), "typed through a Mirage viewer (9 key-downs while locked)")
        XCTAssertTrue(CurtainLogic.unlockCause(remoteDownsWhileLocked: 0, biometryTypingRecently: false).hasPrefix("at the Mac or another way"))
    }

    /// phrz on 541: mac-daddy locked with a Tailscale update's SecurityAgent dialog still open, holding Secure Event Input.
    /// Keys typed then would fill that dialog (an app given an administrator's password), so nothing is typed, and the
    /// viewer is told so, truthfully; loginwindow alone is the lock screen's field.
    static let securityAgent = "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent"
    func testASecurityAgentDialogIsNotTheLockScreen() {
        typealias S = LockScreenUnlocker.StrictLock
        XCTAssertFalse(S.confirmed(sessionLocked: true, consoleLocked: true, secureInputHolder: Self.securityAgent))
        XCTAssertTrue(S.passwordDialog(sessionLocked: true, consoleLocked: true, secureInputHolder: Self.securityAgent))
        XCTAssertTrue(S.confirmed(sessionLocked: true, consoleLocked: true, secureInputHolder: S.loginwindow))
        XCTAssertFalse(S.passwordDialog(sessionLocked: true, consoleLocked: true, secureInputHolder: S.loginwindow))
        XCTAssertFalse(S.passwordDialog(sessionLocked: false, consoleLocked: false, secureInputHolder: Self.securityAgent), "unlocked: no lock to speak of")
    }
    func testThePasswordDialogRefusalTypesNothing() async {
        final class Posted: @unchecked Sendable { var n = 0 }
        let posted = Posted()
        let r = await LockScreenUnlocker.unlock(SecretBytes(Array("pw".utf8)), locked: { false }, dialog: { true }, post: { _ in posted.n += 1 }, wake: .zero, settle: .milliseconds(10))
        XCTAssertEqual(r, .passwordDialog); XCTAssertEqual(posted.n, 0)
    }
    /// On the wire as `refused` plus a flag: older viewers decode it and show the message; this one shows the alert.
    func testThePasswordDialogOutcomeOnTheWire() throws {
        let r = ControlMessage.UnlockResult(outcome: .passwordDialog, message: "A password dialog on mac-daddy has the keyboard; nothing was typed")
        let data = try JSONEncoder().encode(r)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["outcome"] as? String, "refused"); XCTAssertEqual(raw["passwordDialog"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(ControlMessage.UnlockResult.self, from: data), r)
        let old = try JSONDecoder().decode(ControlMessage.UnlockResult.self, from: Data(#"{"outcome":"notLocked","message":"m"}"#.utf8))
        XCTAssertEqual(old.outcome, .notLocked)
        let unknown = try JSONDecoder().decode(ControlMessage.UnlockResult.self, from: Data(#"{"outcome":"someday","message":"m"}"#.utf8))
        XCTAssertEqual(unknown.outcome, .refused)
    }
}
