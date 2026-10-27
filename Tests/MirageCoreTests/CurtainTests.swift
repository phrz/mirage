import XCTest
import CoreGraphics
@testable import MirageHost
import MirageCore

/// The curtain's decisions (DESIGN §3.12).
final class CurtainTests: XCTestCase {
    typealias M = CurtainLogic.Machine
    private let triggers: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel]

    func testOnlyUntaggedHardwareInputIsLocal() {
        for t in triggers {
            XCTAssertTrue(CurtainLogic.isLocalInput(type: t, userData: 0, sourcePID: 0), "\(t.rawValue) from the hardware")
            XCTAssertFalse(CurtainLogic.isLocalInput(type: t, userData: CurtainLogic.injectedTag, sourcePID: 0), "\(t.rawValue) tagged")
            XCTAssertFalse(CurtainLogic.isLocalInput(type: t, userData: 0, sourcePID: 4242), "\(t.rawValue) posted by another program (1Password, Keyboard Maestro…)")
            XCTAssertFalse(CurtainLogic.isLocalInput(type: t, userData: CurtainLogic.injectedTag, sourcePID: Int64(getpid())), "miraged's own")
        }
        for t: CGEventType in [.mouseMoved, .leftMouseUp, .keyUp, .leftMouseDragged] {
            XCTAssertFalse(CurtainLogic.isLocalInput(type: t, userData: 0, sourcePID: 0), "\(t.rawValue): motion and releases do not lock")
        }
        XCTAssertTrue(CurtainLogic.isSwallowedType(.keyUp) && CurtainLogic.isSwallowedType(.leftMouseUp), "the ups of swallowed downs go too")
        XCTAssertFalse(CurtainLogic.isSwallowedType(.mouseMoved), "the pointer still moves")
    }

    func testTheInjectorsSourceTagsEveryKindOfEvent() {
        let s = InputInjector.taggedSource()
        let key = CGEvent(keyboardEventSource: s, virtualKey: 0, keyDown: true)
        let flags = CGEvent(keyboardEventSource: s, virtualKey: 0, keyDown: true); flags?.type = .flagsChanged   // as InputInjector posts modifiers
        let scroll = CGEvent(scrollWheelEvent2Source: s, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: 0, wheel3: 0)
        let click = CGEvent(mouseEventSource: s, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)
        for (name, e) in [("key", key), ("flagsChanged", flags), ("scroll", scroll), ("click", click)] {
            XCTAssertEqual(e?.getIntegerValueField(.eventSourceUserData), CurtainLogic.injectedTag, name)
            XCTAssertFalse(CurtainLogic.isLocalInput(type: e!.type, userData: e!.getIntegerValueField(.eventSourceUserData), sourcePID: 0), name)
        }
    }

    func testTextColourFollowsTheBlurredPicture() {
        XCTAssertEqual(CurtainLogic.textStyle(luminance: 0.9), .init(white: false, alpha: 0.85), "light picture: black text")
        XCTAssertEqual(CurtainLogic.textStyle(luminance: 0.1), .init(white: true, alpha: 0.9), "dark picture: white text")
    }

    func testMeanLuminanceRectIsTopLeftOriented() {
        let w = 100, h = 100, stride = w * 4
        var px = [UInt8](repeating: 0, count: stride * h)   // memory row 0 is the top: white top half, black bottom half
        for y in 0..<50 { for x in 0..<w { let o = y * stride + x * 4; px[o] = 255; px[o + 1] = 255; px[o + 2] = 255; px[o + 3] = 255 } }
        px.withUnsafeBytes { b in
            XCTAssertEqual(CurtainLogic.meanLuminance(bgra: b, width: w, height: h, stride: stride, rect: CGRect(x: 0, y: 0, width: 100, height: 50)), 1, accuracy: 0.01, "y 0..50 is the top")
            XCTAssertEqual(CurtainLogic.meanLuminance(bgra: b, width: w, height: h, stride: stride, rect: CGRect(x: 0, y: 50, width: 100, height: 50)), 0, accuracy: 0.01)
            XCTAssertEqual(CurtainLogic.meanLuminance(bgra: b, width: w, height: h, stride: stride, rect: CGRect(x: 0, y: 25, width: 100, height: 50)), 0.5, accuracy: 0.05)
        }
    }

    // MARK: The state machine

    func testLocalUnlockThenALaterRemoteUnlock() {
        var m = M(); m.sessionBegan("a"); m.visible = true
        XCTAssertTrue(m.wantsCurtain && m.lockOnLocalInput())
        m.lockChanged(true); XCTAssertFalse(m.wantsCurtain)
        m.lockChanged(false)                              // signed in at the Mac: no remote downs while locked
        XCTAssertTrue(m.ownedLocally); XCTAssertFalse(m.wantsCurtain, "never covers the owner")
        m.lockChanged(true)                               // the owner leaves and locks
        m.injectedDown(); m.injectedDown()                // the remote person types the password through Mirage
        m.lockChanged(false)
        XCTAssertFalse(m.ownedLocally, "a remote unlock takes it back (the evil-maid case)"); XCTAssertTrue(m.wantsCurtain)
    }
    func testSessionBeginningWhileLocked() {
        var m = M(locked: true); m.sessionBegan("a")
        XCTAssertFalse(m.wantsCurtain, "deferred while locked")
        m.lockChanged(false)                              // a person at the Mac signs in
        XCTAssertTrue(m.ownedLocally); XCTAssertFalse(m.wantsCurtain, "no curtain over them")
        var r = M(locked: true); r.sessionBegan("a"); r.injectedDown(); r.lockChanged(false)
        XCTAssertTrue(r.wantsCurtain, "unlocked through Mirage: curtain")
    }
    func testSuspendAndResumeKeepLocalOwnership() {
        var m = M(); m.sessionBegan("a"); m.lockChanged(true); m.lockChanged(false)
        XCTAssertTrue(m.ownedLocally)
        m.sessionStreamed("a")
        m.sessionSuspended("a", now: 1); m.sessionBegan("a", now: 2)   // a backgrounded phone, a Wi-Fi roam
        XCTAssertTrue(m.ownedLocally); XCTAssertFalse(m.wantsCurtain, "the signed-in owner is not re-curtained")
        m.sessionStopped("a", now: 3); _ = m.tick(now: 3 + m.debounceNanos)
        XCTAssertFalse(m.ownedLocally, "the session over: forgotten")
    }
    func testPointerMotionAloneDoesNotMakeAnUnlockRemote() {
        var m = M(); m.sessionBegan("a")
        m.injectedDown()                                  // remote activity before the lock does not count
        m.lockChanged(true); m.lockChanged(false)         // only pointer motion while locked (not counted)
        XCTAssertTrue(m.ownedLocally)
    }
    /// Wanted is enough: a curtain still invisible (the sessions' filters catching up, a rebuild after a display change while
    /// the display slept, a resume waiting for its acknowledgement) must not leave the wake key or a click unanswered.
    func testLocalInputLocksWheneverTheCurtainIsWanted() {
        var m = M(); m.sessionBegan("a")
        XCTAssertFalse(m.visible); XCTAssertTrue(m.lockOnLocalInput(), "invisible but wanted: a local click locks")
        m.visible = true; XCTAssertTrue(m.lockOnLocalInput())
        m.lockChanged(true); XCTAssertFalse(m.visible); XCTAssertFalse(m.lockOnLocalInput(), "locked: nothing to lock")
        // A resume (the curtain invisible again until it acknowledges): still locks, and the input is not presence.
        var r = M(); r.sessionBegan("a", .init(curtain: true, lockWhenFinished: true)); r.sessionStreamed("a"); r.visible = true
        r.sessionSuspended("a", now: 0); r.sessionBegan("a", now: Self.s); r.visible = false
        XCTAssertTrue(r.lockOnLocalInput()); r.localInputUncurtained(now: Self.s); XCTAssertNil(r.lastLocalInput)
        // No curtain wanted (the setting off): no lock.
        var off = M(); off.sessionBegan("a", .init(curtain: false)); XCTAssertFalse(off.lockOnLocalInput())
    }
    static let s = UInt64(1_000_000_000)
    func testTwoSessions() {
        var m = M(); m.sessionBegan("a"); m.sessionBegan("b")
        m.sessionStopped("a", now: 0); XCTAssertTrue(m.wantsCurtain, "b still streams")
        m.sessionStopped("b", now: 0); XCTAssertFalse(m.wantsCurtain)
    }
}

