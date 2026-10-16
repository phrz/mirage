import Foundation
import CoreGraphics
import MirageCore

/// Posts CGEvents at the HID tap for input messages with display-normalized coordinates.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var displayBounds: CGRect
    private var buttonsDown: Set<Int> = []
    private var lastPos: CGPoint

    init(displayID: CGDirectDisplayID) {
        displayBounds = CGDisplayBounds(displayID)
        lastPos = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
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

    func handle(_ msg: ControlMessage) {
        switch msg {
        case .mouseMove(let m):
            let p = point(m.x, m.y); lastPos = p
            let type: CGEventType = buttonsDown.isEmpty ? .mouseMoved : mouseType(down: nil, button: buttonsDown.min()!)
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(buttonsDown.min() ?? 0)) else { return }
            e.post(tap: .cghidEventTap)
        case .mouseButton(let m):
            let p = point(m.x, m.y); lastPos = p
            if m.down { buttonsDown.insert(m.button) } else { buttonsDown.remove(m.button) }
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

    /// Releases anything still held when the viewer goes away.
    func releaseAll() {
        for b in buttonsDown {
            CGEvent(mouseEventSource: source, mouseType: mouseType(down: false, button: b), mouseCursorPosition: lastPos, mouseButton: cgButton(b))?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll()
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) { e.type = .flagsChanged; e.flags = []; e.post(tap: .cghidEventTap) }
    }
}
