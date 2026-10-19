import Foundation
import AppKit
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
        if let w = session.windowsSnapshot().first(where: { $0.title.contains("Mirage Test Bench") && ($0.app ?? "Mirage Test Bench") == "Mirage Test Bench" && !$0.title.contains("overlay") && !$0.title.contains("icons") && !["docklike", "tooltip", "vibrancy"].contains(where: $0.title.contains) }) { lastBench = w }
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
        guard let (c, origin) = session.canvas(for: w.id) else { return false }
        let band = PixelRect(x: origin.0 + Int(40 * ppp), y: origin.1 + Int((28 + 20) * ppp), width: min(w.frame.width - Int(80 * ppp), 400), height: 2)
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
            let t = session.lastWatchedLargeTileNanos, v = session.lastWatchedVideoNanos
            last = max(t, v)
            if t >= v, Clock.elapsed(since: last, now: Clock.nowNanos()) > 700_000_000 { break }
        }
        let crisp = session.lastWatchedLargeTileNanos >= session.lastWatchedVideoNanos
        let ms = last > burstEnd ? Double(last - burstEnd) / 1e6 : 0
        crispMs.append(crisp ? ms : 9999); bursts += 1
        session.log(String(format: "scenario %@: burst %d time-to-crisp %.0f ms%@", name, bursts, ms, crisp ? "" : " (NOT crisp: video still arriving)"))
    }

    /// Review M9: the safety checks are re-evaluated before every burst or batch of keystrokes, not once.
    /// Any change of the frontmost window on the host aborts the scenario.
    private var guardedWindowID: UInt32 = 0
    private func guardsStillHold() -> Bool {
        guard let status = session.hostStatus else { session.log("scenario \(name): ABORT, host status lost"); return false }
        if (status.viewers ?? 1) > 1 { session.log("scenario \(name): ABORT, another viewer is connected to the host (\(status.viewers!) streaming)"); return false }
        guard !status.consoleLocked else { session.log("scenario \(name): ABORT, host console LOCKED"); return false }
        if ["drag", "unified", "chrome", "transient"].contains(name), status.inputSink == true { return true }
        guard status.frontmostWindowID == guardedWindowID || status.frontmostApp == "Mirage Test Bench" else {
            session.log("scenario \(name): ABORT, focus moved to \(status.frontmostApp) \(status.frontmostWindowID) '\(status.frontmostWindowTitle)'"); return false
        }
        return true
    }

    /// Per-burst video frames inside the watched window during motion, and frames per second of motion.
    private(set) var motionFrames: [Int] = []
    private(set) var motionFps: [Double] = []
    private(set) var motionCopyRects: [Int] = []
    /// Layered desktop (M3): per burst, how many window-list frame updates moved the bench (and per second
    /// of motion), the bytes received during the burst and in the 3 s after it, and (client drags) how long
    /// after the release the host's list showed the final frame.
    private(set) var motionMoves: [Int] = []
    private(set) var moveFps: [Double] = []
    private(set) var burstKB: [Double] = []
    private(set) var settleKB: [Double] = []
    private(set) var confirmMs: [Double] = []
    private(set) var layered = false
    /// Layered desktop: after each burst, samples of the *display* layer where the bench's caption band was
    /// before the burst (only where the bench no longer is). Purple there = window pixels in the desktop layer.
    private(set) var staleSamples = 0, stalePurple = 0, fillSamples = 0
    private(set) var staleAt: [String] = []
    private func displayShowsBench(at band: PixelRect, label: String) async -> Bool? {
        guard let c = session.compositor else { return nil }
        return await withCheckedContinuation { cont in
            c.sampleEdgeColor(of: band, bottom: false) { col in
                let purple = abs(col.x - 0.42) < 0.15 && abs(col.y - 0.20) < 0.15 && abs(col.z - 0.75) < 0.18
                cont.resume(returning: purple)
            }
        }
    }
    /// The bench's caption band (display coordinates) for a frame.
    private func captionBand(_ f: PixelRect, ppp: Double) -> PixelRect {
        PixelRect(x: f.x + Int(40 * ppp), y: f.y + Int((28 + 20) * ppp), width: min(f.width - Int(80 * ppp), Int(200 * ppp)), height: 2)
    }
    private func latestMotionNanos() -> UInt64 { max(session.lastWatchedVideoNanos, session.lastWatchedCopyNanos, session.lastWatchedMoveNanos) }

    /// `watch`: inject nothing; the bench moves itself (`--drift`). Each burst of motion the host shows in
    /// the bench's rect (video or copy-rects) is timed: frames during it, and time-to-crisp after it.
    private func watch(seconds: Double) async {
        for _ in 0..<250 where bench() == nil || (session.compositor?.width ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        guard var w = bench() else { session.log("scenario watch: no Mirage Test Bench window on the host"); return }
        session.log("scenario watch for \(Int(seconds)) s on window \(w.id) \(w.frame) (\(w.isLayered ? "a layer" : "in the display layer")); nothing is injected")
        session.watchWindowID = w.id
        let end = Date().addingTimeInterval(seconds)
        let started = Date()
        defer { activeSeconds = Date().timeIntervalSince(started) }
        while Date() < end {
            w = bench() ?? w
            layered = layered || w.isLayered
            session.watchRect = PixelRect(x: max(0, w.frame.x - 400), y: max(0, w.frame.y - 200), width: w.frame.width + 800, height: w.frame.height + 400)
            // Wait for motion: video, a copy-rect, or a window-list move of the bench after ≥ 700 ms of quiet.
            session.resetWatched()
            var quietSince = latestMotionNanos()
            while Date() < end {
                try? await Task.sleep(for: .milliseconds(20))
                let latest = latestMotionNanos()
                if latest > quietSince, Clock.elapsed(since: quietSince, now: Clock.nowNanos()) > 700_000_000 { break }
                if latest > quietSince { quietSince = latest }
            }
            guard Date() < end else { break }
            let burstStart = Clock.nowNanos()
            let frameBefore = w.frame
            let bytes0 = session.totalBytes()
            let moves0 = session.watchedMoves
            // The burst lasts while video/copy-rects/moves keep touching the window (300 ms quiet ends it).
            var last = burstStart
            while Date() < end {
                try? await Task.sleep(for: .milliseconds(20))
                let latest = latestMotionNanos()
                if latest > last { last = latest }
                if Clock.elapsed(since: last, now: Clock.nowNanos()) > 300_000_000 { break }
            }
            let dur = Double(last - burstStart) / 1e9
            let frames = session.watchedVideoFrames, copies = session.watchedCopyRects, moves = session.watchedMoves - moves0
            if let now = bench(), now.isLayered, now.frame != frameBefore {
                // The old caption band, wherever the bench is not now: the display layer must show the desktop there.
                let ppp = await MainActor.run { session.pixelsPerPoint }
                let band = captionBand(frameBefore, ppp: ppp)
                // Only where the scene shows the display layer: no window layer over the band.
                // (Only opaque layers hide the desktop: the host marks transparent ones, like the bench's --icons window.)
                let coveredByLayer = session.arrangedWindows().contains { $0.hidesBehind && $0.frame.intersects(band) && $0.id != now.id }
                let free = coveredByLayer ? PixelRect.zero : band
                if !free.isEmpty {
                    Task { [weak self] in
                        guard let self else { return }
                        var waited = 0
                        for wait in [100, 1000, 3000] {
                            try? await Task.sleep(for: .milliseconds(wait - waited)); waited = wait
                            if self.session.desktopUnknown(free) {
                                self.staleSamples += 1; self.fillSamples += 1
                                self.session.log("scenario watch: old caption band \(free.x),\(free.y) \(wait) ms after the burst: drawn as desktop fill (no clean pixels yet)")
                            } else if let purple = await self.displayShowsBench(at: free, label: "") {
                                self.staleSamples += 1
                                if purple { self.stalePurple += 1; self.staleAt.append("\(free.x),\(free.y)+\(wait)ms") }
                                self.session.log("scenario watch: old caption band \(free.x),\(free.y) \(wait) ms after the burst: display layer shows \(purple ? "BENCH PIXELS (stale)" : "the desktop")")
                            }
                        }
                    }
                }
            }
            if frames + copies + moves < 3 || dur < 0.3 { continue }   // a stray refinement frame, not motion
            let during = Double(session.totalBytes() - bytes0) / 1000
            motionFrames.append(frames); motionCopyRects.append(copies); motionFps.append(dur > 0.2 ? Double(frames) / dur : 0)
            motionMoves.append(moves); moveFps.append(dur > 0.2 ? Double(moves) / dur : 0); burstKB.append(during)
            session.log(String(format: "scenario watch: burst %d: %.2f s of motion, %d video frames (%.1f fps), %d copy-rects, %d frame moves (%.1f/s), %.1f KB during", bursts + 1, dur, frames, dur > 0.2 ? Double(frames) / dur : 0, copies, moves, dur > 0.2 ? Double(moves) / dur : 0, during))
            let bytes1 = session.totalBytes()
            await measureCrisp(burstEnd: last)
            try? await Task.sleep(for: .milliseconds(max(0, 3000 - Int(Double(Clock.elapsed(since: last, now: Clock.nowNanos())) / 1e6))))
            settleKB.append(Double(session.totalBytes() - bytes1) / 1000)
            session.log(String(format: "scenario watch: burst %d: %.1f KB in the 3 s after it", bursts, settleKB.last!))
        }
    }

    func run() async {
        if name == "watch" { await watch(seconds: seconds); return }
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
        if name == "realapps" { await realApps(); return }
        // Wait for the stream and the window list.
        for _ in 0..<250 where bench() == nil || (session.compositor?.width ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        guard let w = bench() else { session.log("scenario: no Mirage Test Bench window on the host"); return }
        session.log("scenario \(name) for \(Int(seconds)) s against window \(w.id) \(w.frame)")
        if let dir = ProcessInfo.processInfo.environment["MIRAGE_TEST_BENCH_SHOTS"].map({ URL(fileURLWithPath: $0) }) { startBenchShots(dir: dir, benchID: w.id) }
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
        let maxWait = name == "transient" ? 4 : name == "drag" ? 20 : 60   // other windows on the host may never go quiet; the drag measures its own layer
        for _ in 0..<maxWait {
            try? await Task.sleep(for: .seconds(1))
            if let last = session.samples.last, last.tileKbps + last.kbps < 60 { quiet += 1 } else { quiet = 0 }
            if quiet >= 2 { break }
        }
        session.log("scenario \(name): \(quiet >= 2 ? "stream quiet after refinement" : "stream not quiet after \(maxWait) s (other windows changing)"), starting")
        // Before injecting anything the script must know what it is looking at: the console unlocked,
        // the bench frontmost, and the picture actually showing the bench (its purple caption band).
        guard let w = bench() else { session.log("scenario \(name): ABORT, bench window gone"); return }
        guard let status = session.hostStatus else { session.log("scenario \(name): ABORT, no host status"); return }
        guard !status.consoleLocked else { session.log("scenario \(name): ABORT, host console is LOCKED"); return }
        guard (status.viewers ?? 1) <= 1 else { session.log("scenario \(name): ABORT, another viewer is connected to the host (\(status.viewers!) streaming); a scripted run never shares a host with a person"); return }
        // In input-sink mode nothing the script sends can reach the host's input (window commands move only
        // the bench's own windows there), so the bench need not be frontmost for the drag scenario.
        let sinkDrag = ["drag", "unified", "chrome", "transient"].contains(name) && status.inputSink == true
        guard sinkDrag || status.frontmostWindowID == w.id || status.frontmostApp == "Mirage Test Bench" else {
            session.log("scenario \(name): ABORT, bench is not frontmost (front: \(status.frontmostApp) \(status.frontmostWindowID) '\(status.frontmostWindowTitle)')"); return
        }
        if sinkDrag { session.log("scenario drag: host is in input-sink mode; frontmost guard waived (only the bench's own window can move)") }
        var bandOK = await captionVisible(w, ppp: ppp)
        // The bench's first picture may still be its lossy still: give it a few seconds before giving up.
        for _ in 0..<10 where !bandOK { try? await Task.sleep(for: .seconds(1)); bandOK = await captionVisible(bench() ?? w, ppp: ppp) }
        guard bandOK || (name == "transient" && sinkDrag) else { session.log("scenario \(name): ABORT, the picture does not show the bench's caption band"); return }
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
                    if session.lastWatchedTileNanos > before { got = Double(Clock.elapsed(since: t0, now: session.lastWatchedTileNanos)) / 1e6; break }
                }
                latencies.append(got ?? 9999)
                session.log(String(format: "scenario login: key %d → first changed pixels in the field after %@", i, got.map { String(format: "%.0f ms", $0) } ?? "no update within 2 s"))
                try? await Task.sleep(for: .milliseconds(500))
            }
            keyLatencyMs = latencies
            // No ⌘A + ⌫ cleanup (review M9): the typed text stays in the bench's own field, which closes with it.
        case "typeahead":
            // Typing as in `typing`, through the viewer's prediction (DESIGN §3.5 item 4): each key is predicted at the
            // host's caret, confirmed by the next caret report, and erased when the host's pixels over it arrive.
            session.resetWatched()
            let text = Array("the quick brown fox jumps over the lazy dog while mirage predicts glyphs ")
            var i = 0
            while Date() < end {
                if i % 6 == 0, !guardsStillHold() { break }
                let ch = text[i % text.count]; i += 1
                let code: UInt16 = ch == " " ? 49 : 0
                let seq = session.send(.key(.init(keyCode: code, down: true, isRepeat: false, modifiers: 0, characters: String(ch))), scripted: true)
                session.typeaheadKey(keyCode: code, characters: String(ch), modifiers: [], seq: seq)
                _ = session.typeaheadSnapshot()   // what a window would draw on its next frame (time-to-visible)
                session.send(.key(.init(keyCode: code, down: false, isRepeat: false, modifiers: 0, characters: nil)), scripted: true)
                try? await Task.sleep(for: .milliseconds(160))
                _ = session.typeaheadSnapshot()
            }
            try? await Task.sleep(for: .seconds(2))
            _ = session.typeaheadSnapshot()
            let c = session.typeaheadCounts()
            session.log("scenario typeahead: \(c.shown) predicted, \(c.confirmed) confirmed, \(c.mismatched) mismatched, \(c.expired) expired")
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
            session.watchWindowID = w.id
            while Date() < end {
                guard guardsStillHold(), let win = bench() else { break }
                let x0 = win.frame.x + win.frame.width / 2, y0 = win.frame.y + Int(12 * ppp)
                var (nx, ny) = normalized(x0, y0)
                session.send(.mouseMove(.init(x: nx, y: ny)), scripted: true)
                try? await Task.sleep(for: .milliseconds(50))
                session.watchRect = win.frame.union(win.frame.offset(300 * dir, 150 * dir))
                let bytes0 = session.totalBytes()
                var x = x0, y = y0
                if win.isLayered {
                    // Layered desktop: the window moves here, the host is told the frame; no press travels.
                    layered = true
                    session.beginLayerDrag(windowID: win.id)
                    for _ in 0..<50 {   // 0.8 s drag, 6×3 px per 16 ms
                        x += 6 * dir; y += 3 * dir
                        session.dragLayer(windowID: win.id, to: win.frame.offset(x - x0, y - y0))
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    let final = win.frame.offset(x - x0, y - y0)
                    session.endLayerDrag(windowID: win.id)
                    let released = Clock.nowNanos()
                    let during = Double(session.totalBytes() - bytes0) / 1000
                    // Confirmation: the host's list shows the window within 2 px of where it was dropped.
                    var confirmed: Double? = nil
                    for _ in 0..<300 {
                        try? await Task.sleep(for: .milliseconds(10))
                        if let f = session.windowsSnapshot().first(where: { $0.id == win.id })?.frame, abs(f.x - final.x) <= 2, abs(f.y - final.y) <= 2 { confirmed = Double(Clock.elapsed(since: released, now: Clock.nowNanos())) / 1e6; break }
                    }
                    confirmMs.append(confirmed ?? 9999); burstKB.append(during)
                    session.log(String(format: "scenario drag: burst %d: %.1f KB during the drag, host confirmed the frame after %@", bursts + 1, during, confirmed.map { String(format: "%.0f ms", $0) } ?? "no confirmation in 3 s"))
                    let bytes1 = session.totalBytes()
                    await measureCrisp(burstEnd: released)
                    try? await Task.sleep(for: .milliseconds(max(0, 3000 - Int(Double(Clock.elapsed(since: released, now: Clock.nowNanos())) / 1e6))))
                    settleKB.append(Double(session.totalBytes() - bytes1) / 1000)
                    session.log(String(format: "scenario drag: burst %d: %.1f KB in the 3 s after the release", bursts, settleKB.last!))
                } else {
                    let downSeq = session.send(.mouseButton(.init(button: 0, down: true, x: nx, y: ny, clickCount: 1, modifiers: 0)), scripted: true)
                    session.beginDrag(windowID: win.id, frame: win.frame, pointer: (x0, y0), inputSeq: downSeq)
                    for _ in 0..<50 {   // 0.8 s drag, 6×3 px per 16 ms
                        x += 6 * dir; y += 3 * dir
                        (nx, ny) = normalized(x, y)
                        let seq = session.send(.mouseMove(.init(x: nx, y: ny)), scripted: true)
                        session.dragPointer(windowID: win.id, pointer: (x, y), inputSeq: seq)
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    session.send(.mouseButton(.init(button: 0, down: false, x: nx, y: ny, clickCount: 1, modifiers: 0)), scripted: true)
                    session.endDrag(windowID: win.id)
                    burstKB.append(Double(session.totalBytes() - bytes0) / 1000)
                    await measureCrisp(burstEnd: Clock.nowNanos())
                }
                try? await Task.sleep(for: .milliseconds(800))
                dir = -dir
            }
        case "unified":
            await unifiedRun(end: end, ppp: ppp)
        case "transient":
            await transientRun(end: end)
        case "chrome":
            guard let c = await MainActor.run(body: { session.unified?.chrome }) else { session.log("scenario chrome: ABORT, not in Unified mode"); return }
            let r = await c.selfTest(pid: w.pid, choose: "New Measurement", log: { session.log($0) })
            chromeResult = (r.barMs ?? 9999, r.openMs, r.items, r.chosen, r.strip)
            try? await Task.sleep(for: .seconds(max(0, seconds - 5)))
        default:
            session.log("unknown scenario \(name)")
        }
    }

    /// MIRAGE_TEST_BENCH_SHOTS: the composited scene around the bench (its arranged frame + 32 px), off-screen, at
    /// MIRAGE_TEST_BENCH_FPS, with `bench.jsonl` (time, frame) so sheets can be read against the scenario's log.
    private var shotTimer: DispatchSourceTimer?
    private func startBenchShots(dir: URL, benchID: UInt32) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fps = ProcessInfo.processInfo.environment["MIRAGE_TEST_BENCH_FPS"].flatMap { Double($0) } ?? 2
        let t0 = Clock.nowNanos()
        var n = 0
        let q = DispatchQueue(label: "mirage.benchshots")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1 / max(0.2, fps))
        t.setEventHandler { [weak self] in
            guard let self, let ctx = self.session.context, let sc = self.session.scene(pxPerPoint: 2),
                  let f = self.session.arrangedWindows().first(where: { $0.id == benchID })?.frame, let bg = sc.background else { return }
            let crop = PixelRect(x: f.x - 32, y: f.y - 32, width: f.width + 64, height: f.height + 64).intersection(PixelRect(x: 0, y: 0, width: bg.width, height: bg.height))
            n += 1
            UnifiedShots.write(scene: sc, crop: crop, context: ctx, to: dir.appendingPathComponent(String(format: "bench-%04d.png", n)))
            let line = "{\"n\":\(n),\"ms\":\(Clock.elapsed(since: t0, now: Clock.nowNanos()) / 1_000_000),\"x\":\(crop.x),\"y\":\(crop.y),\"w\":\(crop.width),\"h\":\(crop.height)}\n"
            let url = dir.appendingPathComponent("bench.jsonl")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8)) }
        }
        t.resume(); shotTimer = t
    }

    // MARK: Real apps (phrz's permission, 2026-10-20): a Finder window on ~/MirageScratch only, the Dock hovered (pointer
    // moves, no clicks), widget focus toggled by clicking that Finder window and the bench. Nothing else is touched.
    private(set) var realLog: [String] = []
    private func note(_ s: String) { let t = "t=\(session.samples.count)s "; realLog.append(t + s); session.log("scenario realapps: " + t + s) }
    private func realGuards() -> Bool {
        guard let st = session.hostStatus else { note("ABORT: no host status"); return false }
        if st.consoleLocked { note("ABORT: host console locked"); return false }
        if (st.viewers ?? 1) > 1 { note("ABORT: another viewer is connected (\(st.viewers!))"); return false }
        return true
    }
    private func scratchWindow() -> ControlMessage.WindowInfo? {
        session.windowsSnapshot().first { $0.app == "Finder" && $0.title == "MirageScratch" && $0.windowLevel == 0 }
    }
    private func moveTo(_ x: Int, _ y: Int) { let (nx, ny) = normalized(x, y); session.send(.mouseMove(.init(x: nx, y: ny)), scripted: true) }
    private var shotRects: [String: PixelRect] = [:]
    private var realShotTimer: DispatchSourceTimer?
    private func startRealShots(dir: URL, fps: Double) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 0
        let q = DispatchQueue(label: "mirage.realshots")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1 / max(0.2, fps))
        t.setEventHandler { [weak self] in
            guard let self, let ctx = self.session.context, let sc = self.session.scene(pxPerPoint: 2), let bg = sc.background else { return }
            n += 1
            for (name, r) in self.shotRects {
                let crop = r.intersection(PixelRect(x: 0, y: 0, width: bg.width, height: bg.height))
                guard crop.area > 0 else { continue }
                UnifiedShots.write(scene: sc, crop: crop, context: ctx, to: dir.appendingPathComponent(String(format: "%@-%04d.png", name, n)))
            }
        }
        t.resume(); realShotTimer = t
    }
    private func realApps() async {
        for _ in 0..<250 where scratchWindow() == nil || (session.compositor?.width ?? 0) == 0 || session.hostStatus == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard var w = scratchWindow(), let comp = session.compositor else { note("ABORT: no Finder window on MirageScratch"); return }
        guard realGuards() else { return }
        let ppp = await MainActor.run { session.pixelsPerPoint }
        let H = comp.height, W = comp.width
        let dockBand = PixelRect(x: 0, y: H - Int(170 * ppp), width: W, height: Int(170 * ppp))
        shotRects = ["dock": dockBand]
        if let dir = ProcessInfo.processInfo.environment["MIRAGE_TEST_BENCH_SHOTS"].map({ URL(fileURLWithPath: $0) }) {
            let fps = ProcessInfo.processInfo.environment["MIRAGE_TEST_BENCH_FPS"].flatMap { Double($0) } ?? 2
            startRealShots(dir: dir, fps: fps)
        }
        session.watchWindowID = w.id
        note("Finder window \(w.id) at \(w.frame), layered \(w.isLayered); waiting 20 s for the first picture")
        try? await Task.sleep(for: .seconds(20))
        // Raise it through Accessibility (AXRaise + activate Finder): no click is needed, and none can land elsewhere.
        w = scratchWindow() ?? w
        let inside = (w.frame.x + w.frame.width * 2 / 3, w.frame.y + min(w.frame.height - Int(40 * ppp), Int(200 * ppp)))
        guard realGuards() else { return }
        session.sendWindowCommand(.init(id: w.id, action: .raise))
        for _ in 0..<60 { try? await Task.sleep(for: .milliseconds(100)); if session.hostStatus?.frontmostWindowTitle == "MirageScratch" { break } }
        guard session.hostStatus?.frontmostApp == "Finder", session.hostStatus?.frontmostWindowTitle == "MirageScratch" else { note("ABORT: the scratch window is not frontmost (\(session.hostStatus?.frontmostApp ?? "?") '\(session.hostStatus?.frontmostWindowTitle ?? "")')"); return }
        // Moves first, on a quiet link: the first picture and its refinement done (tiles under 60 kbps for 3 s, up to 60 s),
        // so a move's bytes are the move's.
        var quietFor = 0
        for _ in 0..<60 { try? await Task.sleep(for: .seconds(1)); if let l = session.samples.last, l.tileKbps + l.kbps < 60 { quietFor += 1 } else { quietFor = 0 }; if quietFor >= 3 { break } }
        note("link quiet for \(quietFor) s; drags")
        // 2. Move: three title-bar drags of the layered window (local drag, AX moves), each settling 4 s.
        for b in 0..<3 {
            guard realGuards(), let win = scratchWindow() else { return }
            let old = win.frame
            shotRects["finder"] = PixelRect(x: old.x - 400, y: old.y - 300, width: old.width + 800, height: old.height + 600)
            let b0 = session.totalBytes(), f0 = session.layerBytes(win.id), d0 = session.layerBytes(0)
            let dx = b % 2 == 0 ? 6 : -6, dy = b % 2 == 0 ? 3 : -3
            if win.isLayered {
                session.beginLayerDrag(windowID: win.id)
                for k in 1...50 { session.dragLayer(windowID: win.id, to: old.offset(dx * k, dy * k)); try? await Task.sleep(for: .milliseconds(16)) }
                session.endLayerDrag(windowID: win.id)
            } else { note("Finder window is not a layer; skipping drags"); break }
            try? await Task.sleep(for: .seconds(4))
            note(String(format: "move %d: %.1f KB in 4.8 s (Finder layer %.1f KB, desktop %.1f KB)", b + 1, Double(session.totalBytes() - b0) / 1000, Double(session.layerBytes(win.id) - f0) / 1000, Double(session.layerBytes(0) - d0) / 1000))
        }
        // 1. Scroll: 3 bursts of 40 wheel events, down then up.
        shotRects["finder"] = PixelRect(x: w.frame.x - 64, y: w.frame.y - 64, width: w.frame.width + 128, height: w.frame.height + 128)
        let c0 = session.totalBytes(), cr0 = session.samples.reduce(0) { $0 + $1.copyRects }
        var dir = -1.0
        for b in 0..<3 {
            guard realGuards() else { return }
            moveTo(inside.0, inside.1)
            let (nx, ny) = normalized(inside.0, inside.1)
            for _ in 0..<40 {
                guard let win = scratchWindow() else { break }
                let seq = session.send(.scroll(.init(x: nx, y: ny, dx: 0, dy: 30 * dir, precise: true, modifiers: 0)), scripted: true)
                let rect = session.scrollRect(for: win, titleBarPx: Int(52 * ppp))
                session.predict(kind: .scroll, windowID: win.id, rect: rect, dx: 0, dy: Int((30 * dir * ppp).rounded()), inputSeq: seq)
                try? await Task.sleep(for: .milliseconds(33))
            }
            await measureCrisp(burstEnd: Clock.nowNanos())
            note(String(format: "scroll burst %d: time-to-crisp %.0f ms", b + 1, crispMs.last ?? -1))
            try? await Task.sleep(for: .milliseconds(800))
            dir = -dir
        }
        try? await Task.sleep(for: .seconds(2))
        let cr1 = session.samples.reduce(0) { $0 + $1.copyRects }
        note("scroll: \(cr1 - cr0) copy-rects, \(String(format: "%.0f", Double(session.totalBytes() - c0) / 1000)) KB")
        // 3. Dock hover: the pointer sweeps along the Dock band twice (no clicks), then rests above it for 10 s.
        guard realGuards() else { return }
        let y = H - Int(35 * ppp)
        let d0 = session.totalBytes()
        for pass in 0..<2 {
            for k in 0...60 {
                let x = pass == 0 ? W * k / 60 : W - W * k / 60
                moveTo(x, y); try? await Task.sleep(for: .milliseconds(80))
            }
        }
        moveTo(W / 2, H / 2)
        try? await Task.sleep(for: .seconds(10))
        note(String(format: "dock hover: %.0f KB during and 10 s after", Double(session.totalBytes() - d0) / 1000))
        // 4. Widget focus: alternate Finder (the scratch window) and the bench in front, 3 times, 5 s each.
        for k in 0..<3 {
            guard realGuards() else { return }
            if let b = bench() { session.sendWindowCommand(.init(id: b.id, action: .raise)); try? await Task.sleep(for: .seconds(5)) }
            guard realGuards(), let win = scratchWindow() else { return }
            session.sendWindowCommand(.init(id: win.id, action: .raise))
            try? await Task.sleep(for: .seconds(5))
            note("widget focus toggle \(k + 1) done")
        }
        note("done")
    }

    // MARK: Transient windows (tooltips, menus): when one goes, the area it covered must show current pixels within ~1 RTT.
    /// "offset ms:green or ok" per sample of the display layer where a bench tooltip was, after it left the window list.
    private(set) var transientSamples: [String] = []
    private(set) var transientGhosts = 0
    /// `--docklike` bench: the labels are pixels inside one full-screen window; their rects follow from the bench frame
    /// (points, AppKit → stream pixels). Each label is sampled every 100 ms; after it has shown, the time until the
    /// display layer stops showing green there is measured from the moment the host stops capturing it (unknown here:
    /// the label is up 1.5 s + a 0.2 s fade, so a green sample 2.2 s after it first appeared means a ghost).
    private(set) var dockGhostMs: [Double] = []
    private func dockLikeRun(end: Date, bench w: ControlMessage.WindowInfo, ppp: Double) async {
        let f = w.frame
        let rects = [PixelRect(x: max(Int(8 * ppp), f.x - Int(200 * ppp)), y: f.maxY - Int((40 + 26) * ppp), width: Int(160 * ppp), height: Int(26 * ppp)),
                     PixelRect(x: f.x - Int(100 * ppp), y: f.maxY - Int((140 + 26) * ppp), width: Int(100 * ppp), height: Int(26 * ppp))]
        var firstGreen: [UInt64?] = [nil, nil]
        while Date() < end {
            guard let comp = session.compositor else { break }
            for (i, r) in rects.enumerated() {
                let c = PixelRect(x: r.x + r.width / 4, y: r.y + r.height / 2, width: r.width / 2, height: 1)
                let green: Bool = await withCheckedContinuation { cont in comp.sampleEdgeColor(of: c, bottom: false) { col in cont.resume(returning: col.y > 0.7 && col.x < 0.45 && col.z < 0.45) } }
                let now = Clock.nowNanos()
                if green { if firstGreen[i] == nil { firstGreen[i] = now } }
                else if let t = firstGreen[i] {
                    let shownMs = Double(Clock.elapsed(since: t, now: now)) / 1e6
                    dockGhostMs.append(max(0, shownMs - 1700))   // beyond 1.5 s up + 0.2 s fade
                    session.log(String(format: "scenario transient: dock label %d shown for %.0f ms (%.0f ms beyond its time)", i, shownMs, max(0, shownMs - 1700)))
                    firstGreen[i] = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    private func transientRun(end: Date) async {
        if session.windowsSnapshot().contains(where: { $0.title.contains("docklike") }), let w = bench() {
            await dockLikeRun(end: end, bench: w, ppp: await MainActor.run { session.pixelsPerPoint }); return
        }
        var present: [UInt32: PixelRect] = [:]
        var checks: [(due: UInt64, offsetMs: Int, rect: PixelRect, id: UInt32)] = []
        while Date() < end || !checks.isEmpty {
            let tips = session.windowsSnapshot().filter { $0.title.contains("Mirage Test Bench tooltip") }
            let now = Clock.nowNanos()
            for t in tips { present[t.id] = t.frame }
            for (id, f) in present where !tips.contains(where: { $0.id == id }) {
                present[id] = nil
                // The part of it clear of window layers (a tooltip may straddle a window's edge).
                let clear = f.subtracting(session.arrangedWindows().filter(\.isLayered).map(\.frame)).max { $0.area < $1.area } ?? f
                let center = PixelRect(x: clear.x + clear.width / 4, y: clear.y + clear.height / 2, width: max(1, clear.width / 2), height: 1)
                if Date() < end { for ms in [200, 500, 1000, 3000] { checks.append((now + UInt64(ms) * 1_000_000, ms, center, id)) } }
            }
            for c in checks where c.due <= now {
                guard let comp = session.compositor else { continue }
                // Only where no window layer covers it (the tooltip over the bench is hidden under the layer anyway).
                let covered = session.arrangedWindows().contains { $0.isLayered && $0.frame.intersection(c.rect) == c.rect }
                if covered { transientSamples.append("\(c.id)@\(c.offsetMs):under-layer"); continue }
                if tips.contains(where: { $0.frame.intersects(c.rect) }) { transientSamples.append("\(c.id)@\(c.offsetMs):back"); continue }
                let green: Bool = await withCheckedContinuation { cont in comp.sampleEdgeColor(of: c.rect, bottom: false) { col in cont.resume(returning: col.y > 0.7 && col.x < 0.45 && col.z < 0.45) } }
                transientSamples.append("\(c.id)@\(c.offsetMs):\(green ? "GHOST" : "ok")")
                if green { transientGhosts += 1; session.log("scenario transient: tooltip \(c.id) still shown in the display layer \(c.offsetMs) ms after it went") }
            }
            checks.removeAll { $0.due <= now }
            try? await Task.sleep(for: .milliseconds(20))
        }
        session.log("scenario transient: \(transientGhosts) ghost samples of \(transientSamples.filter { $0.hasSuffix("ok") || $0.hasSuffix("GHOST") }.count): \(transientSamples.joined(separator: " "))")
    }

    // MARK: Unified mode (M3.2): the bench's native window moved and raised here, as the window server would on a drag;
    // nothing is injected, the host follows through window commands.
    private(set) var localMoveMs: [Double] = []      // per step: time for the local window to take the new frame
    private(set) var stepJitterMs: [Double] = []     // per burst: worst gap between consecutive local moves (target 16 ms)
    private(set) var redraws: [Int] = []             // per burst: frames the moved window redrew during its move
    private(set) var switchConfirmMs: [Double] = []  // window switches: host list shows the raised window in front
    private(set) var switchKB: [Double] = []
    private(set) var chromeResult: (barMs: Double, openMs: [Double], items: Int, chosen: Bool, strip: Int)?
    private func unifiedRun(end: Date, ppp: Double) async {
        guard let u = await MainActor.run(body: { session.unified }) else { session.log("scenario unified: ABORT, not in Unified mode (--unified)"); return }
        session.watchWindowID = bench()?.id ?? 0
        var dir: CGFloat = 1
        var round = 0
        while Date() < end {
            guard guardsStillHold() else { break }
            let benches = session.windowsSnapshot().filter { $0.title.contains("Mirage Test Bench") && $0.app == "Mirage Test Bench" && $0.isLayered && !$0.title.contains("overlay") && !$0.title.contains("icons") }
            guard let target = benches.first, let w = await MainActor.run(body: { u.windows[target.id] }) else { try? await Task.sleep(for: .milliseconds(200)); continue }
            round += 1
            // Drag burst: 50 steps of 3×1.5 pt (6×3 px at 2x) per 16 ms, like the Desktop-mode drag.
            let bytes0 = session.totalBytes()
            let drawn0 = await MainActor.run { w.remoteView.framesDrawn }
            var worst = 0.0, last = Clock.nowNanos()
            for _ in 0..<50 {
                let t0 = Clock.nowNanos()
                await MainActor.run {
                    var o = w.frame.origin; o.x += 3 * dir; o.y -= 1.5 * dir
                    w.setFrameOrigin(o)
                }
                let t1 = Clock.nowNanos()
                localMoveMs.append(Double(t1 - t0) / 1e6)
                worst = max(worst, Double(Clock.elapsed(since: last, now: t1)) / 1e6); last = t1
                try? await Task.sleep(for: .milliseconds(16))
            }
            let released = Clock.nowNanos()
            let final = await MainActor.run { u.hostFrame(w.frame) }
            let during = Double(session.totalBytes() - bytes0) / 1000
            var confirmed: Double? = nil
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(10))
                if let f = session.windowsSnapshot().first(where: { $0.id == target.id })?.frame, abs(f.x - final.x) <= 2, abs(f.y - final.y) <= 2 { confirmed = Double(Clock.elapsed(since: released, now: Clock.nowNanos())) / 1e6; break }
            }
            let drawn = await MainActor.run { w.remoteView.framesDrawn } - drawn0
            confirmMs.append(confirmed ?? 9999); burstKB.append(during); stepJitterMs.append(worst); redraws.append(drawn); bursts += 1
            session.log(String(format: "scenario unified: drag %d: %.1f KB during, worst step gap %.1f ms, %d redraws of the window, host confirmed after %@", bursts, during, worst, drawn, confirmed.map { String(format: "%.0f ms", $0) } ?? "no confirmation in 3 s"))
            let bytes1 = session.totalBytes()
            try? await Task.sleep(for: .seconds(3))
            settleKB.append(Double(session.totalBytes() - bytes1) / 1000)
            // Window switch: raise the other bench window here (as a click would make it key), measure the host's echo.
            if benches.count >= 2, let other = await MainActor.run(body: { u.windows[benches[round % benches.count].id] }) {
                let b0 = session.totalBytes(), t0 = Clock.nowNanos()
                await MainActor.run { u.raise(other) }
                var got: Double? = nil
                for _ in 0..<300 {
                    try? await Task.sleep(for: .milliseconds(10))
                    if session.hostOrder().first(where: { $0.windowLevel == 0 })?.id == other.remoteID { got = Double(Clock.elapsed(since: t0, now: Clock.nowNanos())) / 1e6; break }
                }
                try? await Task.sleep(for: .seconds(2))
                switchConfirmMs.append(got ?? 9999); switchKB.append(Double(session.totalBytes() - b0) / 1000)
                session.log(String(format: "scenario unified: switch to %u: host raised it after %@, %.1f KB in 2 s", other.remoteID, got.map { String(format: "%.0f ms", $0) } ?? "never (input sink records raises)", switchKB.last!))
            }
            dir = -dir
        }
    }
}