/// phrz: the curtain's picture is the wallpaper alone, never desktop icons or widgets.
final class CurtainWallpaperTests: XCTestCase {
    typealias C = Curtain.WallpaperCandidate
    func testCandidatesOnMacOS27() {
        // mac-daddy, 2026-10-27: nothing at the desktop level itself; WindowManager one below, the window server's backdrops lower.
        let d = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let desk = Int(CGWindowLevelForKey(.desktopWindow)), icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let all = [
            C(id: 1, level: desk - 1, bundle: "com.apple.WindowManager", owner: "WindowManager", frame: d),
            C(id: 2, level: desk - 3, bundle: "", owner: "Window Server", frame: d),
            C(id: 3, level: desk - 3, bundle: "", owner: "Window Server", frame: CGRect(x: 0, y: 0, width: 880, height: 1912)),   // another surface
            C(id: 4, level: icons, bundle: "com.apple.finder", owner: "Finder", frame: d),                                        // icons
            C(id: 5, level: icons + 2, bundle: "com.apple.notificationcenterui", owner: "Notification Center", frame: d),        // widgets
            C(id: 6, level: desk - 1, bundle: "", owner: "", frame: d),                                                          // no owner
            C(id: 7, level: desk - 1, bundle: "com.example.desktopapp", owner: "Desktop App", frame: d),
            C(id: 8, level: desk, bundle: "com.apple.dock", owner: "Dock", frame: d),
            C(id: 9, level: desk + 1, bundle: "com.apple.dock", owner: "Dock", frame: d),                                        // above the desktop level
        ]
        XCTAssertEqual(Curtain.wallpaperWindows(all, display: d).map(\.id), [1, 2, 8])
        XCTAssertTrue(Curtain.wallpaperWindows([all[3], all[4], all[5], all[6]], display: d).isEmpty, "nothing fits: plain gray, never icons")
    }
    func testTheOpaquePictureClosestToTheBackdropWins() {
        typealias W = Curtain.WallpaperMeasure
        XCTAssertEqual(Curtain.chooseWallpaper([W(id: 1, opaque: 0.02, variance: 0.0, diff: 60),      // a clear surface
                                               W(id: 2, opaque: 1, variance: 0.03, diff: 1.2),       // the picture
                                               W(id: 3, opaque: 1, variance: 0.0001, diff: 40)]), 2)  // a flat fill
        XCTAssertEqual(Curtain.chooseWallpaper([W(id: 1, opaque: 1, variance: 0.02, diff: 9), W(id: 2, opaque: 1, variance: 0.02, diff: 2)]), 2)
        XCTAssertNil(Curtain.chooseWallpaper([W(id: 1, opaque: 0.5, variance: 0.02, diff: 1), W(id: 2, opaque: 1, variance: 0, diff: 1)]), "none qualifies: gray")
        XCTAssertNil(Curtain.chooseWallpaper([]))
    }
}

