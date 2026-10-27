import Foundation
import CoreGraphics
import ApplicationServices
import MirageCore

/// The host's TCC grants (DESIGN §3.7a): Screen & System Audio Recording and Accessibility, both `miraged`'s own (the
/// embedded host, com.paulherz.mirage.host).
///
/// The rule (phrz, 2026-10-27: on a new host "all the permissions requests just pop up unbridled"): `miraged` never raises a
/// permission prompt by itself. Every check here only reads state: `CGPreflightScreenCaptureAccess`, the window list's
/// names (macOS shows other apps' window names only with the grant, and asking never prompts), and `AXIsProcessTrusted`.
/// No ScreenCaptureKit call (which would prompt) happens before the grant reads as present (`mayCapture`). A request is
/// made only when the person presses Allow in Mirage.app's permissions window, which asks the host over the local control
/// socket (`request`): the request must come from this process, whose identity the grant belongs to.
public enum HostPermissions {
    public enum Kind: String, Codable, CaseIterable, Sendable { case screenRecording, accessibility }

    /// How state is read and how a request is made (tests replace them and count).
    public struct System: @unchecked Sendable {
        public var preflightScreen: () -> Bool
        /// Another app's window name is visible: the Screen Recording grant is in force (CGPreflight can stay stale inside a
        /// running process). Never prompts.
        public var windowNamesVisible: () -> Bool
        public var axTrusted: () -> Bool
        public var requestScreen: () -> Void
        public var requestAX: () -> Void
        public init(preflightScreen: @escaping () -> Bool, windowNamesVisible: @escaping () -> Bool, axTrusted: @escaping () -> Bool,
                    requestScreen: @escaping () -> Void, requestAX: @escaping () -> Void) {
            self.preflightScreen = preflightScreen; self.windowNamesVisible = windowNamesVisible; self.axTrusted = axTrusted
            self.requestScreen = requestScreen; self.requestAX = requestAX
        }

        public static let live = System(
            preflightScreen: { CGPreflightScreenCaptureAccess() },
            windowNamesVisible: { HostPermissions.otherWindowNamesVisible() },
            axTrusted: { AXIsProcessTrusted() },
            requestScreen: { _ = CGRequestScreenCaptureAccess() },
            requestAX: { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) })
    }

    nonisolated(unsafe) public static var system = System.live
    private static let lock = NSLock()
    nonisolated(unsafe) private static var screenSeen = false

    /// Screen Recording, read without prompting. Once seen granted it stays so for this process (a revocation takes effect
    /// at the next start, which macOS forces anyway).
    public static func screenRecordingGranted() -> Bool {
        lock.lock(); let seen = screenSeen; lock.unlock()
        if seen { return true }
        let s = system
        let ok = s.preflightScreen() || s.windowNamesVisible()
        if ok { lock.lock(); screenSeen = true; lock.unlock() }
        return ok
    }

    /// Re-read from scratch (the watcher, to notice a revocation as well as a grant).
    public static func screenRecordingGrantedNow() -> Bool {
        let s = system
        let ok = s.preflightScreen() || s.windowNamesVisible()
        lock.lock(); screenSeen = ok; lock.unlock()
        return ok
    }

    public static func accessibilityGranted() -> Bool { system.axTrusted() }

    /// ScreenCaptureKit may be called: the grant reads as present. Every capture path asks this first.
    public static var mayCapture: Bool { screenRecordingGranted() }

    public static func granted(_ k: Kind) -> Bool {
        switch k {
        case .screenRecording: return screenRecordingGranted()
        case .accessibility: return accessibilityGranted()
        }
    }

    /// What is missing now, by kind.
    public static func missing() -> [Kind] { Kind.allCases.filter { !granted($0) } }

    /// The person pressed Allow in Mirage.app: raise the system's request for this process. The only caller.
    public static func request(_ k: Kind) {
        switch k {
        case .screenRecording: system.requestScreen()
        case .accessibility: system.requestAX()
        }
    }

    /// Tests: forget what was seen.
    public static func resetForTests() { lock.lock(); screenSeen = false; lock.unlock() }

    /// Whether an ordinary app's window has a name in the window list: macOS strips other apps' window names without the
    /// grant. Only normal windows (layer 0) of ordinary apps count. The system's own processes (the Dock, the window
    /// server, the menu bar's servers, the login window) are left out, since their names may be readable without it, and
    /// so is this process. No such window on screen: this says nothing (false), and preflight decides alone.
    static func otherWindowNamesVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return namesVisible(in: list, ownPID: Int(getpid()))
    }

    /// Owners whose window names do not show the grant.
    static let systemOwners: Set<String> = ["Dock", "Window Server", "WindowServer", "SystemUIServer", "Control Center", "ControlCenter",
                                            "Notification Center", "NotificationCenter", "loginwindow", "Spotlight", "TextInputMenuAgent",
                                            "Wallpaper", "WallpaperAgent", "universalAccessAuthWarn", "CursorUIViewService", "AXVisualSupportAgent"]

    static func namesVisible(in list: [[String: Any]], ownPID: Int) -> Bool {
        list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = w[kCGWindowOwnerName as String] as? String, !systemOwners.contains(owner) else { return false }
            return !((w[kCGWindowName as String] as? String) ?? "").isEmpty
        }
    }
}

/// The host opens Mirage.app for its permissions window at most once per boot (permissions-app-opened.json: the boot time).
public enum PermissionAppOpen {
    static let file = "permissions-app-opened.json"
    /// This boot's start, from the kernel.
    public static func bootTime() -> Double {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec)
    }
    /// True once per boot: records this boot when it says yes.
    public static func mayOpen(store: Store, boot: Double = bootTime()) -> Bool {
        let u = store.url(file)
        if let d = try? Data(contentsOf: u), let last = try? JSONDecoder().decode(Double.self, from: d), last == boot { return false }
        try? JSONEncoder().encode(boot).write(to: u, options: .atomic)
        return true
    }
}

/// Which permissions the host has requested once (permission-requests.json): a second Allow goes to System Settings, since
/// macOS shows its own sheet only the first time.
public enum PermissionRequests {
    static let file = "permission-requests.json"
    public static func asked(store: Store) -> [HostPermissions.Kind] {
        guard let d = try? Data(contentsOf: store.url(file)), let list = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return list.compactMap(HostPermissions.Kind.init(rawValue:))
    }
    public static func record(_ k: HostPermissions.Kind, store: Store) {
        var list = asked(store: store)
        guard !list.contains(k) else { return }
        list.append(k)
        try? JSONEncoder().encode(list.map(\.rawValue)).write(to: store.url(file), options: .atomic)
    }
}
