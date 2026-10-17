import Foundation
import MirageCore

/// Scripted interactions for `--headless --scenario NAME:SECONDS`, driven against the
/// "Mirage Test Bench" window on the host (experiments/testbench). They send the same input
/// messages the GUI would, run the same local predictions, and measure time-to-crisp: from the
/// end of a motion burst to the last refinement tile before the tile stream goes quiet.
final class ScenarioRunner {
    let session: ViewerSession
    let name: String
    let seconds: Double
    private(set) var crispMs: [Double] = []
    private(set) var bursts = 0
    /// Seconds the scenario was actively driving input (for watched-rect kbps).
    private(set) var activeSeconds = 0.0
    /// login scenario: ms from each keystroke to the first changed pixels inside the field (9999 = none within 2 s).
    private(set) var keyLatencyMs: [Double] = []
    init(session: ViewerSession, name: String, seconds: Double) { self.session = session; self.name = name; self.seconds = seconds }

    private var lastBench: ControlMessage.WindowInfo?
    /// The bench window, or the last one seen (a window-list update can momentarily drop it).
    private func bench() -> ControlMessage.WindowInfo? {
        if let w = session.windowsSnapshot().first(where: { $0.title.contains("Mirage Test Bench") }) { lastBench = w }
        return lastBench
    }
    /// The bench's visible part (it may have drifted partly off-screen); points are picked inside it,
    /// in its upper half, away from the Dock at the bottom of the display.
    private func visible(_ w: ControlMessage.WindowInfo) -> PixelRect {
        let c = session.compositor
        return w.frame.intersection(PixelRect(x: 0, y: 0, width: c?.width ?? w.frame.maxX, height: c?.height ?? w.frame.maxY))
    }
    private func safePoint(_ w: ControlMessage.WindowInfo, ppp: Double) -> (Int, Int) {
        let v = visible(w)
        return (v.x + v.width / 2, min(v.y + Int(120 * ppp), v.maxY - Int(40 * ppp)))
    }
    private func normalized(_ x: Int, _ y: Int) -> (Double, Double) {
        let c = session.compositor
        return (Double(x) / Double(max(1, c?.width ?? 1)), Double(y) / Double(max(1, c?.height ?? 1)))
    }
    private func click(_ x: Int, _ y: Int) async {
        let (nx, ny) = normalized(x, y)
        session.send(.mouseMove(.init(x: nx, y: ny)), scripted: true)
        session.send(.mouseButton(.init(button: 0, down: true, x: nx, y: ny, clickCount: 1, modifiers: 0)), scripted: true)
        try? await Task.sleep(for: .milliseconds(60))
        session.send(.mouseButton(.init(button: 0, down: false, x: nx, y: ny, clickCount: 1, modifiers: 0)), scripted: true)
    }

    /// Samples the canvas where the bench's purple caption band should be (just below its title bar).
    private func captionVisible(_ w: ControlMessage.WindowInfo, ppp: Double) async -> Bool {
        guard let c = session.compositor else { return false }
        let band = PixelRect(x: w.frame.x + Int(40 * ppp), y: w.frame.y + Int((28 + 20) * ppp), width: min(w.frame.width - Int(80 * ppp), 400), height: 2)
        return await withCheckedContinuation { cont in
            c.sampleEdgeColor(of: band, bottom: false) { col in
                // Band colour is (0.42, 0.20, 0.75) sRGB; accept a loose match.
                let ok = abs(col.x - 0.42) < 0.15 && abs(col.y - 0.20) < 0.15 && abs(col.z - 0.75) < 0.18
                self.session.log(String(format: "scenario: caption band sample r %.2f g %.2f b %.2f → %@", col.x, col.y, col.z, ok ? "bench visible" : "NOT the bench"))
                cont.resume(returning: ok)
            }
        }
    }

