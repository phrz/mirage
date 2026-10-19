import Foundation

/// Typeahead (DESIGN §3.5 item 4, mosh's local echo for a GUI): a printable keystroke is drawn at once at the predicted
/// caret, underlined while unconfirmed. The host's caret (Accessibility, `CaretInfo`) confirms it when it has moved by
/// the glyph's advance; the glyph stays (without the underline) until the host's pixels covering it arrive. A mismatch
/// (the caret went elsewhere: autocomplete, a different font, a wrap, a field that ate the key) erases every prediction
/// and turns predictions off for that field until three keystrokes in a row are confirmed silently. Anything that moves
/// the caret unpredictably (Return, arrows, ⌘-shortcuts, clicks, a selection) erases predictions and waits for the host.
public struct Typeahead {
    public struct Glyph: Equatable {
        public var seq: UInt64
        public var text: String
        /// Display-layer pixels: the glyph's box (x from the caret, the line's y and height).
        public var rect: PixelRect
        public var confirmed: Bool
        public var bornNanos: UInt64
    }
    public private(set) var glyphs: [Glyph] = []
    public private(set) var caret: ControlMessage.CaretInfo?
    private var caretNanos: UInt64 = 0
    /// Input after which the host's caret must be seen again before predicting (a key that moves it unpredictably).
    private var resyncAfter: UInt64 = 0
    /// Per field: shown, or tracked silently until it earns trust again.
    private var trusted = true
    private var silentStreak = 0
    private var fieldKey: PixelRect?
    /// Silent predictions while untrusted: (seq, expected caret x after it).
    private var silent: [(seq: UInt64, x: Int)] = []
    public private(set) var shown = 0, confirmed = 0, mismatched = 0, expired = 0
    public var timeoutNanos: UInt64 = 2_000_000_000

    public init() {}

    /// A caret report from the host.
    public mutating func host(_ c: ControlMessage.CaretInfo, now: UInt64) {
        if c.field != fieldKey { fieldKey = c.field; trusted = true; silentStreak = 0; silent = []; glyphs.removeAll { !$0.confirmed } }
        caret = c; caretNanos = now
        guard let cr = c.caret else { glyphs = []; silent = []; return }
        // Silent predictions: count the ones this report settles.
        while let s = silent.first, s.seq <= c.inputSeq {
            silent.removeFirst()
            if abs(s.x - cr.x) <= 3 { silentStreak += 1; if silentStreak >= 3 { trusted = true } } else { silentStreak = 0 }
        }
        // Shown predictions this report covers: the caret must be at the end of the last of them.
        let covered = glyphs.filter { !$0.confirmed && $0.seq <= c.inputSeq }
        guard let last = covered.last else { return }
        let tol = max(3, last.rect.width / 3)
        if abs(last.rect.maxX - cr.x) <= tol && abs(last.rect.y - cr.y) <= max(2, cr.height / 3) {
            for i in glyphs.indices where !glyphs[i].confirmed && glyphs[i].seq <= c.inputSeq { glyphs[i].confirmed = true; confirmed += 1 }
        } else {
            mismatched += covered.count
            glyphs = []; trusted = false; silentStreak = 0; silent = []
        }
    }

    /// A printable keystroke the viewer sends; `advancePx` is the glyph's width in display pixels (measured by the
    /// viewer in the host's font). Returns the glyph to draw, or nil.
    @discardableResult
    public mutating func typed(_ text: String, advancePx: Int, seq: UInt64, now: UInt64) -> Glyph? {
        guard let c = caret, var cr = c.caret, !c.selection, c.inputSeq >= resyncAfter, advancePx > 0,
              Clock.elapsed(since: caretNanos, now: now) < 30_000_000_000 else { return nil }
        if let tail = glyphs.last(where: { !$0.confirmed }) ?? glyphs.last { cr.x = tail.rect.maxX; cr.y = tail.rect.y; cr.height = tail.rect.height }
        else if let s = silent.last { cr.x = s.x }
        let g = Glyph(seq: seq, text: c.secure ? "•" : text, rect: PixelRect(x: cr.x, y: cr.y, width: advancePx, height: max(1, cr.height)), confirmed: false, bornNanos: now)
        // Off the field's right edge: the app wraps or scrolls; not predictable.
        if let f = c.field, g.rect.maxX > f.maxX { invalidate(after: seq); return nil }
        guard trusted else { silent.append((seq, g.rect.maxX)); return nil }
        glyphs.append(g); shown += 1
        return g
    }

    /// Backspace: the newest unconfirmed glyph goes; with none, the host is waited for.
    public mutating func backspace(seq: UInt64) {
        if let i = glyphs.lastIndex(where: { !$0.confirmed }) { glyphs.remove(at: i); return }
        invalidate(after: seq)
    }

    /// A key or click that moves the caret unpredictably: predictions go, and none until the host reports after `seq`.
    public mutating func invalidate(after seq: UInt64) {
        glyphs.removeAll { !$0.confirmed }
        silent = []
        resyncAfter = max(resyncAfter, seq)
    }

    /// Host pixels reflecting input up to `inputSeq` arrived over `rect`: glyphs they cover are drawn by the host now.
    public mutating func pixels(inputSeq: UInt64, rect: PixelRect) {
        glyphs.removeAll { $0.seq <= inputSeq && $0.confirmed && $0.rect.intersects(rect) }
    }

    /// Drops what the host never confirmed or drew in time.
    public mutating func expire(now: UInt64) {
        let before = glyphs.count
        glyphs.removeAll { Clock.elapsed(since: $0.bornNanos, now: now) > timeoutNanos }
        expired += before - glyphs.count
    }
    public var isTrusted: Bool { trusted }
}
