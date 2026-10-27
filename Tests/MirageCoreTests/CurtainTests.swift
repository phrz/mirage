import XCTest
import CoreGraphics
@testable import MirageHost

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
        m.sessionEnded("a", stopped: false); m.sessionBegan("a")   // a backgrounded phone, a Wi-Fi roam
        XCTAssertTrue(m.ownedLocally); XCTAssertFalse(m.wantsCurtain, "the signed-in owner is not re-curtained")
        m.sessionEnded("a", stopped: true)
        XCTAssertFalse(m.ownedLocally, "the session over: forgotten")
    }
    func testPointerMotionAloneDoesNotMakeAnUnlockRemote() {
        var m = M(); m.sessionBegan("a")
        m.injectedDown()                                  // remote activity before the lock does not count
        m.lockChanged(true); m.lockChanged(false)         // only pointer motion while locked (not counted)
        XCTAssertTrue(m.ownedLocally)
    }
    func testNoCurtainNoLock() {
        var m = M(); m.sessionBegan("a")
        XCTAssertFalse(m.lockOnLocalInput(), "still invisible (filters not acknowledged): a local click must not lock")
        m.visible = true; XCTAssertTrue(m.lockOnLocalInput())
        m.lockChanged(true); XCTAssertFalse(m.visible); XCTAssertFalse(m.lockOnLocalInput())
    }
    func testTwoSessions() {
        var m = M(); m.sessionBegan("a"); m.sessionBegan("b")
        m.sessionEnded("a", stopped: true); XCTAssertTrue(m.wantsCurtain, "b still streams")
        m.sessionEnded("b", stopped: true); XCTAssertFalse(m.wantsCurtain)
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
        var m = CurtainLogic.Machine(); m.sessionBegan("a"); m.visible = true
        m.lockFailed()
        XCTAssertFalse(m.wantsCurtain, "a curtain that cannot lock stays off"); XCTAssertFalse(m.lockOnLocalInput())
        m.sessionEnded("a", stopped: false); m.sessionBegan("a")
        XCTAssertFalse(m.wantsCurtain, "still off across a suspend and resume")
        m.sessionEnded("a", stopped: true); m.sessionBegan("b")
        XCTAssertTrue(m.wantsCurtain, "a new session tries again")
    }
    func testSuspendThenStopEndsLocalOwnership() {
        var m = CurtainLogic.Machine(); m.sessionBegan("a"); m.lockChanged(true); m.lockChanged(false)
        XCTAssertTrue(m.ownedLocally)
        m.sessionEnded("a", stopped: false)        // suspended
        m.sessionEnded("a", stopped: true)         // and later expired: no longer among the sessions, still forwarded
        XCTAssertFalse(m.ownedLocally, "the next session on this Mac gets its curtain")
        m.sessionBegan("b"); XCTAssertTrue(m.wantsCurtain)
    }
}
