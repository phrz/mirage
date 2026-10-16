import Foundation
import AppKit
import CoreVideo
import MirageCore

/// Everything the viewer knows about one host connection, published for SwiftUI.
@MainActor
final class ViewerModel: ObservableObject {
    @Published var status = "connecting…"
    @Published var error: String?
    @Published var stats = Stats()
    @Published var showStats = true
    @Published var cursor: CursorImage?
    @Published var remoteCursor: CGPoint? = nil      // normalized, host-reported
    @Published var streamInfo: ControlMessage.StreamInfo?
    @Published var bitrateKbps: Int
    @Published var pixelFactor: Double
    var statsLog: URL?

    struct Stats {
        var rttMs = 0.0, fps = 0.0, kbps = 0.0, frameAgeMs = 0.0, decodeMs = 0.0
        var lost = 0, frames = 0, dropped = 0
        var width = 0, height = 0
        // M2
        var tileKbps = 0.0, tileRects = 0, copyRects = 0
        var rate = ControlMessage.RateState(targetKbps: 0, capacityKbps: 0, queueMs: 0, rung: 0, scale: 1, tileBudgetKbps: 0, videoKbps: 0, tileKbps: 0)
        var predictions = (shown: 0, confirmed: 0, mismatched: 0, expired: 0)
        var upscaling = false
    }
    struct CursorImage {
        let image: NSImage
        let hotspot: CGPoint
        let size: CGSize
    }

    init(bitrateKbps: Int, pixelFactor: Double) { self.bitrateKbps = bitrateKbps; self.pixelFactor = pixelFactor }
}

/// Owns the connection; feeds decoded frames, tiles and copy-rects to the compositor, forwards input,
/// and runs the local scroll/drag prediction against the host's updates.
final class ViewerSession: @unchecked Sendable {
    let host: String
    let port: UInt16
    let pairCode: String?
    let model: ViewerModel
    private var client: QUICClient?
    private var control: MessageStream?
    private var sender: ControlSender?
    private var flow: MessageStream?
    private var tileStream: MessageStream?
    private let videoQueue = DispatchQueue(label: "mirage.viewer.video", qos: .userInteractive)
    private var assembler = FrameAssembler()
    private let decoder = HEVCDecoder()
    private var awaitingRecovery = false
    /// Sequence of the last decoded recovery frame: a loss verdict for an older frame is already healed.
    private var lastRecoverySeq: UInt32 = 0
    let compositor = Compositor()
    /// Called (on the video queue) whenever the picture changed and should be presented.
    var onChange: (() -> Void)?

    // Clock sync: hostNanos ≈ localNanos + offset. Guarded by statsLock together with the counters below.
    private var clockOffset: Double = 0
    private var bestRTT: Double = .infinity
    private var pingSeq: UInt64 = 0
    private let statsLock = NSLock()
    private var sFrames = 0, sBytes = 0, sLost = 0, sDecodeNanos: UInt64 = 0, sAge: Double = 0, sRTT = 0.0, sDropped = 0
    private var sTileBytes = 0, sTileRects = 0, sCopyRects = 0
    private var rateState = ControlMessage.RateState(targetKbps: 0, capacityKbps: 0, queueMs: 0, rung: 0, scale: 1, tileBudgetKbps: 0, videoKbps: 0, tileKbps: 0)
    @MainActor private var lastRequest: ControlMessage.StreamRequest?
    @MainActor private var pendingRequest: ControlMessage.StreamRequest?
    /// One entry per second, for --stats JSON output.
    struct Sample: Codable {
        var t: Double, rttMs: Double, frameAgeMs: Double, fps: Double, kbps: Double, decodeMs: Double, lost: Int, skipped: Int, width: Int, height: Int
        var tileKbps: Double, tileRects: Int, copyRects: Int, targetKbps: Int, capacityKbps: Int, queueMs: Double, rung: Int, scale: Double
        var tier: String?
    }
    private(set) var samples: [Sample] = []
    private let startDate = Date()
    private var lastMoveSent: UInt64 = 0
    private var pendingMove: ControlMessage.MouseMove?

