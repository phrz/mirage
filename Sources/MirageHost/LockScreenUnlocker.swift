import Foundation
import CoreGraphics
import IOKit
import Security
import MirageCore

/// Unlock with biometry, the host's half (DESIGN §3.13): types a viewer's password at the lock screen, only while the lock
/// screen is confirmed up, then Return, and reports whether the Mac unlocked. Every event carries the injection tag, and
/// counts as the remote person's input, so the curtain treats the unlock as remote (DESIGN §3.12). The password is never
/// logged; its bytes are zeroed after typing.
///
/// The lock check is its own and fails closed (`StrictLock`): the session dictionary's CGSSessionScreenIsLocked and the
/// IORegistry's IOConsoleLocked, both true and read fresh, and Secure Event Input, when held, held by loginwindow itself
/// (by executable path). Never the shield-window signal (any process of the user can draw a window it calls loginwindow),
/// never the 250 ms cache, never the MIRAGE_TEST_SCREEN_LOCK override. It runs before the wake, after it, before every
/// keystroke and before Return: a lock screen that goes away mid-typing (Touch ID, an Apple Watch, someone at the Mac)
/// stops the typing, and Return is never sent.
public enum LockScreenUnlocker {
    /// The keystrokes for `password`: each character as a key-down and key-up carrying it as its Unicode string (layout
    /// independent, as the viewer's own typing reaches the host), then Return. Pure, for tests.
    public struct Stroke: Equatable { public var keyCode: UInt16; public var down: Bool; public var utf16: [UInt16] }
    public static func strokes(for password: [UInt8]) -> [Stroke]? {
        guard let s = String(bytes: password, encoding: .utf8), !s.isEmpty, !s.contains(where: { $0.isNewline }) else { return nil }
        var out: [Stroke] = []
        for c in s {
            let u = Array(String(c).utf16)
            out.append(Stroke(keyCode: 0, down: true, utf16: u)); out.append(Stroke(keyCode: 0, down: false, utf16: u))
        }
        out.append(Stroke(keyCode: 36, down: true, utf16: [13])); out.append(Stroke(keyCode: 36, down: false, utf16: [13]))
        return out
    }

    /// The lock screen, confirmed (see the type's notes). Pure decision, for tests; `current()` reads the system.
    public enum StrictLock {
        public static let loginwindow = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
        public static func confirmed(sessionLocked: Bool?, consoleLocked: Bool?, secureInputHolder: String?) -> Bool {
            sessionLocked == true && consoleLocked == true && (secureInputHolder == nil || secureInputHolder == loginwindow)
        }
        public static func current() -> Bool { let s = signals(); return confirmed(sessionLocked: s.session, consoleLocked: s.console, secureInputHolder: s.holder) }
        /// The signals, for the host log at each attempt (they decide whether the feature works at a real lock screen).
        public static func describe() -> String {
            let s = signals()
            return "CGSSessionScreenIsLocked \(s.session.map { "\($0)" } ?? "absent"), IOConsoleLocked \(s.console.map { "\($0)" } ?? "absent"), secure input \(s.holder ?? "not held")"
        }
        static func signals() -> (session: Bool?, console: Bool?, holder: String?) {
            let d = CGSessionCopyCurrentDictionary() as? [String: Any]
            var console: Bool? = nil
            let root = IORegistryGetRootEntry(kIOMainPortDefault)
            if root != 0 {
                console = ScreenLock.flag(IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
                IOObjectRelease(root)
            }
            // The process holding Secure Event Input, when one does (the session dictionary names its pid).
            var holder: String? = nil
            if let pid = (d?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 {
                var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                holder = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
            }
            return (ScreenLock.sessionLocked(d), console, holder)
        }
    }

    /// The handler miraged gives HostContext.
    public static func unlock(_ password: SecretBytes) async -> ControlMessage.UnlockResult.Outcome {
        lastTypingNanos = Clock.nowNanos()
        return await unlock(password, locked: { StrictLock.current() }, post: { postTagged($0) }, wake: .milliseconds(600), settle: .seconds(6))
    }
    /// When Unlock with biometry last began typing (the curtain's log of what unlocked the Mac).
    nonisolated(unsafe) public static var lastTypingNanos: UInt64 = 0
    /// `locked` and `post` injectable for tests.
    static func unlock(_ password: SecretBytes, locked: @escaping @Sendable () -> Bool, post: @escaping @Sendable (Stroke) -> Void,
                       wake: Duration, settle: Duration) async -> ControlMessage.UnlockResult.Outcome {
        defer { password.wipe() }
        guard locked() else { return .notLocked }
        guard var strokes = strokes(for: password.bytes) else { return .refused }
        defer { for i in strokes.indices { strokes[i].utf16 = strokes[i].utf16.map { _ in 0 } } }
        // Wake the display and the lock screen's field (a modifier event changes nothing), then look again.
        post(Stroke(keyCode: 0x38, down: true, utf16: []))
        try? await Task.sleep(for: wake)
        guard locked() else { return .notLocked }
        for s in strokes {
            // Every keystroke, Return included, only while the lock screen is still confirmed: else stop, without Return.
            guard locked() else { return .interrupted }
            if s.down { Curtain.shared.noteInjectedDown() }
            post(s)
            try? await Task.sleep(for: .milliseconds(12))
        }
        // Did it take? The lock screen goes within a second or two of a right password.
        let deadline = ContinuousClock.now + settle
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if !locked() { return .unlocked }
        }
        return .stillLocked
    }

    /// Calls `onUnlock` whenever the Mac goes from locked to unlocked by the system's own flags, either one
    /// (CGSSessionScreenIsLocked or IOConsoleLocked: the latter was seen false on a locked Mac, so requiring both could miss
    /// an unlock): the gate's pause after a failure ends (polled every 2 s). Never the shield-window signal, which any
    /// process of the user can fake; and ending the pause only allows one more attempt, itself strictly checked.
    public static func watchUnlocks(_ onUnlock: @escaping @Sendable () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        func locked() -> Bool { let s = StrictLock.signals(); return s.session == true || s.console == true }
        nonisolated(unsafe) var was = locked()
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { let now = locked(); if was, !now { onUnlock() }; was = now }
        t.resume()
        watcher = t
    }
    nonisolated(unsafe) private static var watcher: DispatchSourceTimer?

    /// This process runs with the hardened runtime (no debugger can attach to read a password mid-typing). Without it the
    /// host does not offer Unlock with biometry.
    public static func hardenedRuntime() -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        var st: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &st) == errSecSuccess, let st else { return false }
        return hardenedRuntime(st)
    }
    /// The same for a binary on disk (tests: the installed Developer ID miraged reports it, the test runner does not).
    public static func hardenedRuntime(path: String) -> Bool {
        var st: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &st) == errSecSuccess, let st else { return false }
        return hardenedRuntime(st)
    }
    /// The code directory's flags come with the signing information (kSecCSSigningInformation), not the dynamic one.
    static func hardenedRuntime(_ st: SecStaticCode) -> Bool {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(st, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], let flags = d[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0
    }

    /// A stroke as a tagged CGEvent at the HID tap. keyCode 0x38 with no utf16: a bare modifier event (the wake).
    static func postTagged(_ s: Stroke) {
        let src = InputInjector.taggedSource()
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(s.keyCode), keyDown: s.down) else { return }
        if s.utf16.isEmpty { e.type = .flagsChanged; e.flags = [] }
        else { var u = s.utf16; e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); for i in u.indices { u[i] = 0 } }
        e.post(tap: .cghidEventTap)
    }
}
