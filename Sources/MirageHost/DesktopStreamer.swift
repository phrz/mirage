import Foundation
import CoreVideo
import CoreGraphics
import VideoToolbox
import ApplicationServices
import MirageCore

/// macOS desktop streamer, M2 hybrid codec (DESIGN §3.3–3.5):
/// SCK capture (BGRA, dirty rects) → CPU tile diff → copy-rect detection (window drags from the
/// window list, scrolls from line signatures) → TileTracker classification → lossless WebP tiles on
/// the reliable tile stream / HEVC of the moving region through a host-side canvas on datagrams →
/// lossless refinement of settled video tiles, all paced by the RateController's budget split.
/// All mutable state lives on `queue`; tile encoding runs on `tileQueue`.
public final class MacDesktopStreamer: DesktopStreamer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "mirage.host.video", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "mirage.host.input", qos: .userInteractive)
    private let tileQueue = DispatchQueue(label: "mirage.host.tiles", qos: .userInitiated)
    private let log: @Sendable (String) -> Void
    private var output: StreamOutput?
    private var capturer: ScreenCapturer?
    private var encoder: HEVCEncoder?
    private var injector: InputInjector?
    private var cursor: CursorMonitor?
    private var windows: WindowTracker?
    private var request: ControlMessage.StreamRequest?
    private var target: ScreenCapturer.Target?

    // Hybrid codec state.
    private var tracker: TileTracker?
    private var detector = ShiftDetector()
    private var rc: RateController?
    private var canvas: CVPixelBuffer?          // native BGRA picture the encoder sees
    private var scaled: CVPixelBuffer?          // encoder input at the current rung (nil at native)
    private var transfer: VTPixelTransferSession?
    private var lastFrame: CVPixelBuffer?       // previous capture: diff source and refinement source
    private var captureSeq: UInt32 = 0
    private var lastInputSeq: UInt64 = 0
    private var pendingVideoTiles = Set<Int>()
    private var pendingVideoRegion = PixelRect.zero
    private var pendingWholeFrame = false
    private var submitted: (tiles: Set<Int>, region: PixelRect, whole: Bool)? = nil
    private var videoActiveNanos: UInt64 = 0
    private var tileTokens: Double = 0
    private var tileMsgSeq: UInt32 = 0
    private var tileSent: [UInt32: (nanos: UInt64, bytes: Int, refinement: Int, block: Bool)] = [:]
    private var lastBudget = RateController.Budget(tileKbps: 0, videoKbps: 0)
    private var refineTimer: DispatchSourceTimer?
    private var rateTimer: DispatchSourceTimer?
    private struct PendingScroll { let x: Int, y: Int; let windowID: UInt32; let nanos: UInt64 }
    private let scrollLock = NSLock()
    private var pendingScroll: PendingScroll?
    private var dumped = false

    // Video pacing state.
    private var seq: UInt32 = 0
    private var tokens: Double = 0                 // bytes available to send
    private var lastRefill = Clock.nowNanos()
    private var lastSendNanos: UInt64 = 0
    private struct InFlight { let sentNanos: UInt64; let bytes: Int; let ltrToken: Int64? }
    private var unacked: [UInt32: InFlight] = [:]
    private var srttNanos: Double = 250_000_000
    private var ackedLTR: [Int64] = []
    private var wantKeyframe = false
    private var wantLTRRefresh = false
    private var encoding = false
    private var recoverySeq: UInt32 = 0
    private var recoverySentNanos: UInt64 = 0
    /// Last ~2 s of sent frames' datagrams, for fragment NACKs.
    private var sentFrames: [UInt32: (nanos: UInt64, datagrams: [Data])] = [:]
    private var statNacks = 0, statNackResent = 0
    private var keyframeArmed = false

    // Stats (per log interval).
    private var statFrames = 0, statBytes = 0, statDropped = 0, statSkippedBudget = 0, statLost = 0
    private var statEncodeNanos: UInt64 = 0
    private var statInput = 0, statTileBytes = 0, statTileRects = 0, statRefineBytes = 0, statCopyRects = 0, statDirtyTiles = 0, statDiffPruned = 0, statTileSkipped = 0
    private var secTileBytes = 0, secVideoBytes = 0, secVideoFrames = 0   // per rateState second
    private var statCaptures = 0
    private var statCaptureNanos: UInt64 = 0
    private var tileKbpsEWMA = 0.0
    private var lastTier: LinkTier? = nil
    private var effort: HostEffort = .full
    private var effortLevel: String { effort.rawValue }
    private var effortCaptureNanos: UInt64 = 0, effortCaptures = 0
    private var effortLogged = false
    private var statTimer: DispatchSourceTimer?

    public init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        hostLog = log
        // Env var, or a marker file for the LaunchAgent: ~/Library/Application Support/Mirage/debug-shift
        let marker = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mirage/debug-shift").path
        if ProcessInfo.processInfo.environment["MIRAGE_DEBUG_SHIFT"] != nil || FileManager.default.fileExists(atPath: marker) { detector.debug = { log($0) } }
    }

    // MARK: DesktopStreamer

    public func start(_ req: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
        let cap = ScreenCapturer(queue: queue)
        let t = try await cap.start(req) { [weak self] pb, nanos, dirty in self?.captured(pb, nanos, dirtyRects: dirty) }
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                do {
                    self.output = output
                    self.capturer = cap
                    self.target = t
                    self.request = req
                    try self.configure(for: t, req: req)
                    self.injector = InputInjector(displayID: t.display.displayID)
                    self.windows = WindowTracker(displayID: t.display.displayID, streamWidth: t.pixelWidth)
                    let cur = CursorMonitor(displayID: t.display.displayID)
                    cur.onShape = { [weak self] s in self?.output?.sendControl(.cursorShape(s)) }
                    cur.onPosition = { [weak self] p in self?.output?.sendControl(.cursorPosition(p)) }
                    cur.start(on: self.queue)
                    self.cursor = cur
                    cap.onStop = { [weak self] err in self?.log("capture stopped: \(err.map { "\($0)" } ?? "ok")") }
                    if let w = self.windows?.sample(captureSeq: 0, now: Clock.nowNanos()) {
                        self.publishedWindows = w.sample.windows; self.lastFullWindowsNanos = Clock.nowNanos()
                        self.sendControlCounted(.windowList(.init(captureSeq: 0, windows: w.sample.windows)))
                    }
                    self.startTimers()
                    c.resume(returning: t.info)
                } catch { c.resume(throwing: error) }
            }
        }
    }

    /// (Re)builds everything that depends on the native stream size.
    private func configure(for t: ScreenCapturer.Target, req: ControlMessage.StreamRequest) throws {
        let w = t.pixelWidth, h = t.pixelHeight
        tracker = TileTracker(width: w, height: h)
        var controller = RateController(initialKbps: min(req.bitrateKbps, 800), maxKbps: req.bitrateKbps, nativePixels: w * h)
        if let old = rc { controller = RateController(initialKbps: old.targetKbps, maxKbps: req.bitrateKbps, nativePixels: w * h) }
        rc = controller
        canvas = try Self.makeBuffer(width: w, height: h)
        scaled = nil; transfer = nil
        lastFrame = nil
        pendingVideoTiles = []; pendingVideoRegion = .zero; pendingWholeFrame = false; submitted = nil
        try rebuildEncoder()
        lastBudget = controller.budget(videoActive: false)
        tokens = bucketCapacity(); tileTokens = Double(lastBudget.tileKbps * 1000 / 8) * 0.5
        wantKeyframe = false; keyframeArmed = false; ackedLTR = []
        windows?.setDisplay(t.display.displayID, streamWidth: w)
        sendTileMessage(.reset(width: w, height: h), captureNanos: Clock.nowNanos())
        beginFreshPicture(reason: "stream start or resize")
    }

    private func rebuildEncoder() throws {
        guard let t = target, let rc else { return }
        let scale = rc.scale
        let ew = max(64, Int(Double(t.pixelWidth) * scale)) & ~1, eh = max(64, Int(Double(t.pixelHeight) * scale)) & ~1
        encoder = try HEVCEncoder(width: ew, height: eh, bitrateKbps: max(100, lastBudget.videoKbps), expectedFPS: plannedFPS())
        if scale < 1 {
            scaled = try Self.makeBuffer(width: ew, height: eh)
            var s: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else { throw MirageError.transport("VTPixelTransferSessionCreate failed") }
            VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            transfer = s
        } else {
            scaled = nil; transfer = nil
        }
        ackedLTR = []
    }

    private static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let pb else { throw MirageError.transport("CVPixelBufferCreate: \(st)") }
        return pb
    }

    public func update(_ req: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo {
        guard let cap = capturer else { throw MirageError.transport("not streaming") }
        let t = try await cap.update(req)
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                let old = self.target
                self.target = t
                if old?.pixelWidth != t.pixelWidth || old?.pixelHeight != t.pixelHeight || self.encoder == nil {
                    do {
                        self.request = req
                        try self.configure(for: t, req: req)
                    } catch {
                        self.log("stream reconfigure to \(t.pixelWidth)x\(t.pixelHeight) failed: \(error)")
                        self.target = old
                        if let oldReq = self.request { Task { _ = try? await cap.update(oldReq) } }   // put SCK back to the old size
                        c.resume(throwing: error); return
                    }
                    self.log("stream reconfigured to \(t.pixelWidth)x\(t.pixelHeight), cap \(req.bitrateKbps) kbps")
                } else {
                    self.rc?.maxKbps = req.bitrateKbps
                    self.log("stream cap set to \(req.bitrateKbps) kbps")
                }
                self.request = req
                self.injector?.setDisplay(t.display.displayID)
                self.cursor?.setDisplay(t.display.displayID)
                c.resume(returning: t.info)
            }
        }
    }

    public func handle(ack: ControlMessage.FrameAck) {
        queue.async { self.acked(ack) }
    }

    public func handle(nack: ControlMessage.Nack) {
        queue.async {
            self.statNacks += 1
            guard let out = self.output, let f = self.sentFrames[nack.frameSeq] else { return }
            for i in nack.fragments where i >= 0 && i < f.datagrams.count { out.sendDatagram(f.datagrams[i]); self.statNackResent += 1 }
        }
    }

    public func handle(tileAck: ControlMessage.TileAck) {
        queue.async {
            guard let sent = self.tileSent.removeValue(forKey: tileAck.msgSeq) else { return }
            let now = Clock.nowNanos()
            self.refinementInFlight = max(0, self.refinementInFlight - sent.refinement)
            if sent.block { self.freshBlockAcked(); self.freshBlocksStep(now: now) }
            self.rc?.delaySample(sentNanos: sent.nanos, receivedNanos: tileAck.receivedNanos, now: now)
            for k in self.tileSent.keys where k < tileAck.msgSeq &- 64 { if let v = self.tileSent.removeValue(forKey: k) { self.refinementInFlight = max(0, self.refinementInFlight - v.refinement) } }
        }
    }

    public func handle(input: ControlMessage) {
        inputQueue.async {
            self.injector?.handle(input)
            if case .scroll(let s) = input, let t = self.target, let w = self.windows {
                let x = Int(s.x * Double(t.pixelWidth)), y = Int(s.y * Double(t.pixelHeight))
                if let win = w.window(at: x, y) {
                    w.queryAXScrollArea(at: x, y, windowID: win.id)
                    self.scrollLock.lock(); self.pendingScroll = PendingScroll(x: x, y: y, windowID: win.id, nanos: Clock.nowNanos()); self.scrollLock.unlock()
                }
            }
            self.queue.async { self.statInput += 1 }
        }
    }

    public func stop() async {
        let cap = capturer
        await cap?.stop()
        await withCheckedContinuation { c in
            queue.async {
                self.cursor?.stop(); self.cursor = nil
                self.statTimer?.cancel(); self.statTimer = nil
                self.refineTimer?.cancel(); self.refineTimer = nil
                self.rateTimer?.cancel(); self.rateTimer = nil
                self.encoder = nil; self.capturer = nil; self.output = nil
                self.lastFrame = nil; self.canvas = nil; self.scaled = nil; self.transfer = nil
                let inj = self.injector; self.injector = nil
                self.inputQueue.async { inj?.releaseAll() }
                c.resume()
            }
        }
    }

    // MARK: Capture pipeline

    private func frameView(_ pb: CVPixelBuffer) -> ShiftDetector.Frame {
        ShiftDetector.Frame(base: CVPixelBufferGetBaseAddress(pb)!, stride: CVPixelBufferGetBytesPerRow(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
    }

    /// Per-channel difference below which a tile counts as unchanged: whole-screen ±1–2 level flickers
    /// and anti-aliasing re-renders are invisible, but through an exact diff they would turn into a
    /// video frame plus a full lossless refinement pass (measured: ~400 KB per flicker).
    private static let diffTolerance: Int32 = 4

    private func tileEqual(_ a: ShiftDetector.Frame, _ b: ShiftDetector.Frame, _ r: PixelRect) -> Bool {
        tileChangedBox(a, b, r) == nil
    }

    /// Bounding box of the pixels that differ beyond the tolerance inside `r`, or nil if none do.
    /// Sparse updates (a typed glyph, a caret) are a fraction of their 64-px tile; sending the tight
    /// box instead of the tile halves typing's bytes.
    private func tileChangedBox(_ a: ShiftDetector.Frame, _ b: ShiftDetector.Frame, _ r: PixelRect) -> PixelRect? {
        let n = r.width * 4
        var x0 = Int.max, x1 = -1, y0 = Int.max, y1 = -1
        for y in r.y..<r.maxY {
            let pa = a.base.advanced(by: y * a.stride + r.x * 4), pb = b.base.advanced(by: y * b.stride + r.x * 4)
            if memcmp(pa, pb, n) == 0 { continue }
            let ua = pa.assumingMemoryBound(to: UInt8.self), ub = pb.assumingMemoryBound(to: UInt8.self)
            var rowChanged = false
            for x in 0..<r.width {
                let o = x * 4
                if abs(Int32(ua[o]) - Int32(ub[o])) > Self.diffTolerance || abs(Int32(ua[o + 1]) - Int32(ub[o + 1])) > Self.diffTolerance || abs(Int32(ua[o + 2]) - Int32(ub[o + 2])) > Self.diffTolerance {
                    rowChanged = true
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                }
            }
            if rowChanged { if y < y0 { y0 = y }; y1 = y }
        }
        guard x1 >= 0 else { return nil }
        return PixelRect(x: r.x + x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    private func captured(_ pb: CVPixelBuffer, _ nanos: UInt64, dirtyRects: [PixelRect]) {
        guard var tracker, request != nil, output != nil, let windows else { return }
        captureSeq &+= 1
        let now = Clock.nowNanos()
        statCaptures += 1; effortCaptures += 1
        defer { let dt = Clock.nowNanos() - now; statCaptureNanos += dt; effortCaptureNanos += dt }
        // Inputs injected less than ~40 ms before the capture are not in these pixels yet (window server + app render).
        lastInputSeq = injector?.inputSeq(before: nanos &- 40_000_000) ?? 0
        var moved: [WindowTracker.Delta] = []
        if let s = windows.sample(captureSeq: captureSeq, now: now) {
            moved = s.moved
            if s.changed { publishWindows(s.sample.windows, captureSeq: captureSeq, now: now) }
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let new = frameView(pb)
        guard new.width == tracker.width, new.height == tracker.height else { return }   // a stale frame around a resize
        var dirty = tracker.tiles(covering: dirtyRects)
        let prev = lastFrame
        var old: ShiftDetector.Frame? = nil
        if let prev { CVPixelBufferLockBaseAddress(prev, .readOnly); old = frameView(prev) }
        defer { if let prev { CVPixelBufferUnlockBaseAddress(prev, .readOnly) } }

        var tightBoxes: [Int: PixelRect] = [:]
        if let old {
            // CPU diff inside SCK's dirty rects: they over-report ~1.7x (experiments/probes), and the
            // exact changed box inside a tile is what a sparse lossless update needs.
            let before = dirty.count
            let wantBoxes = effort.tightBoxes
            dirty.removeAll { i in
                if let box = tileChangedBox(old, new, tracker.rect(of: i)) { if wantBoxes { tightBoxes[i] = box }; return false }
                return true
            }
            statDiffPruned += before - dirty.count
        } else {
            // First frame: everything through one keyframe, then refine lossless.
            dirty = Array(0..<tracker.tileCount)
        }
        statDirtyTiles += dirty.count
        if dirty.isEmpty { lastFrame = pb; refine(now: now); return }

        // Copy-rects: window drags from the window list, scrolls from line signatures.
        var explained = Set<Int>()
        if let old, prev != nil {
            for d in moved {
                let dx0 = d.new.x - d.old.x, dy0 = d.new.y - d.old.y
                guard abs(dx0) + abs(dy0) > 0, abs(dx0) < 600, abs(dy0) < 600 else { continue }
                // The window list is sampled a few ms after the pixels were composited, so during a fast
                // drag the reported delta can be off by a few px: verify it, else search around the window.
                var r = detector.verify(old: old, new: new, rect: d.old, dx: dx0, dy: dy0)
                if r == nil, let (rdx, rdy) = detector.refine(old: old, new: new, rect: d.old, dx: dx0, dy: dy0, radius: effort.shiftSearch.refineRadius), (rdx, rdy) != (dx0, dy0) {
                    r = detector.verify(old: old, new: new, rect: d.old, dx: rdx, dy: rdy)
                }
                guard let r else { continue }
                let dx = r.dx, dy = r.dy
                let dest = tracker.tiles(covering: [r.rect.offset(dx, dy)])
                let mismatched = Set(tracker.tiles(covering: r.mismatchedTiles))
                explained.formUnion(dest.filter { !mismatched.contains($0) })
                sendTileMessage(.copyRect(.init(header: header(windowID: d.id, nanos: nanos), rect: r.rect, dx: dx, dy: dy)), captureNanos: nanos)
                statCopyRects += 1
            }
            let unexplained = dirty.filter { !explained.contains($0) }
            if detector.debug != nil, unexplained.count >= 6 { log("capture \(captureSeq): dirty \(dirty.count) unexplained \(unexplained.count) bb \(tracker.boundingRect(unexplained)) moved \(moved.count) scroll \(pendingScroll != nil)") }
            if let dir = ProcessInfo.processInfo.environment["MIRAGE_DUMP_DIR"], unexplained.count >= 100, !dumped {
                dumped = true
                for (name, f) in [("old", old), ("new", new)] {
                    var d = Data(count: f.width * f.height * 4)
                    d.withUnsafeMutableBytes { dst in for y in 0..<f.height { memcpy(dst.baseAddress!.advanced(by: y * f.width * 4), f.base.advanced(by: y * f.stride), f.width * 4) } }
                    try? d.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(f.width)x\(f.height).bgra"))
                }
                log("dumped frame pair to \(dir)")
            }
            scrollLock.lock(); let scroll = pendingScroll; pendingScroll = nil; scrollLock.unlock()
            let bb = tracker.boundingRect(unexplained)
            if unexplained.count >= 12, bb.height >= 128 || bb.width >= 128 {
                let win = scroll.flatMap { s in windows.window(at: s.x, s.y) } ?? windows.window(at: bb.x + bb.width / 2, bb.y + bb.height / 2)
                let known = win.flatMap { windows.scrollRect(for: $0.id) }
                var region = (known ?? win?.frame ?? bb).intersection(bb)
                if region.width < 64 || region.height < 64 { region = bb }
                if region.height >= 96 || region.width >= 96, let r = detector.detect(old: old, new: new, rect: region) {
                    let dest = tracker.tiles(covering: [r.rect.offset(r.dx, r.dy)])
                    let mismatched = Set(tracker.tiles(covering: r.mismatchedTiles))
                    explained.formUnion(dest.filter { !mismatched.contains($0) })
                    sendTileMessage(.copyRect(.init(header: header(windowID: win?.id ?? 0, nanos: nanos), rect: r.rect, dx: r.dx, dy: r.dy)), captureNanos: nanos)
                    if let win, known == nil { windows.learn(scrollRect: r.rect.union(r.rect.offset(r.dx, r.dy)), for: win.id) }
                    statCopyRects += 1
                }
            }
        }
        if !explained.isEmpty {
            dirty.removeAll { explained.contains($0) }
            tracker.markCopied(Array(explained), now: now)
        }

        var plan = tracker.classify(dirty: dirty, now: now)
        if let rc, !rc.policy.videoEnabled, !plan.video.isEmpty {
            // Extreme tier: no video; motion goes lossless at the tier's frame cap through the refinement queue.
            tracker.markVideo(plan.video, now: now)
            plan.video = []; plan.videoRegion = .zero; plan.wholeFrame = false
        }
        refillTiles(now: now)
        if !plan.lossless.isEmpty {
            // Priority 1: changed pixels near the input locus (pointer or caret) always go, now, on the
            // interactive stream, whatever the budget; they are small and they are what the person is
            // looking at. Priority 2: other changed pixels, budget permitting. Refinement yields to real
            // change (three tiles or more), not to a caret blink or a menu-bar clock.
            if plan.lossless.count >= 3 { lastDirectNanos = now }
            let (near, far) = splitByLocus(plan.lossless, tracker: tracker)
            if !near.isEmpty {
                let bytes = submitLossless(tiles: near, from: new, refinement: false, nanos: nanos, tracker: tracker, tight: tightBoxes)
                tileTokens -= Double(bytes)
                plan.lossless = far
            }
        }
        if !plan.lossless.isEmpty {
            if tileTokens > 0 {
                let bytes = submitLossless(tiles: plan.lossless, from: new, refinement: false, nanos: nanos, tracker: tracker, tight: tightBoxes)
                tileTokens -= Double(bytes)
            } else if plan.lossless.count >= 12, rc?.policy.videoEnabled ?? true {
                // The tile budget is spent and this is a lot of fresh content (a scroll's exposed strip at
                // native scale is megapixels per second): show it through video now, refine it later.
                plan.video.append(contentsOf: plan.lossless)
                plan.videoRegion = plan.videoRegion.union(tracker.boundingRect(plan.lossless))
                tracker.markVideo(plan.lossless, now: now)
                statTileSkipped += plan.lossless.count
            } else {
                tracker.defer(plan.lossless, now: now); statTileSkipped += plan.lossless.count
            }
        }
        if !plan.video.isEmpty, let canvas {
            copyToCanvas(canvas, tiles: plan.video, from: new, tracker: tracker)
            pendingVideoTiles.formUnion(plan.video)
            pendingVideoRegion = pendingVideoRegion.union(plan.videoRegion)
            pendingWholeFrame = pendingWholeFrame || plan.wholeFrame
            videoActiveNanos = now
        }
        self.tracker = tracker
        lastFrame = pb
        if !pendingVideoTiles.isEmpty || wantKeyframe { tryEncode(now: now, latest: new) }
        refine(now: now)
    }

    /// Tiles within ~200 px (native) of the last input event, and the rest.
    private func splitByLocus(_ tiles: [Int], tracker: TileTracker) -> ([Int], [Int]) {
        guard let l = injector?.locus else { return ([], tiles) }
        let lx = Int(l.x * Double(tracker.width)), ly = Int(l.y * Double(tracker.height))
        let radius = 200
        var near: [Int] = [], far: [Int] = []
        for i in tiles {
            let r = tracker.rect(of: i)
            let cx = r.x + r.width / 2, cy = r.y + r.height / 2
            if abs(cx - lx) <= radius + r.width / 2 && abs(cy - ly) <= radius + r.height / 2 { near.append(i) } else { far.append(i) }
        }
        return (near, far)
    }
    private var lastDirectNanos: UInt64 = 0

    /// Progressive, whole-picture refinement of a fresh picture (DESIGN §3.3): level 0 is the tiny
    /// keyframe, then the ladder climbs rung by rung as each step is acked, then lossless lands in
    /// large centre-first blocks. Per-tile refinement is gated off until this is done, and nothing
    /// from the refinement queue goes out before the base frame is acked.
    enum Fresh: CustomStringConvertible, Equatable {
        case base(seq: UInt32)          // waiting for the ack of the tiny keyframe
        case climb(seq: UInt32)         // waiting for the ack of the last ladder step
        case blocks(remaining: [PixelRect], inFlightBytes: Int)
        case done
        var description: String {
            switch self {
            case .base(let s): return "base(\(s))"
            case .climb(let s): return "climb(\(s))"
            case .blocks(let r, let b): return "blocks(\(r.count) left, \(b) B in flight)"
            case .done: return "done"
            }
        }
    }
    private var fresh: Fresh = .done
    private var freshBaseSeq: UInt32 = 0

    /// Starts a fresh-picture sequence; the next keyframe is its base.
    private func beginFreshPicture(reason: String) {
        fresh = .base(seq: 0)
        log("fresh picture (\(reason)): tiny keyframe first, then ladder climb, then large lossless blocks")
    }

    /// Called when a video frame is acked as decoded.
    private func freshAcked(seq: UInt32, now: UInt64) {
        guard let rc, var tracker else { return }
        switch fresh {
        case .base(let s) where seq >= s && s != 0, .climb(let s) where seq >= s && s != 0:
            // Climb while the target affords the next rung; each step is a whole-frame keyframe.
            let kpix = Double(tracker.width * tracker.height) / 1000
            let next = rc.rung - 1
            if next >= rc.policy.minRung, Double(rc.targetKbps) >= kpix * RateController.scales[next] * RateController.scales[next] * rc.tuning.kbpsPerKpixelDown, rc.queueMs < 90 {
                self.rc!.climbOneRung(now: now)
                lastRebuildNanos = now
                if (try? rebuildEncoder()) != nil { wantKeyframe = true; progressiveKeyframe = true; fresh = .climb(seq: 0); log("fresh picture: climbing to rung \(self.rc!.rung) (scale \(self.rc!.scale))") }
                else { fresh = .done }
            } else {
                // Lossless in large blocks sized to ~1 s of the refinement budget, centre-first.
                let perSecond = Double(lastBudget.tileKbps * 1000 / 8) * 0.3
                let blockArea = max(240.0 * 135.0, min(Double(tracker.width * tracker.height), perSecond / 0.3))
                let side = Int(blockArea.squareRoot())
                let cols = max(1, (tracker.width + side - 1) / side), rows = max(1, (tracker.height + side - 1) / side)
                let bw = (tracker.width + cols - 1) / cols, bh = (tracker.height + rows - 1) / rows
                var blocks: [PixelRect] = []
                for r in 0..<rows { for c in 0..<cols {
                    let rect = PixelRect(x: c * bw, y: r * bh, width: min(bw, tracker.width - c * bw), height: min(bh, tracker.height - r * bh))
                    // Skip blocks the client already has pixel-exact.
                    let tiles = tracker.tiles(covering: [rect])
                    if !tiles.allSatisfy({ tracker.isCrisp($0) }) { blocks.append(rect) }
                } }
                let cx = tracker.width / 2, cy = tracker.height / 2
                blocks.sort { a, b in abs(a.x + a.width / 2 - cx) + abs(a.y + a.height / 2 - cy) < abs(b.x + b.width / 2 - cx) + abs(b.y + b.height / 2 - cy) }
                fresh = .blocks(remaining: blocks, inFlightBytes: 0)
                log("fresh picture: rung \(rc.rung) is the top the target affords; \(blocks.count) lossless blocks of \(bw)x\(bh), centre-first")
                self.tracker = tracker
            }
        default: break
        }
    }
    private var progressiveKeyframe = false

    /// Sends the next large lossless block when the previous one is acked (one in flight), within budget.
    private func freshBlocksStep(now: UInt64) {
        guard case .blocks(var remaining, let inFlight) = fresh else { return }
        guard inFlight == 0 else { return }
        guard !remaining.isEmpty else { fresh = .done; log("fresh picture: complete"); return }
        guard let src = lastFrame, var tracker else { return }
        refillTiles(now: now)
        guard tileTokens > 0, now - lastDirectNanos > 100_000_000 else { return }
        let rect = remaining.removeFirst()
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        let f = frameView(src)
        guard f.width == tracker.width else { return }
        let est = submitRects([rect], from: f, refinement: true, nanos: now)
        tileTokens -= Double(est)
        let covered = tracker.tiles(covering: [rect]).filter { tracker.rect(of: $0).intersection(rect) == tracker.rect(of: $0) }
        tracker.sent(lossless: covered, now: now)
        self.tracker = tracker
        fresh = .blocks(remaining: remaining, inFlightBytes: est)
    }
    private func freshBlockAcked() {
        if case .blocks(let remaining, _) = fresh { fresh = .blocks(remaining: remaining, inFlightBytes: 0) }
    }
    /// Refinement bytes sent but not yet acked by the viewer (bounded so refinement cannot fill the link's queue).
    private var refinementInFlight = 0

    // Window list publication: the client holds the last full list; the host sends coalesced deltas
    // at most every 100 ms and a full list every 10 s (and on start). Review §2.2.
    private var publishedWindows: [ControlMessage.WindowInfo] = []
    private var pendingWindows: [ControlMessage.WindowInfo]? = nil
    private var lastWindowsSendNanos: UInt64 = 0
    private var lastFullWindowsNanos: UInt64 = 0
    private var statControlBytes = 0

    private func publishWindows(_ list: [ControlMessage.WindowInfo], captureSeq: UInt32, now: UInt64) {
        pendingWindows = list
        flushWindows(now: now)
    }
    private func flushWindows(now: UInt64) {
        guard let list = pendingWindows, now - lastWindowsSendNanos >= 100_000_000 else { return }
        pendingWindows = nil
        lastWindowsSendNanos = now
        if now - lastFullWindowsNanos > 10_000_000_000 {
            publishedWindows = list; lastFullWindowsNanos = now
            sendControlCounted(.windowList(.init(captureSeq: captureSeq, windows: list)))
        } else if let d = ControlMessage.WindowList.delta(from: publishedWindows, to: list, captureSeq: captureSeq) {
            publishedWindows = list
            sendControlCounted(.windowList(d))
        }
    }
    /// Control-stream sends with byte accounting (the stream is outside the datagram budget; measure it).
    private func sendControlCounted(_ m: ControlMessage) {
        if let d = try? Frame.encode(m) { statControlBytes += d.count }
        output?.sendControl(m)
    }

    private func header(windowID: UInt32, nanos: UInt64) -> TileMessage.Header {
        .init(captureSeq: captureSeq, inputSeq: lastInputSeq, windowID: windowID, captureNanos: nanos)
    }

    /// Fills every tile not in `keep` with its mean colour (the client ignores them: masked out).
    private func flattenCanvas(_ canvas: CVPixelBuffer, except keep: Set<Int>, tracker: TileTracker) {
        CVPixelBufferLockBaseAddress(canvas, [])
        defer { CVPixelBufferUnlockBaseAddress(canvas, []) }
        let base = CVPixelBufferGetBaseAddress(canvas)!, stride = CVPixelBufferGetBytesPerRow(canvas)
        var flattened = 0
        for i in 0..<tracker.tileCount where !keep.contains(i) {
            let r = tracker.rect(of: i)
            var sb = 0, sg = 0, sr = 0, n = 0
            for y in Swift.stride(from: r.y, to: r.maxY, by: 8) {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in Swift.stride(from: r.x, to: r.maxX, by: 8) { sb += Int(row[x * 4]); sg += Int(row[x * 4 + 1]); sr += Int(row[x * 4 + 2]); n += 1 }
            }
            guard n > 0 else { continue }
            var px: UInt32 = 0xFF00_0000 | UInt32(sr / n) << 16 | UInt32(sg / n) << 8 | UInt32(sb / n)
            for y in r.y..<r.maxY { memset_pattern4(base.advanced(by: y * stride + r.x * 4), &px, r.width * 4) }
            flattened += 1
        }
        if flattened > 0 { log("keyframe: flattened \(flattened) masked-out tiles") }
    }

    private func copyToCanvas(_ canvas: CVPixelBuffer, tiles: [Int], from f: ShiftDetector.Frame, tracker: TileTracker) {
        CVPixelBufferLockBaseAddress(canvas, [])
        defer { CVPixelBufferUnlockBaseAddress(canvas, []) }
        let dst = CVPixelBufferGetBaseAddress(canvas)!, ds = CVPixelBufferGetBytesPerRow(canvas)
        for i in tiles {
            let r = tracker.rect(of: i)
            for y in r.y..<r.maxY { memcpy(dst.advanced(by: y * ds + r.x * 4), f.base.advanced(by: y * f.stride + r.x * 4), r.width * 4) }
        }
    }

    // MARK: Lossless tiles

    /// Copies the rects' pixels out and encodes them on the tile queue. Returns the byte estimate charged to the budget.
    @discardableResult
    private func submitLossless(tiles: [Int], from f: ShiftDetector.Frame, refinement: Bool, nanos: UInt64, tracker: TileTracker, tight: [Int: PixelRect]? = nil) -> Int {
        var rects = tracker.mergedRects(tiles)
        if let tight {
            // Shrink each merged rect to the union of its tiles' changed boxes (padded 2 px), when all are known.
            let set = Set(tiles)
            rects = rects.map { r in
                var u = PixelRect.zero
                for i in tracker.tiles(covering: [r]) where set.contains(i) {
                    guard let b = tight[i] else { return r }
                    u = u.union(b)
                }
                return u.isEmpty ? r : PixelRect(x: u.x - 2, y: u.y - 2, width: u.width + 4, height: u.height + 4).intersection(r)
            }
        }
        var jobs: [(PixelRect, Data)] = []
        var estimate = 0
        for r in rects {
            var d = Data(count: r.width * r.height * 4)
            d.withUnsafeMutableBytes { dst in
                for y in 0..<r.height { memcpy(dst.baseAddress!.advanced(by: y * r.width * 4), f.base.advanced(by: (r.y + y) * f.stride + r.x * 4), r.width * 4) }
            }
            jobs.append((r, d)); estimate += r.area / 5
        }
        let hdr = header(windowID: 0, nanos: nanos)
        let webp = effort.webpEffort
        tileQueue.async { [weak self] in
            guard let self else { return }
            var out: [TileMessage.Tile] = []
            for (r, d) in jobs {
                let encoded: (TileCodec.Format, Data)? = d.withUnsafeBytes { p -> (TileCodec.Format, Data)? in
                    let base = p.baseAddress!
                    if let solid = TileCodec.solidColour(base: base, width: r.width, height: r.height, stride: r.width * 4) { return (.solid, solid) }
                    let fmt: TileCodec.Format = TileCodec.colourCount(base: base, width: r.width, height: r.height, stride: r.width * 4, limit: 4096) > 4096 ? .nearLossless : .lossless
                    return TileCodec.encode(base: base, width: r.width, height: r.height, stride: r.width * 4, format: fmt, effort: webp).map { (fmt, $0) }
                }
                if let (fmt, data) = encoded { out.append(.init(rect: r, format: fmt, data: data)) }
            }
            guard !out.isEmpty else { return }
            let bytes = out.reduce(0) { $0 + $1.data.count }
            self.send(tile: .tiles(.init(header: hdr, refinement: refinement, tiles: out)), captureNanos: nanos, fast: !refinement, refinementBytes: refinement ? bytes : 0)
            self.queue.async {
                self.tileTokens -= Double(bytes - estimate)   // true up the estimate
                self.statTileBytes += bytes; self.statTileRects += out.count; self.secTileBytes += bytes
                if refinement { self.statRefineBytes += bytes }
            }
        }
        return estimate
    }

    /// Encodes arbitrary rects (large lossless blocks) on the tile queue. Returns the byte estimate charged.
    @discardableResult
    private func submitRects(_ rects: [PixelRect], from f: ShiftDetector.Frame, refinement: Bool, nanos: UInt64) -> Int {
        var jobs: [(PixelRect, Data)] = []
        var estimate = 0
        for r in rects where !r.isEmpty {
            var d = Data(count: r.width * r.height * 4)
            d.withUnsafeMutableBytes { dst in
                for y in 0..<r.height { memcpy(dst.baseAddress!.advanced(by: y * r.width * 4), f.base.advanced(by: (r.y + y) * f.stride + r.x * 4), r.width * 4) }
            }
            jobs.append((r, d)); estimate += r.area / 5
        }
        let hdr = header(windowID: 0, nanos: nanos)
        let webp = effort.webpEffort
        tileQueue.async { [weak self] in
            guard let self else { return }
            var out: [TileMessage.Tile] = []
            for (r, d) in jobs {
                let encoded: (TileCodec.Format, Data)? = d.withUnsafeBytes { p -> (TileCodec.Format, Data)? in
                    let base = p.baseAddress!
                    if let solid = TileCodec.solidColour(base: base, width: r.width, height: r.height, stride: r.width * 4) { return (.solid, solid) }
                    let fmt: TileCodec.Format = TileCodec.colourCount(base: base, width: r.width, height: r.height, stride: r.width * 4, limit: 4096) > 4096 ? .nearLossless : .lossless
                    return TileCodec.encode(base: base, width: r.width, height: r.height, stride: r.width * 4, format: fmt, effort: webp).map { (fmt, $0) }
                }
                if let (fmt, data) = encoded { out.append(.init(rect: r, format: fmt, data: data)) }
            }
            guard !out.isEmpty else { self.queue.async { self.freshBlockAcked() }; return }
            let bytes = out.reduce(0) { $0 + $1.data.count }
            self.send(tile: .tiles(.init(header: hdr, refinement: refinement, tiles: out)), captureNanos: nanos, fast: false, refinementBytes: bytes, block: true)
            self.queue.async {
                self.tileTokens -= Double(bytes - estimate)
                self.statTileBytes += bytes; self.statTileRects += out.count; self.secTileBytes += bytes; self.statRefineBytes += bytes
            }
        }
        return estimate
    }

    /// Sends a tile-stream message in order (all sends go through the tile queue). Copy-rects and resets are interactive.
    private func sendTileMessage(_ m: TileMessage, captureNanos: UInt64) {
        tileQueue.async { [weak self] in self?.send(tile: m, captureNanos: captureNanos, fast: true, refinementBytes: 0) }
    }
    /// On tileQueue.
    private func send(tile m: TileMessage, captureNanos: UInt64, fast: Bool, refinementBytes: Int, block: Bool = false) {
        guard let out = output else { return }
        tileMsgSeq &+= 1
        let seq = tileMsgSeq
        let d = m.encode(msgSeq: seq)
        out.sendTiles(d, fast: fast)
        queue.async { self.tileSent[seq] = (Clock.nowNanos(), d.count, refinementBytes, block); self.refinementInFlight += refinementBytes }
    }

    private func refillTiles(now: UInt64) {
        let cap = Double(lastBudget.tileKbps * 1000 / 8)
        let dt = Double(now &- lastTileRefill) / 1e9
        lastTileRefill = now
        tileTokens = min(cap * 0.5, tileTokens + dt * cap)
        tileTokens = max(tileTokens, -cap)
    }
    private var lastTileRefill = Clock.nowNanos()

    /// Refinement: settled video tiles and rate-limited sparse tiles, oldest first, centre first, within the tile budget.
    private func refine(now: UInt64) {
        guard var tracker, let src = lastFrame else { return }
        refillTiles(now: now)
        // Priority 4: refinement runs on leftover budget only. It yields for 150 ms after any changed
        // pixels went out, keeps 30 % of the tile budget in reserve for them, and never has more than
        // ~300 ms of the link in flight (so it cannot build the queue the next keystroke would wait in).
        guard now - lastDirectNanos > 150_000_000 else { return }
        // A fresh picture refines progressively and whole-picture (see Fresh); never as a tile march.
        guard fresh == .done else { freshBlocksStep(now: now); return }
        let perSecond = Double(lastBudget.tileKbps * 1000 / 8)
        guard tileTokens > perSecond * 0.3 * 0.5, Double(refinementInFlight) < perSecond * 0.3 else { return }
        let due = tracker.due(now: now, limit: 96)
        guard !due.isEmpty else { return }
        // Take tiles until the budget is spent (allowed to go negative once).
        var take: [Int] = []
        var est = 0.0
        for i in due {
            take.append(i); est += Double(tracker.rect(of: i).area) / 5
            if est >= tileTokens { break }
        }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        let f = frameView(src)
        guard f.width == tracker.width, f.height == tracker.height else { return }
        let bytes = submitLossless(tiles: take, from: f, refinement: true, nanos: now, tracker: tracker)
        tileTokens -= Double(bytes)
        tracker.sent(lossless: take, now: now)
        self.tracker = tracker
    }

    // MARK: Video

    private func plannedFPS() -> Int {
        let bytesPerSec = Double(max(100, lastBudget.videoKbps) * 1000 / 8)
        return max(5, min(request?.maxFPS ?? 30, Int(bytesPerSec / 6000)))
    }
    private func bucketCapacity() -> Double { Double(max(100, lastBudget.videoKbps) * 1000 / 8) * 0.35 }

    private func refill() {
        let now = Clock.nowNanos()
        let dt = Double(now - lastRefill) / 1e9
        lastRefill = now
        tokens = min(bucketCapacity(), tokens + dt * Double(max(100, lastBudget.videoKbps) * 1000 / 8))
        tokens = max(tokens, -3 * bucketCapacity())   // bound the debt a huge keyframe can create
    }

    private func tryEncode(now: UInt64, latest: ShiftDetector.Frame) {
        guard var enc = encoder, let req = request, let canvas, var tracker else { return }
        refill()
        let staleAfter = UInt64(max(3 * srttNanos, 1_000_000_000))
        for (s, f) in unacked where now - f.sentNanos > staleAfter {
            unacked[s] = nil; statLost += 1; requestRecovery()
        }
        if encoding { statDropped += 1; return }
        let inflightBytes = unacked.values.reduce(0) { $0 + $1.bytes }
        // In flight may not exceed what the link drains in one base RTT plus a little: the controller
        // backs off on queuing delay, so this cap only keeps our own burst from building a queue.
        let inflightBudget = Double(max(100, lastBudget.videoKbps) * 1000 / 8) * (srttNanos / 1e9 + 0.05)
        if !unacked.isEmpty && Double(inflightBytes) > inflightBudget { statSkippedBudget += 1; return }
        if tokens < 0 { statSkippedBudget += 1; return }
        let fraction = Double(pendingVideoRegion.area) / Double(tracker.width * tracker.height)
        let tierFPS = Double(rc?.policy.maxVideoFPS ?? req.maxFPS)
        let fpsCap: Double = min(tierFPS, fraction < 0.03 ? 15 : Double(req.maxFPS))
        let minInterval = UInt64(1e9 / min(fpsCap, Double(max(1, req.maxFPS))))
        if now - lastSendNanos < minInterval * 9 / 10 && !wantKeyframe { statDropped += 1; return }

        var opts = HEVCEncoder.FrameOptions()
        var region = pendingWholeFrame ? PixelRect(x: 0, y: 0, width: tracker.width, height: tracker.height) : pendingVideoRegion
        var tiles = pendingVideoTiles
        if wantKeyframe, var rc, rc.rung != RateController.tinyRung {
            // Lossy-first on recovery too: a keyframe at the current rung that would take more than ~1 s
            // of the video budget goes out on the tiny rung instead (the ladder climbs back afterwards).
            let estBytes = Double(enc.width * enc.height) * 0.025
            if estBytes > Double(max(150, lastBudget.videoKbps) * 1000 / 8) {
                rc.dropToTinyRung(now: now); self.rc = rc
                lastRebuildNanos = now
                log("lossy-first: recovery keyframe on the tiny rung (\(Int(estBytes / 1000)) KB estimated at rung \(rc.rung))")
            }
        }
        if wantKeyframe {
            // Recovery: the canvas must be the whole current picture. The mask leaves out tiles the
            // client already has pixel-exact, so a keyframe does not degrade crisp text elsewhere.
            CVPixelBufferLockBaseAddress(canvas, [])
            let dst = CVPixelBufferGetBaseAddress(canvas)!, ds = CVPixelBufferGetBytesPerRow(canvas)
            for y in 0..<latest.height { memcpy(dst.advanced(by: y * ds), latest.base.advanced(by: y * latest.stride), latest.width * 4) }
            CVPixelBufferUnlockBaseAddress(canvas, [])
            region = PixelRect(x: 0, y: 0, width: tracker.width, height: tracker.height)
            tiles = Set((0..<tracker.tileCount).filter { !tracker.isCrisp($0) })
            tiles.formUnion(pendingVideoTiles)
            tracker.markVideo(Array(tiles), now: now)
            self.tracker = tracker
            // Review #6: tiles the client already has crisp are masked out of this keyframe, so their
            // pixels are wasted bits; flatten each to its mean colour before encoding.
            flattenCanvas(canvas, except: tiles, tracker: tracker)
            // A forced keyframe ignores MinAllowedFrameQP (measured: ~125 KB regardless); a fresh
            // session's first IDR honours it (~18 KB). Recovery therefore replaces the session.
            if (try? rebuildEncoder()) != nil, let fresh = encoder { enc = fresh } else { opts.forceKeyframe = true }
            wantKeyframe = false; wantLTRRefresh = false
            keyframeArmed = true
        } else if enc.coarse && seq > 0 { enc.setCoarse(false) }
        if !keyframeArmed && wantLTRRefresh { opts.forceLTRRefresh = true }
        opts.acknowledgedLTRTokens = ackedLTR
        let recovery = keyframeArmed || wantLTRRefresh
        if recovery { lastRecoveryWasLTR = wantLTRRefresh && !keyframeArmed }
        keyframeArmed = false; wantLTRRefresh = false

        // Build the mask over the region's tile grid.
        let grid = TileMask.grid(for: region)
        var mask = TileMask(cols: grid.cols, rows: grid.rows)
        let c0 = region.x / TileTracker.tile, r0 = region.y / TileTracker.tile
        for i in tiles {
            let c = i % tracker.cols - c0, r = i / tracker.cols - r0
            if c >= 0, r >= 0, c < grid.cols, r < grid.rows { mask[c, r] = true }
        }
        // Encoder input: the canvas, scaled down at lower rungs.
        var input = canvas
        if let scaled, let transfer {
            guard VTPixelTransferSessionTransferImage(transfer, from: canvas, to: scaled) == noErr else { log("pixel transfer failed"); return }
            input = scaled
        }
        submitted = (tiles, region, pendingWholeFrame)
        pendingVideoTiles = []; pendingVideoRegion = .zero; pendingWholeFrame = false
        encoding = true
        lastSendNanos = now
        let captureSeq = self.captureSeq, inputSeq = self.lastInputSeq
        enc.encode(input, captureNanos: now, options: opts) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.encoding = false
                switch result {
                case .failure(let e):
                    // A rate-limited drop keeps the reference chain intact; the pending tiles ride the next frame.
                    if let s = self.submitted { self.pendingVideoTiles.formUnion(s.tiles); self.pendingVideoRegion = self.pendingVideoRegion.union(s.region); self.pendingWholeFrame = self.pendingWholeFrame || s.whole }
                    if case MirageError.transport(let t) = e, t.contains("dropped") { self.statDropped += 1 }
                    else { self.log("encode: \(e)"); self.wantKeyframe = true }
                case .success(let f):
                    self.send(f, recovery: recovery, region: region, mask: mask, captureSeq: captureSeq, inputSeq: inputSeq)
                }
                self.submitted = nil
            }
        }
    }

    private func send(_ f: HEVCEncoder.Encoded, recovery: Bool, region: PixelRect, mask: TileMask, captureSeq: UInt32, inputSeq: UInt64) {
        guard let out = output else { return }
        seq &+= 1
        var flags: VideoFragment.Flags = [.tileMask]
        if f.keyframe { flags.insert(.keyframe); flags.insert(.recovery) }
        if progressiveKeyframe && f.keyframe { flags.insert(.progressive); progressiveKeyframe = false }
        if recovery { flags.insert(.recovery) }
        if flags.contains(.recovery) { recoverySeq = seq; recoverySentNanos = Clock.nowNanos() }
        if !f.parameterSets.isEmpty { flags.insert(.parameterSets) }
        let payload = VideoFramePayload.encode(parameterSets: f.parameterSets, tileMask: mask.bits, sample: f.sample)
        let maxPayload = out.maxDatagramSize - VideoFragment.headerSize
        var frags = VideoFragment.fragments(frameSeq: seq, flags: flags, captureNanos: f.captureNanos, payload: payload, maxPayload: maxPayload,
                                            captureSeq: captureSeq, inputSeq: inputSeq, region: region)
        sentFrames[seq] = (Clock.nowNanos(), frags)
        for (k, v) in sentFrames where Clock.nowNanos() - v.nanos > 2_000_000_000 { sentFrames[k] = nil }
        // XOR parity on key/recovery frames always, on others when the link is losing packets: one lost
        // datagram per group of 8 is rebuilt by the viewer without a round trip.
        if flags.contains(.recovery) || (rc?.lossPercent ?? 0) > 0.5, frags.count >= 2 {
            let payloads = (0..<frags.count).map { i -> Data in let lo = payload.startIndex + i * maxPayload; return payload.subdata(in: lo..<min(lo + maxPayload, payload.endIndex)) }
            frags.append(contentsOf: ParityFragment.parity(frameSeq: seq, payloads: payloads))
        }
        // Intra-frame pacing (review §2.1): datagrams go out at ~1.25x the video budget in 5 ms slices
        // rather than as one burst, so a 25 KB frame or a keyframe never builds a queue on a 1 Mbps hop.
        let bytesPerSec = Double(max(150, lastBudget.videoKbps)) * 1000 / 8 * 1.25
        let perSlice = max(1, Int(bytesPerSec * 0.005 / Double(maxPayload)))
        if frags.count <= perSlice {
            for d in frags { out.sendDatagram(d) }
        } else {
            var i = 0, slice = 0
            while i < frags.count {
                let chunk = Array(frags[i..<min(frags.count, i + perSlice)])
                queue.asyncAfter(deadline: .now() + .milliseconds(5 * slice)) { for d in chunk { out.sendDatagram(d) } }
                i += perSlice; slice += 1
            }
        }
        tokens -= Double(payload.count)
        unacked[seq] = InFlight(sentNanos: Clock.nowNanos(), bytes: payload.count, ltrToken: f.ltrToken)
        statFrames += 1; statBytes += payload.count; statEncodeNanos += f.encodeNanos; secVideoBytes += payload.count; secVideoFrames += 1
        if f.keyframe {
            log("keyframe \(payload.count) bytes (\(frags.count) datagrams, \(mask.count) tiles masked)")
            switch fresh {
            case .base: fresh = .base(seq: seq); freshBaseSeq = seq
            case .climb: fresh = .climb(seq: seq)
            default:
                // A keyframe that replaces most of the picture is a fresh picture too (large invalidation).
                if mask.count * 10 >= (tracker?.tileCount ?? 1) * 4 { beginFreshPicture(reason: "large invalidation"); fresh = .base(seq: seq); freshBaseSeq = seq }
            }
        }
    }

    private func acked(_ ack: ControlMessage.FrameAck) {
        let now = Clock.nowNanos()
        if let f = unacked.removeValue(forKey: ack.seq) {
            // Loss acks come after the assembler's timeout; they say nothing about the path's RTT.
            if !ack.lost {
                let rtt = Double(now - f.sentNanos)
                srttNanos = srttNanos * 0.8 + rtt * 0.2
                rc?.frameAcked(sentNanos: f.sentNanos, firstReceived: ack.firstReceivedNanos ?? ack.receivedNanos, lastReceived: ack.receivedNanos,
                               fragments: ack.fragments ?? 1, bytes: f.bytes, now: now, rttNanos: rtt)
            }
            if !ack.lost, ack.decodedNanos != 0, ack.seq >= recoverySeq { lastRecoveryWasLTR = false }
            if !ack.lost, ack.decodedNanos != 0 { freshAcked(seq: ack.seq, now: now) }
            if !ack.lost, ack.decodedNanos != 0, let tok = f.ltrToken {
                ackedLTR.append(tok)
                if ackedLTR.count > 8 { ackedLTR.removeFirst(ackedLTR.count - 8) }
            }
        }
        for s in unacked.keys where s < ack.seq { unacked[s] = nil }
        if ack.lost { statLost += 1; rc?.lossDetected(now: now); if ack.seq >= recoverySeq { requestRecovery() } }
        // Safety net: a viewer still skipping (not decoding) frames newer than the last recovery for
        // over a second did not get that recovery frame; send another.
        if !ack.lost, ack.decodedNanos == 0, ack.seq > recoverySeq, now - recoverySentNanos > 1_500_000_000, !wantKeyframe {
            log("viewer skipping frames after recovery \(recoverySeq); resending keyframe")
            requestRecovery(); recoverySentNanos = now
        }
        applyBudget(now: now)
    }

    /// Pushes the controller's decisions into the encoder (rate, rung) at most every 500 ms.
    private var lastBudgetApply: UInt64 = 0
    private var lastRebuildNanos: UInt64 = 0
    private func applyBudget(now: UInt64) {
        guard let rc, now - lastBudgetApply > 500_000_000 else { return }
        lastBudgetApply = now
        let b = rc.budget(videoActive: now - videoActiveNanos < 500_000_000, recentTileKbps: Int(tileKbpsEWMA))
        let wantedWidth = max(64, Int(Double(target?.pixelWidth ?? 0) * rc.scale)) & ~1
        let rungChanged = encoder.map { wantedWidth != $0.width } ?? false
        // A rung change costs a keyframe: at most one per 5 s, and never to a *larger* picture while the link is queuing.
        let growing = encoder.map { wantedWidth > $0.width } ?? false
        if rungChanged, fresh == .done, now - lastRebuildNanos > 5_000_000_000, !(growing && rc.queueMs > 60) {
            lastBudget = b
            lastRebuildNanos = now
            if (try? rebuildEncoder()) != nil { wantKeyframe = true; log("ladder: rung \(rc.rung) (scale \(rc.scale)), target \(rc.targetKbps) kbps") }
        } else if abs(b.videoKbps - lastBudget.videoKbps) > lastBudget.videoKbps / 10 || b.tileKbps != lastBudget.tileKbps {
            lastBudget = b
            encoder?.setRate(bitrateKbps: b.videoKbps, expectedFPS: plannedFPS())
        }
    }

    /// Recovery defaults to a (QP-floored) keyframe from a fresh session. LTR refresh is opt-in (MIRAGE_LTR=1); see DESIGN §6 M1.
    private static let ltrEnabled = ProcessInfo.processInfo.environment["MIRAGE_LTR"] != nil
    private var lastRecoveryWasLTR = false
    private func requestRecovery() {
        if Self.ltrEnabled && !ackedLTR.isEmpty && !lastRecoveryWasLTR {
            wantLTRRefresh = true
        } else {
            wantKeyframe = true
        }
    }

    // MARK: Timers and stats

    private func startTimers() {
        let r = DispatchSource.makeTimerSource(queue: queue)
        r.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        r.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Clock.nowNanos()
            self.refine(now: now)
            if !self.pendingVideoTiles.isEmpty || self.wantKeyframe, let src = self.lastFrame {
                CVPixelBufferLockBaseAddress(src, .readOnly)
                self.tryEncode(now: now, latest: self.frameView(src))
                CVPixelBufferUnlockBaseAddress(src, .readOnly)
            }
            self.applyBudget(now: now)
        }
        r.resume(); refineTimer = r

        let s = DispatchSource.makeTimerSource(queue: queue)
        s.schedule(deadline: .now() + 1, repeating: 1)
        s.setEventHandler { [weak self] in
            guard let self, let rc = self.rc else { return }
            // The window list must not depend on captures: a static desktop produces none.
            if let w = self.windows?.sample(captureSeq: self.captureSeq, now: Clock.nowNanos()), w.changed {
                self.publishWindows(w.sample.windows, captureSeq: self.captureSeq, now: Clock.nowNanos())
            }
            self.flushWindows(now: Clock.nowNanos())
            self.output?.sendControl(.rateState(.init(targetKbps: rc.targetKbps, capacityKbps: rc.capacityKbps, queueMs: rc.queueMs, rung: rc.rung, scale: rc.scale,
                                                      tileBudgetKbps: self.lastBudget.tileKbps, videoKbps: self.secVideoBytes * 8 / 1000, tileKbps: self.secTileBytes * 8 / 1000, tier: rc.tier)))
            if rc.tier != self.lastTier {
                let first = self.lastTier == nil
                let previous = self.lastTier
                self.lastTier = rc.tier; self.log("link tier: \(rc.tier.name) (capacity \(rc.capacityKbps) kbps, srtt \(Int(rc.srttMs)) ms, loss \(String(format: "%.1f", rc.lossPercent)) %)")
                // A worse tier restarts lossy-first from the tiny rung; a better one just lets the ladder climb.
                if !first, self.fresh == .done, rc.tier.rawValue > (previous?.rawValue ?? 0) { self.rc?.dropToTinyRung(now: Clock.nowNanos()); self.lastRebuildNanos = Clock.nowNanos(); if (try? self.rebuildEncoder()) != nil { self.wantKeyframe = true; self.beginFreshPicture(reason: "tier change to \(rc.tier.name)") } }
            }
            self.tileKbpsEWMA = self.tileKbpsEWMA * 0.5 + Double(self.secTileBytes * 8 / 1000) * 0.5
            let capMs = self.effortCaptures > 0 ? Double(self.effortCaptureNanos) / Double(self.effortCaptures) / 1e6 : 0
            self.effortCaptureNanos = 0; self.effortCaptures = 0
            let pressure = HostEffort.measure(captureMs: capMs)
            if pressure.level != self.effort || !self.effortLogged {
                self.effortLogged = true
                self.effort = pressure.level
                self.detector.maxShift = self.effort.shiftSearch.maxShift
                self.log(String(format: "host effort: %@ (load/core %.2f, thermal %d, capture %.1f ms)", self.effort.rawValue, pressure.loadPerCore, pressure.thermal.rawValue, capMs))
            }
            let active = Clock.nowNanos() - self.videoActiveNanos < 1_000_000_000
            self.rc?.videoRate(achievedFPS: Double(self.secVideoFrames), wantedFPS: Double(min(self.request?.maxFPS ?? 30, rc.policy.maxVideoFPS)), active: active, now: Clock.nowNanos())
            self.secVideoBytes = 0; self.secTileBytes = 0; self.secVideoFrames = 0
            let front: (app: String, id: UInt32, title: String) = self.windows?.frontmost() ?? (app: "", id: 0, title: "")
            self.output?.sendControl(.hostStatus(.init(consoleLocked: InputInjector.consoleLocked(), frontmostApp: front.app, frontmostWindowID: front.id, frontmostWindowTitle: front.title)))
        }
        s.resume(); rateTimer = s

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let fps = Double(statFrames) / 5
            let vkbps = Double(statBytes) * 8 / 5 / 1000, tkbps = Double(statTileBytes) * 8 / 5 / 1000
            let enc = statFrames > 0 ? Double(statEncodeNanos) / Double(statFrames) / 1e6 : 0
            let capMs = statCaptures > 0 ? Double(statCaptureNanos) / Double(statCaptures) / 1e6 : 0
            log(String(format: "video %.1f fps %.0f kbps (%dx%d) | tiles %.0f kbps %d rects (refine %.0f kbps) copy-rects %d backlog %d skipped %d | captures %d (%.1f ms each) dirty %d pruned %d | target %d cap %d queue %.0f ms rung %d srtt %.0f ms | inflight %d skipped %d dropped %d lost %d encode %.1f ms input %d",
                       fps, vkbps, encoder?.width ?? 0, encoder?.height ?? 0, tkbps, statTileRects, Double(statRefineBytes) * 8 / 5 / 1000, statCopyRects, tracker?.pendingTotal ?? 0, statTileSkipped,
                       statCaptures, capMs, statDirtyTiles, statDiffPruned, rc?.targetKbps ?? 0, rc?.capacityKbps ?? 0, rc?.queueMs ?? 0, rc?.rung ?? 0, srttNanos / 1e6,
                       unacked.count, statSkippedBudget, statDropped, statLost, enc, statInput)
                + (statNacks > 0 ? " nacks \(statNacks) resent \(statNackResent)" : "") + " fresh \(fresh)"
                + String(format: " control %.0f kbps effort %@", Double(statControlBytes) * 8 / 5 / 1000, effortLevel))
            statControlBytes = 0
            statFrames = 0; statBytes = 0; statDropped = 0; statSkippedBudget = 0; statLost = 0; statEncodeNanos = 0; statInput = 0; statCaptures = 0; statCaptureNanos = 0; statNacks = 0; statNackResent = 0
            statTileBytes = 0; statTileRects = 0; statRefineBytes = 0; statCopyRects = 0; statDirtyTiles = 0; statDiffPruned = 0; statTileSkipped = 0
        }
        t.resume()
        statTimer = t
    }
}

/// TCC state the host needs; prompting adds `miraged` to the System Settings lists.
public enum HostPermissions {
    public static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }
    public static func accessibilityGranted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
    }
}
