import Foundation
import CoreGraphics
import MirageCore

/// Posts CGEvents at the HID tap for input messages with display-normalized coordinates.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var displayBounds: CGRect
    private var buttonsDown: Set<Int> = []
    private var lastPos: CGPoint
    /// (input seq, injection clock) of recent inputs, so captures can be stamped with the last input they reflect.
    private var injected: [(seq: UInt64, nanos: UInt64)] = []
    private let seqLock = NSLock()
    private var lastRefusalLog: UInt64 = 0
    /// Last input position (normalized), the scheduler's "input locus".
    private var _locus: (x: Double, y: Double)? = nil
    private let locusLock = NSLock()
    var locus: (x: Double, y: Double)? { locusLock.lock(); defer { locusLock.unlock() }; return _locus }
    /// Host clock of the last input that implies motion on screen (a drag move, a scroll, a press):
    /// the streamer freezes refinement while this is recent, before the pixels even show it.
    private var _motionHintNanos: UInt64 = 0
    var motionHintNanos: UInt64 { locusLock.lock(); defer { locusLock.unlock() }; return _motionHintNanos }

    /// `MIRAGE_INPUT_SINK=/path`: every input the host would inject is appended to that file as one JSON
    /// line and *nothing* is posted to the HID tap. The loopback integrity tests compare that file with
    /// what the viewer sent, without a single event reaching the machine's real input.
    static let sinkPath = ProcessInfo.processInfo.environment["MIRAGE_INPUT_SINK"]
    private let sink: FileHandle?

    init(displayID: CGDirectDisplayID) {
        displayBounds = CGDisplayBounds(displayID)
        lastPos = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        if let path = Self.sinkPath {
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            sink = FileHandle(forWritingAtPath: path); sink?.seekToEndOfFile()
            hostLog("input sink: \(path) (no input is injected)")
        } else { sink = nil }
    }

    func setDisplay(_ id: CGDirectDisplayID) { displayBounds = CGDisplayBounds(id) }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: displayBounds.origin.x + min(max(x, 0), 1) * displayBounds.width,
                y: displayBounds.origin.y + min(max(y, 0), 1) * displayBounds.height)
    }

    private func mouseType(down: Bool?, button: Int) -> CGEventType {
        switch (button, down) {
        case (0, true?): return .leftMouseDown
        case (0, false?): return .leftMouseUp
        case (1, true?): return .rightMouseDown
        case (1, false?): return .rightMouseUp
        case (_, true?): return .otherMouseDown
        case (_, false?): return .otherMouseUp
        case (0, nil): return .leftMouseDragged
        case (1, nil): return .rightMouseDragged
        case (_, nil): return .otherMouseDragged
        }
    }
    private func cgButton(_ b: Int) -> CGMouseButton { b == 0 ? .left : b == 1 ? .right : .center }

    /// A window command (not injected as an event) counts as applied input at `seq`, so the window list
    /// can say it reflects it.
    func noteApplied(seq: UInt64) {
        seqLock.lock()
        if (injected.last?.seq ?? 0) < seq { injected.append((seq, Clock.nowNanos())); if injected.count > 512 { injected.removeFirst(injected.count - 512) } }
        seqLock.unlock()
    }

    /// Highest input sequence injected at or before `nanos` (host clock).
    func inputSeq(before nanos: UInt64) -> UInt64 {
        seqLock.lock(); defer { seqLock.unlock() }
        return injected.last(where: { $0.nanos <= nanos })?.seq ?? 0
    }

    /// Scripted (measurement) input is refused while the console is locked: a script must never type
    /// into the login window. A person's input still goes through; they may be logging in on purpose.
    static func consoleLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let v = dict["CGSSessionScreenIsLocked"] as? Bool { return v }
        if let v = dict["CGSSessionScreenIsLocked"] as? Int { return v != 0 }
        return false
    }

    func handle(_ msg: ControlMessage) {
        if msg.isScripted, Self.consoleLocked() {
            if Clock.nowNanos() - lastRefusalLog > 2_000_000_000 { lastRefusalLog = Clock.nowNanos(); hostLog("refusing scripted input: console is locked") }
            return
        }
        if let p = msg.inputPoint { locusLock.lock(); _locus = p; locusLock.unlock() }
        switch msg {
        case .mouseButton(let m): if m.down { buttonsDown.insert(m.button) } else { buttonsDown.remove(m.button) }; if m.down { noteMotion() }
        case .mouseMove where !buttonsDown.isEmpty: noteMotion()
        case .scroll: noteMotion()
        default: break
        }
        if let seq = msg.inputSeq {
            seqLock.lock()
            injected.append((seq, Clock.nowNanos()))
            if injected.count > 512 { injected.removeFirst(injected.count - 512) }
            seqLock.unlock()
        }
        if let sink {
            if let d = try? JSONEncoder().encode(msg) { sink.write(d); sink.write(Data("\n".utf8)) }
            return
        }
        switch msg {
        case .mouseMove(let m):
            let p = point(m.x, m.y); lastPos = p
            let type: CGEventType = buttonsDown.isEmpty ? .mouseMoved : mouseType(down: nil, button: buttonsDown.min()!)
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(buttonsDown.min() ?? 0)) else { return }
            e.post(tap: .cghidEventTap)
        case .mouseButton(let m):
            let p = point(m.x, m.y); lastPos = p
            guard let e = CGEvent(mouseEventSource: source, mouseType: mouseType(down: m.down, button: m.button), mouseCursorPosition: p, mouseButton: cgButton(m.button)) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, m.clickCount)))
            if m.button >= 2 { e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(m.button)) }
            e.flags = CGEventFlags(rawValue: m.modifiers)
            e.post(tap: .cghidEventTap)
        case .scroll(let s):
            let p = point(s.x, s.y); lastPos = p
            let units: CGScrollEventUnit = s.precise ? .pixel : .line
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2, wheel1: Int32(s.dy.rounded()), wheel2: Int32(s.dx.rounded()), wheel3: 0) else { return }
            if s.precise {
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: s.dy)
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: s.dx)
            }
            e.location = p
            e.flags = CGEventFlags(rawValue: s.modifiers)
            e.post(tap: .cghidEventTap)
        case .key(let k):
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(k.keyCode), keyDown: k.down) else { return }
            e.flags = CGEventFlags(rawValue: k.modifiers)
            if k.isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            if k.down, let chars = k.characters, !chars.isEmpty {
                let utf16 = Array(chars.utf16)
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            }
            e.post(tap: .cghidEventTap)
        case .modifiers(let m):
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(m.keyCode), keyDown: true) else { return }
            e.type = .flagsChanged
            e.flags = CGEventFlags(rawValue: m.modifiers)
            e.post(tap: .cghidEventTap)
        default: break
        }
    }

    /// Writes a message to the input sink (input-sink mode), for commands that are not injected.
    func record(_ msg: ControlMessage) {
        guard let sink, let d = try? JSONEncoder().encode(msg) else { return }
        sink.write(d); sink.write(Data("\n".utf8))
    }

    private func noteMotion() { locusLock.lock(); _motionHintNanos = Clock.nowNanos(); locusLock.unlock() }

    /// Releases anything still held when the viewer goes away.
    func releaseAll() {
        guard sink == nil else { return }
        for b in buttonsDown {
            CGEvent(mouseEventSource: source, mouseType: mouseType(down: false, button: b), mouseCursorPosition: lastPos, mouseButton: cgButton(b))?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll()
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) { e.type = .flagsChanged; e.flags = []; e.post(tap: .cghidEventTap) }
    }
}