    // Prediction state (predictorLock): window list from the host, predictor, band colours.
    private let predictorLock = NSLock()
    private var predictor = Predictor()
    private(set) var windows: [ControlMessage.WindowInfo] = []
    private var bandColors: [UInt32: SIMD4<Float>] = [:]
    private var inputSeq: UInt64 = 0
    /// Receiver clock of the last refinement-flagged tile batch (scenario time-to-crisp).
    private(set) var lastRefinementNanos: UInt64 = 0
    /// Scenario watch rect: last lossless tile / video frame that touched it.
    var watchRect: PixelRect = .zero
    private(set) var lastWatchedTileNanos: UInt64 = 0, lastWatchedVideoNanos: UInt64 = 0
    private(set) var watchedTileBytes = 0, watchedTileCount = 0
    static let debugTiles = ProcessInfo.processInfo.environment["MIRAGE_DEBUG_TILES"] != nil
    func resetWatched() { videoQueue.async { self.watchedTileBytes = 0; self.watchedTileCount = 0 } }
    func windowsSnapshot() -> [ControlMessage.WindowInfo] { predictorLock.lock(); defer { predictorLock.unlock() }; return windows }
    var scenario: ScenarioRunner?

    init(host: String, port: UInt16, pairCode: String?, model: ViewerModel) {
        self.host = host; self.port = port; self.pairCode = pairCode; self.model = model
    }

    func log(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }

    func start() {
        Task { await run() }
    }

    private func setStatus(_ s: String) { Task { @MainActor in model.status = s } }

    private func run() async {
        do {
            let store = try Store()
            let identity = try store.identity(role: "client", name: DeviceNames.current())
            let client = QUICClient(host: host, port: port)
            self.client = client
            try await client.connect()
            guard let fp = client.tlsFingerprint else { throw MirageError.transport("no TLS fingerprint") }
            let control = try await client.openStream()
            self.control = control
            let session = ClientSession(identity: identity, store: store, alias: host, tlsFingerprint: fp, stream: control)
            if let pairCode {
                guard let code = PairingCode.normalize(pairCode) else { throw MirageError.pairingFailed("--pair needs 6 digits") }
                let h = try await session.pair(code: code)
                log("paired with \(h.name)")
            }
            let welcome = try await session.authenticate()
            setStatus("authenticated to \(welcome.hostName)")
            sender = ControlSender(stream: control, log: { [weak self] in self?.log($0) })
            // Tile stream (reliable) and datagram flow, both before the stream request so the host finds them.
            let tiles = try await client.openStream()
            try await tiles.sendRaw(Data([tileStreamMagic]))
            tileStream = tiles
            Task.detached { [weak self] in await self?.receiveTiles(tiles) }
            let flow = try await client.openDatagramFlow()
            self.flow = flow
            try await flow.sendRaw(DatagramPing.encode(seq: 0))   // opens the flow on the host side
            Task.detached { [weak self] in await self?.receiveDatagrams(flow) }
            await MainActor.run { if let p = pendingRequest { pendingRequest = nil; requestStream(width: p.width, height: p.height) } }
            Task.detached { [weak self] in await self?.pingLoop() }
            Task.detached { [weak self] in await self?.statsLoop() }
            try await receiveControl(control)
        } catch {
            log("viewer: \(error)")
            Task { @MainActor in model.error = "\(error)"; model.status = "disconnected" }
        }
    }

    // MARK: Stream control

    func requestStream(width: Int, height: Int) {
        Task { @MainActor in
            let req = ControlMessage.StreamRequest(width: width, height: height, bitrateKbps: model.bitrateKbps, maxFPS: 30)
            if req == lastRequest { return }
            guard let sender else { pendingRequest = req; return }   // not connected yet; sent once the control stream is up
            lastRequest = req
            sender.send(.streamRequest(req))
        }
    }

