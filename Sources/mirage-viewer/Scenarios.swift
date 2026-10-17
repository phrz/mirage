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
    init(session: ViewerSession, name: String, seconds: Double) { self.session = session; self.name = name; self.seconds = seconds }

    private func bench() -> ControlMessage.WindowInfo? {
        session.windowsSnapshot().first { $0.title.contains("Mirage Test Bench") }
    }
    private func normalized(_ x: Int, _ y: Int) -> (Double, Double) {
        let c = session.compositor
        return (Double(x) / Double(max(1, c?.width ?? 1)), Double(y) / Double(max(1, c?.height ?? 1)))
    }
    private func click(_ x: Int, _ y: Int) async {
        let (nx, ny) = normalized(x, y)
        session.send(.mouseMove(.init(x: nx, y: ny)))
        session.send(.mouseButton(.init(button: 0, down: true, x: nx, y: ny, clickCount: 1, modifiers: 0)))
        try? await Task.sleep(for: .milliseconds(60))
        session.send(.mouseButton(.init(button: 0, down: false, x: nx, y: ny, clickCount: 1, modifiers: 0)))
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

    func run() async {
        // Wait for the stream and the window list.
        for _ in 0..<100 where bench() == nil || (session.compositor?.width ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        guard let w = bench() else { session.log("scenario: no Mirage Test Bench window on the host"); return }
        session.log("scenario \(name) for \(Int(seconds)) s against window \(w.id) \(w.frame)")
        session.watchRect = w.frame
        let ppp = await MainActor.run { session.pixelsPerPoint }
        let end = Date().addingTimeInterval(seconds)
        let started = Date()
        defer { activeSeconds = Date().timeIntervalSince(started) }
        switch name {
        case "idle":
            session.resetWatched()
            try? await Task.sleep(for: .seconds(seconds))
        case "typing":
            // Click into the text (lower half, so the caret sits at the end) then type at 6 keys/s.
            await click(w.frame.x + w.frame.width / 2, w.frame.maxY - Int(60 * ppp))
            try? await Task.sleep(for: .seconds(1))
            session.resetWatched()
            let text = Array("the quick brown fox jumps over the lazy dog while mirage streams tiles ")
            var i = 0
            while Date() < end {
                let ch = text[i % text.count]; i += 1
                let code: UInt16 = ch == " " ? 49 : 0
                session.send(.key(.init(keyCode: code, down: true, isRepeat: false, modifiers: 0, characters: String(ch))))
                session.send(.key(.init(keyCode: code, down: false, isRepeat: false, modifiers: 0, characters: nil)))
                try? await Task.sleep(for: .milliseconds(160))
            }
        case "scroll":
            let x = w.frame.x + w.frame.width / 2, y = w.frame.y + w.frame.height / 2
            let (nx, ny) = normalized(x, y)
            session.send(.mouseMove(.init(x: nx, y: ny)))
            var dir = -1.0
            while Date() < end {
                let titleBar = Int(28 * ppp)
                for _ in 0..<40 {   // 1.3 s of wheel at 30 Hz, 30 pt per event
                    let dy = 30.0 * dir
                    guard let win = bench() else { break }
                    let seq = session.send(.scroll(.init(x: nx, y: ny, dx: 0, dy: dy, precise: true, modifiers: 0)))
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
                guard let win = bench() else { break }
                let x0 = win.frame.x + win.frame.width / 2, y0 = win.frame.y + Int(12 * ppp)
                var (nx, ny) = normalized(x0, y0)
                session.send(.mouseMove(.init(x: nx, y: ny)))
                try? await Task.sleep(for: .milliseconds(50))
                session.send(.mouseButton(.init(button: 0, down: true, x: nx, y: ny, clickCount: 1, modifiers: 0)))
                var x = x0, y = y0
                session.watchRect = win.frame.union(win.frame.offset(300 * dir, 150 * dir))
                for _ in 0..<50 {   // 0.8 s drag, 6×3 px per 16 ms
                    x += 6 * dir; y += 3 * dir
                    (nx, ny) = normalized(x, y)
                    let seq = session.send(.mouseMove(.init(x: nx, y: ny)))
                    session.predict(kind: .drag, windowID: win.id, rect: win.frame, dx: 6 * dir, dy: 3 * dir, inputSeq: seq)
                    try? await Task.sleep(for: .milliseconds(16))
                }
                session.send(.mouseButton(.init(button: 0, down: false, x: nx, y: ny, clickCount: 1, modifiers: 0)))
                await measureCrisp(burstEnd: Clock.nowNanos())
                try? await Task.sleep(for: .milliseconds(800))
                dir = -dir
            }
        default:
            session.log("unknown scenario \(name)")
        }
    }
}