final class CurtainMachineEdgeTests: XCTestCase {
    func testAFailedLockTurnsTheCurtainOffUntilTheSessionsEnd() {
        var m = CurtainLogic.Machine(); m.sessionBegan("a"); m.sessionStreamed("a"); m.visible = true
        m.lockFailed()
        XCTAssertFalse(m.wantsCurtain, "a curtain that cannot lock stays off"); XCTAssertFalse(m.lockOnLocalInput())
        m.sessionSuspended("a", now: 0); m.sessionBegan("a", now: 1)
        XCTAssertFalse(m.wantsCurtain, "still off across a suspend and resume")
        m.sessionStopped("a", now: 2); _ = m.tick(now: 2 + m.debounceNanos); m.sessionBegan("b")
        XCTAssertTrue(m.wantsCurtain, "a new session tries again")
    }
}

/// phrz's two host settings: Curtain and Lock when finished (both on by default), and when the end is decided.
final class CurtainSettingsTests: XCTestCase {
    typealias M = CurtainLogic.Machine
    static let s = UInt64(1_000_000_000)
    /// A streaming session "a" with these settings, at t = 0.
    private func streaming(curtain: Bool = true, lock: Bool = true, locked: Bool = false) -> M {
        var m = M(locked: locked); m.sessionBegan("a", .init(curtain: curtain, lockWhenFinished: lock), now: 0); m.sessionStreamed("a"); return m
    }