    @MainActor func adjustBitrate(by delta: Int) {
        model.bitrateKbps = max(100, min(20_000, model.bitrateKbps + delta))
        if let r = lastRequest { lastRequest = nil; requestStream(width: r.width, height: r.height) }
    }

    // MARK: Receive loops

    private func receiveControl(_ control: MessageStream) async throws {
        while true {
            let msg = try await control.receive()
            switch msg {
            case .pong(let p):
                let now = Clock.nowNanos()
                let rtt = Double(now - p.sentNanos)
                statsLock.lock()
                if let echo = p.echoNanos, rtt < bestRTT {
                    bestRTT = rtt
                    clockOffset = Double(echo) - (Double(p.sentNanos) + rtt / 2)
                }
                sRTT = rtt / 1e6
                statsLock.unlock()
                predictorLock.lock(); predictor.timeoutNanos = UInt64(rtt * 3) + 500_000_000; predictorLock.unlock()
            case .streamInfo(let info):
                videoQueue.async { self.compositor?.configure(width: info.width, height: info.height); self.onChange?() }
                Task { @MainActor in model.streamInfo = info; model.status = "streaming \(info.width)x\(info.height) from \(host)" }
            case .cursorShape(let c):
                if let img = NSImage(data: c.png) {
                    Task { @MainActor in model.cursor = .init(image: img, hotspot: CGPoint(x: c.hotspotX, y: c.hotspotY), size: CGSize(width: c.width, height: c.height)) }
                }
            case .cursorPosition(let p):
                if probeLog { log(String(format: "host cursor at (%.3f, %.3f)", p.x, p.y)) }
                Task { @MainActor in model.remoteCursor = p.visible ? CGPoint(x: p.x, y: p.y) : nil }
            case .windowList(let list):
                predictorLock.lock(); windows = list.windows; predictorLock.unlock()
            case .rateState(let r):
                statsLock.lock(); rateState = r; statsLock.unlock()
            case .reject(let r):
                log("host: \(r.reason)")
                Task { @MainActor in model.error = r.reason; model.status = "host refused"; lastRequest = nil }   // a later resize/bitrate change retries
            default:
                log("unexpected control message: \(msg)")
            }
        }
    }

    private func receiveDatagrams(_ flow: MessageStream) async {
        while true {
            guard let d = try? await flow.receiveSome() else { log("datagram flow closed"); return }
            if let frag = VideoFragment.decode(d) {
                videoQueue.async { self.ingest(frag) }
            }
        }
    }

    private func receiveTiles(_ stream: MessageStream) async {
        var parser = TileStreamParser()
        while true {
            guard let d = try? await stream.receiveSome() else { log("tile stream closed"); return }
            do {
                for (seq, bytes, msg) in try parser.feed(d) {
                    let now = Clock.nowNanos()
                    videoQueue.async { self.apply(msg, seq: seq, bytes: bytes, now: now) }
                }
            } catch { log("tile stream: \(error)"); return }
        }
    }

    private func apply(_ msg: TileMessage, seq: UInt32, bytes: Int, now: UInt64) {
        switch msg {
        case .tiles(let t):
            let n = compositor?.applyTiles(t.tiles) ?? 0
            statsLock.lock(); sTileBytes += t.bytes; sTileRects += n; statsLock.unlock()
            if t.refinement { lastRefinementNanos = now }
            if !watchRect.isEmpty {
                let inside = t.tiles.filter { $0.rect.intersects(watchRect) }
                if !inside.isEmpty {
                    lastWatchedTileNanos = now; watchedTileBytes += inside.reduce(0) { $0 + $1.data.count }; watchedTileCount += inside.count
                    if Self.debugTiles { log("tiles\(t.refinement ? " (refine)" : "") seq \(t.header.captureSeq) in watch rect: " + inside.map { "\($0.rect.width)x\($0.rect.height)@\($0.rect.x),\($0.rect.y) \($0.data.count)B \($0.format)" }.joined(separator: "  ")) }
                }
            }
            predictorLock.lock()
            for tile in t.tiles { predictor.hostUpdate(inputSeq: t.header.inputSeq, rect: tile.rect, now: now) }
            predictorLock.unlock()
            sender?.send(.tileAck(.init(msgSeq: seq, captureNanos: t.header.captureNanos, receivedNanos: now, bytes: bytes)))
        case .copyRect(let c):
            compositor?.applyCopyRect(c.rect, dx: c.dx, dy: c.dy)
            statsLock.lock(); sCopyRects += 1; statsLock.unlock()
            predictorLock.lock()
            predictor.hostCopyRect(windowID: c.header.windowID, rect: c.rect, dx: c.dx, dy: c.dy, now: now)
            predictor.hostUpdate(inputSeq: c.header.inputSeq, rect: c.rect.union(c.rect.offset(c.dx, c.dy)), now: now)
            predictorLock.unlock()
            sender?.send(.tileAck(.init(msgSeq: seq, captureNanos: c.header.captureNanos, receivedNanos: now, bytes: bytes)))
        case .reset(let w, let h):
            compositor?.configure(width: w, height: h)
            compositor?.clear()
            predictorLock.lock(); predictor = Predictor(); predictorLock.unlock()
        }
        onChange?()
    }