    /// Waits until the test window's rect stops receiving updates after a burst: time-to-crisp is the
    /// last lossless tile that touched it, provided no video frame touched it later (then it is not crisp yet).
    private func measureCrisp(burstEnd: UInt64) async {
        let deadline = burstEnd + 5_000_000_000
        var last: UInt64 = 0
        while Clock.nowNanos() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let t = session.lastWatchedTileNanos, v = session.lastWatchedVideoNanos
            last = max(t, v)
            if t >= v, Clock.nowNanos() - last > 700_000_000 { break }
        }
        let crisp = session.lastWatchedTileNanos >= session.lastWatchedVideoNanos
        let ms = last > burstEnd ? Double(last - burstEnd) / 1e6 : 0
        crispMs.append(crisp ? ms : 9999); bursts += 1
        session.log(String(format: "scenario %@: burst %d time-to-crisp %.0f ms%@", name, bursts, ms, crisp ? "" : " (NOT crisp: video still arriving)"))
    }

    /// Review M9: the safety checks are re-evaluated before every burst or batch of keystrokes, not once.
    /// Any change of the frontmost window on the host aborts the scenario.
    private var guardedWindowID: UInt32 = 0
    private func guardsStillHold() -> Bool {
        guard let status = session.hostStatus else { session.log("scenario \(name): ABORT, host status lost"); return false }
        guard !status.consoleLocked else { session.log("scenario \(name): ABORT, host console LOCKED"); return false }
        guard status.frontmostWindowID == guardedWindowID || status.frontmostApp == "Mirage Test Bench" else {
            session.log("scenario \(name): ABORT, focus moved to \(status.frontmostApp) \(status.frontmostWindowID) '\(status.frontmostWindowTitle)'"); return false
        }
        return true
    }

    func run() async {
        if name == "keys" {
            // Input-integrity run: N scripted keystrokes at 20 keys/s. Only against a host that records
            // input instead of injecting it (HostStatus.inputSink), whatever is frontmost there.
            for _ in 0..<100 where session.hostStatus == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard session.hostStatus?.inputSink == true else { session.log("scenario keys: ABORT, the host is not in input-sink mode (MIRAGE_INPUT_SINK); refusing to type into a real session"); return }
            let n = Int(seconds)
            let text = Array("the quick brown fox jumps over the lazy dog 0123456789 ")
            let started = Date()
            for i in 0..<n {
                guard session.hostStatus?.inputSink == true else { session.log("scenario keys: ABORT, host left input-sink mode"); break }
                let ch = text[i % text.count]
                session.send(.key(.init(keyCode: UInt16(i % 50), down: true, isRepeat: false, modifiers: 0, characters: String(ch))), scripted: true)
                session.send(.key(.init(keyCode: UInt16(i % 50), down: false, isRepeat: false, modifiers: 0, characters: nil)), scripted: true)
                if i % 3 == 0 { session.send(.mouseMove(.init(x: Double(i % 100) / 100, y: 0.5)), scripted: true) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            activeSeconds = Date().timeIntervalSince(started)
            // Let the channel drain (a burst may be in progress), then report.
            for _ in 0..<600 where session.inputState().queued > 0 { try? await Task.sleep(for: .milliseconds(50)) }
            let st = session.inputState()
            session.log("scenario keys: \(n) keystrokes sent in \(Int(activeSeconds)) s, \(st.packets) packets, queue \(st.queued), dropped by cap \(st.dropped)")
            return
        }
        // Wait for the stream and the window list.
        for _ in 0..<250 where bench() == nil || (session.compositor?.width ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        guard let w = bench() else { session.log("scenario: no Mirage Test Bench window on the host"); return }
        session.log("scenario \(name) for \(Int(seconds)) s against window \(w.id) \(w.frame)")
        session.watchRect = w.frame
        let ppp = await MainActor.run { session.pixelsPerPoint }
        if name == "fovea" {
            // Pointer over the bench text from the start; the session logs when text under it became lossless.
            let (px, py) = (w.frame.x + w.frame.width / 2, w.frame.y + w.frame.height / 2)
            let (nx, ny) = normalized(px, py)
            session.notePointer(x: nx, y: ny)
            session.send(.mouseMove(.init(x: nx, y: ny)), scripted: true)
            try? await Task.sleep(for: .seconds(seconds))
            activeSeconds = seconds
            return
        }
        // Let the opening keyframe's full-screen lossless refinement finish first (up to 60 s): the
        // measurements are about the interaction, not the first picture.
        var quiet = 0
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            if let last = session.samples.last, last.tileKbps + last.kbps < 60 { quiet += 1 } else { quiet = 0 }
            if quiet >= 2 { break }
        }
        session.log("scenario \(name): stream quiet after refinement, starting")
        // Before injecting anything the script must know what it is looking at: the console unlocked,
        // the bench frontmost, and the picture actually showing the bench (its purple caption band).
        guard let w = bench() else { session.log("scenario \(name): ABORT, bench window gone"); return }
        guard let status = session.hostStatus else { session.log("scenario \(name): ABORT, no host status"); return }
        guard !status.consoleLocked else { session.log("scenario \(name): ABORT, host console is LOCKED"); return }
        guard status.frontmostWindowID == w.id || status.frontmostApp == "Mirage Test Bench" else {
            session.log("scenario \(name): ABORT, bench is not frontmost (front: \(status.frontmostApp) \(status.frontmostWindowID) '\(status.frontmostWindowTitle)')"); return
        }
        let bandOK = await captionVisible(w, ppp: ppp)
        guard bandOK else { session.log("scenario \(name): ABORT, the picture does not show the bench's caption band"); return }
        session.log("scenario \(name): checks passed (console unlocked, bench frontmost, caption visible)")
        guardedWindowID = w.id
        let end = Date().addingTimeInterval(seconds)
        let started = Date()
        defer { activeSeconds = Date().timeIntervalSince(started) }
        // Raise the bench (a click inside its text) so the scenario drives it and not whatever covers it.
        let (cx, cy) = safePoint(w, ppp: ppp)
        await click(cx, cy)
        try? await Task.sleep(for: .milliseconds(800))
        switch name {
        case "idle":
            session.resetWatched()
            try? await Task.sleep(for: .seconds(seconds))
        case "login":
            // Password-style field at the top of the bench (below the caption): click it, type a character every
            // 500 ms, and time each keystroke to the first changed pixels arriving inside the field.
            let field = PixelRect(x: w.frame.x + Int(20 * ppp), y: w.frame.y + Int((28 + 44 + 6) * ppp), width: Int(360 * ppp), height: Int(28 * ppp))
            await click(field.x + field.width / 2, field.y + field.height / 2)
            try? await Task.sleep(for: .milliseconds(800))
            session.watchRect = field
            session.resetWatched()
            var latencies: [Double] = []
            let chars = Array("correct horse battery staple")
            var i = 0
            while Date() < end, i < chars.count {
                guard guardsStillHold() else { break }
                let ch = chars[i]; i += 1
                let before = session.lastWatchedTileNanos
                let t0 = Clock.nowNanos()
                session.send(.key(.init(keyCode: ch == " " ? 49 : 0, down: true, isRepeat: false, modifiers: 0, characters: String(ch))), scripted: true)
                session.send(.key(.init(keyCode: ch == " " ? 49 : 0, down: false, isRepeat: false, modifiers: 0, characters: nil)), scripted: true)
                var got: Double? = nil
                for _ in 0..<200 {   // up to 2 s
                    try? await Task.sleep(for: .milliseconds(10))
                    if session.lastWatchedTileNanos > before { got = Double(session.lastWatchedTileNanos - t0) / 1e6; break }
                }
                latencies.append(got ?? 9999)
                session.log(String(format: "scenario login: key %d → first changed pixels in the field after %@", i, got.map { String(format: "%.0f ms", $0) } ?? "no update within 2 s"))
                try? await Task.sleep(for: .milliseconds(500))
            }
            keyLatencyMs = latencies
            // No ⌘A + ⌫ cleanup (review M9): the typed text stays in the bench's own field, which closes with it.
        case "typing":
            // Caret sits where the raise-click put it (lower half of the text); type at 6 keys/s.
            session.resetWatched()
            let text = Array("the quick brown fox jumps over the lazy dog while mirage streams tiles ")
            var i = 0
            while Date() < end {
                if i % 6 == 0, !guardsStillHold() { break }
                let ch = text[i % text.count]; i += 1
                let code: UInt16 = ch == " " ? 49 : 0
                session.send(.key(.init(keyCode: code, down: true, isRepeat: false, modifiers: 0, characters: String(ch))), scripted: true)
                session.send(.key(.init(keyCode: code, down: false, isRepeat: false, modifiers: 0, characters: nil)), scripted: true)
                try? await Task.sleep(for: .milliseconds(160))
            }
        case "scroll":
            let (x, y) = safePoint(w, ppp: ppp)
            let (nx, ny) = normalized(x, y)
            session.send(.mouseMove(.init(x: nx, y: ny)), scripted: true)
            var dir = -1.0
            while Date() < end {
                guard guardsStillHold() else { break }
                let titleBar = Int(28 * ppp)
                for _ in 0..<40 {   // 1.3 s of wheel at 30 Hz, 30 pt per event
                    let dy = 30.0 * dir
                    guard let win = bench() else { break }
                    let seq = session.send(.scroll(.init(x: nx, y: ny, dx: 0, dy: dy, precise: true, modifiers: 0)), scripted: true)
                    let rect = session.scrollRect(for: win, titleBarPx: titleBar)
                    session.predict(kind: .scroll, windowID: win.id, rect: rect, dx: 0, dy: Int((dy * ppp).rounded()), inputSeq: seq)
                    try? await Task.sleep(for: .milliseconds(33))
                }
                await measureCrisp(burstEnd: Clock.nowNanos())
                try? await Task.sleep(for: .milliseconds(800))
                dir = -dir
            }
        case "drag":
            var dir = 1
            while Date() < end {
                guard guardsStillHold(), let win = bench() else { break }
                let x0 = win.frame.x + win.frame.width / 2, y0 = win.frame.y + Int(12 * ppp)
                var (nx, ny) = normalized(x0, y0)
                session.send(.mouseMove(.init(x: nx, y: ny)), scripted: true)
                try? await Task.sleep(for: .milliseconds(50))
                session.send(.mouseButton(.init(button: 0, down: true, x: nx, y: ny, clickCount: 1, modifiers: 0)), scripted: true)
                var x = x0, y = y0
                session.watchRect = win.frame.union(win.frame.offset(300 * dir, 150 * dir))
                for _ in 0..<50 {   // 0.8 s drag, 6×3 px per 16 ms
                    x += 6 * dir; y += 3 * dir
                    (nx, ny) = normalized(x, y)
                    let seq = session.send(.mouseMove(.init(x: nx, y: ny)), scripted: true)
                    session.predict(kind: .drag, windowID: win.id, rect: win.frame, dx: 6 * dir, dy: 3 * dir, inputSeq: seq)
                    try? await Task.sleep(for: .milliseconds(16))
                }
                session.send(.mouseButton(.init(button: 0, down: false, x: nx, y: ny, clickCount: 1, modifiers: 0)), scripted: true)
                await measureCrisp(burstEnd: Clock.nowNanos())
                try? await Task.sleep(for: .milliseconds(800))
                dir = -dir
            }
        default:
            session.log("unknown scenario \(name)")
        }
    }
}