    func testAStopLocksAfterTheDebounce() {
        var m = streaming()
        m.sessionStopped("a", now: 10 * Self.s)
        XCTAssertFalse(m.tick(now: 11 * Self.s), "not before the debounce")
        XCTAssertTrue(m.tick(now: 10 * Self.s + m.debounceNanos), "the last session over, unlocked: lock")
        XCTAssertFalse(m.tick(now: 30 * Self.s), "once")
        XCTAssertFalse(m.needsWatching)
    }
    func testStopThenRestartNeverLocks() {
        // The flow died, or a resume failed: stopped, then started over at once.
        var m = streaming()
        m.sessionStopped("a", now: 10 * Self.s); m.sessionBegan("b", now: 11 * Self.s)
        XCTAssertFalse(m.tick(now: 20 * Self.s), "a new session cancels the end")
        // A connect that fails before streaming: stopped (twice: the streamer, then the session's catch) and never locks.
        var f = M(); f.sessionBegan("x", now: 0); f.sessionStopped("x", now: 0); f.sessionStopped("x", now: 0)
        XCTAssertNil(f.pendingEnd); XCTAssertFalse(f.tick(now: 60 * Self.s))
    }
    func testSettingsAndOwnership() {
        var two = streaming(); two.sessionBegan("b"); two.sessionStreamed("b")
        two.sessionStopped("a", now: 0); XCTAssertNil(two.pendingEnd, "another session still streams")
        var owner = streaming(); owner.lockChanged(true); owner.lockChanged(false)
        owner.sessionStopped("a", now: 0); XCTAssertFalse(owner.tick(now: owner.debounceNanos), "never lock a Mac its person signed in to")
        var locked = streaming(); locked.lockChanged(true)
        locked.sessionStopped("a", now: 0); XCTAssertFalse(locked.tick(now: locked.debounceNanos), "already locked")
        var off = streaming(lock: false)
        off.sessionStopped("a", now: 0); XCTAssertFalse(off.tick(now: off.debounceNanos), "the setting off")
        var noCurtain = streaming(curtain: false)
        XCTAssertFalse(noCurtain.wantsCurtain)
        noCurtain.sessionStopped("a", now: 0); XCTAssertTrue(noCurtain.tick(now: noCurtain.debounceNanos), "Lock when finished works without the curtain")
    }
    func testEachSessionKeepsItsOwnSettings() {
        // a began with Lock when finished off; b (after the setting changed) with it on. a ends last: a's decides.
        var m = M(); m.sessionBegan("a", .init(lockWhenFinished: false)); m.sessionStreamed("a")
        m.sessionBegan("b", .init(lockWhenFinished: true)); m.sessionStreamed("b")
        m.sessionStopped("b", now: 0); m.sessionStopped("a", now: 0)
        XCTAssertFalse(m.tick(now: m.debounceNanos))
        // A resume keeps the snapshot it began with, whatever it is offered now.
        var r = M(); r.sessionBegan("a", .init(curtain: true, lockWhenFinished: true)); r.sessionStreamed("a")
        r.sessionSuspended("a", now: 0); r.sessionBegan("a", .init(curtain: false, lockWhenFinished: false), now: Self.s)
        XCTAssertTrue(r.wantsCurtain); r.sessionStopped("a", now: Self.s); XCTAssertTrue(r.tick(now: Self.s + r.debounceNanos))
    }

    // MARK: Suspends (a backgrounded phone, a roam, a dropped or crashed viewer)

