import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreVideo
import Network
import CryptoKit
import MirageCore

/// Everything the viewer knows about one host connection, published for SwiftUI.
@MainActor
final class ViewerModel: ObservableObject {
    @Published var status = "connecting…"
    @Published var error: String?
    @Published var stats = Stats()
    /// The stats overlay (debug numbers): off unless the person turned it on (`ViewerControls` remembers it).
    @Published var showStats = false
    @Published var cursor: CursorImage?
    @Published var remoteCursor: CGPoint? = nil      // normalized, host-reported
    @Published var streamInfo: ControlMessage.StreamInfo?
    /// The bitrate cap the person chose, kbit/s; 0 = automatic (the host probes up to what the link sustains).
    @Published var bitrateKbps: Int
    /// A simulated link for testing (developer setting); nil = the real link. Not kept across launches unless pinned.
    @Published var throttle: NetworkThrottle?
    /// The host's own name and build, from its Welcome (About).
    @Published var hostDisplayName: String?
    @Published var hostBuild: String?
    @Published var pixelFactor: Double
    var statsLog: URL?
    /// Forward no local input (a scripted run is being watched).
    var observeOnly = false
    @Published var hostStatus: ControlMessage.HostStatus?
    /// The host as the person named it (the alias they connected to), for messages.
    var hostName = "the host"
    /// Non-nil while the connection is down: (attempt number, seconds until the next try).
    @Published var reconnecting: (attempt: Int, inSeconds: Int)? = nil
    /// Seconds without any packet from the host while connected (0 = fine).
    @Published var stalledSeconds = 0
    /// Input channel: events waiting for the host's ack, dropped by the cap, and whether a decision is pending.
    @Published var inputQueued = 0
    @Published var inputDropped = 0
    @Published var inputHeld = false
    /// Unified mode: remote windows as native windows (DESIGN §3.2); Desktop mode otherwise. Local; no reconnect.
    @Published var unified = false

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
        var layers = 0, layerMB = 0
    }
    struct CursorImage {
        let image: PlatformImage
        let hotspot: CGPoint
        let size: CGSize
    }

    init(bitrateKbps: Int, pixelFactor: Double, throttle: NetworkThrottle? = nil) { self.bitrateKbps = bitrateKbps; self.pixelFactor = pixelFactor; self.throttle = throttle }
}

/// Owns the connection; feeds decoded frames, tiles and copy-rects to the compositor, forwards input,
/// and runs the local scroll/drag prediction against the host's updates.
final class ViewerSession: @unchecked Sendable {
    let host: String
    let port: UInt16
    let pairCode: String?
    /// A scanned or opened pairing link (pairs with its secret and pins the host key it names).
    let pairLink: PairingLink?
    let model: ViewerModel
    private var client: QUICClient?
    private var control: MessageStream?
    private var sender: ControlSender?
    private var flow: MessageStream?
    private var tileStream: MessageStream?
    private var fastTileStream: MessageStream?
    private(set) var hostStatus: ControlMessage.HostStatus?
    private let videoQueue = DispatchQueue(label: "mirage.viewer.video", qos: .userInteractive)
    private var assembler = FrameAssembler()
    private var assemblerTimer: DispatchSourceTimer?
    /// One per layer (DESIGN §3.2): the display layer (0) and every window the host captures as its own
    /// layer. Each has its canvas, its decoder (HEVC references are per layer), per-tile capture
    /// sequences (a refinement queued before a newer interactive update of the same tile must not
    /// overwrite it) and its recovery state.
    final class LayerView {
        let id: UInt32
        let compositor: Compositor
        let decoder = HEVCDecoder()
        var tileCaptureSeq: [UInt32] = []
        var losslessAt: [UInt64] = []
        var awaitingRecovery = false
        /// Sequence of the last decoded recovery frame: a loss verdict for an older frame is already healed.
        var lastRecoverySeq: UInt32 = 0
        var lastSeenInListNanos: UInt64 = 0
        /// Diagnostics: bytes and tile rects received for this layer, stills, video frames decoded.
        var receivedBytes = 0, tilesApplied = 0, stills = 0, videoFrames = 0
        /// Presentation steps (DESIGN §3.3): what the person sees change on this layer outside direct changes. "still"
        /// (the lossy first picture), "fade" (a whole-layer level crossfading in), "commit" (a staged level presented),
        /// "loose" (a refinement block presented on its own: must stay 0 outside the underlay).
        var steps: [(ms: Int, kind: String)] = []
        var looseRefinements = 0
        let createdNanos = Clock.nowNanos()
        /// Lossless rects written to the staged level, marked crisp when it is presented.
        var stagedLossless: [PixelRect] = []
        func step(_ kind: String, now: UInt64) { if steps.count < 64 { steps.append((Int(Clock.elapsed(since: createdNanos, now: now) / 1_000_000), kind)) } }
        init(id: UInt32, context: MetalContext) { self.id = id; compositor = Compositor(context: context); compositor.layerID = id; compositor.hasAlpha = id != 0 }
    }
    let context = MetalContext()
    private(set) var layerViews: [UInt32: LayerView] = [:]
    /// The display layer's canvas (what scripts and the single-canvas paths mean by "the picture").
    var compositor: Compositor? { displayView?.compositor }
    private var displayView: LayerView? { layerViews[0] }
    private func layerView(_ id: UInt32) -> LayerView? { layerViews[id] }
    /// Texture memory the layer cache may hold before absent layers are evicted.
    var layerMemoryBudget = 768 << 20
    /// Called (on the video queue) whenever the picture changed and should be presented.
    var onChange: (() -> Void)?
    /// The host's tunables (defaults until it sends them): gesture thresholds, prediction lead, fades (DESIGN §3.0).
    private(set) var tunables = Tunables.defaults
    /// Called on the main queue when the host's tunables arrive (the iOS view applies its touch thresholds).
    var onTunables: ((Tunables) -> Void)?

    // Clock sync: hostNanos ≈ localNanos + offset. Guarded by statsLock together with the counters below.
    private var clockOffset: Double = 0
    private var bestRTT: Double = .infinity
    private var pingSeq: UInt64 = 0
    private let statsLock = NSLock()
    private var sFrames = 0, sBytes = 0, sLost = 0, sDecodeNanos: UInt64 = 0, sAge: Double = 0, sRTT = 0.0, sDropped = 0
    private var sTileBytes = 0, sTileRects = 0, sCopyRects = 0, sNacks = 0, sBursts = 0
    /// Every byte from the host (video, tiles, control messages), cumulative: scenario bytes-during-a-burst.
    private var sTotalBytes = 0, sControlBytes = 0
    func totalBytes() -> Int { statsLock.lock(); defer { statsLock.unlock() }; return sTotalBytes + sControlBytes }
    /// Native-chrome messages (menus, apps, icons): bytes so far, and the handler (main actor).
    private var sChromeBytes = 0
    func chromeBytes() -> Int { statsLock.lock(); defer { statsLock.unlock() }; return sChromeBytes }
    @MainActor var onChrome: ((ControlMessage) -> Void)?
    /// Sends a control message (native chrome requests).
    func sendControl(_ m: ControlMessage) { sender?.send(m) }
    /// What the viewer shows (Unified mode); re-sent on every new connection.
    private var viewInterest: ControlMessage.ViewInterest?
    func setViewInterest(_ v: ControlMessage.ViewInterest) {
        guard v != viewInterest else { return }
        viewInterest = v
        sender?.send(.viewInterest(v))
    }
    private var rateState = ControlMessage.RateState(targetKbps: 0, capacityKbps: 0, queueMs: 0, rung: 0, scale: 1, tileBudgetKbps: 0, videoKbps: 0, tileKbps: 0)
    @MainActor private var lastRequest: ControlMessage.StreamRequest?
    @MainActor private var pendingRequest: ControlMessage.StreamRequest?
    /// One entry per second, for --stats JSON output.
    struct Sample: Codable {
        var t: Double, rttMs: Double, frameAgeMs: Double, fps: Double, kbps: Double, decodeMs: Double, lost: Int, skipped: Int, width: Int, height: Int
        var tileKbps: Double, tileRects: Int, copyRects: Int, targetKbps: Int, capacityKbps: Int, queueMs: Double, rung: Int, scale: Double
        var tier: String?
        /// Every byte from the host so far (video, tiles, control): bytes in any interval of a run.
        var totalBytes: Int?
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
    /// Last watched tile of at least 32×32 px: time-to-crisp ignores caret blinks and single glyphs.
    private(set) var lastWatchedLargeTileNanos: UInt64 = 0
    private(set) var watchedVideoFrames = 0, watchedCopyRects = 0
    private(set) var watchedTileBytes = 0, watchedTileCount = 0, watchedDirectBytes = 0
    /// Foveation metric: the first lossless tile within ~100 px of the pointer after the stream started.
    private var pointerRect: PixelRect = .zero
    private var streamStartNanos: UInt64 = 0
    private(set) var legibleUnderPointerMs: Double? = nil
    private var refinementLogged = 0
    static let debugTiles = ProcessInfo.processInfo.environment["MIRAGE_DEBUG_TILES"] != nil
    /// Native-scale snap (StreamScale): always on since the mac-daddy A/B (2026-10-20): scroll 0 → 225 copy-rects and its
    /// predictions 0 → 234 confirmed, crisp 5.0 → 2.5 s, terminal 8 → 389 copy-rects and 580 → 401 kbps, first 30 s lighter.
    static let snapNative = true
    static let debugPresent = ProcessInfo.processInfo.environment["MIRAGE_DEBUG_PRESENT"] != nil
    func resetWatched() { videoQueue.async { self.watchedTileBytes = 0; self.watchedTileCount = 0; self.watchedDirectBytes = 0; self.watchedVideoFrames = 0; self.watchedCopyRects = 0 } }
    func windowsSnapshot() -> [ControlMessage.WindowInfo] { predictorLock.lock(); defer { predictorLock.unlock() }; return windows }
    #if os(macOS)
    var scenario: ScenarioRunner?
    /// Unified mode's controller while it is on (scenarios drive its windows).
    @MainActor weak var unified: UnifiedController?
    #endif

    init(host: String, port: UInt16, pairCode: String?, pairLink: PairingLink? = nil, model: ViewerModel) {
        self.host = host; self.port = port; self.pairCode = pairCode; self.pairLink = pairLink; self.model = model
        let throttle = MainActor.assumeIsolated { () -> NetworkThrottle? in model.hostName = host; return model.throttle }
        applyUpstreamThrottle(throttle)
        if let context { layerViews[0] = LayerView(id: 0, context: context) }
        if let saved = ViewerCredentials.savedResume(host: host, port: port) {
            // A relaunched app (iOS): resume the host's session; input numbering continues past what the host has applied.
            resumeToken = saved.token; input.continueAfter(saved.inputSeq + (1 << 20))
        }
    }

    /// The host is this Mac (loopback tests).
    var isLoopback: Bool { ["localhost", "127.0.0.1", "::1"].contains(host) || host == ProcessInfo.processInfo.hostName }
    func log(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }

    /// Test only: MIRAGE_TEST_DELAY_MS=N holds every message from the host until N ms after it arrived (order kept
    /// per stream), so a loopback run sees a WAN-like round trip (no dummynet, no sudo).
    static let testDelayNanos: UInt64 = ProcessInfo.processInfo.environment["MIRAGE_TEST_DELAY_MS"].flatMap { UInt64($0) }.map { $0 * 1_000_000 } ?? 0
    static func holdForTestDelay(arrived: UInt64) async {
        guard testDelayNanos > 0 else { return }
        let due = arrived + testDelayNanos, now = Clock.nowNanos()
        if due > now { try? await Task.sleep(nanoseconds: due - now) }
    }

    func start() {
        watchWakeAndPath()
        Task { await run() }
    }