    private func ingest(_ frag: VideoFragment) {
        let now = Clock.nowNanos()
        for ev in assembler.ingest(frag, now: now) {
            switch ev {
            case .lost(let seq):
                // The assembler gives up on an old partial after its timeout; if a recovery frame newer
                // than it was decoded meanwhile, nothing is missing (the host ignores such acks too).
                if seq > lastRecoverySeq { awaitingRecovery = true }
                statsLock.lock(); sLost += 1; statsLock.unlock()
                sender?.send(.frameAck(.init(seq: seq, captureNanos: 0, receivedNanos: now, decodedNanos: 0, bytes: 0, lost: true)))
            case .completed(let frame):
                statsLock.lock(); sBytes += frame.bytes; statsLock.unlock()
                if awaitingRecovery && !frame.flags.contains(.recovery) {
                    statsLock.lock(); sDropped += 1; statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: 0, bytes: frame.bytes, lost: false,
                                                 firstReceivedNanos: frame.firstFragmentNanos, fragments: frame.fragments)))
                    continue
                }
                let t0 = Clock.nowNanos()
                do {
                    let image = try decoder.decode(frame)
                    let t1 = Clock.nowNanos()
                    awaitingRecovery = false
                    if frame.flags.contains(.recovery) { lastRecoverySeq = max(lastRecoverySeq, frame.seq) }
                    if let compositor {
                        if compositor.width == 0 { compositor.configure(width: decoder.width, height: decoder.height) }
                        let region = frame.region.isEmpty ? PixelRect(x: 0, y: 0, width: compositor.width, height: compositor.height) : frame.region
                        let grid = TileMask.grid(for: region)
                        let mask = frame.tileMask.flatMap { TileMask(cols: grid.cols, rows: grid.rows, bits: $0) }
                        compositor.applyVideo(image, region: region, mask: mask)
                        if !watchRect.isEmpty, region.intersects(watchRect) { lastWatchedVideoNanos = now }
                        predictorLock.lock(); predictor.hostUpdate(inputSeq: frame.inputSeq, rect: region, now: now); predictorLock.unlock()
                        onChange?()
                    }
                    statsLock.lock()
                    sFrames += 1; sDecodeNanos += t1 - t0
                    if bestRTT.isFinite {   // frame age needs the clock offset from a pong first
                        let ageNanos = max(0, (Double(t1) + clockOffset) - Double(frame.captureNanos))
                        sAge = sAge == 0 ? ageNanos : sAge * 0.7 + ageNanos * 0.3
                    }
                    statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: t1, bytes: frame.bytes, lost: false,
                                                 firstReceivedNanos: frame.firstFragmentNanos, fragments: frame.fragments)))
                } catch {
                    log("decode seq \(frame.seq): \(error)")
                    awaitingRecovery = true
                    statsLock.lock(); sLost += 1; statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: 0, bytes: frame.bytes, lost: true,
                                                 firstReceivedNanos: frame.firstFragmentNanos, fragments: frame.fragments)))
                }
            }
        }
    }

    private func pingLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(1))
            pingSeq += 1
            sender?.send(.ping(.init(seq: pingSeq, sentNanos: Clock.nowNanos())))
        }
    }

    private func statsLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(1))
            statsLock.lock()
            let frames = sFrames, bytes = sBytes, lost = sLost, dec = sDecodeNanos, age = sAge, rtt = sRTT, dropped = sDropped
            let tileBytes = sTileBytes, tileRects = sTileRects, copies = sCopyRects, rate = rateState
            sFrames = 0; sBytes = 0; sLost = 0; sDecodeNanos = 0; sDropped = 0; sTileBytes = 0; sTileRects = 0; sCopyRects = 0
            statsLock.unlock()
            predictorLock.lock(); let pstats = predictor.stats; predictorLock.unlock()
            let w = decoder.width, h = decoder.height
            let upscaling = compositor?.usesMetalFX ?? false
            await MainActor.run {
                var s = model.stats
                s.fps = Double(frames); s.kbps = Double(bytes) * 8 / 1000; s.lost += lost; s.frames += frames; s.dropped += dropped
                s.decodeMs = frames > 0 ? Double(dec) / Double(frames) / 1e6 : s.decodeMs
                s.frameAgeMs = age / 1e6; s.rttMs = rtt; s.width = w; s.height = h
                s.tileKbps = Double(tileBytes) * 8 / 1000; s.tileRects += tileRects; s.copyRects += copies; s.rate = rate; s.predictions = pstats; s.upscaling = upscaling
                model.stats = s
                if frames > 0 || bytes > 0 || tileBytes > 0 {
                    samples.append(Sample(t: Date().timeIntervalSince(startDate), rttMs: rtt, frameAgeMs: age / 1e6, fps: Double(frames), kbps: Double(bytes) * 8 / 1000,
                                          decodeMs: s.decodeMs, lost: lost, skipped: dropped, width: w, height: h,
                                          tileKbps: s.tileKbps, tileRects: tileRects, copyRects: copies, targetKbps: rate.targetKbps, capacityKbps: rate.capacityKbps,
                                          queueMs: rate.queueMs, rung: rate.rung, scale: rate.scale, tier: rate.tier?.name))
                }
                if let url = model.statsLog {
                    let line = String(format: "%@ rtt %.0f age %.0f fps %.1f kbps %.0f tiles %.0f target %d cap %d queue %.0f rung %d decode %.1f lost %d skipped %d size %dx%d\n",
                                      ISO8601DateFormatter().string(from: Date()), s.rttMs, s.frameAgeMs, s.fps, s.kbps, s.tileKbps, rate.targetKbps, rate.capacityKbps, rate.queueMs, rate.rung, s.decodeMs, lost, dropped, w, h)
                    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
                }
            }
        }
    }

    // MARK: Input

    private func nextSeq() -> UInt64 { predictorLock.lock(); defer { predictorLock.unlock() }; inputSeq += 1; return inputSeq }

    func sendMouseMove(x: Double, y: Double) {
        // Coalesce to ~60 Hz; the control stream is ordered so later moves supersede earlier ones anyway.
        let now = Clock.nowNanos()
        if now - lastMoveSent < 15_000_000 { pendingMove = .init(x: x, y: y); scheduleMoveFlush(); return }
        lastMoveSent = now; pendingMove = nil
        sender?.send(.mouseMove(.init(x: x, y: y, seq: nextSeq())))
    }
    private var flushScheduled = false
    private func scheduleMoveFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [self] in
            flushScheduled = false
            if var m = pendingMove { pendingMove = nil; lastMoveSent = Clock.nowNanos(); m.seq = nextSeq(); sender?.send(.mouseMove(m)) }
        }
    }
    /// Sends an input message with a fresh sequence number; returns the number.
    @discardableResult
    func send(_ m: ControlMessage) -> UInt64 {
        let seq = nextSeq()
        var m = m
        switch m {
        case .mouseButton(var b): b.seq = seq; m = .mouseButton(b)
        case .scroll(var s): s.seq = seq; m = .scroll(s)
        case .key(var k): k.seq = seq; m = .key(k)
        case .mouseMove(var mm): mm.seq = seq; m = .mouseMove(mm)
        default: break
        }
        sender?.send(m)
        return seq
    }

    // MARK: Prediction

    /// Stream pixels per host display point (for scroll deltas and title-bar heights).
    @MainActor var pixelsPerPoint: Double {
        guard let i = model.streamInfo, i.displayWidth > 0 else { return 2 }
        return Double(i.width) / Double(i.displayWidth)
    }

    /// Topmost host window under a stream-pixel point.
    func window(at x: Int, _ y: Int) -> ControlMessage.WindowInfo? {
        predictorLock.lock(); defer { predictorLock.unlock() }
        return windows.first { $0.frame.contains(x, y) }
    }

    /// The rect a wheel event over `window` should shift: the host's learned scroll rect, else the content area below the title bar.
    func scrollRect(for w: ControlMessage.WindowInfo, titleBarPx: Int) -> PixelRect {
        if let r = w.scrollRect { return r }
        return PixelRect(x: w.frame.x, y: w.frame.y + titleBarPx, width: w.frame.width, height: max(0, w.frame.height - titleBarPx))
    }

    func predict(kind: Predictor.Kind, windowID: UInt32, rect: PixelRect, dx: Int, dy: Int, inputSeq: UInt64) {
        let now = Clock.nowNanos()
        predictorLock.lock()
        predictor.predict(kind: kind, windowID: windowID, rect: rect, dx: dx, dy: dy, inputSeq: inputSeq, now: now)
        let needColor = bandColors[windowID] == nil
        predictorLock.unlock()
        if needColor, let c = compositor {
            videoQueue.async {
                c.sampleEdgeColor(of: rect, bottom: dy < 0) { [weak self] color in
                    guard let self else { return }
                    self.predictorLock.lock(); self.bandColors[windowID] = color; self.predictorLock.unlock()
                }
            }
        }
        onChange?()
    }

    /// Current displacements for the renderer (also expires stale predictions).
    func displacements() -> ([Predictor.Displacement], [UInt32: SIMD4<Float>]) {
        predictorLock.lock(); defer { predictorLock.unlock() }
        predictor.expire(now: Clock.nowNanos())
        return (predictor.displacements(), bandColors)
    }
    var hasPendingPredictions: Bool { predictorLock.lock(); defer { predictorLock.unlock() }; return predictor.hasPending }

    var probeLog = false
    /// Headless input check: moves the pointer across the host display, opens and closes Spotlight
    /// (⌘Space, Esc). The host echoes its cursor position on the control stream, which proves the
    /// mouse path end to end; the key path shows up as a dirty-area burst in the host log.
    func probeInput() async {
        probeLog = true
        log("probe: moving pointer")
        for (x, y) in [(0.25, 0.25), (0.75, 0.25), (0.75, 0.75), (0.25, 0.75), (0.5, 0.5)] {
            send(.mouseMove(.init(x: x, y: y)))
            try? await Task.sleep(for: .milliseconds(300))
        }
        try? await Task.sleep(for: .seconds(1))
        let cmd: UInt64 = 1 << 20   // kCGEventFlagMaskCommand
        log("probe: ⌘Space")
        send(.modifiers(.init(keyCode: 55, modifiers: cmd)))
        send(.key(.init(keyCode: 49, down: true, isRepeat: false, modifiers: cmd, characters: " ")))
        send(.key(.init(keyCode: 49, down: false, isRepeat: false, modifiers: cmd, characters: nil)))
        send(.modifiers(.init(keyCode: 55, modifiers: 0)))
        try? await Task.sleep(for: .seconds(2))
        log("probe: Esc")
        send(.key(.init(keyCode: 53, down: true, isRepeat: false, modifiers: 0, characters: "\u{1B}")))
        send(.key(.init(keyCode: 53, down: false, isRepeat: false, modifiers: 0, characters: nil)))
        try? await Task.sleep(for: .seconds(1))
        probeLog = false
    }

    func stop() {
        sender?.send(.streamStop)
        client?.close()
    }
}