    func testSuspendedTheCurtainStaysAndLocalInputLocks() {
        var m = streaming(); m.visible = true
        m.sessionSuspended("a", now: 0)
        XCTAssertTrue(m.wantsCurtain, "the curtain stays up while suspended")
        XCTAssertTrue(m.lockOnLocalInput(), "a local click locks the Mac")
        XCTAssertNil(m.pendingEnd, "a suspend is not an end: no grace lock")
        XCTAssertFalse(m.tick(now: 3600 * Self.s), "nothing locks on time alone")
        m.lockChanged(true); XCTAssertFalse(m.wantsCurtain, "locked: the lock screen covers it")
        // Unlocked at the Mac by its person: no curtain over them, and no lock when the session later expires.
        m.lockChanged(false); XCTAssertTrue(m.ownedLocally); XCTAssertFalse(m.wantsCurtain)
        m.sessionStopped("a", now: 86_400 * Self.s); XCTAssertFalse(m.tick(now: 86_400 * Self.s + m.debounceNanos))
    }
    func testDisplayMayIdleOnlyWhileEverySessionIsSuspended() {
        var m = streaming(); XCTAssertFalse(m.allSuspended, "streaming: the captures keep the display awake")
        m.sessionBegan("b"); m.sessionStreamed("b")
        m.sessionSuspended("a", now: 0); XCTAssertFalse(m.allSuspended, "b still streams")
        m.sessionSuspended("b", now: 0); XCTAssertTrue(m.allSuspended, "nothing streams: the display may sleep")
        XCTAssertTrue(m.wantsCurtain, "the curtain stays logically up")
        m.sessionBegan("a", now: Self.s); XCTAssertFalse(m.allSuspended, "a resume takes the display back")
        XCTAssertFalse(M().allSuspended, "no session: not this state")
    }
    func testSuspendThenExpiryLocks() {
        var m = streaming()
        m.sessionSuspended("a", now: 0)
        m.sessionStopped("a", now: 86_400 * Self.s)   // the resume window passed (or evicted, or claimed elsewhere)
        XCTAssertTrue(m.tick(now: 86_400 * Self.s + m.debounceNanos), "finished without anyone signing in at the Mac: lock")
        XCTAssertFalse(m.needsWatching)
        // The curtain protected it the whole time: no presence check (a person would have locked it with their first click).
        var p = streaming(); p.sessionSuspended("a", now: 0); p.localInputUncurtained(now: 10 * Self.s)
        XCTAssertNil(p.lastLocalInput, "presence is not watched behind the curtain")
        p.sessionStopped("a", now: 20 * Self.s); XCTAssertTrue(p.tick(now: 20 * Self.s + p.debounceNanos))
    }
    func testSuspendThenResumeDoesNotLock() {
        var m = streaming()
        m.sessionSuspended("a", now: 0); m.sessionBegan("a", now: 600 * Self.s); m.sessionStreamed("a")
        XCTAssertNil(m.pendingEnd); XCTAssertFalse(m.tick(now: 3600 * Self.s)); XCTAssertTrue(m.wantsCurtain)
    }
    func testAStopWhileAnotherIsSuspendedIsNotTheEnd() {
        var m = streaming(); m.sessionBegan("b"); m.sessionStreamed("b")
        m.sessionSuspended("a", now: 0); m.sessionStopped("b", now: 10 * Self.s)
        XCTAssertNil(m.pendingEnd, "a may still come back"); XCTAssertTrue(m.wantsCurtain)
        m.sessionStopped("a", now: 100 * Self.s); XCTAssertTrue(m.tick(now: 100 * Self.s + m.debounceNanos))
    }

    // MARK: Presence (only where the curtain is not protecting the Mac)

