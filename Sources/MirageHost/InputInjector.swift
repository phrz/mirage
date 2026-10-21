import Foundation
import CoreGraphics
import IOKit
import MirageCore

/// Posts CGEvents at the HID tap for input messages with display-normalized coordinates.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var displayBounds: CGRect
    private var buttonsDown: Set<Int> = []
    private var lastPos: CGPoint
    private var draggedSinceDown = false
    /// Precise scrolls: one axis per gesture, whole points (ScrollShaper). Every precise scroll goes through it, finger
    /// travel and momentum alike (a touch client's momentum is more precise scroll messages; nothing carries a phase),
    /// in input-sink mode too.
    private var scrollShaper = ScrollShaper()
    /// The last gesture whose axis was logged, and the raw travel of the current one (for that line).
    private var loggedScrollGesture = -1
    private var scrollRaw = (dx: 0.0, dy: 0.0, gesture: -1)
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
    private var _lastInputNanos: UInt64 = 0
    /// When the last key, button or scroll came in (bare pointer moves excluded).
    var lastInputNanos: UInt64 { locusLock.lock(); defer { locusLock.unlock() }; return _lastInputNanos }

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

    /// Scripted (measurement) input is refused while the screen is locked: a script must never type into the
    /// login window. A person's input still goes through; they may be logging in on purpose. Every lock signal
    /// counts (ScreenLock); the result is cached for 250 ms (this runs per input event).
    static func consoleLocked() -> Bool { lockSignals().locked }
    nonisolated(unsafe) private static var cachedSignals: (nanos: UInt64, signals: ScreenLock.Signals)? = nil
    private static let cacheLock = NSLock()
    /// The streamer feeds the shield-window signal from its window list.
    nonisolated(unsafe) static var shieldWindow = false
    static let testLockPath = ProcessInfo.processInfo.environment["MIRAGE_TEST_SCREEN_LOCK"]
    static func lockSignals() -> ScreenLock.Signals {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let now = Clock.nowNanos()
        if let c = cachedSignals, Clock.elapsed(since: c.nanos, now: now) < 250_000_000, c.signals.shieldWindow == shieldWindow { return c.signals }
        let session = ScreenLock.sessionLocked(CGSessionCopyCurrentDictionary() as? [String: Any])
        var io: Bool? = nil
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        if root != 0 {
            io = ScreenLock.flag(IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
            IOObjectRelease(root)
        }
        // Test only (loopback runs must not lock the person's screen): MIRAGE_TEST_SCREEN_LOCK=/path reads as
        // locked while that file exists.
        let simulated = testLockPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let s = ScreenLock.Signals(sessionScreenIsLocked: simulated ? true : session, ioConsoleLocked: io, shieldWindow: shieldWindow)
        cachedSignals = (now, s)
        return s
    }

    func handle(_ msg: ControlMessage) {
        if msg.isScripted, Self.consoleLocked() {
            if Clock.elapsed(since: lastRefusalLog, now: Clock.nowNanos()) > 2_000_000_000 { lastRefusalLog = Clock.nowNanos(); hostLog("refusing scripted input: console is locked") }
            return
        }
        if let p = msg.inputPoint { locusLock.lock(); _locus = p; locusLock.unlock() }
        switch msg {
        case .mouseButton(let m): if m.down { buttonsDown.insert(m.button) } else { buttonsDown.remove(m.button) }; if m.down { noteMotion() }
        case .mouseMove where !buttonsDown.isEmpty: noteMotion()
        case .scroll: noteMotion()
        default: break
        }
        // Input of any kind but a bare pointer move: the small-region rule (TileTracker `flicker`) stands aside meanwhile.
        if case .mouseMove = msg, buttonsDown.isEmpty {} else { locusLock.lock(); _lastInputNanos = Clock.nowNanos(); locusLock.unlock() }
        if let seq = msg.inputSeq {
            seqLock.lock()
            injected.append((seq, Clock.nowNanos()))
            if injected.count > 512 { injected.removeFirst(injected.count - 512) }
            seqLock.unlock()
        }
        // Shaped before the sink, so an input-sink run records what would be posted (a `postedScroll` line after the
        // scroll it came from; none while the gesture is undecided or for travel off its axis).
        var shaped: (dx: Int, dy: Int)? = nil
        if case .scroll(let s) = msg, s.precise { shaped = shapeScroll(s) }
        if let sink {
            if let d = try? JSONEncoder().encode(msg) { sink.write(d); sink.write(Data("\n".utf8)) }
            if case .scroll(let s) = msg, s.precise, let shaped {
                sink.write(Data("{\"postedScroll\":{\"seq\":\(s.seq ?? 0),\"dx\":\(shaped.dx),\"dy\":\(shaped.dy)}}\n".utf8))
            }
            return
        }
        switch msg {
        case .mouseMove(let m):
            let p = point(m.x, m.y); lastPos = p
            if !buttonsDown.isEmpty { draggedSinceDown = true }
            let type: CGEventType = buttonsDown.isEmpty ? .mouseMoved : mouseType(down: nil, button: buttonsDown.min()!)
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(buttonsDown.min() ?? 0)) else { return }
            e.post(tap: .cghidEventTap)
        case .mouseButton(let m):
            let p = point(m.x, m.y)
            // After a drag, one more drag event at the release point before the release: injected window drags stopped ~26 px
            // short of the pointer (mac-daddy), the release arriving right behind the last moves.
            if !m.down, draggedSinceDown, m.button < 2,
               let d = CGEvent(mouseEventSource: source, mouseType: m.button == 1 ? .rightMouseDragged : .leftMouseDragged, mouseCursorPosition: p, mouseButton: cgButton(m.button)) {
                d.flags = CGEventFlags(rawValue: m.modifiers)
                d.post(tap: .cghidEventTap)
                // A frame's time for the window server to apply it before the release ends the drag (on the input queue,
                // after a drag only): with the release right behind, drops still landed 2-8 px short (mac-daddy).
                usleep(16_000)
            }
            lastPos = p; draggedSinceDown = false
            guard let e = CGEvent(mouseEventSource: source, mouseType: mouseType(down: m.down, button: m.button), mouseCursorPosition: p, mouseButton: cgButton(m.button)) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, m.clickCount)))
            if m.button >= 2 { e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(m.button)) }
            e.flags = CGEventFlags(rawValue: m.modifiers)
            e.post(tap: .cghidEventTap)
        case .scroll(let s):
            let p = point(s.x, s.y); lastPos = p
            let units: CGScrollEventUnit = s.precise ? .pixel : .line
            var dx = Int32(s.dx.rounded()), dy = Int32(s.dy.rounded())
            if s.precise {
                guard let d = shaped else { return }
                dx = Int32(d.dx); dy = Int32(d.dy)
            }
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            if s.precise {
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
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

    /// One precise scroll through the shaper; the axis each gesture took is logged once (the streamer's scroll
    /// diagnostics print the wheel delta as the viewer sent it, before this).
    private func shapeScroll(_ s: ControlMessage.Scroll) -> (dx: Int, dy: Int)? {
        let d = scrollShaper.shape(dx: s.dx, dy: s.dy, nanos: Clock.nowNanos())
        let g = scrollShaper.lock.gesture
        if scrollRaw.gesture != g { scrollRaw = (0, 0, g) }
        scrollRaw.dx += s.dx; scrollRaw.dy += s.dy
        if let a = scrollShaper.axis, loggedScrollGesture != g {
            loggedScrollGesture = g
            hostLog(String(format: "scroll gesture: %@ after %.0f,%.0f pt of travel", "\(a)", scrollRaw.dx, scrollRaw.dy))
        }
        return d
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
