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
    /// Forward no local input (a scripted run is being watched).
    var observeOnly = false
    @Published var hostStatus: ControlMessage.HostStatus?
    /// Non-nil while the connection is down: (attempt number, seconds until the next try).
    @Published var reconnecting: (attempt: Int, inSeconds: Int)? = nil
    /// Seconds without any packet from the host while connected (0 = fine).
    @Published var stalledSeconds = 0
    /// Input channel: events waiting for the host's ack, dropped by the cap, and whether a decision is pending.
    @Published var inputQueued = 0
    @Published var inputDropped = 0
    @Published var inputHeld = false

    struct Stats {
        var rttMs = 0.0, fps = 0.0, kbps = 0.0, frameAgeMs = 0.0, decodeMs = 0.0
        var lost = 0, frames = 0, dropped = 0
        var width = 0, height = 0
        // M2
        var tileKbps = 0.0, tileRects = 0, copyRects = 0
        var rate = ControlMessage.RateState(targetKbps: 0, capacityKbps: 0, queueMs: 0, rung: 0, scale: 1, tileBudgetKbps: 0, videoKbps: 0, tileKbps: 0)
        var predictions = (shown: 0, confirmed: 0, mismatched: 0, expired: 0)
        var upscaling = false
        var nacks = 0, recoveredByNack = 0, recoveredByParity = 0, bursts = 0
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
    private var fastTileStream: MessageStream?
    /// Capture sequence last applied per 64-px tile: a refinement that was queued before a newer
    /// interactive update of the same tile must not overwrite it.
    private var tileCaptureSeq: [UInt32] = []
    private(set) var hostStatus: ControlMessage.HostStatus?
    private let videoQueue = DispatchQueue(label: "mirage.viewer.video", qos: .userInteractive)
    private var assembler = FrameAssembler()
    private var assemblerTimer: DispatchSourceTimer?
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
    private var sTileBytes = 0, sTileRects = 0, sCopyRects = 0, sNacks = 0, sBursts = 0
    private var rateState = ControlMessage.RateState(targetKbps: 0, capacityKbps: 0, queueMs: 0, rung: 0, scale: 1, tileBudgetKbps: 0, videoKbps: 0, tileKbps: 0)
    @MainActor private var lastRequest: ControlMessage.StreamRequest?
    @MainActor private var pendingRequest: ControlMessage.StreamRequest?
    /// One entry per second, for --stats JSON output.
    struct Sample: Codable {
        var t: Double, rttMs: Double, frameAgeMs: Double, fps: Double, kbps: Double, decodeMs: Double, lost: Int, skipped: Int, width: Int, height: Int
        var tileKbps: Double, tileRects: Int, copyRects: Int, targetKbps: Int, capacityKbps: Int, queueMs: Double, rung: Int, scale: Double
        var tier: String?
    }
    private(set) var samples: [Sample] = []   // appended on the main actor; read by the scenario runner (benign race on a value array)
    private let startDate = Date()
    private var lastMoveSent: UInt64 = 0
    private var pendingMove: ControlMessage.MouseMove?

    // Prediction state (predictorLock): window list from the host, predictor, band colours.
    private let predictorLock = NSLock()
    private var predictor = Predictor()
    private(set) var windows: [ControlMessage.WindowInfo] = []
    private var bandColors: [UInt32: SIMD4<Float>] = [:]
    /// Receiver clock of the last refinement-flagged tile batch (scenario time-to-crisp).
    private(set) var lastRefinementNanos: UInt64 = 0
    /// Scenario watch rect: last lossless tile / video frame that touched it.
    var watchRect: PixelRect = .zero
    private(set) var lastWatchedTileNanos: UInt64 = 0, lastWatchedVideoNanos: UInt64 = 0, lastWatchedCopyNanos: UInt64 = 0
    private(set) var watchedVideoFrames = 0, watchedCopyRects = 0
    private(set) var watchedTileBytes = 0, watchedTileCount = 0, watchedDirectBytes = 0
    /// Foveation metric: the first lossless tile within ~100 px of the pointer after the stream started.
    private var pointerRect: PixelRect = .zero
    private var streamStartNanos: UInt64 = 0
    private(set) var legibleUnderPointerMs: Double? = nil
    private var refinementLogged = 0
    /// Receiver clock of the last lossless tile per 64-px tile (for the legibility metric).
    private var losslessAt: [UInt64] = []
    static let debugTiles = ProcessInfo.processInfo.environment["MIRAGE_DEBUG_TILES"] != nil
    func resetWatched() { videoQueue.async { self.watchedTileBytes = 0; self.watchedTileCount = 0; self.watchedDirectBytes = 0; self.watchedVideoFrames = 0; self.watchedCopyRects = 0 } }
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
    private var stopped = false

    /// Connects, and reconnects forever with exponential backoff (1, 2, 4, 8, then 15 s) until the
    /// window is closed. The last picture stays on screen meanwhile; the stream is re-requested on
    /// every reconnect. A 15 s handshake limit per attempt is fine; giving up is not.
    private func run() async {
        var attempt = 0
        while !stopped {
            let t0 = Date()
            let failure = await connectOnce()
            if stopped { return }
            // A session that lasted a while resets the backoff; a quick failure escalates it.
            if Date().timeIntervalSince(t0) > 30 { attempt = 0 }
            attempt += 1
            var delay = attempt >= 5 ? 15 : 1 << (attempt - 1)
            // While the host may still hold our session (resume window), dial every second with a 4 s
            // timeout: the §4a bar is "back within 2 s of the path returning", a failed dial costs one
            // 1.2 KB datagram, and QUIC's own Initial retransmits back off too slowly to meet it alone.
            if resumable { delay = min(delay, 1) }
            log("viewer: \(failure); reconnecting in \(delay) s (attempt \(attempt))")
            await MainActor.run {
                model.reconnecting = (attempt, delay)
                model.status = "reconnecting… (attempt \(attempt), \(failure))"
                lastRequest = nil   // re-request the stream once the new connection is up
                if pendingRequest == nil, let r = lastRequestSent { pendingRequest = r }
            }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// The stream request we last sent, kept across reconnects.
    @MainActor private var lastRequestSent: ControlMessage.StreamRequest?
    /// Resume token from the host's last Welcome; presented on every reconnect (DESIGN §4a outage survival).
    private(set) var resumeToken: Data?
    private var disconnectedAt: Date?
    private var resumable: Bool { resumeToken != nil && Date().timeIntervalSince(disconnectedAt ?? Date()) < Double(Mirage.resumeWindowSeconds) }
    /// Receiver clock of the last packet of any kind from the host (stall watchdog).
    private var lastHostPacketNanos: UInt64 = 0
    private var connectedAtNanos: UInt64 = 0
    /// Connection generation: closures queued by a dead connection's receive loops must not touch the new one's state.
    private var gen = 0
    private var receiveTasks: [Task<Void, Never>] = []
    private(set) var resumes = 0, reconnects = 0
    /// Receiver clock when the picture last changed and the longest gap between picture changes (freeze metric).
    private var lastPictureNanos: UInt64 = 0
    private(set) var maxPictureGapMs = 0.0
    private(set) var pictureGapsOver500 = 0
    private var lastResumeNanos: UInt64 = 0
    private(set) var resumeToPictureMs: [Double] = []
    /// Video-only freeze metric: the longest gap between decoded frames after the first 3 s of a connection
    /// (tiles ride a reliable stream the loss injector does not touch, so they would mask video stalls).
    private var lastVideoNanos: UInt64 = 0
    var steadyAfterNanos: UInt64 = 3_000_000_000
    private(set) var maxVideoGapMs = 0.0
    private(set) var videoGapsOver500: [Double] = []

    /// One connection's life: returns the reason it ended.
    private func connectOnce() async -> String {
        // Per-connection state; the compositor's picture is deliberately kept.
        let myGen = videoQueue.sync { () -> Int in gen += 1; assembler = FrameAssembler(); awaitingRecovery = resumeToken != nil; lastRecoverySeq = 0; tileCaptureSeq = []; return gen }
        sender = nil
        for t in receiveTasks { t.cancel() }
        receiveTasks = []
        let client = QUICClient(host: host, port: port)
        self.client = client
        defer { client.close(); disconnectedAt = Date(); statsLock.lock(); hostStatus = nil; statsLock.unlock() }   // review M5: no leaked groups
        do {
            let store = try Store()
            let identity = try store.identity(role: "client", name: DeviceNames.current())
            try await client.connect(timeout: resumable ? 4 : 15)
            guard let fp = client.tlsFingerprint else { throw MirageError.transport("no TLS fingerprint") }
            let control = try await client.openStream()
            self.control = control
            let session = ClientSession(identity: identity, store: store, alias: host, tlsFingerprint: fp, stream: control)
            if let pairCode {
                guard let code = PairingCode.normalize(pairCode) else { throw MirageError.pairingFailed("--pair needs 6 digits") }
                let h = try await session.pair(code: code)
                log("paired with \(h.name)")
            }
            let welcome = try await session.authenticate(resumeToken: resumeToken)
            let resumed = welcome.resumed == true
            if resumeToken != nil { if resumed { resumes += 1 } else { reconnects += 1 } }
            if let t = welcome.resumeToken { resumeToken = t }
            if resumeToken != nil, !resumed {
                // The host did not know us (restarted, or the window passed): a fresh stream follows. The
                // picture stays until its first keyframe replaces it; predictions from the old session are void.
                predictorLock.lock(); predictor = Predictor(); predictorLock.unlock()
                videoQueue.sync { awaitingRecovery = false }
            }
            log(resumed ? "session resumed by \(welcome.hostName) (\(disconnectedAt.map { String(format: "%.1f s gap", Date().timeIntervalSince($0)) } ?? ""))" : "authenticated to \(welcome.hostName)")
            setStatus(resumed ? "resumed session with \(welcome.hostName)" : "authenticated to \(welcome.hostName)")
            sender = ControlSender(stream: control, log: { [weak self] in self?.log($0) })
            // Tile stream (reliable) and datagram flow, both before the stream request so the host finds them.
            let tiles = try await client.openStream()
            try await tiles.sendRaw(Data([tileStreamMagic]))
            tileStream = tiles
            receiveTasks.append(Task.detached { [weak self] in await self?.receiveTiles(tiles, gen: myGen) })
            let fast = try await client.openStream()
            try await fast.sendRaw(Data([fastTileStreamMagic]))
            fastTileStream = fast
            receiveTasks.append(Task.detached { [weak self] in await self?.receiveTiles(fast, gen: myGen) })
            let flow = try await client.openDatagramFlow()
            self.flow = flow
            pingSeq += 1
            try await flow.sendRaw(DatagramPing.encode(seq: pingSeq))   // opens the flow on the host side; first RTT sample
            receiveTasks.append(Task.detached { [weak self] in await self?.receiveDatagrams(flow, gen: myGen) })
            let now = Clock.nowNanos()
            statsLock.lock(); lastHostPacketNanos = now; connectedAtNanos = now; if resumed { lastResumeNanos = now }; statsLock.unlock()
            // Path changes (Wi-Fi ↔ cellular): Network.framework reports viability and better paths per
            // connection. QUIC migration itself is up to the framework; if the path came back and the
            // connection is still stalled, the watchdog redials at once instead of waiting for its timeout.
            control.connection.viabilityUpdateHandler = { [weak self] viable in self?.log("path \(viable ? "viable" : "not viable")"); if viable { self?.pathChanged() } }
            control.connection.betterPathUpdateHandler = { [weak self] better in if better { self?.log("a better path is available"); self?.pathChanged() } }
            log("connected: control, tile streams and datagram flow up")
            await MainActor.run { if let p = pendingRequest { pendingRequest = nil; requestStream(width: p.width, height: p.height) } }
            await MainActor.run { model.reconnecting = nil; model.error = nil }
            startLoopsOnce()
            try await receiveControl(control)
            return "control stream ended"
        } catch {
            return "\(error)"
        }
    }

    /// The path changed under a stalled connection: redial now (the host resumes the session).
    private func pathChanged() {
        statsLock.lock(); let stalled = lastHostPacketNanos > 0 && Clock.nowNanos() - lastHostPacketNanos > 2_000_000_000; statsLock.unlock()
        if stalled { log("path changed while stalled: redialing"); dropConnection() }
    }

    /// Tears the current connection down so `connectOnce` returns and the reconnect loop dials again.
    /// Cancelling the group alone leaves extracted streams pending (observed on macOS 27), so each is cancelled.
    private func dropConnection() {
        control?.cancel(); tileStream?.cancel(); fastTileStream?.cancel(); flow?.cancel()
        client?.close()
    }

    /// Stall watchdog (once a second): no packet of any kind from the host for 12 s while connected
    /// means the path or the host is gone; drop the connection and redial (the resume token brings the
    /// same session back). QUIC's own idle timeout is 45 s so a shorter outage never closes anything.
    private func watchdog(now: UInt64) {
        statsLock.lock(); let last = lastHostPacketNanos, since = connectedAtNanos; statsLock.unlock()
        guard sender != nil, last > 0, since > 0 else { return }
        let silent = Double(now - last) / 1e9
        if silent > 12 {
            log(String(format: "no packet from the host for %.0f s: redialing", silent))
            statsLock.lock(); lastHostPacketNanos = 0; statsLock.unlock()
            dropConnection()
        } else if silent > 3 {
            Task { @MainActor in model.stalledSeconds = Int(silent) }
        } else {
            Task { @MainActor in if model.stalledSeconds != 0 { model.stalledSeconds = 0 } }
        }
    }

    private func noteHostPacket(_ now: UInt64) { statsLock.lock(); lastHostPacketNanos = now; statsLock.unlock() }
    /// The picture changed: freeze metric and resume-to-picture time.
    private func notePictureChange(_ now: UInt64) {
        statsLock.lock(); let connectedAt = connectedAtNanos, resumedAt = lastResumeNanos; statsLock.unlock()
        if connectedAt > 0 {
            // Gaps count across reconnects: the person sees one frozen picture either way.
            let base = lastPictureNanos > 0 ? lastPictureNanos : connectedAt
            let gap = now > base ? Double(now - base) / 1e6 : 0
            if gap > maxPictureGapMs { maxPictureGapMs = gap }
            if gap > 500 { pictureGapsOver500 += 1 }
        }
        lastPictureNanos = max(lastPictureNanos, now)
        if resumedAt > 0, now >= resumedAt {
            resumeToPictureMs.append(Double(now - resumedAt) / 1e6)
            statsLock.lock(); lastResumeNanos = 0; statsLock.unlock()
        }
    }

    private var loopsStarted = false
    private func startLoopsOnce() {
        guard !loopsStarted else { return }
        loopsStarted = true
        let t = DispatchSource.makeTimerSource(queue: videoQueue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.assemblerTick() }
        t.resume()
        assemblerTimer = t
        Task.detached { [weak self] in await self?.pingLoop() }
        Task.detached { [weak self] in await self?.statsLoop() }
        startInputTimer()
    }

    // MARK: Stream control

    func requestStream(width: Int, height: Int) {
        Task { @MainActor in
            let req = ControlMessage.StreamRequest(width: width, height: height, bitrateKbps: model.bitrateKbps, maxFPS: 30)
            if req == lastRequest { return }
            guard let sender else { pendingRequest = req; log("stream request \(width)x\(height) queued until connected"); return }
            lastRequest = req; lastRequestSent = req
            log("stream request \(width)x\(height) cap \(req.bitrateKbps) kbps")
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
            noteHostPacket(Clock.nowNanos())
            switch msg {
            case .pong(let p):
                rttSample(sentNanos: p.sentNanos, echoNanos: p.echoNanos, now: Clock.nowNanos())
            case .streamInfo(let info):
                videoQueue.async {
                    // A new or resumed stream: the picture is kept (same size) until the host's first keyframe
                    // or masked keyframe replaces what changed; the assembler starts over (review M4).
                    self.compositor?.configure(width: info.width, height: info.height); self.onChange?()
                    self.assembler = FrameAssembler(); self.lastRecoverySeq = 0
                    self.streamStartNanos = Clock.nowNanos(); self.legibleUnderPointerMs = nil; self.losslessAt = []
                }
                Task { @MainActor in model.streamInfo = info; model.status = "streaming \(info.width)x\(info.height) from \(host)" }
            case .cursorShape(let c):
                if let img = NSImage(data: c.png) {
                    Task { @MainActor in model.cursor = .init(image: img, hotspot: CGPoint(x: c.hotspotX, y: c.hotspotY), size: CGSize(width: c.width, height: c.height)) }
                }
            case .cursorPosition(let p):
                if probeLog { log(String(format: "host cursor at (%.3f, %.3f)", p.x, p.y)) }
                Task { @MainActor in model.remoteCursor = p.visible ? CGPoint(x: p.x, y: p.y) : nil }
            case .windowList(let list):
                predictorLock.lock(); windows = list.apply(to: windows); predictorLock.unlock()
            case .rateState(let r):
                statsLock.lock(); rateState = r; statsLock.unlock()
            case .hostStatus(let h):
                statsLock.lock(); hostStatus = h; statsLock.unlock()
                Task { @MainActor in model.hostStatus = h }
            case .reject(let r):
                log("host: \(r.reason)")
                Task { @MainActor in model.error = r.reason; model.status = "host refused"; lastRequest = nil }   // a later resize/bitrate change retries
            default:
                log("unexpected control message: \(msg)")
            }
        }
    }

    /// RTT and clock offset from a ping echo (stream pong or datagram ping).
    private func rttSample(sentNanos: UInt64, echoNanos: UInt64?, now: UInt64) {
        let rtt = Double(now &- sentNanos)
        statsLock.lock()
        if let echo = echoNanos, echo != 0, rtt < bestRTT {
            bestRTT = rtt
            clockOffset = Double(echo) - (Double(sentNanos) + rtt / 2)
        }
        sRTT = rtt / 1e6
        statsLock.unlock()
        predictorLock.lock(); predictor.timeoutNanos = UInt64(rtt * 3) + 500_000_000; predictorLock.unlock()
        inputQueue.async { self.input.setRTT(nanos: UInt64(rtt)) }
    }

    private func receiveDatagrams(_ flow: MessageStream, gen myGen: Int) async {
        while !Task.isCancelled {
            guard let d = try? await flow.receiveSome() else { log("datagram flow closed"); return }
            let now = Clock.nowNanos()
            noteHostPacket(now)
            if let frag = VideoFragment.decode(d) {
                videoQueue.async { guard myGen == self.gen else { return }; self.ingest(frag) }
            } else if let parity = ParityFragment.decode(d) {
                videoQueue.async { guard myGen == self.gen else { return }; self.handle(self.assembler.ingest(parity: parity, now: Clock.nowNanos()), now: Clock.nowNanos()) }
            } else if let ack = InputAck.decode(d) {
                inputAck(ack)
            } else if let ping = DatagramPing.decode(d) {
                if ping.echoNanos == 0 {
                    // A host delay probe: stamp it with our clock and send it straight back (the host's
                    // serialization-free one-way-delay sample for its rate controller).
                    flow.connection.send(content: DatagramPing.echo(d, now: now), completion: .contentProcessed { _ in })
                } else {
                    rttSample(sentNanos: ping.sentNanos, echoNanos: ping.echoNanos, now: now)
                }
            }
        }
    }

    private func receiveTiles(_ stream: MessageStream, gen myGen: Int) async {
        var parser = TileStreamParser()
        while !Task.isCancelled {
            guard let d = try? await stream.receiveSome() else { log("tile stream closed"); return }
            do {
                for (seq, bytes, msg) in try parser.feed(d) {
                    let now = Clock.nowNanos()
                    noteHostPacket(now)
                    videoQueue.async { guard myGen == self.gen else { return }; self.apply(msg, seq: seq, bytes: bytes, now: now) }
                }
            } catch { log("tile stream: \(error)"); return }
        }
    }

    /// Every pixel update carries the host capture it came from; per 64-px tile the viewer keeps the
    /// newest capture that touched it (tiles, copy-rects, video alike). A tile message is applied only
    /// if *no* tile under its rect holds a newer capture (review M2: applying a rect because one tile
    /// under it was still old put stale blocks over a moved window), and applying it marks the tiles.
    private func isFresh(_ rect: PixelRect, captureSeq: UInt32) -> Bool {
        guard let c = compositor, c.width > 0 else { return true }
        let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
        if tileCaptureSeq.count != cols * rows { tileCaptureSeq = Array(repeating: 0, count: cols * rows) }
        let c0 = max(0, rect.x / 64), c1 = min(cols - 1, (rect.maxX - 1) / 64), r0 = max(0, rect.y / 64), r1 = min(rows - 1, (rect.maxY - 1) / 64)
        guard c1 >= c0, r1 >= r0 else { return true }
        for r in r0...r1 { for cc in c0...c1 where tileCaptureSeq[r * cols + cc] > captureSeq { staleDiscards += 1; return false } }
        markCapture(rect, captureSeq: captureSeq)
        return true
    }
    /// Records that `rect` now shows pixels from `captureSeq` (copy-rects and video frames too).
    private func markCapture(_ rect: PixelRect, captureSeq: UInt32) {
        guard let c = compositor, c.width > 0 else { return }
        let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
        if tileCaptureSeq.count != cols * rows { tileCaptureSeq = Array(repeating: 0, count: cols * rows) }
        let c0 = max(0, rect.x / 64), c1 = min(cols - 1, (rect.maxX - 1) / 64), r0 = max(0, rect.y / 64), r1 = min(rows - 1, (rect.maxY - 1) / 64)
        guard c1 >= c0, r1 >= r0 else { return }
        for r in r0...r1 { for cc in c0...c1 { tileCaptureSeq[r * cols + cc] = max(tileCaptureSeq[r * cols + cc], captureSeq) } }
    }
    /// Tile messages discarded because newer pixels (a copy-rect, video, a later tile) had already landed
    /// under them; `staleCommits` counts the opposite and must stay 0 (the drag scenario asserts it).
    private(set) var staleDiscards = 0, staleCommits = 0
    private func wouldBeStale(_ rect: PixelRect, captureSeq: UInt32) -> Bool {
        guard let c = compositor, c.width > 0, !tileCaptureSeq.isEmpty else { return false }
        let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
        let c0 = max(0, rect.x / 64), c1 = min(cols - 1, (rect.maxX - 1) / 64), r0 = max(0, rect.y / 64), r1 = min(rows - 1, (rect.maxY - 1) / 64)
        guard c1 >= c0, r1 >= r0 else { return false }
        for r in r0...r1 { for cc in c0...c1 where tileCaptureSeq[r * cols + cc] > captureSeq { return true } }
        return false
    }

    private func apply(_ msg: TileMessage, seq: UInt32, bytes: Int, now: UInt64) {
        switch msg {
        case .tiles(let t):
            let fresh = t.tiles.filter { isFresh($0.rect, captureSeq: t.header.captureSeq) }
            for tile in fresh where wouldBeStale(tile.rect, captureSeq: t.header.captureSeq) { staleCommits += 1 }   // must never happen
            let n = compositor?.applyTiles(fresh, crossfade: t.refinement) ?? 0
            statsLock.lock(); sTileBytes += t.bytes; sTileRects += n; statsLock.unlock()
            if t.refinement { lastRefinementNanos = now; if Self.debugTiles, refinementLogged < 6 { refinementLogged += 1; log("refinement batch: \(t.tiles.prefix(2).map { "\($0.rect)" })") } }
            if let c = compositor, c.width > 0 {
                let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
                if losslessAt.count != cols * rows { losslessAt = Array(repeating: 0, count: cols * rows) }
                for tile in fresh {
                    let c0 = max(0, tile.rect.x / 64), c1 = min(cols - 1, (tile.rect.maxX - 1) / 64), r0 = max(0, tile.rect.y / 64), r1 = min(rows - 1, (tile.rect.maxY - 1) / 64)
                    if c1 >= c0, r1 >= r0 { for r in r0...r1 { for cc in c0...c1 { losslessAt[r * cols + cc] = now } } }
                }
            }
            checkLegible()
            if !watchRect.isEmpty {
                let inside = t.tiles.filter { $0.rect.intersects(watchRect) }
                if !inside.isEmpty {
                    lastWatchedTileNanos = now; watchedTileBytes += inside.reduce(0) { $0 + $1.data.count }; watchedTileCount += inside.count
                    if !t.refinement { watchedDirectBytes += inside.reduce(0) { $0 + $1.data.count } }
                    if Self.debugTiles { log("tiles\(t.refinement ? " (refine)" : "") seq \(t.header.captureSeq) in watch rect: " + inside.map { "\($0.rect.width)x\($0.rect.height)@\($0.rect.x),\($0.rect.y) \($0.data.count)B \($0.format)" }.joined(separator: "  ")) }
                }
            }
            predictorLock.lock()
            for tile in t.tiles { predictor.hostUpdate(inputSeq: t.header.inputSeq, rect: tile.rect, now: now) }
            predictorLock.unlock()
            sender?.send(.tileAck(.init(msgSeq: seq, captureNanos: t.header.captureNanos, receivedNanos: now, bytes: bytes)))
        case .copyRect(let c):
            compositor?.applyCopyRect(c.rect, dx: c.dx, dy: c.dy)
            markCapture(c.rect.union(c.rect.offset(c.dx, c.dy)), captureSeq: c.header.captureSeq)
            statsLock.lock(); sCopyRects += 1; statsLock.unlock()
            if !watchRect.isEmpty, c.rect.union(c.rect.offset(c.dx, c.dy)).intersects(watchRect) { lastWatchedCopyNanos = now; watchedCopyRects += 1 }
            predictorLock.lock()
            predictor.hostCopyRect(windowID: c.header.windowID, rect: c.rect, dx: c.dx, dy: c.dy, inputSeq: c.header.inputSeq, now: now)
            predictor.hostUpdate(inputSeq: c.header.inputSeq, rect: c.rect.union(c.rect.offset(c.dx, c.dy)), now: now)
            predictorLock.unlock()
            sender?.send(.tileAck(.init(msgSeq: seq, captureNanos: c.header.captureNanos, receivedNanos: now, bytes: bytes)))
        case .reset(let w, let h):
            // A fresh stream at the same size keeps the pixels (review M11: the last picture stays until the
            // first keyframe replaces it); a size change clears. Either way nothing old is trusted any more.
            compositor?.configure(width: w, height: h)   // clears only on a size change
            tileCaptureSeq = []
            assembler = FrameAssembler(); lastRecoverySeq = 0   // review M4: the host's sequence may restart
            predictorLock.lock(); predictor = Predictor(); predictorLock.unlock()
        }
        onChange?()
        if case .reset = msg {} else { notePictureChange(now) }
    }

    private func ingest(_ frag: VideoFragment) {
        let now = Clock.nowNanos()
        handle(assembler.ingest(frag, now: now), now: now)
    }

    /// Time-driven assembler pass (NACKs and timeouts fire even when nothing arrives).
    func assemblerTick() {
        let now = Clock.nowNanos()
        statsLock.lock(); let rtt = sRTT; statsLock.unlock()
        if rtt > 0 {
            assembler.timeoutNanos = UInt64(rtt * 1e6 * 2.5) + 300_000_000   // NACK round trip plus slack
            assembler.nackRepeatNanos = UInt64(rtt * 1e6) + 50_000_000
        }
        handle(assembler.tick(now: now), now: now)
    }

    private func handle(_ events: [FrameAssembler.Event], now: UInt64) {
        for ev in events {
            switch ev {
            case .nack(let seq, let fragments):
                statsLock.lock(); sNacks += 1; statsLock.unlock()
                sender?.send(.nack(.init(frameSeq: seq, fragments: fragments)))
            case .lost(let seq):
                // The assembler gives up on an old partial after its timeout; if a recovery frame newer
                // than it was decoded meanwhile, nothing is missing (the host ignores such acks too).
                if seq > lastRecoverySeq { awaitingRecovery = true }
                statsLock.lock(); sLost += 1; statsLock.unlock()
                sender?.send(.frameAck(.init(seq: seq, captureNanos: 0, receivedNanos: now, decodedNanos: 0, bytes: 0, lost: true)))
            case .gap(let from, let to):
                // A loss burst: nothing of frames from...to ever arrived. Ask for a recovery frame now
                // rather than after a timeout; frames that follow are P-frames and are skipped until it lands.
                log("video: frames \(from)–\(to) never arrived (loss burst); asking for recovery")
                if to > lastRecoverySeq { awaitingRecovery = true }
                statsLock.lock(); sLost += Int(to - from + 1); sBursts += 1; statsLock.unlock()
                sender?.send(.frameAck(.init(seq: to, captureNanos: 0, receivedNanos: now, decodedNanos: 0, bytes: 0, lost: true)))
            case .completed(let frame):
                statsLock.lock(); sBytes += frame.bytes; statsLock.unlock()
                if awaitingRecovery && !frame.flags.contains(.recovery) {
                    statsLock.lock(); sDropped += 1; statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: 0, bytes: frame.bytes, lost: false,
                                                 firstReceivedNanos: frame.firstFragmentNanos, fragments: frame.fragments, fragmentsLost: frame.fragmentsLost)))
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
                        compositor.applyVideo(image, region: region, mask: mask, crossfade: frame.flags.contains(.progressive))
                        if !frame.flags.contains(.progressive) { markCapture(region, captureSeq: frame.captureSeq) }
                        notePictureChange(now)
                        statsLock.lock(); let since = connectedAtNanos; statsLock.unlock()
                        if lastVideoNanos > 0, since > 0, now > since &+ steadyAfterNanos, now > lastVideoNanos {
                            let gap = Double(now - lastVideoNanos) / 1e6
                            if gap > maxVideoGapMs { maxVideoGapMs = gap }
                            if gap > 500 { videoGapsOver500.append(gap) }
                        }
                        lastVideoNanos = now
                        if !watchRect.isEmpty, region.intersects(watchRect) { lastWatchedVideoNanos = now; watchedVideoFrames += 1 }
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
                                                 firstReceivedNanos: frame.firstFragmentNanos, fragments: frame.fragments, fragmentsLost: frame.fragmentsLost)))
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

    /// Keepalive: one small datagram ping every 10 s (DESIGN §4a). It also carries RTT and the clock offset.
    private func pingLoop() async {
        while !stopped {
            try? await Task.sleep(for: .seconds(Mirage.keepaliveSeconds))
            pingSeq += 1
            if let flow { try? await flow.sendRaw(DatagramPing.encode(seq: pingSeq)) }
        }
    }

    private func statsLoop() async {
        while !stopped {
            try? await Task.sleep(for: .seconds(1))
            watchdog(now: Clock.nowNanos())
            statsLock.lock()
            let frames = sFrames, bytes = sBytes, lost = sLost, dec = sDecodeNanos, age = sAge, rtt = sRTT, dropped = sDropped
            let tileBytes = sTileBytes, tileRects = sTileRects, copies = sCopyRects, rate = rateState, nacks = sNacks, bursts = sBursts
            sFrames = 0; sBytes = 0; sLost = 0; sDecodeNanos = 0; sDropped = 0; sTileBytes = 0; sTileRects = 0; sCopyRects = 0; sNacks = 0; sBursts = 0
            statsLock.unlock()
            predictorLock.lock(); let pstats = predictor.stats; predictorLock.unlock()
            let inp = inputState()
            let w = decoder.width, h = decoder.height
            let upscaling = compositor?.usesMetalFX ?? false
            await MainActor.run {
                var s = model.stats
                s.fps = Double(frames); s.kbps = Double(bytes) * 8 / 1000; s.lost += lost; s.frames += frames; s.dropped += dropped
                s.decodeMs = frames > 0 ? Double(dec) / Double(frames) / 1e6 : s.decodeMs
                s.frameAgeMs = age / 1e6; s.rttMs = rtt; s.width = w; s.height = h
                s.tileKbps = Double(tileBytes) * 8 / 1000; s.tileRects += tileRects; s.copyRects += copies; s.rate = rate; s.predictions = pstats; s.upscaling = upscaling
                s.nacks += nacks; s.recoveredByNack = self.assembler.recoveredByNack; s.recoveredByParity = self.assembler.recoveredByParity; s.bursts += bursts
                model.stats = s
                model.inputQueued = inp.queued; model.inputDropped = inp.dropped; model.inputHeld = inp.held
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

    // Input rides datagrams with redundancy (InputChannel): the latest pointer state and every unacked
    // discrete event in each packet, retransmitted until the host acknowledges them, held for a
    // decision after a long gap. One queue serializes the channel.
    private let inputQueue = DispatchQueue(label: "mirage.viewer.input", qos: .userInteractive)
    private var input = InputChannel()
    private var inputTimer: DispatchSourceTimer?
    /// Headless and scripted runs never hold the queue: it flushes by itself when the path returns.
    var inputAutoFlush = false { didSet { inputQueue.async { self.input.autoFlush = self.inputAutoFlush } } }
    /// What the channel looks like, for the overlay and --stats.
    struct InputState { var queued = 0, dropped = 0, packets = 0; var held = false; var oldestMs = 0.0 }
    func inputState() -> InputState { inputQueue.sync { let now = Clock.nowNanos(); return InputState(queued: input.queuedEvents, dropped: input.droppedByCap, packets: input.packetsSent, held: input.held, oldestMs: Double(input.oldestUnackedNanos(now: now)) / 1e6) } }
    private(set) var keysSent: [String] = []   // scenario record: "seq:down:chars"

    private func startInputTimer() {
        guard inputTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: inputQueue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if let d = self.input.tick(now: Clock.nowNanos()) { self.sendInputDatagram(d) }
        }
        t.resume(); inputTimer = t
    }
    /// On inputQueue.
    private func sendInputDatagram(_ d: Data) {
        guard let flow else { return }
        if LossInjector.shared.shouldDrop() { return }   // test-only (MIRAGE_TEST_LOSS in the viewer's environment)
        flow.connection.send(content: d, completion: .contentProcessed { _ in })
    }
    private func flushInputNow() { if let d = input.packet(now: Clock.nowNanos()) { sendInputDatagram(d) } }
    private func inputAck(_ a: InputAck) { inputQueue.async { self.input.ack(a) } }
    /// After a long gap: send what was typed meanwhile, or drop it.
    func flushInput() { inputQueue.async { self.input.flush(); self.flushInputNow(); self.log("input: flushed the queue") } }
    func discardInput() { inputQueue.async { let n = self.input.queuedEvents; self.input.discard(); self.log("input: discarded \(n) queued events") } }

    /// Remembers where the pointer is (stream px) for the foveation metric.
    func notePointer(x: Double, y: Double) {
        guard let c = compositor, c.width > 0 else { return }
        let px = Int(x * Double(c.width)), py = Int(y * Double(c.height))
        videoQueue.async { self.pointerRect = PixelRect(x: px - 100, y: py - 100, width: 200, height: 200); self.checkLegible() }
    }

    /// Time-to-legible under the pointer: the earliest lossless arrival (since the stream started) of any
    /// tile under the pointer rect, counted even if it landed before the pointer was known.
    private func checkLegible() {
        guard legibleUnderPointerMs == nil, streamStartNanos > 0, !pointerRect.isEmpty, let c = compositor, c.width > 0, !losslessAt.isEmpty else { return }
        let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
        let c0 = max(0, pointerRect.x / 64), c1 = min(cols - 1, (pointerRect.maxX - 1) / 64), r0 = max(0, pointerRect.y / 64), r1 = min(rows - 1, (pointerRect.maxY - 1) / 64)
        guard c1 >= c0, r1 >= r0 else { return }
        var earliest: UInt64 = .max
        for r in r0...r1 { for cc in c0...c1 { let t = losslessAt[r * cols + cc]; if t > streamStartNanos, t < earliest { earliest = t } } }
        guard earliest != .max else { return }
        legibleUnderPointerMs = Double(earliest - streamStartNanos) / 1e6
        log(String(format: "legible under the pointer %.0f ms after the stream started", legibleUnderPointerMs!))
    }

    func sendMouseMove(x: Double, y: Double) {
        notePointer(x: x, y: y)
        // Coalesce to ~60 Hz; the pointer state is latest-wins so a skipped move costs nothing.
        let now = Clock.nowNanos()
        if now - lastMoveSent < 15_000_000 { pendingMove = .init(x: x, y: y); scheduleMoveFlush(); return }
        lastMoveSent = now; pendingMove = nil
        send(.mouseMove(.init(x: x, y: y)))
    }
    private var flushScheduled = false
    private func scheduleMoveFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [self] in
            flushScheduled = false
            if let m = pendingMove { pendingMove = nil; lastMoveSent = Clock.nowNanos(); send(.mouseMove(m)) }
        }
    }
    /// Queues an input message on the input channel with a fresh sequence number and sends a packet
    /// now; returns the number (the predictor keys its epochs on it).
    @discardableResult
    func send(_ m: ControlMessage, scripted: Bool = false) -> UInt64 {
        let m = scripted ? m.markedScripted() : m
        return inputQueue.sync {
            let seq: UInt64
            if case .mouseMove(let mm) = m { seq = input.pointer(x: mm.x, y: mm.y) }
            else if m.isDiscreteInput { seq = input.enqueue(m, now: Clock.nowNanos()) }
            else { return 0 }
            if case .key(let k) = m, scripted, seq != 0 { keysSent.append("\(seq):\(k.down ? 1 : 0):\(k.characters ?? "")") }
            flushInputNow()
            return seq
        }
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

    func beginDrag(windowID: UInt32, frame: PixelRect, pointer: (Int, Int), inputSeq: UInt64) {
        predictorLock.lock(); predictor.beginDrag(windowID: windowID, frame: frame, pointer: pointer, inputSeq: inputSeq, now: Clock.nowNanos()); predictorLock.unlock()
    }
    func dragPointer(windowID: UInt32, pointer: (Int, Int), inputSeq: UInt64) {
        predictorLock.lock(); predictor.dragPointer(windowID: windowID, pointer: pointer, inputSeq: inputSeq, now: Clock.nowNanos()); predictorLock.unlock()
        onChange?()
    }
    func endDrag(windowID: UInt32) { predictorLock.lock(); predictor.endDrag(windowID: windowID); predictorLock.unlock() }

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
            send(.mouseMove(.init(x: x, y: y)), scripted: true)
            try? await Task.sleep(for: .milliseconds(300))
        }
        try? await Task.sleep(for: .seconds(1))
        let cmd: UInt64 = 1 << 20   // kCGEventFlagMaskCommand
        log("probe: ⌘Space")
        send(.modifiers(.init(keyCode: 55, modifiers: cmd)), scripted: true)
        send(.key(.init(keyCode: 49, down: true, isRepeat: false, modifiers: cmd, characters: " ")), scripted: true)
        send(.key(.init(keyCode: 49, down: false, isRepeat: false, modifiers: cmd, characters: nil)), scripted: true)
        send(.modifiers(.init(keyCode: 55, modifiers: 0)), scripted: true)
        try? await Task.sleep(for: .seconds(2))
        log("probe: Esc")
        send(.key(.init(keyCode: 53, down: true, isRepeat: false, modifiers: 0, characters: "\u{1B}")), scripted: true)
        send(.key(.init(keyCode: 53, down: false, isRepeat: false, modifiers: 0, characters: nil)), scripted: true)
        try? await Task.sleep(for: .seconds(1))
        probeLog = false
    }

    func stop() {
        stopped = true
        sender?.send(.streamStop)
        dropConnection()
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
            var nacksSent: Int?, recoveredByNack: Int?, recoveredByParity: Int?
            var scenario: String?, crispMs: [Double]?, crispMsMedian: Double?, crispMsMax: Double?
            var watchedTileBytes: Int?, watchedTileCount: Int?, watchedKbps: Double?, watchedDirectKbps: Double?
            var keyLatencyMs: [Double]?, keyLatencyMsMedian: Double?, keyLatencyMsMax: Double?
            var legibleUnderPointerMs: Double?
            var resumes: Int?, reconnects: Int?, resumeToPictureMs: [Double]?, maxPictureGapMs: Double?, pictureGapsOver500ms: Int?, bursts: Int?
            var inputPackets: Int?, inputQueued: Int?, inputDropped: Int?, keysSent: [String]?
            var maxVideoGapMs: Double?, videoGapsOver500ms: [Double]?
            var keepalivesSent: UInt64?
            var motionFps: [Double]?, motionFrames: [Int]?, motionCopyRects: [Int]?
            var staleTilesDiscarded: Int?, staleTilesCommitted: Int?
            var samples: [Sample]
        }
        let target = MainActor.assumeIsolated { lastRequest?.bitrateKbps ?? 0 }
        let inputStateNow = inputState()
        // The gap since the last decoded frame counts too: a stream that died stays died.
        var videoGapMax = maxVideoGapMs, videoGaps = videoGapsOver500
        if lastVideoNanos > 0 {
            let tail = Double(Clock.nowNanos() &- lastVideoNanos) / 1e6
            if tail > videoGapMax { videoGapMax = tail }
            if tail > 500 { videoGaps.append(tail) }
        }
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
                      nacksSent: MainActor.assumeIsolated { model.stats.nacks }, recoveredByNack: assembler.recoveredByNack, recoveredByParity: assembler.recoveredByParity,
                      scenario: scenario?.name, crispMs: scenario?.crispMs, crispMsMedian: scenario.map { median($0.crispMs) }, crispMsMax: scenario?.crispMs.max(),
                      watchedTileBytes: scenario == nil ? nil : watchedTileBytes, watchedTileCount: scenario == nil ? nil : watchedTileCount,
                      watchedKbps: scenario.map { Double(watchedTileBytes) * 8 / 1000 / max(1, $0.activeSeconds) },
                      watchedDirectKbps: scenario.map { Double(watchedDirectBytes) * 8 / 1000 / max(1, $0.activeSeconds) },
                      keyLatencyMs: scenario?.keyLatencyMs, keyLatencyMsMedian: scenario.map { median($0.keyLatencyMs) }, keyLatencyMsMax: scenario?.keyLatencyMs.max(),
                      legibleUnderPointerMs: legibleUnderPointerMs,
                      resumes: resumes, reconnects: reconnects, resumeToPictureMs: resumeToPictureMs, maxPictureGapMs: maxPictureGapMs, pictureGapsOver500ms: pictureGapsOver500, bursts: MainActor.assumeIsolated { model.stats.bursts },
                      inputPackets: inputStateNow.packets, inputQueued: inputStateNow.queued, inputDropped: inputStateNow.dropped, keysSent: keysSent.isEmpty ? nil : keysSent,
                      maxVideoGapMs: videoGapMax, videoGapsOver500ms: videoGaps, keepalivesSent: pingSeq,
                      motionFps: scenario?.motionFps, motionFrames: scenario?.motionFrames, motionCopyRects: scenario?.motionCopyRects,
                      staleTilesDiscarded: staleDiscards, staleTilesCommitted: staleCommits,
                      samples: samples)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(out)) ?? Data()
    }
}