    func testLocalInputWithCurtainOffMeansSomeoneIsThere() {
        var m = streaming(curtain: false)
        XCTAssertTrue(m.watchesPresence)
        XCTAssertFalse(streaming(curtain: false, lock: false).watchesPresence, "nothing to decide without Lock when finished")
        XCTAssertFalse(streaming().watchesPresence, "the curtain protects: local input locks instead")
        XCTAssertFalse(M().watchesPresence, "no session, no watch")
        m.localInputUncurtained(now: 0)
        XCTAssertTrue(m.presentLocally(at: 0)); XCTAssertFalse(m.lockOnLocalInput(), "never a lock mid-session")
        m.sessionStopped("a", now: 0); XCTAssertFalse(m.tick(now: m.debounceNanos), "someone is at the Mac")
        // The next session starts afresh.
        m.sessionBegan("b", .init(curtain: false)); m.sessionStreamed("b"); m.sessionStopped("b", now: 0); XCTAssertTrue(m.tick(now: m.debounceNanos))
        // They left and locked it; the remote person unlocked it through Mirage: the end locks it again.
        var left = streaming(curtain: false)
        left.localInputUncurtained(now: 0); left.lockChanged(true); left.injectedDown(); left.lockChanged(false)
        XCTAssertNil(left.lastLocalInput); XCTAssertFalse(left.ownedLocally)
        left.sessionStopped("a", now: 0); XCTAssertTrue(left.tick(now: left.debounceNanos))
        // Input at the lock screen is not presence.
        var lockedM = streaming(curtain: false, locked: true); lockedM.localInputUncurtained(now: 0); XCTAssertNil(lockedM.lastLocalInput)
    }
    func testCurtainOffSuspendThenSomeoneAtTheMac() {
        var m = streaming(curtain: false); m.sessionSuspended("a", now: 0)
        XCTAssertFalse(m.wantsCurtain)
        m.localInputUncurtained(now: 86_390 * Self.s)
        m.sessionStopped("a", now: 86_400 * Self.s)
        XCTAssertFalse(m.tick(now: 86_400 * Self.s + m.debounceNanos), "someone is using it: left unlocked")
    }
    func testOnlyRecentInputCounts() {
        var m = streaming(curtain: false)
        m.localInputUncurtained(now: 5 * Self.s)
        m.sessionStopped("a", now: 100 * Self.s)
        XCTAssertTrue(m.tick(now: 100 * Self.s + m.debounceNanos), "one stray click long before does not count")
        var n = streaming(curtain: false)
        n.localInputUncurtained(now: 5 * Self.s); n.localInputUncurtained(now: 80 * Self.s)
        n.sessionStopped("a", now: 100 * Self.s)
        XCTAssertFalse(n.tick(now: 100 * Self.s + n.debounceNanos), "still in use shortly before")
    }
    func testCurtainOnButUnableToProtectWatches() {
        // The curtain could not show (no tap) or could not lock: like Curtain off, presence counts.
        var m = streaming(); m.curtainFailed()
        XCTAssertTrue(m.watchesPresence)
        m.localInputUncurtained(now: 0); XCTAssertTrue(m.presentLocally(at: 0))
        m.sessionStopped("a", now: 0); XCTAssertFalse(m.tick(now: m.debounceNanos))
        var f = streaming(); f.lockFailed(); XCTAssertTrue(f.watchesPresence)
        // Wherever the curtain is wanted (opaque or not), local input locks instead and is not presence.
        var up = streaming(); up.localInputUncurtained(now: 0); XCTAssertNil(up.lastLocalInput); XCTAssertTrue(up.lockOnLocalInput())
        // A curtain that cannot show is not wanted (no "not shown" on every update).
        XCTAssertFalse(m.wantsCurtain)
    }
    /// Curtain off: an expiring suspended session stays unlocked after any presence since the suspend, not only the last
    /// minute's (someone reading for an hour).
    func testCurtainOffPresenceSinceTheSuspend() {
        var m = streaming(curtain: false); m.sessionSuspended("a", now: 100 * Self.s)
        m.localInputUncurtained(now: 3_600 * Self.s)
        m.sessionStopped("a", now: 86_400 * Self.s)
        XCTAssertFalse(m.tick(now: 86_400 * Self.s + m.debounceNanos), "used since the suspend: left unlocked")
        var before = streaming(curtain: false); before.localInputUncurtained(now: 50 * Self.s); before.sessionSuspended("a", now: 100 * Self.s)
        before.sessionStopped("a", now: 86_400 * Self.s)
        XCTAssertTrue(before.tick(now: 86_400 * Self.s + before.debounceNanos), "input only before the suspend: lock")
    }
    /// A begin that hangs (a start or a resume that never streams nor fails) holds the end 30 s at most.
    func testAHungBeginHoldsTheEndAtMost30s() {
        var m = streaming()
        m.sessionStopped("a", now: 0); m.sessionBegan("b", now: Self.s)
        XCTAssertFalse(m.tick(now: 20 * Self.s), "b on its way")
        XCTAssertTrue(m.tick(now: 31 * Self.s + Self.s), "b hung: the end goes on")
        XCTAssertNotNil(m.sessions["b"], "still tracked: if it ever streams, its curtain follows")
        m.sessionStreamed("b"); XCTAssertTrue(m.wantsCurtain)
        // A hung resume the same.
        var r = streaming(); r.sessionBegan("c"); r.sessionStreamed("c")
        r.sessionSuspended("a", now: 0); r.sessionBegan("a", now: Self.s); r.sessionStopped("c", now: 2 * Self.s)
        XCTAssertNil(r.pendingEnd, "a is resuming (it streamed before): not the end")
    }

