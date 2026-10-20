import Foundation

/// What a touch client (iOS) sends as Mac input: virtual key codes for typed characters and hardware keys, and the
/// CGEventFlags bits the host injects with them. The host injects key events by code and, for key downs, also sets
/// the typed string, so a character without a US-layout key still arrives as itself.
public enum MacKeys {
    // CGEventFlags masks (kCGEventFlagMask*).
    public static let shiftFlag: UInt64 = 1 << 17, controlFlag: UInt64 = 1 << 18, optionFlag: UInt64 = 1 << 19, commandFlag: UInt64 = 1 << 20
    public static let capsLockFlag: UInt64 = 1 << 16

    // kVK_* codes the clients refer to by name.
    public static let returnKey: UInt16 = 36, tab: UInt16 = 48, space: UInt16 = 49, delete: UInt16 = 51, escape: UInt16 = 53
    public static let command: UInt16 = 55, shift: UInt16 = 56, capsLock: UInt16 = 57, option: UInt16 = 58, control: UInt16 = 59
    public static let rightCommand: UInt16 = 54, rightShift: UInt16 = 60, rightOption: UInt16 = 61, rightControl: UInt16 = 62
    public static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    private static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    private static let plain: [Character: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50, " ": 49, "\n": 36, "\r": 36, "\t": 48,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The US-layout key for a typed character and whether it takes shift; nil for characters with no such key
    /// (accented letters, emoji), which are sent with code 0 and their string.
    public static func key(for ch: Character) -> (keyCode: UInt16, shift: Bool)? {
        if let k = plain[ch] { return (k, false) }
        if let k = letters[ch] { return (k, false) }
        if ch.isUppercase, let lower = ch.lowercased().first, let k = letters[lower] { return (k, true) }
        if let base = shifted[ch], let k = plain[base] { return (k, true) }
        return nil
    }

    /// A USB HID keyboard usage (UIKeyboardHIDUsage) as a Mac virtual key code.
    public static func keyCode(hidUsage u: Int) -> UInt16? {
        switch u {
        case 4...29:   // a–z
            let ch = Character(UnicodeScalar(UInt8(97 + u - 4)))
            return letters[ch]
        case 30...38: return plain[Character(String(u - 29))]   // 1–9
        case 39: return 29
        case 40: return returnKey
        case 41: return escape
        case 42: return delete
        case 43: return tab
        case 44: return space
        case 45: return 27
        case 46: return 24
        case 47: return 33
        case 48: return 30
        case 49, 50: return 42
        case 51: return 41
        case 52: return 39
        case 53: return 50
        case 54: return 43
        case 55: return 47
        case 56: return 44
        case 57: return capsLock
        case 58...69: return [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111][u - 58]   // F1–F12
        case 73: return 114   // insert → help
        case 74: return 115   // home
        case 75: return 116   // page up
        case 76: return 117   // forward delete
        case 77: return 119   // end
        case 78: return 121   // page down
        case 79: return right
        case 80: return left
        case 81: return down
        case 82: return up
        case 83: return 71    // num lock → keypad clear
        case 84: return 75
        case 85: return 67
        case 86: return 78
        case 87: return 69
        case 88: return 76    // keypad enter
        case 89...97: return [83, 84, 85, 86, 87, 88, 89, 91, 92][u - 89]   // keypad 1–9
        case 98: return 82
        case 99: return 65
        case 100: return 10   // ISO section
        case 103: return 81
        case 104...106: return [105, 107, 113][u - 104]   // F13–F15
        case 224: return control
        case 225: return shift
        case 226: return option
        case 227: return command
        case 228: return rightControl
        case 229: return rightShift
        case 230: return rightOption
        case 231: return rightCommand
        default: return nil
        }
    }

    /// Whether a key code is a modifier key (sent as a flags change, not a key event).
    public static func isModifier(_ k: UInt16) -> Bool { [command, shift, capsLock, option, control, rightCommand, rightShift, rightOption, rightControl].contains(k) }
}

/// A trackpad-style pointer for a touch screen: one finger moves the pointer relative to where it was (it does not
/// jump to the finger), with acceleration, so small targets on a big remote display are reachable on a phone.
public struct TrackpadPointer: Equatable {
    /// Position in the picture, 0…1 on both axes.
    public var x: Double, y: Double
    /// Pointer travel per finger travel at slow speed, and the most acceleration adds.
    public var baseGain = 1.0, maxGain = 3.0
    /// Finger speed (points per second) at which the gain reaches half way to its maximum.
    public var halfSpeed = 900.0

    public init(x: Double = 0.5, y: Double = 0.5) { self.x = x; self.y = y }

    /// The gain at a finger speed.
    public func gain(speed: Double) -> Double {
        let s = max(0, speed)
        return baseGain + (maxGain - baseGain) * s / (s + halfSpeed)
    }

    /// Moves by a finger delta (view points) over a picture shown `width`×`height` points large, `dt` seconds after
    /// the previous delta.
    public mutating func move(dx: Double, dy: Double, pictureWidth w: Double, pictureHeight h: Double, dt: Double) {
        guard w > 0, h > 0 else { return }
        let speed = dt > 0 ? (dx * dx + dy * dy).squareRoot() / dt : 0
        let g = gain(speed: speed)
        x = min(1, max(0, x + dx * g / w))
        y = min(1, max(0, y + dy * g / h))
    }
}

/// Two-finger scroll on a touch screen as precise scroll deltas, plus the momentum after the fingers lift (what a
/// Mac trackpad sends as momentum-phase events): the velocity decays exponentially until it is too slow to matter.
public struct ScrollMomentum {
    public var vx = 0.0, vy = 0.0
    /// Velocity left after one second (0.135 ≈ e⁻²: a flick coasts for ~1.5 s, like a Mac trackpad).
    public var decayPerSecond = 0.135
    public var stopSpeed = 12.0
    public init() {}
    public var active: Bool { (vx * vx + vy * vy).squareRoot() >= stopSpeed }
    public mutating func start(vx: Double, vy: Double) { self.vx = vx; self.vy = vy }
    public mutating func stop() { vx = 0; vy = 0 }
    /// The scroll delta for the next `dt` seconds of coasting (zero once it has stopped).
    public mutating func step(dt: Double) -> (dx: Double, dy: Double) {
        guard active, dt > 0 else { stop(); return (0, 0) }
        let k = pow(decayPerSecond, dt)
        // Distance covered while the velocity decays from v to v·k: v·(k − 1)/ln(decay).
        let f = (k - 1) / log(decayPerSecond)
        let d = (vx * f, vy * f)
        vx *= k; vy *= k
        return d
    }
}