extension ViewerSession {
    /// Aggregates for --stats: medians over the steady state (first 3 s dropped), plus totals.
    func statsJSON() -> Data {
        let steady = samples.count > 5 ? Array(samples.dropFirst(3)) : samples
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        func p95(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.95))] }
        struct Out: Codable {
            var host: String, seconds: Double, targetKbps: Int, width: Int, height: Int
            var fpsMedian: Double, kbpsMedian: Double, frameAgeMsMedian: Double, frameAgeMsP95: Double, rttMsMedian: Double, rttMsMin: Double, decodeMsMedian: Double
            var tileKbpsMedian: Double, totalKbpsMedian: Double, controllerTargetKbpsMedian: Double, capacityKbpsMedian: Double, queueMsMedian: Double, queueMsP95: Double, rungMax: Int, rungFinal: Int
            var framesTotal: Int, lostTotal: Int, skippedTotal: Int, tileRectsTotal: Int, copyRectsTotal: Int
            var predictionsShown: Int, predictionsConfirmed: Int, predictionsMismatched: Int
            var scenario: String?, crispMs: [Double]?, crispMsMedian: Double?, crispMsMax: Double?
            var watchedTileBytes: Int?, watchedTileCount: Int?, watchedKbps: Double?
            var samples: [Sample]
        }
        let target = MainActor.assumeIsolated { lastRequest?.bitrateKbps ?? 0 }
        let pstats = MainActor.assumeIsolated { model.stats.predictions }
        let out = Out(host: host, seconds: samples.last?.t ?? 0, targetKbps: target,
                      width: samples.last?.width ?? 0, height: samples.last?.height ?? 0,
                      fpsMedian: median(steady.map(\.fps)), kbpsMedian: median(steady.map(\.kbps)),
                      frameAgeMsMedian: median(steady.map(\.frameAgeMs)), frameAgeMsP95: p95(steady.map(\.frameAgeMs)),
                      rttMsMedian: median(steady.map(\.rttMs)), rttMsMin: steady.map(\.rttMs).filter { $0 > 0 }.min() ?? 0,
                      decodeMsMedian: median(steady.map(\.decodeMs)),
                      tileKbpsMedian: median(steady.map(\.tileKbps)), totalKbpsMedian: median(steady.map { $0.kbps + $0.tileKbps }),
                      controllerTargetKbpsMedian: median(steady.map { Double($0.targetKbps) }), capacityKbpsMedian: median(steady.map { Double($0.capacityKbps) }),
                      queueMsMedian: median(steady.map(\.queueMs)), queueMsP95: p95(steady.map(\.queueMs)),
                      rungMax: samples.map(\.rung).max() ?? 0, rungFinal: samples.last?.rung ?? 0,
                      framesTotal: Int(samples.map(\.fps).reduce(0, +)), lostTotal: samples.map(\.lost).reduce(0, +), skippedTotal: samples.map(\.skipped).reduce(0, +),
                      tileRectsTotal: samples.map(\.tileRects).reduce(0, +), copyRectsTotal: samples.map(\.copyRects).reduce(0, +),
                      predictionsShown: pstats.shown, predictionsConfirmed: pstats.confirmed, predictionsMismatched: pstats.mismatched,
                      scenario: scenario?.name, crispMs: scenario?.crispMs, crispMsMedian: scenario.map { median($0.crispMs) }, crispMsMax: scenario?.crispMs.max(),
                      watchedTileBytes: scenario == nil ? nil : watchedTileBytes, watchedTileCount: scenario == nil ? nil : watchedTileCount,
                      watchedKbps: scenario.map { Double(watchedTileBytes) * 8 / 1000 / max(1, $0.activeSeconds) },
                      samples: samples)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(out)) ?? Data()
    }
}