    private func setStatus(_ s: String) { Task { @MainActor in model.status = s } }
    private var stopped = false
    private var paired = false

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
            // For the first five minutes; after that (a night's sleep, a dead network) the backoff applies, and a wake or a
            // network change dials at once instead (`nudge`).
            if resumable, Date().timeIntervalSince(disconnectedAt ?? Date()) < 300 { delay = min(delay, 1) }
            log("viewer: \(failure); reconnecting in \(delay) s (attempt \(attempt))")
            await MainActor.run {
                model.reconnecting = (attempt, delay)
                model.status = "reconnecting… (attempt \(attempt), \(failure))"
                lastRequest = nil   // re-request the stream once the new connection is up
                if pendingRequest == nil, let r = lastRequestSent { pendingRequest = r }
            }
            let wait = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
            backoffWait = wait
            await wait.value
            backoffWait = nil
        }
    }
    /// The backoff sleep in progress (cancelled by `nudge`).
    private var backoffWait: Task<Void, Never>?
    private var wakeObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    /// The current network, hashed (the stream request carries it; the host's careful resume keys on it).
    private(set) var networkFingerprint: String?
    static func fingerprint(_ p: NWPath) -> String? {
        guard p.status == .satisfied else { return nil }
        let kind = p.usesInterfaceType(.wifi) ? "wifi" : p.usesInterfaceType(.cellular) ? "cell" : p.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
        let gw = p.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        let digest = SHA256.hash(data: Data((kind + "|" + gw).utf8))
        return kind + "-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    /// The Mac woke or the network changed: a dead connection is dropped and the host dialed at once (the resume token
    /// brings the same session back for a day, DESIGN §4a), instead of after the backoff.
    func nudge(_ why: String) {
        statsLock.lock(); let last = lastHostPacketNanos; statsLock.unlock()
        let silent = last > 0 ? Double(Clock.elapsed(since: last, now: Clock.nowNanos())) / 1e9 : 0
        log("viewer: \(why)\(silent > 0 ? String(format: " (%.0f s since the host was last heard)", silent) : ""); dialing now")
        if sender != nil, silent > 3 { dropConnection() }
        backoffWait?.cancel()
    }
    private func watchWakeAndPath() {
        wakeObservers.append(PlatformEvents.observeWake { [weak self] why in self?.nudge(why) })
        if let o = PlatformEvents.observeSuspend({ [weak self] in self?.saveResume() }) { wakeObservers.append(o) }
        let m = NWPathMonitor()
        var lastPath: String?
        m.pathUpdateHandler = { [weak self] p in
            self?.networkFingerprint = Self.fingerprint(p)
            let desc = p.status == .satisfied ? p.availableInterfaces.map(\.name).joined(separator: ",") : "none"
            defer { lastPath = desc }
            guard let lp = lastPath, lp != desc, p.status == .satisfied else { return }
            self?.nudge("network changed (\(lp) → \(desc))")
        }
        m.start(queue: DispatchQueue(label: "mirage.viewer.path"))
        pathMonitor = m
    }

    /// Keeps the resume token and the input numbering where the platform persists them (iOS: the keychain).
    private func saveResume() { if let t = resumeToken { ViewerCredentials.saveResume(t, inputSeq: lastInputSeqSent(), host: host, port: port) } }

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
        let myGen = videoQueue.sync { () -> Int in
            gen += 1; assembler = FrameAssembler()
            for v in layerViews.values { v.awaitingRecovery = resumeToken != nil; v.lastRecoverySeq = 0; v.tileCaptureSeq = [] }
            return gen
        }
        sender = nil
        for t in receiveTasks { t.cancel() }
        receiveTasks = []
        let client = QUICClient(host: host, port: port)
        // Connect timing (M-FIVE: the time before the first picture), logged at each step from here.
        let connectStart = Date()
        func since() -> String { String(format: "%.0f ms", Date().timeIntervalSince(connectStart) * 1000) }
        self.client = client
        defer { client.close(); disconnectedAt = Date(); statsLock.lock(); hostStatus = nil; statsLock.unlock() }   // review M5: no leaked groups
        do {
            let store = try Store()
            let identity = try ViewerCredentials.clientIdentity(store: store)
            try await client.connect(timeout: resumable ? 4 : 15)
            log("connect timing: QUIC connected at \(since())")
            guard let fp = client.tlsFingerprint else { throw MirageError.transport("no TLS fingerprint") }
            let control = try await client.openStream()
            self.control = control
            let session = ClientSession(identity: identity, store: store, alias: host, tlsFingerprint: fp, stream: control)
            if !paired, pairLink != nil || pairCode != nil {
                do {
                    let h: DeviceRecord
                    if let link = pairLink { h = try await session.pair(link: link) }
                    else {
                        guard let code = PairingCode.normalize(pairCode ?? "") else { throw MirageError.pairingFailed("the code needs 6 digits") }
                        h = try await session.pair(code: code)
                    }
                    paired = true   // a code pairs once: reconnects authenticate with the identity
                    log("paired with \(h.name)")
                } catch {
                    // A code or link is single use: retrying it can only fail again. Stop and say why.
                    stopped = true
                    let why = "\(error)".replacingOccurrences(of: "authenticationFailed(\"host rejected: ", with: "").replacingOccurrences(of: "pairingFailed(\"", with: "").replacingOccurrences(of: "\")", with: "")
                    await MainActor.run { model.error = "Pairing failed: \(why)"; model.status = "not paired"; model.reconnecting = nil }
                    return "pairing failed: \(error)"
                }
            }
            log("connect timing: control stream open at \(since())")
            let welcome = try await session.authenticate(resumeToken: resumeToken)
            log("connect timing: authenticated at \(since())")
            let resumed = welcome.resumed == true
            if resumeToken != nil { if resumed { resumes += 1 } else { reconnects += 1 } }
            if let t = welcome.resumeToken { resumeToken = t; saveResume() }
            if resumeToken != nil, !resumed {
                // The host did not know us (restarted, or the window passed): a fresh stream follows. The
                // picture stays until its first keyframe replaces it; predictions from the old session are void.
                predictorLock.lock(); predictor = Predictor(); predictorLock.unlock()
                videoQueue.sync { for v in layerViews.values { v.awaitingRecovery = false } }
            }
            Task { @MainActor in model.hostDisplayName = welcome.hostName; model.hostBuild = welcome.hostBuild }
            log(resumed ? "session resumed by \(welcome.hostName) (\(disconnectedAt.map { String(format: "%.1f s gap", Date().timeIntervalSince($0)) } ?? ""))" : "authenticated to \(welcome.hostName)")
            setStatus(resumed ? "resumed session with \(welcome.hostName)" : "authenticated to \(welcome.hostName)")
            let s = ControlSender(stream: control, log: { [weak self] in self?.log($0) })
            s.shaper = { [weak self] in self?.upShaper }   // the throttle's upstream: acks, requests, window commands
            sender = s
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
            log("connect timing: all streams up at \(since())")
            if let v = viewInterest { sender?.send(.viewInterest(v)) }   // before the stream: Unified never streams the desktop
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
        statsLock.lock(); let stalled = lastHostPacketNanos > 0 && Clock.nowNanos() &- lastHostPacketNanos > 2_000_000_000 && Clock.nowNanos() > lastHostPacketNanos; statsLock.unlock()
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
        let silent = Double(now > last ? Clock.elapsed(since: last, now: now) : 0) / 1e9   // a packet noted after `now` was taken is not silence (was a UInt64 underflow trap)
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
        statsLock.lock(); let connectedAt = connectedAtNanos, resumedAt = lastResumeNanos; pictureHeld = true; statsLock.unlock()
        if connectedAt > 0 {
            // Gaps count across reconnects: the person sees one frozen picture either way.
            let base = lastPictureNanos > 0 ? lastPictureNanos : connectedAt
            let gap = now > base ? Double(Clock.elapsed(since: base, now: now)) / 1e6 : 0
            if gap > maxPictureGapMs { maxPictureGapMs = gap }
            if gap > 500 { pictureGapsOver500 += 1 }
        }
        lastPictureNanos = max(lastPictureNanos, now)
        if resumedAt > 0, now >= resumedAt {
            resumeToPictureMs.append(Double(Clock.elapsed(since: resumedAt, now: now)) / 1e6)
            statsLock.lock(); lastResumeNanos = 0; statsLock.unlock()
        }
    }

    private var loopsStarted = false
    private var frameTimer: DispatchSourceTimer?
    private func startLoopsOnce() {
        guard !loopsStarted else { return }
        loopsStarted = true
        let t = DispatchSource.makeTimerSource(queue: videoQueue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.assemblerTick() }
        t.resume()
        assemblerTimer = t
        if let dir = FrameRecorder.directory, let context {
            let rec = FrameRecorder(dir: dir)
            let ft = DispatchSource.makeTimerSource(queue: videoQueue)
            // MIRAGE_TEST_FRAMES_MS: the interval (the M-FIVE connect test records at 100 ms from the start of the stream).
            let ms = ProcessInfo.processInfo.environment["MIRAGE_TEST_FRAMES_MS"].flatMap { Int($0) } ?? 200
            ft.schedule(deadline: .now(), repeating: .milliseconds(max(20, ms)))
            ft.setEventHandler { [weak self] in
                guard let self, let sc = self.scene(pxPerPoint: 2) else { return }
                let rects = self.arrangedWindows().filter { $0.isLayered && (self.layerViews[$0.id]?.compositor.width ?? 0) > 0 }.map { ($0.id, $0.frame) }
                rec.capture(scene: sc, layers: rects, context: context)
            }
            ft.resume()
            frameTimer = ft
        }
        Task.detached { [weak self] in await self?.pingLoop() }
        Task.detached { [weak self] in await self?.statsLoop() }
        startInputTimer()
    }

    /// Presents a layer's staged level (a commit, alone or in stage 1's set).
    private func commit(layer: UInt32, now: UInt64) {
        guard let v = layerView(layer) else { return }
        let staged = v.compositor.stagedTiles
        // A layer's first level appears at once: there is nothing to crossfade from (on Japan bus the fade was 0.22 s of the
        // first picture's 2.3 s).
        v.compositor.commitStaged(durationNanos: v.compositor.commitsPresented == 0 ? 1_000_000 : tunables.levelFadeNanos)
        if layer != 0 { measureCorner(v) }
        if staged > 0 { v.step("commit", now: now) }
        let c = v.compositor
        if c.width > 0, !v.stagedLossless.isEmpty {
            let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
            if v.losslessAt.count != cols * rows { v.losslessAt = Array(repeating: 0, count: cols * rows) }
            for rect in v.stagedLossless {
                let c0 = max(0, rect.x / 64), c1 = min(cols - 1, (rect.maxX - 1) / 64), r0 = max(0, rect.y / 64), r1 = min(rows - 1, (rect.maxY - 1) / 64)
                if c1 >= c0, r1 >= r0 { for r in r0...r1 { for cc in c0...c1 { v.losslessAt[r * cols + cc] = now } } }
            }
        }
        v.stagedLossless = []
        if Self.debugTiles || Self.debugPresent { log("\(Clock.nowNanos() / 1_000_000) present L\(layer): level committed (\(staged) staged tiles)") }
        checkLegible()
    }

    // MARK: Stream control

    func requestStream(width: Int, height: Int) {
        Task { @MainActor in
            var req = ControlMessage.StreamRequest(width: width, height: height, bitrateKbps: max(0, model.bitrateKbps), maxFPS: 30, snapNative: Self.snapNative ? true : nil, tunablesVersion: Tunables.schemaVersion,
                                                   explicitBitrate: true, throttle: model.throttle, networkFingerprint: networkFingerprint)
            req.stageTransaction = true
            if req == lastRequest { return }
            guard let sender else { pendingRequest = req; log("stream request \(width)x\(height) queued until connected"); return }
            lastRequest = req; lastRequestSent = req
            // Said at send time (not part of what is compared): a resumed session sends a fresh picture of every layer to
            // a viewer that holds none (an app relaunched with its saved resume token), and brings a kept one current.
            let held = holdsPicture
            req.holdsPicture = held
            log("stream request \(width)x\(height) \(req.bitrateKbps > 0 ? "cap \(req.bitrateKbps) kbps" : "automatic bitrate")\(req.throttle.map { ", throttled: \($0.name) (\($0.summary))" } ?? "")\(held ? "" : ", no picture held")")
            sender.send(.streamRequest(req))
        }
    }

    /// Whether any layer has shown pixels from the host in this process (a relaunched app starts with none).
    var holdsPicture: Bool { statsLock.lock(); defer { statsLock.unlock() }; return pictureHeld }
    private var pictureHeld = false

    /// ⌃⌥⌘↑/↓ on the Mac: from automatic, the steps start at the host's current target.
    @MainActor func adjustBitrate(by delta: Int) {
        statsLock.lock(); let target = rateState.targetKbps; statsLock.unlock()
        let base = model.bitrateKbps > 0 ? model.bitrateKbps : (target > 0 ? target : BitratePolicy.startKbps)
        setBitrate(max(BitratePolicy.minimumCapKbps, min(50_000, base + delta)))
    }
    /// The person's cap (0 = automatic), applied at once with a new stream request.
    @MainActor func setBitrate(_ kbps: Int) {
        guard kbps != model.bitrateKbps else { return }
        model.bitrateKbps = max(0, kbps)
        if let r = lastRequest { lastRequest = nil; requestStream(width: r.width, height: r.height) }
    }
    /// A simulated link (nil = off): the host shapes its downstream from the next stream request, this viewer its upstream now.
    @MainActor func setThrottle(_ t: NetworkThrottle?) {
        guard t != model.throttle else { return }
        model.throttle = t
        applyUpstreamThrottle(t)
        log(t.map { "network throttle: \($0.name) (\($0.summary))" } ?? "network throttle off")
        if let r = lastRequest { lastRequest = nil; requestStream(width: r.width, height: r.height) }
    }

    /// The throttle's upstream half: input datagrams, pings, probe echoes and control messages go through it.
    private let shaperLock = NSLock()
    private var _upShaper: LinkShaper?
    var upShaper: LinkShaper? { shaperLock.lock(); defer { shaperLock.unlock() }; return _upShaper }
    func applyUpstreamThrottle(_ t: NetworkThrottle?) {
        shaperLock.lock(); defer { shaperLock.unlock() }
        guard let t else { _upShaper = nil; return }
        if let s = _upShaper { s.update(t, upstream: true) } else { _upShaper = LinkShaper(profile: t, upstream: true, label: "mirage.viewer.shaper") }
    }
    /// A datagram to the host, through the throttle when there is one.
    private func sendDatagram(_ d: Data, on flow: MessageStream) {
        let send = { flow.connection.send(content: d, completion: .contentProcessed { _ in }) }
        if let s = upShaper { s.send(bytes: d.count, channel: LinkShaper.Channel.datagrams, reliable: false, send) } else { send() }
    }

    // MARK: Receive loops

    private func receiveControl(_ control: MessageStream) async throws {
        guard Self.testDelayNanos > 0 else { while true { handleControl(try await control.receive()) } }
        // Test delay: one task reads and stamps arrival, this one handles each message at arrival + delay, in order. Holding
        // the delay inside the read loop serialized the stream at one message per delay (window lists sent every 33 ms
        // arrived 200 ms apart, seconds behind the host by the end of a Show Desktop slide).
        let (arrivals, sink) = AsyncThrowingStream<(ControlMessage, UInt64), Error>.makeStream()
        let reader = Task {
            do { while true { sink.yield((try await control.receive(), Clock.nowNanos())) } } catch { sink.finish(throwing: error) }
        }
        defer { reader.cancel() }
        for try await (msg, arrived) in arrivals {
            await Self.holdForTestDelay(arrived: arrived)
            handleControl(msg)
        }
    }

    private func handleControl(_ msg: ControlMessage) {
        do {
            noteHostPacket(Clock.nowNanos())
            switch msg {
            case .pong(let p):
                rttSample(sentNanos: p.sentNanos, echoNanos: p.echoNanos, now: Clock.nowNanos())
            case .streamInfo(let info):
                videoQueue.async {
                    // A new or resumed stream: the picture is kept (same size) until the host's first keyframe
                    // or masked keyframe replaces what changed; the assembler starts over (review M4).
                    self.compositor?.configure(width: info.width, height: info.height); self.onChange?()
                    self.assembler = FrameAssembler()
                    for v in self.layerViews.values { v.lastRecoverySeq = 0; v.losslessAt = [] }
                    self.streamStartNanos = Clock.nowNanos(); self.legibleUnderPointerMs = nil
                }
                if info.displayWidth > 0 { hostPxPerPoint = Double(info.width) / Double(info.displayWidth) }
                Task { @MainActor in model.streamInfo = info; model.status = "streaming \(info.width)x\(info.height) from \(host)" }
            case .cursorShape(let c):
                if let img = PlatformImage(data: c.png) {
                    Task { @MainActor in model.cursor = .init(image: img, hotspot: CGPoint(x: c.hotspotX, y: c.hotspotY), size: CGSize(width: c.width, height: c.height)) }
                }
            case .cursorPosition(let p):
                if probeLog { log(String(format: "host cursor at (%.3f, %.3f)", p.x, p.y)) }
                Task { @MainActor in model.remoteCursor = p.visible ? CGPoint(x: p.x, y: p.y) : nil }
            case .tunables(let t):
                tunables = t
                predictorLock.lock(); t.apply(to: &predictor); predictorLock.unlock()
                videoQueue.async { for c in [self.compositor].compactMap({ $0 }) + self.layerViews.values.map(\.compositor) { c.crossfadeNanos = t.crossfadeNanos } }
                log("host tunables v\(t.version): \(t.values.count) values")
                DispatchQueue.main.async { self.onTunables?(t) }
            case .windowList(let list):
                if let d = try? Frame.encode(msg) { statsLock.lock(); sControlBytes += d.count; statsLock.unlock() }
                hostWindowList(list, now: Clock.nowNanos())
            case .rateState(let r):
                statsLock.lock(); rateState = r; statsLock.unlock()
            case .hostStatus(let h):
                statsLock.lock(); let wasLocked = hostStatus?.consoleLocked; hostStatus = h; statsLock.unlock()
                if wasLocked != h.consoleLocked, h.consoleLocked || wasLocked == true { log(h.consoleLocked ? "host: \(host)'s screen is locked (window layers paused on the host)" : "host: \(host)'s screen is unlocked") }
                Task { @MainActor in model.hostStatus = h }
            case .caret(let c):
                predictorLock.lock(); typeahead.host(c, now: Clock.nowNanos()); predictorLock.unlock()
                if let d = try? Frame.encode(msg) { statsLock.lock(); sControlBytes += d.count; statsLock.unlock() }
                onChange?()
            case .tileAudit(let a):
                if let d = try? Frame.encode(msg) { statsLock.lock(); sControlBytes += d.count; statsLock.unlock() }
                videoQueue.async { self.audit(a) }
            case .apps, .icon, .menu, .statusItems:
                // Native chrome (DESIGN §3.8); counted with the control bytes.
                if let d = try? Frame.encode(msg) { statsLock.lock(); sControlBytes += d.count; sChromeBytes += d.count; statsLock.unlock() }
                Task { @MainActor in onChrome?(msg) }
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
            if Self.testDelayNanos > 0 {
                // Test delay: the datagram is handled later, not read later (an unread flow drops datagrams).
                delayQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.testDelayNanos))) { [weak self] in self?.handleDatagram(d, flow: flow, gen: myGen) }
                continue
            }
            handleDatagram(d, flow: flow, gen: myGen)
        }
    }
    private let delayQueue = DispatchQueue(label: "mirage.viewer.testdelay")
    private func handleDatagram(_ d: Data, flow: MessageStream, gen myGen: Int) {
        do {   // (scope kept from the receive loop this was moved out of)
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
                    // Only the header goes back: the host's bandwidth probe train pads its pings to 1.2 KB (M-FIVE).
                    sendDatagram(DatagramPing.echo(Data(d.prefix(DatagramPing.minSize)), now: now), on: flow)
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
                    if Self.testDelayNanos > 0 {
                        videoQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.testDelayNanos))) { guard myGen == self.gen else { return }; self.apply(msg, seq: seq, bytes: bytes, now: Clock.nowNanos()) }
                    } else {
                        videoQueue.async { guard myGen == self.gen else { return }; self.apply(msg, seq: seq, bytes: bytes, now: now) }
                    }
                }
            } catch { log("tile stream: \(error)"); return }
        }
    }

    /// Every pixel update carries the host capture it came from; per 64-px tile of its layer the viewer
    /// keeps the newest capture that touched it (tiles, copy-rects, video alike). A tile message is applied
    /// only if *no* tile under its rect holds a newer capture (review M2: applying a rect because one tile
    /// under it was still old put stale blocks over a moved window), and applying it marks the tiles.
    private func isFresh(_ v: LayerView, _ rect: PixelRect, captureSeq: UInt32) -> Bool {
        let c = v.compositor
        guard c.width > 0 else { return true }
        let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
        if v.tileCaptureSeq.count != cols * rows { v.tileCaptureSeq = Array(repeating: 0, count: cols * rows) }
        let c0 = max(0, rect.x / 64), c1 = min(cols - 1, (rect.maxX - 1) / 64), r0 = max(0, rect.y / 64), r1 = min(rows - 1, (rect.maxY - 1) / 64)
        guard c1 >= c0, r1 >= r0 else { return true }
        for r in r0...r1 { for cc in c0...c1 where v.tileCaptureSeq[r * cols + cc] > captureSeq {
            staleDiscards += 1
            if Self.debugPresent { log("stale discard L\(v.id) \(rect.x),\(rect.y) \(rect.width)x\(rect.height) capture \(captureSeq) < \(v.tileCaptureSeq[r * cols + cc]) at tile \(cc),\(r)") }
            return false
        } }
        markCapture(v, rect, captureSeq: captureSeq)
        return true
    }
    /// Records that `rect` of a layer now shows pixels from `captureSeq` (copy-rects and video frames too).
    private func markCapture(_ v: LayerView, _ rect: PixelRect, captureSeq: UInt32) {
        let c = v.compositor
        guard c.width > 0 else { return }
        let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
        if v.tileCaptureSeq.count != cols * rows { v.tileCaptureSeq = Array(repeating: 0, count: cols * rows) }
        let c0 = max(0, rect.x / 64), c1 = min(cols - 1, (rect.maxX - 1) / 64), r0 = max(0, rect.y / 64), r1 = min(rows - 1, (rect.maxY - 1) / 64)
        guard c1 >= c0, r1 >= r0 else { return }
        for r in r0...r1 { for cc in c0...c1 { v.tileCaptureSeq[r * cols + cc] = max(v.tileCaptureSeq[r * cols + cc], captureSeq) } }
    }
    /// Tile messages discarded because newer pixels (a copy-rect, video, a later tile) had already landed
    /// under them; `staleCommits` counts the opposite and must stay 0 (the drag scenario asserts it).
    private(set) var staleDiscards = 0, staleCommits = 0
    private func wouldBeStale(_ v: LayerView, _ rect: PixelRect, captureSeq: UInt32) -> Bool {
        let c = v.compositor
        guard c.width > 0, !v.tileCaptureSeq.isEmpty else { return false }
        let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
        let c0 = max(0, rect.x / 64), c1 = min(cols - 1, (rect.maxX - 1) / 64), r0 = max(0, rect.y / 64), r1 = min(rows - 1, (rect.maxY - 1) / 64)
        guard c1 >= c0, r1 >= r0 else { return false }
        for r in r0...r1 { for cc in c0...c1 where v.tileCaptureSeq[r * cols + cc] > captureSeq { return true } }
        return false
    }

    /// The layer view for a tile message's layer, created on its `.reset`; messages for an unknown layer are dropped.
    private func ensureLayerView(_ id: UInt32) -> LayerView? {
        if let v = layerViews[id] { return v }
        guard let context else { return nil }
        let v = LayerView(id: id, context: context); v.compositor.crossfadeNanos = tunables.crossfadeNanos
        v.lastSeenInListNanos = Clock.nowNanos()
        layerViews[id] = v
        return v
    }

    /// A tile message's rect in display coordinates (window layers are stored in their own coordinates).
    private func displayRect(_ r: PixelRect, layer: UInt32) -> PixelRect {
        guard layer != 0 else { return r }
        predictorLock.lock(); defer { predictorLock.unlock() }
        guard let f = hostFrames[layer] else { return r }
        return r.offset(f.x, f.y)
    }

    private func apply(_ msg: TileMessage, seq: UInt32, bytes: Int, now: UInt64) {
        statsLock.lock(); sTotalBytes += bytes; statsLock.unlock()
        switch msg {
        case .tiles(let t):
            guard let v = layerView(t.header.windowID) else { sender?.send(.tileAck(.init(msgSeq: seq, captureNanos: t.header.captureNanos, receivedNanos: now, bytes: bytes))); return }
            var candidates = t.tiles
            // Window-free desktop pixels (the host's desktop-only capture) pass the guard: nothing of a window can be in them.
            if v.id == 0, !t.windowFree {
                let n = candidates.count
                let dropped = candidates.filter { !viewerGuard.allows($0.rect, now: now) }
                candidates.removeAll { !viewerGuard.allows($0.rect, now: now) }
                guardDrops += n - candidates.count
                let m = candidates.count
                candidates.removeAll { preExclusion($0.rect, captureSeq: t.header.captureSeq) }
                preExclusionDrops += m - candidates.count
                _ = dropped   // the canvas keeps what it had there; a dropped write contaminates nothing
            }
            let fresh = candidates.filter { isFresh(v, $0.rect, captureSeq: t.header.captureSeq) }
            // A lossy desktop refinement is that tile's final quality (photographic rects end at q90 on links ≤ 2 Mbps): it counts
            // as final for the lossless measurements, like a lossless tile. (A window's lossy refinement is its middle level.)
            let finalLossy = v.id == 0 && t.refinement
            for tile in fresh where wouldBeStale(v, tile.rect, captureSeq: t.header.captureSeq) { staleCommits += 1 }   // must never happen
            // Staged tiles build the layer's next level off-screen (DESIGN §3.3); where one lands on desktop the scene
            // draws as fill (nothing clean known there, not under a window layer), that part is shown at once too: any
            // clean picture beats the fill.
            let staged = t.staged ? fresh : []
            var shown = t.staged ? [] : fresh
            // Test only: MIRAGE_TEST_DROP_DESKTOP=N silently drops every Nth directly shown desktop write (a lost write,
            // the failure the picture audit must heal).
            if v.id == 0, Self.testDropEvery > 0, !shown.isEmpty { testDropCount += 1; if testDropCount % Self.testDropEvery == 0 { testDropped += shown.count; shown = [] } }
            let fillParts = t.staged && v.id == 0 ? visibleFillTiles(touching: staged.map(\.rect)) : []
            if v.id == 0 { markDesktopClean(shown.map(\.rect) + fillParts) }
            var n = 0
            if Self.debugPresent { log("\(Clock.nowNanos() / 1_000_000) present L\(v.id) seq \(seq) capture \(t.header.captureSeq): shown \(shown.map { "\($0.rect.x),\($0.rect.y) \($0.rect.width)x\($0.rect.height)\($0.format == .lossy ? "L" : "")" }.joined(separator: " ")) staged \(staged.map { "\($0.rect.x),\($0.rect.y) \($0.rect.width)x\($0.rect.height)" }.joined(separator: " "))\(t.refinement ? " (refinement)" : "")") }
            if !shown.isEmpty { n += v.compositor.applyTiles(shown, crossfade: t.refinement && !t.staged) }
            if !staged.isEmpty { n += v.compositor.applyTiles(staged, staged: true, alsoShow: fillParts); v.stagedLossless += staged.filter { $0.format != .lossy || finalLossy }.map(\.rect) }
            if !t.staged, !shown.isEmpty {
                let area = shown.reduce(0) { $0 + $1.rect.area }, whole = area * 10 >= max(1, v.compositor.width * v.compositor.height) * 9
                if shown.contains(where: { $0.format == .lossy }) && whole { v.step(t.refinement ? "fade" : "still", now: now) }
                else if t.refinement && !(v.id == 0 && shown.allSatisfy { underWindow($0.rect) }) { v.looseRefinements += 1 }
            }
            v.receivedBytes += t.bytes; v.tilesApplied += n; v.stills += fresh.filter { $0.format == .lossy }.count
            statsLock.lock(); sTileBytes += t.bytes; sTileRects += n; statsLock.unlock()
            if t.refinement { lastRefinementNanos = now; if Self.debugTiles, refinementLogged < 6 { refinementLogged += 1; log("refinement batch (layer \(v.id)): \(t.tiles.prefix(2).map { "\($0.rect)" })") } }
            let c = v.compositor
            if c.width > 0 {
                let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
                if v.losslessAt.count != cols * rows { v.losslessAt = Array(repeating: 0, count: cols * rows) }
                for tile in shown where tile.format != .lossy || finalLossy {
                    let c0 = max(0, tile.rect.x / 64), c1 = min(cols - 1, (tile.rect.maxX - 1) / 64), r0 = max(0, tile.rect.y / 64), r1 = min(rows - 1, (tile.rect.maxY - 1) / 64)
                    if c1 >= c0, r1 >= r0 { for r in r0...r1 { for cc in c0...c1 { v.losslessAt[r * cols + cc] = now } } }
                }
            }
            checkLegible()
            if !watchRect.isEmpty {
                // A layered watched window: only its own layer's tiles count (the display around it is other people's business).
                let inside = watchWindowID != 0 && isWatchedLayered() ? (v.id == watchWindowID ? t.tiles : []) : t.tiles.filter { displayRect($0.rect, layer: v.id).intersects(watchRect) }
                if !inside.isEmpty {
                    lastWatchedTileNanos = now; watchedTileBytes += inside.reduce(0) { $0 + $1.data.count }; watchedTileCount += inside.count
                    if inside.contains(where: { $0.rect.area >= 1024 }) { lastWatchedLargeTileNanos = now }
                    if !t.refinement { watchedDirectBytes += inside.reduce(0) { $0 + $1.data.count } }
                    if Self.debugTiles { log("tiles\(t.refinement ? " (refine)" : "") layer \(v.id) seq \(t.header.captureSeq) in watch rect: " + inside.map { "\($0.rect.width)x\($0.rect.height)@\($0.rect.x),\($0.rect.y) \($0.data.count)B \($0.format)" }.joined(separator: "  ")) }
                }
            }
            // Display rects first: displayRect takes predictorLock itself (NSLock is not recursive; calling it inside the
            // lock deadlocked the video queue on the first direct tile, fc43def).
            let landed = t.staged ? [] : t.tiles.map { displayRect($0.rect, layer: v.id) }
            predictorLock.lock()
            for tile in t.tiles { predictor.hostUpdate(inputSeq: t.header.inputSeq, rect: tile.rect, now: now) }
            for r in landed { typeaheadLanded(inputSeq: t.header.inputSeq, rect: r, now: now) }
            predictorLock.unlock()
            sender?.send(.tileAck(.init(msgSeq: seq, captureNanos: t.header.captureNanos, receivedNanos: now, bytes: bytes)))
        case .copyRect(let c):
            guard let v = layerView(c.header.windowID) else { sender?.send(.tileAck(.init(msgSeq: seq, captureNanos: c.header.captureNanos, receivedNanos: now, bytes: bytes))); return }
            v.compositor.applyCopyRect(c.rect, dx: c.dx, dy: c.dy)
            if Self.debugPresent { log("\(Clock.nowNanos() / 1_000_000) present L\(v.id) seq \(seq): copy \(c.rect.x),\(c.rect.y) \(c.rect.width)x\(c.rect.height) by \(c.dx),\(c.dy) capture \(c.header.captureSeq)") }
            markCapture(v, c.rect.union(c.rect.offset(c.dx, c.dy)), captureSeq: c.header.captureSeq)
            statsLock.lock(); sCopyRects += 1; statsLock.unlock()
            if !watchRect.isEmpty, watchWindowID != 0 && isWatchedLayered() ? v.id == watchWindowID : displayRect(c.rect.union(c.rect.offset(c.dx, c.dy)), layer: v.id).intersects(watchRect) { lastWatchedCopyNanos = now; watchedCopyRects += 1 }
            predictorLock.lock()
            predictor.hostCopyRect(windowID: c.header.windowID, rect: c.rect, dx: c.dx, dy: c.dy, inputSeq: c.header.inputSeq, now: now)
            predictor.hostUpdate(inputSeq: c.header.inputSeq, rect: c.rect.union(c.rect.offset(c.dx, c.dy)), now: now)
            predictorLock.unlock()
            sender?.send(.tileAck(.init(msgSeq: seq, captureNanos: c.header.captureNanos, receivedNanos: now, bytes: bytes)))
        case .commitSet(let ids):
            // Stage 1 as one transaction: every layer's level presented in the same pass (one message: all or nothing).
            for id in ids { commit(layer: id, now: now) }
            if Self.debugTiles || Self.debugPresent { log("\(Clock.nowNanos() / 1_000_000) present: stage 1 committed together (layers \(ids.map(String.init).joined(separator: " ")))") }
        case .commit(let layer):
            commit(layer: layer, now: now)
        case .reset(let layer, let w, let h):
            if layer == 0 {
                // A fresh stream at the same size keeps the pixels (review M11: the last picture stays until the
                // first keyframe replaces it); a size change clears. Either way nothing old is trusted any more.
                compositor?.configure(width: w, height: h)   // clears only on a size change
                compositor?.discardStaged(); displayView?.stagedLossless = []
                displayView?.tileCaptureSeq = []
                assembler = FrameAssembler(); for v in layerViews.values { v.lastRecoverySeq = 0 }   // review M4: the host's sequence may restart
                predictorLock.lock(); predictor = Predictor(); predictorLock.unlock()
            } else if let v = ensureLayerView(layer) {
                // A window layer announced (new, resized, or re-announced on resume): its canvas at the window's pixel size.
                v.compositor.configureKeepingPixels(width: w, height: h)
                v.compositor.discardStaged(); v.stagedLossless = []
                v.tileCaptureSeq = []
                predictorLock.lock(); predictor.forget(windowID: layer); predictorLock.unlock()
                enforceLayerMemory(now: now)
            }
        }
        onChange?()
        if case .reset = msg {} else { notePictureChange(now) }
    }

    /// A window layer's corner radius from its alpha, after each presented level (its shadow follows it).
    private func measureCorner(_ v: LayerView) {
        let c = v.compositor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {   // after the commit's crossfade has landed
            c.sampleCornerRadius { r in if let r, r > 0 { c.cornerRadius = Float(r) } }
        }
    }

    /// Picture audit (TileAudit), on the video queue: fingerprints of the host's view of desktop tiles against this
    /// canvas; a tile that differs (and is not newer here, staged or fading) is asked for again.
    private(set) var auditCompared = 0, auditMismatched = 0
    static let testDropEvery = ProcessInfo.processInfo.environment["MIRAGE_TEST_DROP_DESKTOP"].flatMap { Int($0) } ?? 0
    private var testDropCount = 0
    private(set) var staleVideoTiles = 0
    private(set) var testDropped = 0
    private func audit(_ a: ControlMessage.TileAuditMessage) {
        guard let v = layerView(a.layer), v.compositor.width > 0, a.prints.count == a.tiles.count * 16 else { return }
        let c = v.compositor
        let t = TileTracker(width: c.width, height: c.height)
        var idx: [Int] = [], rects: [PixelRect] = []
        for (k, ti) in a.tiles.enumerated() {
            let i = Int(ti)
            guard i < t.tileCount else { continue }
            if i < v.tileCaptureSeq.count, v.tileCaptureSeq[i] > a.captureSeq { continue }   // newer pixels here
            let r = t.rect(of: i)
            if c.isStaged(tile: i) || c.fading(r) { continue }
            idx.append(k); rects.append(r)
        }
        guard !rects.isEmpty else { return }
        let prints = [UInt8](a.prints)
        c.read(rects) { [weak self] datas in
            guard let self, datas.count == rects.count else { return }
            var bad: [UInt32] = []
            for (n, d) in datas.enumerated() {
                let r = rects[n]
                let mine: [UInt8] = d.withUnsafeBytes { p in TileAudit.fingerprint(ShiftDetector.Frame(base: p.baseAddress!, stride: r.width * 4, width: r.width, height: r.height), PixelRect(x: 0, y: 0, width: r.width, height: r.height)) }
                let k = idx[n]
                if TileAudit.differs(mine[...], prints[(k * 16)..<(k * 16 + 16)]) { bad.append(a.tiles[k]) }
            }
            self.videoQueue.async {
                self.auditCompared += datas.count; self.auditMismatched += bad.count
                if !bad.isEmpty {
                    self.log("picture audit: \(bad.count) of \(datas.count) \(a.layer == 0 ? "desktop" : "window \(a.layer)") tiles differ from the host's; asking for them again")
                    self.sender?.send(.refreshTiles(.init(layer: a.layer, tiles: bad)))
                }
            }
        }
    }

    /// Desktop tiles (64-px rects) under `rects` that the scene draws as fill: no clean pixels known, not under a window layer.
    private func visibleFillTiles(touching rects: [PixelRect]) -> [PixelRect] {
        let unknown = unknownDesktop
        guard !unknown.isEmpty, let c = compositor, c.width > 0 else { return [] }
        let layerRects = arrangedWindows().filter(\.hidesBehind).map(\.frame)
        let t = TileTracker(width: c.width, height: c.height)
        return t.tiles(covering: rects).filter { i in unknown[i]?.contains { p in !layerRects.contains { $0.intersection(p.rect) == p.rect } } ?? false }.map { t.rect(of: $0) }
    }

    /// Whether a display rect lies under an opaque window layer the scene draws (the underlay: nobody sees it now).
    private func underWindow(_ r: PixelRect) -> Bool {
        arrangedWindows().contains { $0.hidesBehind && $0.isLayered && $0.frame.intersection(r) == r }
    }

    /// A desktop write captured before a layered window was excluded from the display stream, where that window
    /// was before its exclusion: it may show the window (the M3.1 fragments). Never committed.
    private func preExclusion(_ rect: PixelRect, captureSeq: UInt32) -> Bool {
        for (id, area) in preExclusionArea where area.intersects(rect) {
            guard let from = excludedFrom[id] else { return true }   // not excluded yet: anything there may show it
            if captureSeq < from { return true }
        }
        return false
    }

    /// Every 2 s: ask the host to resend the unknown desktop tiles the scene shows (not under a window layer).
    private var lastRefreshAskNanos: UInt64 = 0
    private func askForUnknownDesktop(now: UInt64) {
        guard Clock.elapsed(since: lastRefreshAskNanos, now: now) > 300_000_000, let c = compositor, c.width > 0 else { return }
        lastRefreshAskNanos = now
        let unknown = unknownDesktop
        guard !unknown.isEmpty else { return }
        let layerRects = arrangedWindows().filter(\.hidesBehind).map(\.frame)
        let visible = unknown.filter { _, parts in parts.contains { p in !layerRects.contains { $0.intersection(p.rect) == p.rect } } }.keys.sorted().prefix(4000)
        guard !visible.isEmpty else { return }
        sender?.send(.refreshTiles(.init(layer: 0, tiles: visible.map { UInt32($0) })))
    }

    func unknownVisibleCount() -> Int {
        guard let c = compositor, c.width > 0 else { return 0 }
        _ = c
        let layerRects = arrangedWindows().filter(\.hidesBehind).map(\.frame)
        return unknownDesktop.filter { _, parts in parts.contains { p in !layerRects.contains { $0.intersection(p.rect) == p.rect } } }.count
    }
    /// Whether the scene draws any of `rect` as fill (no clean desktop pixels known there).
    func desktopUnknown(_ rect: PixelRect) -> Bool {
        guard let c = compositor, c.width > 0 else { return false }
        _ = c
        return unknownDesktop.values.contains { $0.contains { $0.rect.intersects(rect) } }
    }
    /// Desktop tiles fully written by a host update that passed the guard hold clean desktop now.
    private func markDesktopClean(_ rects: [PixelRect]) {
        guard !unknownDesktop.isEmpty, let c = compositor, c.width > 0 else { return }
        let t = TileTracker(width: c.width, height: c.height)
        var u = unknownDesktop
        for r in rects { for i in t.tiles(covering: [r]) where t.rect(of: i).intersection(r) == t.rect(of: i) { u[i] = nil } }
        unknownDesktop = u
    }
    /// The fill for desktop tiles with no clean pixels: the desktop's own average colour (sampled every 2 s).
    private func refreshDesktopColor(now: UInt64) {
        desktopLock.lock(); let due = Clock.elapsed(since: lastDesktopColorNanos, now: now) > 2_000_000_000; if due { lastDesktopColorNanos = now }; desktopLock.unlock()
        guard due, let c = compositor, c.width > 0 else { return }
        videoQueue.async { c.sampleEdgeColor(of: PixelRect(x: 0, y: c.height * 3 / 5, width: c.width, height: 1), bottom: false) { [weak self] col in self?.desktopColor = col } }
    }

    /// Layers absent from the window list are released after a while, sooner under memory pressure.
    private func enforceLayerMemory(now: UInt64) {
        predictorLock.lock(); let present = Set(windows.map(\.id)); predictorLock.unlock()
        var total = layerViews.values.reduce(0) { $0 + $1.compositor.textureBytes }
        let absent = layerViews.values.filter { $0.id != 0 && !present.contains($0.id) }.sorted { $0.lastSeenInListNanos < $1.lastSeenInListNanos }
        for v in absent where Clock.elapsed(since: v.lastSeenInListNanos, now: now) > 30_000_000_000 || total > layerMemoryBudget {
            total -= v.compositor.textureBytes
            v.compositor.release(); layerViews[v.id] = nil
            predictorLock.lock(); predictor.forget(windowID: v.id); predictorLock.unlock()
        }
        if total > layerMemoryBudget { for v in layerViews.values where v.id != 0 { v.compositor.trim() } }
    }

    private func ingest(_ frag: VideoFragment) {
        let now = Clock.nowNanos()
        handle(assembler.ingest(frag, now: now), now: now)
    }

    /// Time-driven assembler pass (NACKs and timeouts fire even when nothing arrives).
    func assemblerTick() {
        let now = Clock.nowNanos()
        for v in layerViews.values { v.compositor.settle(now: now) }
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
            case .lost(let seq, let layer):
                // The assembler gives up on an old partial after its timeout; if a recovery frame newer
                // than it was decoded meanwhile, nothing is missing (the host ignores such acks too). A frame
                // of unknown layer (nothing of it arrived) puts every layer that decodes into recovery.
                for v in layerViews.values where (layer == nil || layer == v.id) && seq > v.lastRecoverySeq && v.decoder.width > 0 { v.awaitingRecovery = true }
                statsLock.lock(); sLost += 1; statsLock.unlock()
                sender?.send(.frameAck(.init(seq: seq, captureNanos: 0, receivedNanos: now, decodedNanos: 0, bytes: 0, lost: true)))
            case .gap(let from, let to):
                // A loss burst: nothing of frames from...to ever arrived. Ask for a recovery frame now
                // rather than after a timeout; frames that follow are P-frames and are skipped until it lands.
                log("video: frames \(from)–\(to) never arrived (loss burst); asking for recovery")
                for v in layerViews.values where to > v.lastRecoverySeq && v.decoder.width > 0 { v.awaitingRecovery = true }
                statsLock.lock(); sLost += Int(to - from + 1); sBursts += 1; statsLock.unlock()
                sender?.send(.frameAck(.init(seq: to, captureNanos: 0, receivedNanos: now, decodedNanos: 0, bytes: 0, lost: true)))
            case .completed(let frame):
                statsLock.lock(); sBytes += frame.bytes; sTotalBytes += frame.bytes; statsLock.unlock()
                guard let v = layerView(frame.layerID) else {
                    if Self.debugTiles { log("video: frame \(frame.seq) for unknown layer \(frame.layerID) (\(layerViews.keys.sorted()))") }
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: 0, bytes: frame.bytes, lost: false,
                                                 firstReceivedNanos: frame.firstFragmentNanos, fragments: frame.fragments, fragmentsLost: frame.fragmentsLost)))
                    continue
                }
                if v.awaitingRecovery && !frame.flags.contains(.recovery) {
                    if Self.debugTiles { log("video: frame \(frame.seq) layer \(v.id) skipped (awaiting recovery)") }
                    statsLock.lock(); sDropped += 1; statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: 0, bytes: frame.bytes, lost: false,
                                                 firstReceivedNanos: frame.firstFragmentNanos, fragments: frame.fragments, fragmentsLost: frame.fragmentsLost)))
                    continue
                }
                let t0 = Clock.nowNanos()
                do {
                    let image = try v.decoder.decode(frame)
                    let t1 = Clock.nowNanos()
                    if Self.debugTiles, frame.flags.contains(.keyframe) { log("video: keyframe \(frame.seq) layer \(v.id) decoded \(v.decoder.width)x\(v.decoder.height) region \(frame.region)") }
                    v.awaitingRecovery = false
                    if frame.flags.contains(.recovery) { v.lastRecoverySeq = max(v.lastRecoverySeq, frame.seq) }
                    let compositor = v.compositor
                    if compositor.width == 0 { compositor.configure(width: v.decoder.width, height: v.decoder.height) }
                    let region = frame.region.isEmpty ? PixelRect(x: 0, y: 0, width: compositor.width, height: compositor.height) : frame.region
                    let grid = TileMask.grid(for: region)
                    var mask = frame.tileMask.flatMap { TileMask(cols: grid.cols, rows: grid.rows, bits: $0) } ?? TileMask.full(cols: grid.cols, rows: grid.rows)
                    var written: [PixelRect] = []
                    for r in 0..<grid.rows { for c in 0..<grid.cols where mask[c, r] {
                        let tr = PixelRect(x: region.x + c * 64, y: region.y + r * 64, width: 64, height: 64).intersection(region)
                        if v.id == 0, !viewerGuard.allows(tr, now: now) { mask[c, r] = false; guardDrops += 1 }
                        else if v.id == 0, preExclusion(tr, captureSeq: frame.captureSeq) { mask[c, r] = false; preExclusionDrops += 1 }
                        // Video rides datagrams, copy-rects and tiles the stream: a frame from an older capture than what already
                        // landed here (a scroll's copy-rect that overtook it) would put pre-scroll pixels back (striped Finder icons).
                        else if wouldBeStale(v, tr, captureSeq: frame.captureSeq) { mask[c, r] = false; staleVideoTiles += 1 }
                        else { written.append(tr) }
                    } }
                    compositor.applyVideo(image, region: region, mask: mask, crossfade: frame.flags.contains(.progressive))
                    if Self.debugPresent { log("\(Clock.nowNanos() / 1_000_000) present L\(v.id) video \(frame.seq)\(frame.flags.contains(.keyframe) ? " key" : "")\(frame.flags.contains(.progressive) ? " progressive" : "") region \(region) tiles \(written.count)") }
                    if frame.flags.contains(.keyframe), region.area * 10 >= compositor.width * compositor.height * 9 { v.step(frame.flags.contains(.progressive) ? "fade" : "key", now: now) }
                    if v.id == 0 { markDesktopClean(written) }
                    v.receivedBytes += frame.bytes; v.videoFrames += 1
                    if !frame.flags.contains(.progressive) { markCapture(v, region, captureSeq: frame.captureSeq) }
                    notePictureChange(now)
                    statsLock.lock(); let since = connectedAtNanos; statsLock.unlock()
                    if lastVideoNanos > 0, since > 0, now > since &+ steadyAfterNanos, now > lastVideoNanos {
                        let gap = Double(Clock.elapsed(since: lastVideoNanos, now: now)) / 1e6
                        if gap > maxVideoGapMs { maxVideoGapMs = gap }
                        if gap > 500 { videoGapsOver500.append(gap) }
                    }
                    lastVideoNanos = now
                    if !watchRect.isEmpty, watchWindowID != 0 && isWatchedLayered() ? v.id == watchWindowID : displayRect(region, layer: v.id).intersects(watchRect) { lastWatchedVideoNanos = now; watchedVideoFrames += 1 }
                    predictorLock.lock(); predictor.hostUpdate(inputSeq: frame.inputSeq, rect: region, now: now); predictorLock.unlock()
                    onChange?()
                    statsLock.lock()
                    sFrames += 1; sDecodeNanos += Clock.elapsed(since: t0, now: t1)
                    if bestRTT.isFinite {   // frame age needs the clock offset from a pong first
                        let ageNanos = max(0, (Double(t1) + clockOffset) - Double(frame.captureNanos))
                        sAge = sAge == 0 ? ageNanos : sAge * 0.7 + ageNanos * 0.3
                    }
                    statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: t1, bytes: frame.bytes, lost: false,
                                                 firstReceivedNanos: frame.firstFragmentNanos, fragments: frame.fragments, fragmentsLost: frame.fragmentsLost)))
                } catch {
                    log("decode seq \(frame.seq) (layer \(v.id)): \(error)")
                    v.awaitingRecovery = true
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
            if let flow { if upShaper != nil { sendDatagram(DatagramPing.encode(seq: pingSeq), on: flow) } else { try? await flow.sendRaw(DatagramPing.encode(seq: pingSeq)) } }
        }
    }

    private func statsLoop() async {
        while !stopped {
            try? await Task.sleep(for: .seconds(1))
            watchdog(now: Clock.nowNanos())
            askForUnknownDesktop(now: Clock.nowNanos())
            statsLock.lock()
            let frames = sFrames, bytes = sBytes, lost = sLost, dec = sDecodeNanos, age = sAge, rtt = sRTT, dropped = sDropped
            let tileBytes = sTileBytes, tileRects = sTileRects, copies = sCopyRects, rate = rateState, nacks = sNacks, bursts = sBursts
            sFrames = 0; sBytes = 0; sLost = 0; sDecodeNanos = 0; sDropped = 0; sTileBytes = 0; sTileRects = 0; sCopyRects = 0; sNacks = 0; sBursts = 0
            statsLock.unlock()
            predictorLock.lock(); let pstats = predictor.stats; predictorLock.unlock()
            let diags = videoQueue.sync { layerDiagnostics() }
            let shape = diags.map { "\($0.id) \($0.drawnAs) \($0.visible) \($0.why ?? "") \($0.canvas) \($0.layeredOnHost)" }
            if shape != lastDiagLog.map({ "\($0.id) \($0.drawnAs) \($0.visible) \($0.why ?? "") \($0.canvas) \($0.layeredOnHost)" }) || Clock.elapsed(since: lastDiagLogNanos, now: Clock.nowNanos()) > 10_000_000_000 {
                lastDiagLog = diags; lastDiagLogNanos = Clock.nowNanos()
                for d in diags { log("layer diag: \(d.id) '\(d.title)' L\(d.level) host-layered \(d.layeredOnHost) canvas \(d.canvas) rx \(d.receivedBytes / 1000) KB (\(d.tiles) tiles, \(d.stills) stills, \(d.videoFrames) frames) frame \(d.frame.x),\(d.frame.y) \(d.frame.width)x\(d.frame.height) viewport \(d.viewport.x),\(d.viewport.y) \(d.viewport.width)x\(d.viewport.height) drawn as \(d.drawnAs) \(d.visible ? "VISIBLE" : "NOT VISIBLE") \(d.why ?? "")\(d.coveredBy.isEmpty ? "" : " covered by \(d.coveredBy)")") }
            }
            let inp = inputState()
            let w = displayView?.decoder.width ?? 0, h = displayView?.decoder.height ?? 0
            let upscaling = compositor?.usesMetalFX ?? false
            await MainActor.run {
                var s = model.stats
                s.fps = Double(frames); s.kbps = Double(bytes) * 8 / 1000; s.lost += lost; s.frames += frames; s.dropped += dropped
                s.decodeMs = frames > 0 ? Double(dec) / Double(frames) / 1e6 : s.decodeMs
                s.frameAgeMs = age / 1e6; s.rttMs = rtt; s.width = w; s.height = h
                s.tileKbps = Double(tileBytes) * 8 / 1000; s.tileRects += tileRects; s.copyRects += copies; s.rate = rate; s.predictions = pstats; s.upscaling = upscaling
                s.nacks += nacks; s.recoveredByNack = self.assembler.recoveredByNack; s.recoveredByParity = self.assembler.recoveredByParity; s.bursts += bursts
                s.layers = self.layerViews.count - 1; s.layerMB = self.layerViews.values.reduce(0) { $0 + $1.compositor.textureBytes } >> 20
                model.stats = s
                model.inputQueued = inp.queued; model.inputDropped = inp.dropped; model.inputHeld = inp.held
                if frames > 0 || bytes > 0 || tileBytes > 0 {
                    samples.append(Sample(t: Date().timeIntervalSince(startDate), rttMs: rtt, frameAgeMs: age / 1e6, fps: Double(frames), kbps: Double(bytes) * 8 / 1000,
                                          decodeMs: s.decodeMs, lost: lost, skipped: dropped, width: w, height: h,
                                          tileKbps: s.tileKbps, tileRects: tileRects, copyRects: copies, targetKbps: rate.targetKbps, capacityKbps: rate.capacityKbps,
                                          queueMs: rate.queueMs, rung: rate.rung, scale: rate.scale, tier: rate.tier?.name, totalBytes: self.totalBytes()))
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
    /// `queued`: keystrokes only (pointer events are best effort, never counted or replayed late).
    func inputState() -> InputState { inputQueue.sync { let now = Clock.nowNanos(); return InputState(queued: input.queuedKeystrokes, dropped: input.droppedByCap, packets: input.packetsSent, held: input.held && input.queuedKeystrokes > 0, oldestMs: Double(input.oldestUnackedNanos(now: now)) / 1e6) } }
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
        sendDatagram(d, on: flow)
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
        guard legibleUnderPointerMs == nil, streamStartNanos > 0, !pointerRect.isEmpty else { return }
        var earliest: UInt64 = .max
        for v in layerViews.values {
            let c = v.compositor
            guard c.width > 0, !v.losslessAt.isEmpty else { continue }
            // The pointer rect in this layer's coordinates (the window under the pointer, or the display).
            var pr = pointerRect
            if v.id != 0 { predictorLock.lock(); let f = hostFrames[v.id]; predictorLock.unlock(); guard let f else { continue }; pr = pr.offset(-f.x, -f.y) }
            let cols = (c.width + 63) / 64, rows = (c.height + 63) / 64
            let c0 = max(0, pr.x / 64), c1 = min(cols - 1, (pr.maxX - 1) / 64), r0 = max(0, pr.y / 64), r1 = min(rows - 1, (pr.maxY - 1) / 64)
            guard c1 >= c0, r1 >= r0 else { continue }
            for r in r0...r1 { for cc in c0...c1 { let t = v.losslessAt[r * cols + cc]; if t > streamStartNanos, t < earliest { earliest = t } } }
        }
        guard earliest != .max else { return }
        legibleUnderPointerMs = Double(earliest - streamStartNanos) / 1e6
        log(String(format: "legible under the pointer %.0f ms after the stream started", legibleUnderPointerMs!))
    }

    /// Test measurement: of the desktop layer's tiles touching `rects`, how many have been shown lossless since the stream
    /// started, and when the last of those landed (ms after the start).
    func desktopLosslessCoverage(_ rects: [PixelRect], excluding covered: [PixelRect] = []) -> (lossless: Int, total: Int, lastMs: Double) {
        var n = 0, total = 0, last: UInt64 = 0
        videoQueue.sync {
            guard let v = layerViews[0], v.compositor.width > 0, !v.losslessAt.isEmpty, streamStartNanos > 0 else { return }
            let cols = (v.compositor.width + 63) / 64, rows = (v.compositor.height + 63) / 64
            var seen = Set<Int>()
            for pr in rects {
                let c0 = max(0, pr.x / 64), c1 = min(cols - 1, (pr.maxX - 1) / 64), r0 = max(0, pr.y / 64), r1 = min(rows - 1, (pr.maxY - 1) / 64)
                guard c1 >= c0, r1 >= r0 else { continue }
                for r in r0...r1 { for c in c0...c1 where seen.insert(r * cols + c).inserted {
                    let tile = PixelRect(x: c * 64, y: r * 64, width: 64, height: 64)
                    if covered.contains(where: { $0.intersection(tile) == tile }) { continue }   // under a window: never sent there
                    total += 1
                    let t = v.losslessAt[r * cols + c]
                    if t > streamStartNanos { n += 1; last = max(last, t) }
                } }
            }
        }
        return (n, total, last > streamStartNanos ? Double(last - streamStartNanos) / 1e6 : 0)
    }

    func sendMouseMove(x: Double, y: Double) {
        notePointer(x: x, y: y)
        // Coalesce to ~60 Hz; the pointer state is latest-wins so a skipped move costs nothing.
        let now = Clock.nowNanos()
        if Clock.elapsed(since: lastMoveSent, now: now) < 15_000_000 { pendingMove = .init(x: x, y: y); scheduleMoveFlush(); return }
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

    // MARK: Typeahead (DESIGN §3.5 item 4)

    /// Guarded by predictorLock.
    private var typeahead = Typeahead()
    /// Stream pixels per host point, readable from any queue (typeahead runs on the scenario's task too).
    private var hostPxPerPoint = 2.0
    /// Key time per predicted glyph, and the measured times: key → drawn here, key → host pixels over it.
    private var typeaheadKeyNanos: [UInt64: UInt64] = [:]
    private(set) var typeaheadVisibleMs: [Double] = [], typeaheadEchoMs: [Double] = []
    var typeaheadEnabled = ProcessInfo.processInfo.environment["MIRAGE_NO_TYPEAHEAD"] == nil
    /// On predictorLock.
    private func typeaheadLanded(inputSeq: UInt64, rect: PixelRect, now: UInt64) {
        let before = typeahead.glyphs
        typeahead.pixels(inputSeq: inputSeq, rect: rect)
        for g in before where !typeahead.glyphs.contains(where: { $0.seq == g.seq }) {
            if let k = typeaheadKeyNanos.removeValue(forKey: g.seq) { typeaheadEchoMs.append(Double(Clock.elapsed(since: k, now: now)) / 1e6) }
        }
    }
    /// A key the viewer just sent (`seq`): predicted, taken back (backspace), or the predictions invalidated.
    func typeaheadKey(keyCode: UInt16, characters: String?, modifiers: KeyModifiers, seq: UInt64) {
        guard typeaheadEnabled, seq != 0 else { return }
        let now = Clock.nowNanos()
        predictorLock.lock(); defer { predictorLock.unlock() }
        let unpredictable: Set<UInt16> = [36, 76, 48, 53, 123, 124, 125, 126, 115, 116, 117, 119, 121]
        if keyCode == 51, modifiers.intersection([.command, .option, .control]).isEmpty { typeahead.backspace(seq: seq); return }
        guard modifiers.intersection([.command, .control]).isEmpty, !unpredictable.contains(keyCode),
              let ch = characters, ch.count == 1, let scalar = ch.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7f,
              !(0xF700...0xF8FF).contains(scalar.value) else { typeahead.invalidate(after: seq); return }
        guard let adv = advancePx(ch, caret: typeahead.caret) else { return }
        if typeahead.typed(ch, advance: adv, seq: seq, now: now) != nil {
            typeaheadKeyNanos[seq] = now
            if typeaheadKeyNanos.count > 256 { typeaheadKeyNanos = typeaheadKeyNanos.filter { $0.key + 128 > seq } }
        }
        onChange?()
    }
    /// Where typing lands now (display-layer pixels): just after the last predicted glyph, else the host's caret; nil
    /// without an editable focus. The iOS viewer keeps it in view when zoomed.
    func typingCaret() -> PixelRect? {
        predictorLock.lock(); defer { predictorLock.unlock() }
        if let g = typeahead.glyphs.last { return PixelRect(x: g.rect.maxX, y: g.rect.y, width: 1, height: g.rect.height) }
        return typeahead.caret?.caret
    }
    func typeaheadInvalidate(seq: UInt64) { predictorLock.lock(); typeahead.invalidate(after: seq); predictorLock.unlock() }
    /// A click is about to be sent (it moves the caret): predictions wait for the host's report after it.
    func typeaheadInvalidateBeforeClick() { typeaheadInvalidate(seq: lastInputSeqSent() + 1) }
    /// The glyph's advance in display pixels, in the host's font (the same font ships on both Macs; else the system font).
    private func advancePx(_ ch: String, caret: ControlMessage.CaretInfo?) -> Double? {
        guard let c = caret else { return nil }
        let size = c.size ?? 13
        let font = c.font.flatMap { PlatformFont(name: $0, size: size) } ?? PlatformFont.systemFont(ofSize: size)
        let w = (c.secure ? "•" : ch as NSString).size(withAttributes: [.font: font]).width
        return max(0.5, Double(w) * hostPxPerPoint)
    }
    /// What the overlay draws (and the first time each glyph is drawn, for the time-to-visible metric).
    struct TypeaheadView { var glyphs: [Typeahead.Glyph]; var font: String?; var size: Double; var color: [Double]? }
    func typeaheadSnapshot(drawnNow: Bool = true) -> TypeaheadView {
        predictorLock.lock(); defer { predictorLock.unlock() }
        let now = Clock.nowNanos()
        typeahead.expire(now: now)
        if drawnNow { for g in typeahead.glyphs where !typeaheadDrawn.contains(g.seq) { typeaheadDrawn.insert(g.seq); if let k = typeaheadKeyNanos[g.seq] { typeaheadVisibleMs.append(Double(Clock.elapsed(since: k, now: now)) / 1e6) } } }
        if typeaheadDrawn.count > 512 { typeaheadDrawn = Set(typeaheadDrawn.sorted().suffix(128)) }
        return TypeaheadView(glyphs: typeahead.glyphs, font: typeahead.caret?.font, size: typeahead.caret?.size ?? 13, color: typeahead.caret?.color)
    }
    private var typeaheadDrawn = Set<UInt64>()
    /// Bytes received for one layer so far (scenarios: per-layer cost of an interaction).
    func layerBytes(_ id: UInt32) -> Int { videoQueue.sync { layerViews[id]?.receivedBytes ?? 0 } }
    func typeaheadMisses() -> [Typeahead.Miss] { predictorLock.lock(); defer { predictorLock.unlock() }; return typeahead.misses }
    func typeaheadCounts() -> (shown: Int, confirmed: Int, mismatched: Int, expired: Int) {
        predictorLock.lock(); defer { predictorLock.unlock() }
        return (typeahead.shown, typeahead.confirmed, typeahead.mismatched, typeahead.expired)
    }

    // MARK: Window arrangement, local window management, prediction

    /// Host window frames (display coordinates) by id, as last published; layered windows' canvases map
    /// through these. Guarded by predictorLock.
    private var hostFrames: [UInt32: PixelRect] = [:]
    /// Local window management (DESIGN §3.5 item 2): a window being dragged shows at the local frame; a
    /// window clicked shows in front. Each override lasts until the host's list reflects the input that
    /// caused it (its `inputSeq`), or a moment after the interaction ends.
    private struct LocalFrame { var frame: PixelRect; var inputSeq: UInt64; var releasedNanos: UInt64 }
    /// Viewer half of the DisplayGuard (host frames, 0.5 s history): desktop writes where a layered window is or
    /// just was are dropped, never committed. `unknownDesktop`: desktop tiles that were under a window when it
    /// became a layer, so the canvas may still hold that window there; filled with the desktop colour wherever
    /// they show, until a clean write lands. Both on the video queue.
    private var viewerGuard = DisplayGuard(historyNanos: 500_000_000, margin: 0)
    private var _unknownDesktop: [Int: [(id: UInt32, rect: PixelRect)]] = [:]
    private let desktopLock = NSLock()
    private var unknownDesktop: [Int: [(id: UInt32, rect: PixelRect)]] {
        get { desktopLock.lock(); defer { desktopLock.unlock() }; return _unknownDesktop }
        set { desktopLock.lock(); _unknownDesktop = newValue; desktopLock.unlock() }
    }
    private(set) var guardDrops = 0, preExclusionDrops = 0
    /// Per layered window: the capture from which the display stream excludes it, and everywhere it was before
    /// that (desktop pixels captured earlier may show it there). On the video queue.
    private var excludedFrom: [UInt32: UInt32] = [:]
    private var preExclusionArea: [UInt32: PixelRect] = [:]
    private var _desktopColor = SIMD4<Float>(0.3, 0.3, 0.32, 1)
    private var desktopColor: SIMD4<Float> {
        get { desktopLock.lock(); defer { desktopLock.unlock() }; return _desktopColor }
        set { desktopLock.lock(); _desktopColor = newValue; desktopLock.unlock() }
    }
    private var lastDesktopColorNanos: UInt64 = 0
    private var localFrames: [UInt32: LocalFrame] = [:]
    private struct LocalRaise { var inputSeq: UInt64; var since: UInt64 }
    private var localRaise: (id: UInt32, LocalRaise)? = nil
    private var lastHostListInputSeq: UInt64 = 0
    private(set) var windowCommandsSent = 0
    /// Scenario metrics: frame changes of the watched window in host lists, and the last one's time.
    var watchWindowID: UInt32 = 0
    private(set) var lastWatchedMoveNanos: UInt64 = 0, watchedMoves = 0
    private var hostListSeq: UInt64 = 0
    private var wasLayered = Set<UInt32>()

    private func isWatchedLayered() -> Bool { predictorLock.lock(); defer { predictorLock.unlock() }; return windows.first { $0.id == watchWindowID }?.isLayered ?? false }
    /// The canvas showing a window (its own layer, or the display layer) and the window's origin in it.
    func canvas(for windowID: UInt32) -> (Compositor, origin: (Int, Int))? {
        guard let w = windowsSnapshot().first(where: { $0.id == windowID }) else { return nil }
        if w.isLayered, let v = layerViews[windowID], v.compositor.width > 0 { return (v.compositor, (0, 0)) }
        guard let c = compositor else { return nil }
        return (c, (w.frame.x, w.frame.y))
    }

    private func hostWindowList(_ list: ControlMessage.WindowList, now: UInt64) {
        if Self.debugPresent, let ch = list.changed, !ch.isEmpty { log(String(format: "%.3f window list in: ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)) + ch.map { "\($0.id) \($0.frame.x),\($0.frame.y)" }.joined(separator: " | ")) }
        predictorLock.lock()
        let before = hostFrames
        windows = list.apply(to: windows)
        hostFrames = Dictionary(windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        if let s = list.inputSeq { lastHostListInputSeq = max(lastHostListInputSeq, s) }
        hostListSeq += 1
        if watchWindowID != 0, let f = hostFrames[watchWindowID], before[watchWindowID] != f { lastWatchedMoveNanos = now; watchedMoves += 1 }
        // Overrides the host has caught up with are dropped.
        for (id, lf) in localFrames {
            let caughtUp = lastHostListInputSeq >= lf.inputSeq && lf.releasedNanos > 0
            let expired = lf.releasedNanos > 0 && Clock.elapsed(since: lf.releasedNanos, now: now) > 2_000_000_000
            if caughtUp || expired { localFrames[id] = nil }
        }
        if let (_, r) = localRaise, lastHostListInputSeq >= r.inputSeq || Clock.elapsed(since: r.since, now: now) > 1_500_000_000 { localRaise = nil }
        predictorLock.unlock()
        predictorLock.lock(); let snapshot = windows; predictorLock.unlock()
        let moved = snapshot.contains { $0.isLayered && before[$0.id] != nil && before[$0.id] != $0.frame }
        // Where a newly layered window's pixels may sit in the desktop canvas: its frame minus the desktop-layer
        // windows that were in front of it (the canvas shows those there, not it).
        // Only windows that hide what is behind them leave their pixels in the desktop canvas (a transparent overlay or
        // icons window does so only where it is opaque, which is tiny; a full-frame mark would fill the whole desktop).
        let newlyLayered: [(id: UInt32, pieces: [PixelRect])] = snapshot.filter { $0.hidesBehind && !(before.keys.contains($0.id) && wasLayered.contains($0.id)) }.map { w in
            (w.id, w.frame.subtracting(snapshot.filter { $0.z < w.z && !$0.isLayered && $0.windowLevel == 0 }.map(\.frame)))
        }
        let transparentIDs = Set(snapshot.filter { $0.isLayered && !$0.hidesBehind }.map(\.id))
        wasLayered = Set(snapshot.filter(\.isLayered).map(\.id))
        videoQueue.async { [weak self] in
            guard let self else { return }
            for w in snapshot { self.layerViews[w.id]?.lastSeenInListNanos = now }
            let layered = snapshot.filter(\.isLayered)
            for w in layered {
                if let e = w.excludedFrom { self.excludedFrom[w.id] = e }
                else { self.preExclusionArea[w.id] = self.preExclusionArea[w.id].map { $0.union(w.frame) } ?? w.frame }
                if w.excludedFrom == nil { self.excludedFrom[w.id] = nil }
            }
            for id in Array(self.preExclusionArea.keys) where !layered.contains(where: { $0.id == id }) && Clock.elapsed(since: self.layerViews[id]?.lastSeenInListNanos ?? 0, now: now) > 30_000_000_000 { self.preExclusionArea[id] = nil; self.excludedFrom[id] = nil }
            self.viewerGuard.update(layered: Dictionary(layered.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a }), verified: Set(layered.compactMap { $0.excludedFrom == nil ? nil : $0.id }), now: now)
            if let c = self.compositor, c.width > 0, !newlyLayered.isEmpty || !transparentIDs.isEmpty {
                // The desktop canvas may hold this window exactly where it was when it became a layer.
                let t = TileTracker(width: c.width, height: c.height)
                var u = self.unknownDesktop
                for (id, pieces) in newlyLayered { for p in pieces { for i in t.tiles(covering: [p]) {
                    let part = t.rect(of: i).intersection(p)
                    if !part.isEmpty { u[i, default: []].append((id, part)) }
                } } }
                // A window the host reports transparent left (almost) nothing there: withdraw its marks.
                if !transparentIDs.isEmpty { for (i, list) in u { let kept = list.filter { !transparentIDs.contains($0.id) }; u[i] = kept.isEmpty ? nil : kept } }
                self.unknownDesktop = u
            }
            self.enforceLayerMemory(now: now)
        }
        if moved { askForUnknownDesktop(now: now) }   // on uncover, not on a poll
        onChange?()
    }

    /// The window list as shown: local frames and the local raise applied, front to back.
    func arrangedWindows() -> [ControlMessage.WindowInfo] {
        predictorLock.lock(); defer { predictorLock.unlock() }
        return arrangedLocked()
    }
    private func arrangedLocked() -> [ControlMessage.WindowInfo] {
        var list = windows
        for i in list.indices { if let lf = localFrames[list[i].id] { list[i].frame = lf.frame } }
        if let (id, _) = localRaise, let i = list.firstIndex(where: { $0.id == id }), i > 0 {
            // A raised normal window goes in front of the other normal windows (never above menus or the menu bar).
            let w = list.remove(at: i)
            let j = list.firstIndex(where: { $0.windowLevel <= w.windowLevel }) ?? list.count
            list.insert(w, at: j)
        }
        return list
    }

    /// The scene for the renderer: the display layer, then every window back to front as a layer (its
    /// canvas at its shown frame, with a shadow) or as a cut-out of the display layer.
    func scene(pxPerPoint: Double) -> LayerScene? {
        guard let bg = compositor, bg.width > 0 else { return nil }
        scenePxPerPoint = pxPerPoint
        let arranged = arrangedWindows()
        let plan = LayerScenePlan.plan(arranged, hasCanvas: { id in (self.layerViews[id]?.compositor.width ?? 0) > 0 }, display: PixelRect(x: 0, y: 0, width: bg.width, height: bg.height), shadowMargin: Int(48 * pxPerPoint))
        let items = plan.sceneItems(pxPerPoint: Float(pxPerPoint), canvas: { self.layerViews[$0]?.compositor })
        let (disp, colors) = displacements()
        let layered = Set(plan.entries.filter { $0.kind == .layer }.map(\.id))
        let sd = disp.map { LayerScene.Displacement(layerID: layered.contains($0.windowID) ? $0.windowID : 0, displacement: $0) }
        // Unknown desktop tiles that the scene shows (no window layer over them).
        refreshDesktopColor(now: Clock.nowNanos())
        let fillColor = desktopColor
        let opaqueIDs = Set(arranged.filter(\.hidesBehind).map(\.id))
        let layerRects = plan.entries.filter { $0.kind == .layer && opaqueIDs.contains($0.id) }.map(\.frame)
        let fill = unknownDesktop.values.flatMap { $0.map(\.rect) }.filter { part in !layerRects.contains { $0.intersection(part) == part } }
        return LayerScene(background: bg, items: items, displacements: sd, bandColors: colors, displayFill: fill, fillColor: fillColor)
    }

    /// Per-layer diagnostics (DESIGN §6 M3.1 field regression): what the viewer holds for every window the
    /// host lists, and what the composited scene shows of it. `viewport` is where the window lands in the
    /// drawable (pixels; display-layer pixels when headless), `visible` whether any of it is drawn from
    /// pixels that contain the window, `why` the reason when not.
    struct LayerDiag: Codable, Equatable {
        var id: UInt32, title: String, level: Int, layeredOnHost: Bool, canvas: String, receivedBytes: Int, tiles: Int, stills: Int, videoFrames: Int
        var frame: PixelRect, viewport: PixelRect, drawnAs: String, coveredBy: [UInt32], visible: Bool, why: String?
        /// Presentation steps ("ms:kind") since the layer view was made, and refinement blocks presented on their own.
        var steps: [String] = [], looseRefinements = 0
    }
    /// The drawable rect the display layer was last drawn into (GUI); nil = headless (identity).
    var lastDest: CGRect? = nil
    func layerDiagnostics() -> [LayerDiag] {
        guard let bg = compositor, bg.width > 0 else { return [] }
        let arranged = arrangedWindows()
        let plan = LayerScenePlan.plan(arranged, hasCanvas: { id in (self.layerViews[id]?.compositor.width ?? 0) > 0 }, display: PixelRect(x: 0, y: 0, width: bg.width, height: bg.height))
        let sx = lastDest.map { Double($0.width) / Double(bg.width) } ?? 1, sy = lastDest.map { Double($0.height) / Double(bg.height) } ?? 1
        let ox = lastDest?.minX ?? 0, oy = lastDest?.minY ?? 0
        return arranged.filter { $0.windowLevel == 0 || $0.isLayered }.map { w in
            let v = layerViews[w.id]
            let vp = PixelRect(x: Int(ox + Double(w.frame.x) * sx), y: Int(oy + Double(w.frame.y) * sy), width: Int(Double(w.frame.width) * sx), height: Int(Double(w.frame.height) * sy))
            let e = plan.entries.first { $0.id == w.id }
            return LayerDiag(id: w.id, title: String(w.title.prefix(32)), level: w.windowLevel, layeredOnHost: w.isLayered,
                             canvas: v.map { "\($0.compositor.width)x\($0.compositor.height)" } ?? "none",
                             receivedBytes: v?.receivedBytes ?? 0, tiles: v?.tilesApplied ?? 0, stills: v?.stills ?? 0, videoFrames: v?.videoFrames ?? 0,
                             frame: w.frame, viewport: vp, drawnAs: e?.kind.rawValue ?? "?", coveredBy: e?.coveredBy ?? [], visible: e?.visible ?? false, why: e?.why,
                             steps: v?.steps.map { "\($0.ms):\($0.kind)" } ?? [], looseRefinements: v?.looseRefinements ?? 0)
        }
    }
    private var lastDiagLog: [LayerDiag] = []
    private var lastDiagLogNanos: UInt64 = 0

    /// Stream pixels per host display point (for scroll deltas and title-bar heights).
    @MainActor var pixelsPerPoint: Double {
        guard let i = model.streamInfo, i.displayWidth > 0 else { return 2 }
        return Double(i.width) / Double(i.displayWidth)
    }

    /// Topmost window under a stream-pixel point, as arranged locally (`WindowHitTest`: never the overlay layer, nor a
    /// display-sized window above the normal level).
    func window(at x: Int, _ y: Int) -> ControlMessage.WindowInfo? {
        WindowHitTest.window(at: x, y, in: arrangedWindows(), displayArea: compositor.map { $0.width * $0.height } ?? 0)
    }

    /// What a press at a stream pixel lands on and may become (a held title-bar press, a local raise, a predicted drag):
    /// the one rule the Mac and iOS views both follow.
    @MainActor func press(at x: Int, _ y: Int, plain: Bool, firstClick: Bool = true) -> WindowHitTest.Press {
        WindowHitTest.press(at: x, y, in: arrangedWindows(), displayArea: compositor.map { $0.width * $0.height } ?? 0,
                            pxPerPoint: pixelsPerPoint, plain: plain, firstClick: firstClick)
    }

    /// The rect a wheel event over `window` should shift (in the window's own coordinates when it is a
    /// layer): the host's learned scroll rect, else the content area below the title bar.
    /// The host's scroll rect for the view under the pointer (its AX scroll area), or nil until the host knows it. Real input
    /// predicts only with this: the guess below (the window under its title bar) included Finder's sidebar, and the first
    /// scroll frames showed the whole window body displaced locally.
    func knownScrollRect(for w: ControlMessage.WindowInfo) -> PixelRect? { w.scrollRect }
    func scrollRect(for w: ControlMessage.WindowInfo, titleBarPx: Int) -> PixelRect {
        if let r = w.scrollRect { return r }
        let f = w.isLayered ? PixelRect(x: 0, y: 0, width: w.frame.width, height: w.frame.height) : w.frame
        return PixelRect(x: f.x, y: f.y + titleBarPx, width: f.width, height: max(0, f.height - titleBarPx))
    }

    /// A press in a layered window: it comes to the front locally at once; the host's own raise (the click) confirms.
    func localRaise(windowID: UInt32, inputSeq: UInt64) {
        predictorLock.lock(); localRaise = (windowID, LocalRaise(inputSeq: inputSeq, since: Clock.nowNanos())); predictorLock.unlock()
        onChange?()
    }

    /// Local drag of a layered window (DESIGN §3.2): the window moves here, nothing is streamed for it,
    /// and the host is told the frame through a window command (throttled; the final one on release).
    private var lastMoveCommandNanos: UInt64 = 0
    /// A local layer drag's frame at its start and where the host lets it go (the frame shown and sent stays inside).
    private var layerDragLimits: [UInt32: (start: PixelRect, limits: WindowDragLimits?)] = [:]   // under predictorLock
    /// Pixels per point of the last scene drawn (the views pass it each frame).
    private var scenePxPerPoint = 2.0
    /// Where macOS lets a window of the host display be dragged (its menu bar from the window list), in stream pixels.
    func windowDragLimits() -> WindowDragLimits? {
        guard let c = compositor, c.width > 0, c.height > 0 else { return nil }
        return WindowDragLimits.host(display: PixelRect(x: 0, y: 0, width: c.width, height: c.height), windows: windowsSnapshot(), pxPerPoint: scenePxPerPoint)
    }
    /// Window drags as real mouse events on the host (tunable `injectedDrags`): the press, the moves and the release go as
    /// input, so the window server raises, activates and moves the window (Stage Manager, snapping, edge limits stay ground
    /// truth); the local layer drag is only a prediction, retired when the host's list reflects the release. Accessibility
    /// raises did not reorder windows across apps from the host's background agent (mac-daddy, 2026-10-21).
    var injectedDrags: Bool { tunables[.injectedDrags] >= 0.5 }
    /// A press on a window layer's title bar raises it at once, here and on the host, as macOS does on the press (not when
    /// the drag starts): the window is in front on both sides before it moves over another.
    func pressTitleBar(windowID: UInt32) {
        if !injectedDrags { sendWindowCommand(.init(id: windowID, action: .raise)) }   // injected: the press itself raises it
        localRaise(windowID: windowID, inputSeq: lastInputSeqSent())
    }
    func beginLayerDrag(windowID: UInt32) {
        guard let f = arrangedWindows().first(where: { $0.id == windowID })?.frame else { return }
        let limits = windowDragLimits()
        predictorLock.lock(); localFrames[windowID] = LocalFrame(frame: f, inputSeq: 0, releasedNanos: 0); layerDragLimits[windowID] = (f, limits); predictorLock.unlock()
        if !injectedDrags { sendWindowCommand(.init(id: windowID, action: .raise)) }
        localRaise(windowID: windowID, inputSeq: lastInputSeqSent())
    }
    func dragLayer(windowID: UInt32, to frame: PixelRect) {
        predictorLock.lock()
        guard localFrames[windowID] != nil else { predictorLock.unlock(); return }
        let frame = layerDragLimits[windowID].flatMap { d in d.limits?.clamp(frame, from: d.start) } ?? frame
        localFrames[windowID]?.frame = frame
        predictorLock.unlock()
        let now = Clock.nowNanos()
        if !injectedDrags, Clock.elapsed(since: lastMoveCommandNanos, now: now) > 50_000_000 { lastMoveCommandNanos = now; sendWindowCommand(.init(id: windowID, action: .move, x: frame.x, y: frame.y)) }
        onChange?()
    }
    func endLayerDrag(windowID: UInt32) {
        predictorLock.lock()
        guard var lf = localFrames[windowID] else { predictorLock.unlock(); return }
        lf.releasedNanos = Clock.nowNanos()
        layerDragLimits[windowID] = nil
        predictorLock.unlock()
        // Injected: the release has just gone as input; the prediction retires once the host's list reflects it.
        let seq = injectedDrags ? lastInputSeqSent() : sendWindowCommand(.init(id: windowID, action: .move, x: lf.frame.x, y: lf.frame.y))
        lf.inputSeq = seq
        predictorLock.lock(); localFrames[windowID] = lf; predictorLock.unlock()
    }
    // Unified mode (DESIGN §3.5 item 2): native windows move and resize under the window server; each change becomes a
    // local frame override, and the host is sent one window command once the change has settled; the override retires
    // once the host's list reflects it.
    private var trailingCommand: [UInt32: DispatchWorkItem] = [:]   // main thread
    private var lastUnifiedCommandNanos: [UInt32: UInt64] = [:]    // main thread
    @MainActor func moveLayerLocally(windowID: UInt32, to frame: PixelRect) { setLocalFrame(windowID: windowID, frame: frame, action: .move, immediate: false) }
    /// A local resize: the frame shows at once (the canvas is drawn 1:1, never stretched); the host is told when the live resize ends.
    @MainActor func resizeLayerLocally(windowID: UInt32, to frame: PixelRect, final: Bool) {
        if final { setLocalFrame(windowID: windowID, frame: frame, action: .resize, immediate: true); return }
        predictorLock.lock()
        let now = Clock.nowNanos()
        var lf = localFrames[windowID] ?? LocalFrame(frame: frame, inputSeq: .max, releasedNanos: now)
        lf.frame = frame; lf.inputSeq = .max; lf.releasedNanos = now
        localFrames[windowID] = lf
        predictorLock.unlock()
        onChange?()
    }
    @MainActor private func setLocalFrame(windowID: UInt32, frame: PixelRect, action: ControlMessage.WindowCommand.Action, immediate: Bool) {
        let now = Clock.nowNanos()
        predictorLock.lock()
        var lf = localFrames[windowID] ?? LocalFrame(frame: frame, inputSeq: .max, releasedNanos: now)
        lf.frame = frame; lf.releasedNanos = now; lf.inputSeq = .max   // not retired by an older command's echo
        localFrames[windowID] = lf
        predictorLock.unlock()
        trailingCommand[windowID]?.cancel(); trailingCommand[windowID] = nil
        let send: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.predictorLock.lock(); let f = self.localFrames[windowID]?.frame; self.predictorLock.unlock()
            guard let f else { return }
            let seq = self.sendWindowCommand(action == .resize ? .init(id: windowID, action: .resize, x: f.x, y: f.y, width: f.width, height: f.height) : .init(id: windowID, action: .move, x: f.x, y: f.y))
            self.lastUnifiedCommandNanos[windowID] = Clock.nowNanos()
            self.predictorLock.lock()
            if var cur = self.localFrames[windowID], cur.frame == f { cur.inputSeq = seq; cur.releasedNanos = Clock.nowNanos(); self.localFrames[windowID] = cur }
            self.predictorLock.unlock()
        }
        // Unified mode needs the host window only where it ends up (nobody sees the host's screen): one move when the
        // local drag has been still for 150 ms, not a stream of them (each move re-captures the window there).
        if immediate { send() }
        else {
            let w = DispatchWorkItem { MainActor.assumeIsolated { send() } }
            trailingCommand[windowID] = w
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: w)
        }
        onChange?()
    }
    /// The host's own stacking (front to back), local overrides not applied.
    func hostOrder() -> [ControlMessage.WindowInfo] { windowsSnapshot() }
    /// A layer's canvas (Unified mode draws each in its own window).
    func layerCanvas(_ id: UInt32) -> Compositor? { layerViews[id]?.compositor }
    /// Displacements (scroll predictions) of one window, in its own canvas coordinates, with its band colours.
    func displacements(forWindow id: UInt32) -> ([Predictor.Displacement], [UInt32: SIMD4<Float>]) {
        let (d, c) = displacements()
        return (d.filter { $0.windowID == id }, c)
    }

    /// Sends a window command stamped with a fresh input sequence (so the host's list can say when it reflects it).
    @discardableResult
    func sendWindowCommand(_ c: ControlMessage.WindowCommand) -> UInt64 {
        var c = c
        c.inputSeq = inputQueue.sync { input.reserveSequence() }
        sender?.send(.windowCommand(c))
        windowCommandsSent += 1
        return c.inputSeq ?? 0
    }
    private func lastInputSeqSent() -> UInt64 { inputQueue.sync { input.lastSequence } }

    func beginDrag(windowID: UInt32, frame: PixelRect, pointer: (Int, Int), inputSeq: UInt64) {
        let limits = windowDragLimits()
        predictorLock.lock(); predictor.beginDrag(windowID: windowID, frame: frame, pointer: pointer, inputSeq: inputSeq, now: Clock.nowNanos(), limits: limits); predictorLock.unlock()
    }
    func dragPointer(windowID: UInt32, pointer: (Int, Int), inputSeq: UInt64) {
        predictorLock.lock(); predictor.dragPointer(windowID: windowID, pointer: pointer, inputSeq: inputSeq, now: Clock.nowNanos()); predictorLock.unlock()
        onChange?()
    }
    func endDrag(windowID: UInt32) { predictorLock.lock(); predictor.endDrag(windowID: windowID); predictorLock.unlock() }

    func predict(kind: Predictor.Kind, windowID: UInt32, rect: PixelRect, dx: Int, dy: Int, inputSeq: UInt64) {
        let now = Clock.nowNanos()
        predictorLock.lock()
        var rect = rect
        if kind == .scroll {
            // A scroll is predicted only over the host's scroll rect for that window (its AX scroll area), whatever the caller
            // guessed: the iPhone's first scroll frames showed the band at the bottom of the whole window (c3c67a6 had fixed
            // the Mac's callers, not the iOS one). Until the host knows the rect, nothing is predicted.
            guard let known = windows.first(where: { $0.id == windowID })?.scrollRect else { predictorLock.unlock(); return }
            rect = known
        }
        predictor.predict(kind: kind, windowID: windowID, rect: rect, dx: dx, dy: dy, inputSeq: inputSeq, now: now)
        let needColor = bandColors[windowID] == nil
        let layered = windows.first(where: { $0.id == windowID })?.isLayered ?? false
        predictorLock.unlock()
        if needColor, let c = layered ? layerViews[windowID]?.compositor : compositor {
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
    var hasPendingPredictions: Bool { predictorLock.lock(); defer { predictorLock.unlock() }; return predictor.hasPending || !localFrames.isEmpty || localRaise != nil || !typeahead.glyphs.isEmpty }
    /// Whether the picture needs a redraw for reasons the compositors do not know (local arrangement).
    var arrangementGeneration: Int { predictorLock.lock(); defer { predictorLock.unlock() }; return Int(hostListSeq) }

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

#if os(macOS)   // --stats is for the command-line runs (headless, scenarios)
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
            var motionMoves: [Int]?, moveFps: [Double]?, burstKB: [Double]?, settleKB: [Double]?, confirmMs: [Double]?, layered: Bool?, layersHeld: Int?, windowCommandsSent: Int?
            var staleTilesDiscarded: Int?, staleTilesCommitted: Int?, staleVideoTiles: Int?
            var layers: [LayerDiag]?
            var staleSamples: Int?, staleBenchPixels: Int?, staleAt: [String]?
            var guardDrops: Int?, unknownDesktopTiles: Int?, fillSamples: Int?, unknownVisibleTiles: Int?, preExclusionDrops: Int?
            var samples: [Sample]
            var unified: UnifiedStats? = nil
            var transientSamples: [String]? = nil, transientGhosts: Int? = nil, dockGhostMs: [Double]? = nil
            var typeahead: TypeaheadStats? = nil
            /// Every byte from the host in the run (video, tiles, control) and the run's length when written.
            var totalBytes: Int? = nil, totalBytesAtSeconds: Double? = nil
        }
        struct TypeaheadStats: Codable { var shown: Int, confirmed: Int, mismatched: Int, expired: Int; var accuracy: Double?; var visibleMsMedian: Double?, visibleMsMax: Double?, echoMsMedian: Double?, echoMsP95: Double?; var misses: [String]? }
        struct UnifiedStats: Codable {
            var windows: Int, hostFramesApplied: Int, localMoves: Int
            var localMoveMsMedian: Double?, localMoveMsMax: Double?, stepJitterMs: [Double]?, redraws: [Int]?
            var switchConfirmMs: [Double]?, switchKB: [Double]?
            var chromeBytes: Int, menuLatencyMs: [Double], menuPresses: Int
            var menuBarMs: Double?, menuOpenMs: [Double]?, menuItems: Int?, statusItems: Int?, apps: Int?
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
        var out = Out(host: host, seconds: samples.last?.t ?? 0, targetKbps: target,
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
                      motionMoves: scenario?.motionMoves, moveFps: scenario?.moveFps, burstKB: scenario?.burstKB, settleKB: scenario?.settleKB, confirmMs: scenario?.confirmMs,
                      layered: scenario?.layered, layersHeld: layerViews.count - 1, windowCommandsSent: windowCommandsSent,
                      staleTilesDiscarded: staleDiscards, staleTilesCommitted: staleCommits, staleVideoTiles: staleVideoTiles,
                      layers: videoQueue.sync { layerDiagnostics() },
                      staleSamples: scenario?.staleSamples, staleBenchPixels: scenario?.stalePurple, staleAt: scenario?.staleAt,
                      guardDrops: videoQueue.sync { guardDrops }, unknownDesktopTiles: unknownDesktop.count, fillSamples: scenario?.fillSamples, unknownVisibleTiles: unknownVisibleCount(), preExclusionDrops: videoQueue.sync { preExclusionDrops },
                      samples: samples)
        let tc = typeaheadCounts()
        if tc.shown > 0 {
            predictorLock.lock(); let vis = typeaheadVisibleMs, echo = typeaheadEchoMs; predictorLock.unlock()
            out.typeahead = TypeaheadStats(shown: tc.shown, confirmed: tc.confirmed, mismatched: tc.mismatched, expired: tc.expired,
                                           accuracy: tc.confirmed + tc.mismatched > 0 ? Double(tc.confirmed) / Double(tc.confirmed + tc.mismatched) : nil,
                                           visibleMsMedian: vis.isEmpty ? nil : median(vis), visibleMsMax: vis.max(), echoMsMedian: echo.isEmpty ? nil : median(echo), echoMsP95: echo.isEmpty ? nil : p95(echo),
                                           misses: typeaheadMisses().map { "'\($0.text)' predicted end \($0.predictedX),\($0.predictedY) host caret \($0.hostX),\($0.hostY) (glyph \($0.glyphWidth) px)" })
        }
        out.totalBytes = totalBytes(); out.totalBytesAtSeconds = Date().timeIntervalSince(startDate)
        out.transientSamples = scenario?.transientSamples; out.transientGhosts = scenario?.transientGhosts; out.dockGhostMs = scenario?.dockGhostMs
        out.unified = MainActor.assumeIsolated { () -> UnifiedStats? in
            guard let u = unified else { return nil }
            let lm = scenario?.localMoveMs ?? []
            return UnifiedStats(windows: u.windows.count, hostFramesApplied: u.hostFramesApplied, localMoves: u.localMoves,
                                localMoveMsMedian: lm.isEmpty ? nil : median(lm), localMoveMsMax: lm.max(), stepJitterMs: scenario?.stepJitterMs, redraws: scenario?.redraws,
                                switchConfirmMs: scenario?.switchConfirmMs, switchKB: scenario?.switchKB,
                                chromeBytes: chromeBytes(), menuLatencyMs: u.chrome?.menuLatencies ?? [], menuPresses: u.chrome?.menuPresses ?? 0,
                                menuBarMs: scenario?.chromeResult?.barMs, menuOpenMs: scenario?.chromeResult?.openMs, menuItems: scenario?.chromeResult?.items,
                                statusItems: scenario?.chromeResult?.strip, apps: u.chrome?.apps.count)
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(out)) ?? Data()
    }
}
#endif
