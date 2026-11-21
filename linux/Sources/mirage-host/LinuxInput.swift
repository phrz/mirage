import Foundation
import MirageCore
import CMirageDesktop

/// Viewer input (normalized pointer positions, Mac key codes and modifier flags) injected through the Mutter session.
///
/// Keys go by position (Mac virtual key code → Linux evdev code), so GNOME's own keyboard layout applies. Modifiers:
/// Command is Ctrl (⌘C copies, as Mac users expect), Control is the other Ctrl, Option is Alt (right Option is AltGr),
/// and right Command is Super (the Activities key).
final class LinuxInput: @unchecked Sendable {
    private let lock = NSLock()
    private var _session: OpaquePointer?
    var session: OpaquePointer? {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); _session = newValue; if newValue == nil { held = [] }; lock.unlock() }
    }
    var size: (Double, Double) {
        get { lock.lock(); defer { lock.unlock() }; return _size }
        set { lock.lock(); _size = newValue; lock.unlock() }
    }
    private var _size: (Double, Double) = (1, 1)
    /// Modifier keys (evdev) held down here, so they are released when the viewer's flags say they are up.
    private var held: Set<UInt32> = []
    private var buttons: Set<Int32> = []

    func apply(_ m: ControlMessage) {
        lock.lock()
        guard let s = _session else { lock.unlock(); return }
        let (w, h) = _size
        lock.unlock()
        func move(_ x: Double, _ y: Double) { md_pointer_move(s, min(max(x, 0), 1) * (w - 1), min(max(y, 0), 1) * (h - 1)) }
        switch m {
        case .mouseMove(let mv):
            move(mv.x, mv.y)
        case .mouseButton(let b):
            syncModifiers(b.modifiers, s)
            move(b.x, b.y)
            let code: Int32 = [0: 0x110, 1: 0x111, 2: 0x112, 3: 0x113, 4: 0x114][b.button] ?? 0x112
            lock.lock()
            let change = b.down ? buttons.insert(code).inserted : buttons.remove(code) != nil
            lock.unlock()
            if change { md_pointer_button(s, code, b.down ? 1 : 0) }
        case .scroll(let sc):
            syncModifiers(sc.modifiers, s)
            move(sc.x, sc.y)
            // Mac deltas are positive up/left; GNOME's are positive down/right.
            if sc.precise {
                md_pointer_axis(s, -sc.dx, -sc.dy, 1)
            } else {
                let v = Int32((-sc.dy).rounded()), hz = Int32((-sc.dx).rounded())
                if v != 0 { md_pointer_axis_discrete(s, 0, v) }
                if hz != 0 { md_pointer_axis_discrete(s, 1, hz) }
            }
        case .key(let k):
            if Self.modifierKeys[k.keyCode] != nil { modifierKey(k.keyCode, flags: k.modifiers, s); return }
            syncModifiers(k.modifiers, s)
            if k.isRepeat { return }   // GNOME repeats a held key itself
            if let code = Self.keys[k.keyCode] { md_key(s, code, k.down ? 1 : 0) }
            else if let ch = k.characters?.unicodeScalars.first { md_keysym(s, Self.keysym(ch), k.down ? 1 : 0) }
        case .modifiers(let mo):
            modifierKey(mo.keyCode, flags: mo.modifiers, s)
        default:
            break
        }
    }

    // MARK: Modifiers

    /// CGEventFlags bits.
    private static let shift: UInt64 = 0x20000, control: UInt64 = 0x40000, option: UInt64 = 0x80000, command: UInt64 = 0x100000, caps: UInt64 = 0x10000

    /// Mac modifier key code → (evdev key, the flag that says it is down).
    private static let modifierKeys: [UInt16: (UInt32, UInt64)] = [
        0x38: (42, shift), 0x3C: (54, shift),          // Shift, right Shift
        0x37: (29, command), 0x36: (125, command),     // Command → Ctrl, right Command → Super
        0x3B: (97, control), 0x3E: (97, control),      // Control → right Ctrl
        0x3A: (56, option), 0x3D: (100, option),       // Option → Alt, right Option → AltGr
    ]

    private func modifierKey(_ keyCode: UInt16, flags: UInt64, _ s: OpaquePointer) {
        if keyCode == 0x39 { md_key(s, 58, 1); md_key(s, 58, 0); return }   // Caps Lock toggles
        guard let (code, flag) = Self.modifierKeys[keyCode] else { syncModifiers(flags, s); return }
        let down = flags & flag != 0
        lock.lock()
        // A modifier event says the state of its own key; when its family's flag is down, the key that changed is the
        // one going down unless it was already held (then it is this key going up while its twin stays down).
        let isHeld = held.contains(code)
        let press = down && !isHeld
        if press { held.insert(code) } else if isHeld { held.remove(code) }
        lock.unlock()
        if press { md_key(s, code, 1) } else if isHeld { md_key(s, code, 0) }
        syncModifiers(flags, s)
    }

    /// Releases held modifiers whose flag is no longer set (a release the viewer never sent as its own event).
    private func syncModifiers(_ flags: UInt64, _ s: OpaquePointer) {
        lock.lock()
        let stale = held.filter { code in
            guard let flag = Self.modifierKeys.values.first(where: { $0.0 == code })?.1 else { return false }
            return flags & flag == 0
        }
        held.subtract(stale)
        lock.unlock()
        for code in stale { md_key(s, code, 0) }
    }

    // MARK: Key codes

    /// Mac virtual key code → Linux evdev key code (by position, ANSI layout).
    static let keys: [UInt16: UInt32] = [
        0x00: 30, 0x01: 31, 0x02: 32, 0x03: 33, 0x04: 35, 0x05: 34, 0x06: 44, 0x07: 45, 0x08: 46, 0x09: 47,   // A S D F H G Z X C V
        0x0A: 86, 0x0B: 48, 0x0C: 16, 0x0D: 17, 0x0E: 18, 0x0F: 19, 0x10: 21, 0x11: 20,                       // § B Q W E R Y T
        0x12: 2, 0x13: 3, 0x14: 4, 0x15: 5, 0x16: 7, 0x17: 6, 0x18: 13, 0x19: 10, 0x1A: 8, 0x1B: 12,         // 1 2 3 4 6 5 = 9 7 -
        0x1C: 9, 0x1D: 11, 0x1E: 27, 0x1F: 24, 0x20: 22, 0x21: 26, 0x22: 23, 0x23: 25, 0x24: 28,              // 8 0 ] O U [ I P Return
        0x25: 38, 0x26: 36, 0x27: 40, 0x28: 37, 0x29: 39, 0x2A: 43, 0x2B: 51, 0x2C: 53, 0x2D: 49, 0x2E: 50,   // L J ' K ; \ , / N M
        0x2F: 52, 0x30: 15, 0x31: 57, 0x32: 41, 0x33: 14, 0x35: 1,                                             // . Tab Space ` Delete Esc
        0x40: 187, 0x41: 83, 0x43: 55, 0x45: 78, 0x47: 69, 0x48: 115, 0x49: 114, 0x4A: 113, 0x4B: 98, 0x4C: 96,
        0x4E: 74, 0x4F: 188, 0x50: 189, 0x51: 117, 0x52: 82, 0x53: 79, 0x54: 80, 0x55: 81, 0x56: 75, 0x57: 76,
        0x58: 77, 0x59: 71, 0x5A: 190, 0x5B: 72, 0x5C: 73, 0x5D: 124, 0x5E: 89, 0x5F: 121,
        0x60: 63, 0x61: 64, 0x62: 65, 0x63: 61, 0x64: 66, 0x65: 67, 0x67: 87, 0x69: 183, 0x6A: 186, 0x6B: 184,  // F5 F6 F7 F3 F8 F9 F11 F13 F16 F14
        0x6D: 68, 0x6F: 88, 0x71: 185, 0x72: 110, 0x73: 102, 0x74: 104, 0x75: 111, 0x76: 62, 0x77: 107,        // F10 F12 F15 Help→Insert Home PgUp Del F4 End
        0x78: 60, 0x79: 109, 0x7A: 59, 0x7B: 105, 0x7C: 106, 0x7D: 108, 0x7E: 103,                             // F2 PgDn F1 ← → ↓ ↑
        0x66: 122, 0x68: 123,                                                                                  // JIS Eisu, Kana
    ]

    /// X keysym for a character the key table lacks: Latin-1 as is, else Unicode keysyms (0x01000000 + code point).
    static func keysym(_ c: Unicode.Scalar) -> UInt32 {
        c.value < 0x100 ? c.value : 0x0100_0000 + c.value
    }
}