    // MARK: A session that begins but never streams

    func testAFailedBeginDuringTheDebounceStillLocks() {
        var m = streaming()
        m.sessionStopped("a", now: 0)
        m.sessionBegan("b", now: Self.s)
        XCTAssertFalse(m.tick(now: m.debounceNanos), "b is on its way: wait")
        m.sessionStopped("b", now: m.debounceNanos + Self.s)   // its start failed
        XCTAssertTrue(m.tick(now: m.debounceNanos + Self.s), "the clean end goes on: lock")
        var n = streaming(); n.sessionStopped("a", now: 0); n.sessionBegan("b", now: Self.s); n.sessionSuspended("b", now: 2 * Self.s)
        XCTAssertTrue(n.tick(now: n.debounceNanos), "a start that failed with a suspend the same")
        // A begin that was already on its way when the last stream stopped, and then failed: the end still comes.
        var o = streaming(); o.sessionBegan("b", now: 0); o.sessionStopped("a", now: Self.s); o.sessionStopped("b", now: 2 * Self.s)
        XCTAssertTrue(o.tick(now: Self.s + o.debounceNanos))
    }
    func testAFailedBeginWhileSuspendedChangesNothing() {
        var m = streaming(); m.lockFailed()
        m.sessionSuspended("a", now: 0)
        m.sessionBegan("b", now: 10 * Self.s); m.sessionStopped("b", now: 11 * Self.s)
        XCTAssertNil(m.pendingEnd); XCTAssertEqual(Set(m.sessions.keys), ["a"], "a is still suspended")
        m.sessionStopped("a", now: 100 * Self.s); XCTAssertTrue(m.tick(now: 100 * Self.s + m.debounceNanos))
        // Nothing stale carries over: the next session gets its curtain.
        XCTAssertFalse(m.lockUnavailable); m.sessionBegan("c"); XCTAssertTrue(m.wantsCurtain)
    }
    func testAResumeThatFailsStaysSuspended() {
        var m = streaming(); m.sessionSuspended("a", now: 0)
        m.sessionBegan("a", now: 10 * Self.s)                  // resuming
        m.sessionSuspended("a", now: 11 * Self.s)               // the resume failed
        XCTAssertTrue(m.allSuspended); XCTAssertTrue(m.wantsCurtain); XCTAssertNil(m.pendingEnd)
    }

    /// Stay Reachable: held with the setting on, on the power adapter or where no power source is reported (a desktop).
    func testStayReachableOnlyOnThePowerAdapter() {
        XCTAssertTrue(StayReachable.shouldHold(enabled: true, powerSource: "AC Power"))
        XCTAssertTrue(StayReachable.shouldHold(enabled: true, powerSource: nil), "a desktop")
        XCTAssertFalse(StayReachable.shouldHold(enabled: true, powerSource: "Battery Power"), "on battery: macOS sleeps it as usual")
        XCTAssertFalse(StayReachable.shouldHold(enabled: true, powerSource: "UPS Power"))
        XCTAssertFalse(StayReachable.shouldHold(enabled: false, powerSource: "AC Power"), "the setting off")
        XCTAssertEqual(try JSONDecoder().decode(HostSettings.self, from: Data(#"{"curtain": false}"#.utf8)).stayReachable, true, "default on")
        XCTAssertEqual(try JSONDecoder().decode(HostSettings.self, from: Data(#"{"stayReachable": false}"#.utf8)).stayReachable, false)
    }
    func testSettingsFileDefaultsAndTolerance() throws {
        XCTAssertEqual(try JSONDecoder().decode(HostSettings.self, from: Data("{}".utf8)), HostSettings(curtain: true, lockWhenFinished: true))
        XCTAssertEqual(try JSONDecoder().decode(HostSettings.self, from: Data(#"{"curtain": false, "future": 3, "lockWhenFinished": "x"}"#.utf8)),
                       HostSettings(curtain: false, lockWhenFinished: true))
    }
}
