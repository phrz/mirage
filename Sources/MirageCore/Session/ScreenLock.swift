import Foundation

/// Whether the host's screen is locked, from every signal macOS gives (M3.1 field run: `IOConsoleLocked`
/// read false while `CGSSessionScreenIsLocked` was 1 and loginwindow's shield windows covered the screen).
/// Any one signal saying "locked" means locked: a guard that refuses scripted input must fail closed.
public enum ScreenLock {
    public struct Signals: Equatable, Sendable {
        /// `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`, whatever it bridged as.
        public var sessionScreenIsLocked: Bool?
        /// The IORegistry root's `IOConsoleLocked`.
        public var ioConsoleLocked: Bool?
        /// loginwindow owns an on-screen window at the shield level (≥ 2000) covering most of the display.
        public var shieldWindow: Bool
        public init(sessionScreenIsLocked: Bool?, ioConsoleLocked: Bool?, shieldWindow: Bool) {
            self.sessionScreenIsLocked = sessionScreenIsLocked; self.ioConsoleLocked = ioConsoleLocked; self.shieldWindow = shieldWindow
        }
        public var locked: Bool { (sessionScreenIsLocked ?? false) || (ioConsoleLocked ?? false) || shieldWindow }
        public var description: String { "CGSSessionScreenIsLocked \(sessionScreenIsLocked.map { "\($0)" } ?? "absent"), IOConsoleLocked \(ioConsoleLocked.map { "\($0)" } ?? "absent"), shield window \(shieldWindow)" }
    }

    /// A property-list value as a boolean: CFBoolean, NSNumber of any width, or the strings "1"/"true"/"yes".
    public static func flag(_ v: Any?) -> Bool? {
        switch v {
        case nil: return nil
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let i as Int: return i != 0
        case let s as String: return ["1", "true", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    /// The session-dictionary signal.
    public static func sessionLocked(_ dict: [String: Any]?) -> Bool? { flag(dict?["CGSSessionScreenIsLocked"]) }

    /// The shield-window signal from a window list (frames in display pixels).
    public static func shieldPresent(_ windows: [ControlMessage.WindowInfo], display: PixelRect) -> Bool {
        windows.contains { w in w.app == "loginwindow" && w.windowLevel >= 2000 && w.frame.intersection(display).area * 10 >= display.area * 9 }
    }
}
