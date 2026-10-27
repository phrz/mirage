import Foundation
import CoreGraphics

/// The curtain's decisions, apart from AppKit so they can be tested (DESIGN §3.12).
public enum CurtainLogic {
    /// Every event miraged injects carries this in `kCGEventSourceUserData` (its CGEventSource's `userData`): the curtain's
    /// event tap tells the remote person's input from a local one by it. ASCII "MIRAGE!!".
    public static let injectedTag: Int64 = 0x4D49_5241_4745_2121

    /// The events that count as someone at the Mac: a click, a key, a modifier, a scroll from the hardware. Pointer motion
    /// alone does not (a nudged table, a mouse settling), nor anything a program posts: miraged's own (tagged, and its pid),
    /// or another app's synthetic input (1Password autofill, Keyboard Maestro, BetterTouchTool, TextExpander, Raycast, Voice
    /// Control, the Accessibility Keyboard), which carries the poster's pid in `kCGEventSourceUnixProcessID`; hardware events
    /// carry 0 there.
    public static func isLocalInput(type: CGEventType, userData: Int64, sourcePID: Int64) -> Bool {
        guard userData != injectedTag, sourcePID == 0 else { return false }
        return isTriggerType(type)
    }
    /// A down-type event (and modifiers, scroll): what can trigger the lock.
    public static func isTriggerType(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel: return true
        default: return false
        }
    }
    /// What the active tap swallows while the lock it triggered takes hold (about 2.5 s or until locked): the hardware's
    /// downs and their matching ups, modifiers and scrolls; pointer motion passes.
    public static func isSwallowedType(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .flagsChanged, .scrollWheel,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return true
        default: return false
        }
    }

    /// The text over the blurred wallpaper: black on a light picture, white on a dark one, slightly transparent either way (as
    /// the lock screen's message reads). `luminance` is the mean relative luminance (0...1) behind the text block.
    public struct TextStyle: Equatable { public var white: Bool; public var alpha: Double }
    public static func textStyle(luminance: Double) -> TextStyle {
        luminance > 0.55 ? TextStyle(white: false, alpha: 0.85) : TextStyle(white: true, alpha: 0.9)
    }

    /// Mean relative luminance (Rec. 709 on sRGB-ish 8-bit values, linearised) of premultiplied BGRA pixels in `rect`.
    public static func meanLuminance(bgra: UnsafeRawBufferPointer, width: Int, height: Int, stride: Int, rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX)), y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return 0.5 }
        func lin(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var sum = 0.0, n = 0
        let step = max(1, (x1 - x0) * (y1 - y0) / 20_000)   // ~20k samples are plenty for a blurred picture
        var i = 0
        for y in y0..<y1 { for x in x0..<x1 {
            i += 1; if i % step != 0 { continue }
            let o = y * stride + x * 4
            sum += 0.0722 * lin(bgra[o]) + 0.7152 * lin(bgra[o + 1]) + 0.2126 * lin(bgra[o + 2]); n += 1
        } }
        return n > 0 ? sum / Double(n) : 0.5
    }

    /// Whose lock is it, and should the curtain show: sessions, the lock, and who unlocked (DESIGN §3.12). Pure: Curtain feeds
    /// it events and does what it says.
    public struct Machine: Equatable {
        public private(set) var sessions = Set<String>()
        public private(set) var locked = false
        /// A person at the Mac signed in (an unlock with no remote key or click while locked): no curtain until a remote unlock
        /// or the end of every session. Kept across a suspend and resume (a backgrounded phone, a Wi-Fi roam).
        public private(set) var ownedLocally = false
        /// Injected key-downs and clicks since the Mac locked: the remote person typing a password through Mirage. Pointer
        /// motion and input refused before the lock do not count.
        public private(set) var remoteDownsWhileLocked = 0
        /// The curtain is up on the screens (opaque): only then does local input lock.
        public var visible = false
        public init(locked: Bool = false) { self.locked = locked }

        /// A lock the curtain asked for did not land (⌃⌘Q remapped or grabbed by a VM or remote-desktop app, and no password
        /// after display sleep): a curtain that cannot lock would only swallow the Mac's own input, so it stays off until every
        /// session has ended.
        public private(set) var lockUnavailable = false
        /// The curtain should be on the screens.
        public var wantsCurtain: Bool { !sessions.isEmpty && !locked && !ownedLocally && !lockUnavailable }
        public mutating func lockFailed() { lockUnavailable = true; visible = false }

        public mutating func sessionBegan(_ id: String) { sessions.insert(id) }
        /// `stopped`: the session ended for good (stop), not suspended: once none is left, local ownership is forgotten.
        public mutating func sessionEnded(_ id: String, stopped: Bool) {
            sessions.remove(id)
            if sessions.isEmpty, stopped { ownedLocally = false; lockUnavailable = false }
        }
        public mutating func injectedDown() { if locked { remoteDownsWhileLocked += 1 } }
        /// The lock state changed: an unlock is remote (Mirage typed the password) when injected downs came in while locked,
        /// local otherwise.
        public mutating func lockChanged(_ nowLocked: Bool) {
            guard nowLocked != locked else { return }
            locked = nowLocked
            if nowLocked { remoteDownsWhileLocked = 0; visible = false; return }
            ownedLocally = remoteDownsWhileLocked == 0
            remoteDownsWhileLocked = 0
        }
        /// Local input arrived: lock, if and only if the curtain is up (no curtain, no lock).
        public func lockOnLocalInput() -> Bool { visible && !locked }
    }
}
