import Foundation
import CoreVideo
import CoreGraphics
import VideoToolbox
import ApplicationServices
import ScreenCaptureKit
import MirageCore

/// macOS desktop streamer, M3 layered desktop over the M2 hybrid codec (DESIGN §3.2–3.5):
/// the display captured without the layered windows (layer 0) plus one `desktopIndependentWindow`
/// capture per normal window (its own layer, whole and unoccluded), each through the same pipeline:
/// CPU tile diff → copy-rect detection (scrolls from line signatures; drags of windows the display
/// layer still carries from the window list) → TileTracker classification → lossless WebP tiles on the
/// reliable tile streams / HEVC of the moving region through a per-layer canvas on datagrams →
/// lossless refinement, all paced by one RateController's budget split. The window list (frames,
/// z-order, levels, which windows are layers) goes on the control stream; the client composites.
/// All mutable state lives on `queue`; tile encoding runs on `tileQueue`.
public final class MacDesktopStreamer: DesktopStreamer, @unchecked Sendable {
    /// One queue for every streamer and the warm pool (WarmPool), so a capture the pool started is adopted on its own queue.
    static let hostQueue = DispatchQueue(label: "mirage.host.video", qos: .userInteractive)
    private let queue = MacDesktopStreamer.hostQueue
    /// This streamer counts as an active stream for the warm pool (between start/resume and suspend/stop).
    private var warmHeld = false
    /// On `queue`.
    private func holdWarm(_ on: Bool) {
        guard on != warmHeld else { return }
        warmHeld = on
        if on { WarmPool.shared.streamStarted() } else { WarmPool.shared.streamStopped() }
    }
    private let inputQueue = DispatchQueue(label: "mirage.host.input", qos: .userInteractive)
    private let tileQueue = DispatchQueue(label: "mirage.host.tiles", qos: .userInitiated)
    private let log: @Sendable (String) -> Void
    private var output: StreamOutput?
    private var capturer: ScreenCapturer?
    private let catalog = WindowCatalog()
    private var injector: InputInjector?
    private var cursor: CursorMonitor?
    private var windows: WindowTracker?
    private var ax: AXWindows?
    /// Native chrome (DESIGN §3.8): menus, running apps, icons.
    private var chrome: NativeChrome?
    /// Typeahead (DESIGN §3.5 item 4): the focused text element's caret.
    private var caret: CaretTracker?
    /// What the viewer shows (M3.2): in Unified mode window layers are not held back for being covered on this screen,
    /// and the display layer is sent only where the viewer shows it (menus, popovers, the status-item strip).
    private var interest: ControlMessage.ViewInterest?
    private var unifiedView: Bool { interest?.unified ?? false }
    private var lastInterestLog: UInt64 = 0
    /// Display tiles that changed outside ScreenCaptureKit's dirty rects (logged every 30 s).
    private var statDirtyMissed = 0
    /// Picture audit (TileAudit): every 5 s, fingerprints of desktop tiles the viewer should hold.
    private var lastAuditNanos: UInt64 = 0, auditCursor = 0, statAudited = 0, statAuditRefreshed = 0
    /// When the display filter excluding each window was applied: its exclusion is checked only a second later (the
    /// last display frame may predate the filter: a false "SHOWS THIS WINDOW" 19 ms after it applied, eea3220).
    private var excludedAtNanos: [UInt32: UInt64] = [:]
    private func sendAudit(now: UInt64) {
        guard let d = display, let src = d.lastFrame, !screenLocked, !unifiedView else { return }
        CVPixelBufferLockBaseAddress(src, .readOnly); defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        let f = frameView(src)
        guard f.width == d.width, f.height == d.height else { return }
        let t = d.tracker
        func auditable(_ i: Int) -> Bool {
            t.isCrisp(i) && !d.occludedTiles.contains(i) && !d.underLayer.contains(i) && Clock.elapsed(since: t.lastDirty(i), now: now) > 2_000_000_000
        }
        // Tiles that changed in the last two minutes (where a lost write would be), then a slow sweep of the rest.
        var tiles: [Int] = []
        // Most recently changed first (row order reached the Dock's rows last once more than 400 tiles had changed).
        tiles = (0..<t.tileCount).filter { auditable($0) && Clock.elapsed(since: t.lastDirty($0), now: now) < 120_000_000_000 }
            .sorted { t.lastDirty($0) > t.lastDirty($1) }.prefix(400).map { $0 }
        var swept = 0, k = 0
        while swept < 96, k < t.tileCount {
            let i = (auditCursor + k) % t.tileCount; k += 1
            if auditable(i), !tiles.contains(i) { tiles.append(i); swept += 1 }
        }
        auditCursor = (auditCursor + k) % max(1, t.tileCount)
        guard !tiles.isEmpty else { return }
        var prints = Data(capacity: tiles.count * 16)
        for i in tiles { prints.append(contentsOf: TileAudit.fingerprint(f, t.rect(of: i))) }
        statAudited += tiles.count
        sendControlCounted(.tileAudit(.init(layer: 0, captureSeq: captureSeq, tiles: tiles.map(UInt32.init), prints: prints)))
    }
    /// The same audit for window layers (the backstop that was missing when copy-rects left a scrolled Finder window's
    /// toolbar stacked for 13 s, 2df0793): opaque, visible, crisp tiles quiet for 2 s, newest changes first, plus a slow sweep.
    private var statWindowAudited = 0, statWindowAuditRefreshed = 0
    private func sendWindowAudits(now: UInt64) {
        guard !screenLocked else { return }
        // Only layers on screen now: a closed or minimized window's layer is kept a while (absent, no capturer) and the viewer
        // may hold nothing for it any more (after a resume: "32 of 32 window tiles differ" every 5 s for a closed window).
        for l in layers.values where !l.isDisplay && l.announced && l.exposed && l.fresh == .done && l.absentSince == 0 && l.capturer != nil && plannedFrames[l.id] != nil {
            guard let src = l.lastFrame else { continue }
            CVPixelBufferLockBaseAddress(src, .readOnly); defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            let f = frameView(src)
            guard f.width == l.width, f.height == l.height else { continue }
            let t = l.tracker
            func auditable(_ i: Int) -> Bool {
                t.isCrisp(i) && l.opaqueTiles.contains(i) && !l.occludedTiles.contains(i) && Clock.elapsed(since: t.lastDirty(i), now: now) > 2_000_000_000
            }
            var tiles = (0..<t.tileCount).filter { auditable($0) && Clock.elapsed(since: t.lastDirty($0), now: now) < 120_000_000_000 }
                .sorted { t.lastDirty($0) > t.lastDirty($1) }.prefix(150).map { $0 }
            var swept = 0, k = 0
            while swept < 32, k < t.tileCount {
                let i = (l.auditCursor + k) % t.tileCount; k += 1
                if auditable(i), !tiles.contains(i) { tiles.append(i); swept += 1 }
            }
            l.auditCursor = (l.auditCursor + k) % max(1, t.tileCount)
            guard !tiles.isEmpty else { continue }
            var prints = Data(capacity: tiles.count * 16)
            for i in tiles { prints.append(contentsOf: TileAudit.fingerprint(f, t.rect(of: i))) }
            statWindowAudited += tiles.count
            sendControlCounted(.tileAudit(.init(layer: l.id, captureSeq: captureSeq, tiles: tiles.map(UInt32.init), prints: prints)))
        }
    }
    /// Window-command targets of windows that left the list (minimized from the viewer), for the restore.
    private var lastTargets: [UInt32: (target: AXWindows.Target, nanos: UInt64)] = [:]
    private var request: ControlMessage.StreamRequest?
    private var target: ScreenCapturer.Target?

    // Layers (DESIGN §3.2): 0 = the display without the layered windows; others keyed by CGWindow id.
    private var layers: [UInt32: Layer] = [:]
    private var display: Layer? { layers[0] }
    /// Bounds on per-window capture (host memory and WindowServer work): count and summed pixels.
    private var maxWindowLayers = 16
    private var maxLayerPixels = 48_000_000
    private var loggedCapMiss = Set<UInt32>()
    private var lastExcludedIDs: Set<UInt32> = []
    private var pendingMoved: [WindowTracker.Delta] = []
    private var layerRetainNanos: UInt64 = 10_000_000_000
    private var maxLayerEncoders = 4

    // Hybrid codec state shared across layers.
    private var detector = ShiftDetector()
    /// Scroll diagnostics (why captures fail to verify byte-exact): the detector's candidate lines for the current capture, and
    /// how many scroll captures may still be logged in this 30 s period.
    private var shiftDiag: [String] = []
    private var scrollDiagBudget = 40
    private var rc: RateController?
    private var captureSeq: UInt32 = 0
    private var lastInputSeq: UInt64 = 0
    private var tileTokens: Double = 0
    private var tileMsgSeq: UInt32 = 0
    private var tileSent: [UInt32: (nanos: UInt64, bytes: Int, refinement: Int, block: Int?, layer: UInt32, rects: [PixelRect])] = [:]
    /// Tile-stream bytes sent and not yet acked (RateController.inflightCapBytes bounds refinement by it).
    private var tileInflightBytes = 0
    private var refineDesktopFirst = false
    private var lastEdgeLogNanos: UInt64 = 0
    /// In flight for the cap: what is on the stream plus blocks still being encoded (several were dispatched before the
    /// first was counted: 1.8 MB in flight against a 480 KB cap on a shaped Fast 4G run).
    private var tileInflightForCap: Int { tileInflightBytes + pacer.blocks.reduce(0) { $1.msgSeq == nil ? $0 + $1.bytes : $0 } }
    /// The rate blocks are sized from: the tile budget, and at most half the in-flight cap per block (a block is ~0.25 s of
    /// it), so one block cannot overrun the cap by itself (375 KB blocks against 480 KB on Fast 4G in startup).
    private var blockRate: Double {
        let budget = Double(lastBudget.tileKbps * 1000 / 8)
        guard let rc else { return budget }
        return min(budget, Double(rc.inflightCapBytes) * 0.5 / RefinementPacer.blockSeconds)
    }
    private var lastBudget = RateController.Budget(tileKbps: 0, videoKbps: 0)
    private var refineTimer: DispatchSourceTimer?
    private var rateTimer: DispatchSourceTimer?
    /// The last wheel event's place, and the wheel delta (pixels) accumulated since a capture last took it: a tie-breaker for
    /// the scroll detector on periodic content (magnitude only; the sign depends on natural scrolling).
    private struct PendingScroll { let x: Int, y: Int; let windowID: UInt32; let nanos: UInt64; var dxPx = 0, dyPx = 0 }
    private let scrollLock = NSLock()
    private var pendingScroll: PendingScroll?

    // Video pacing state.
    /// Video frame sequence, monotonic across streamers of one host process (review M4: a viewer whose
    /// stream restarted on the same connection must never see a sequence below what it delivered).
    private var seq: UInt32 { get { Self.frameSeqLock.lock(); defer { Self.frameSeqLock.unlock() }; return Self.frameSeq } set { Self.frameSeqLock.lock(); Self.frameSeq = newValue; Self.frameSeqLock.unlock() } }
    nonisolated(unsafe) private static var frameSeq: UInt32 = 0
    private static let frameSeqLock = NSLock()
    private var tokens: Double = 0                 // bytes available to send
    private var lastRefill = Clock.nowNanos()
    private struct InFlight { let layer: UInt32; let sentNanos: UInt64; let bytes: Int; let ltrToken: Int64?; var paceEndNanos: UInt64 = 0 }
    private var unacked: [UInt32: InFlight] = [:]
    private var srttNanos: Double = 250_000_000
    /// Last ~2 s of sent frames' datagrams, for fragment NACKs; `sent` = how many have left the pacer so far
    /// (review H5: a NACK for a datagram still queued in the pacer is ignored).
    private final class SentFrame { let nanos: UInt64; let datagrams: [Data]; var sent = 0; init(nanos: UInt64, datagrams: [Data]) { self.nanos = nanos; self.datagrams = datagrams } }
    private var sentFrames: [UInt32: SentFrame] = [:]
    /// Datagram pacer (review H6): datagrams leave at the video budget × 1.25 from a dedicated queue, the
    /// cursor being the time the last scheduled datagram leaves; resends queue behind the frame in flight.
    private let paceQueue = DispatchQueue(label: "mirage.host.pace", qos: .userInteractive)
    private var paceCursorNanos: UInt64 = 0
    private var lastHostStatus: ControlMessage.HostStatus? = nil
    private var lastHostStatusNanos: UInt64 = 0
    private var statNacks = 0, statNackResent = 0
    /// Frames purged as stale whose ack may still arrive (review H3): they still teach srtt and the fresh-picture state.
    private var recentlyPurged: [UInt32: InFlight] = [:]

    // Stats (per log interval).
    private var statFrames = 0, statBytes = 0, statDropped = 0, statSkippedBudget = 0, statLost = 0
    private var statEncodeNanos: UInt64 = 0
    private var statInput = 0, statTileBytes = 0, statTileRects = 0, statRefineBytes = 0, statCopyRects = 0, statDirtyTiles = 0, statDiffPruned = 0, statTileSkipped = 0, statFoveaTiles = 0, statStills = 0, statOccluded = 0
    private var secTileBytes = 0, secVideoBytes = 0, secVideoFrames = 0, secSkippedBudget = 0   // per rateState second
    private var statCaptures = 0
    private var statCaptureNanos: UInt64 = 0
    private var tileKbpsEWMA = 0.0
    private var lastTier: LinkTier? = nil
    private var effort: HostEffort = .full
    private var effortLevel: String { effort.rawValue }
    private var effortCaptureNanos: UInt64 = 0, effortCaptures = 0
    private var effortLogged = false
    private var statTimer: DispatchSourceTimer?
    private var statStaleDropped = 0
    private var accountTicks = 0
    /// Invariant (compositor model): no tile anyone can see stays unsent. Every 5 s, per layer, visible tiles (not covered;
    /// the desktop's not under a shown window) pending for over 10 s without changing are logged loudly and made due at
    /// once. Hold-and-release rules had left revealed desktop black for good (phrz, 08:24Z: "patchy with black that never
    /// heals"); whatever rule misses a release next, this catches it.
    private func auditVisibleUnsent(now: UInt64) {
        guard compositor, !screenLocked else { return }
        for l in layers.values where l.announced || l.isDisplay {
            let visible = (0..<l.tracker.tileCount).filter { !l.occludedTiles.contains($0) && !(l.isDisplay && l.underLayer.contains($0)) && !l.offDisplayTiles.contains($0) }
            // Held back (not due) while visible at this audit and the last one: a tile uncovered a moment ago after a long
            // wait covered is not a missed release (the uncover path makes it due), nor is a due backlog waiting its turn.
            let held = Set(l.tracker.stalePending(visible, olderThan: 10_000_000_000, now: now))
            let stale = held.intersection(l.auditHeldVisible).sorted()
            l.auditHeldVisible = held
            guard !stale.isEmpty else { continue }
            l.tracker.forceDue(stale, now: now)
            log("INVARIANT: layer \(l.id) had \(stale.count) visible tiles unsent for over 10 s; made due now")
        }
    }

    /// Per-layer bytes by class over the last 30 s, largest first (app names only, never window titles).
    private func logAccount() {
        let byID = windows?.current?.byID ?? [:]
        let rows = layers.values.sorted { $0.account.total > $1.account.total }.map { l -> String in
            let a = l.account
            let who = l.isDisplay ? "desktop" : "\(byID[l.id]?.app ?? "?") \(l.id)"
            return String(format: "%@ %dx%d vis %d%%%@: %.0f KB = still %.0f + blocks %.0f + refine %.0f + direct %.0f + video %.0f + underlay %.0f + backdrop %.0f + strip %.0f + corrections %.0f (upgrade %.0f of the refine), dirty %.0f tiles/s",
                          who as NSString, l.width, l.height, Int(l.visibleFraction * 100), l.isDisplay || l.opaque ? "" : " transparent", Double(a.total) / 1000, Double(a.still) / 1000, Double(a.blocks) / 1000,
                          Double(a.refine) / 1000, Double(a.direct) / 1000, Double(a.video) / 1000, Double(a.underlay) / 1000, Double(a.backdrop) / 1000, Double(a.strip) / 1000, Double(a.correction) / 1000, Double(a.upgrade) / 1000, Double(a.dirtyTiles) / 30)
        }
        let total = layers.values.reduce(0) { $0 + $1.account.total }
        log(String(format: "layer bytes, last 30 s (%.0f kbps): ", Double(total) * 8 / 30 / 1000) + rows.joined(separator: " | "))
        // Window captures (display filter excluding all other windows): frames passed on, unchanged frames skipped,
        // frames dropped because the window had moved (stale source rect) or showed shifted (edge check).
        let caps = layers.values.compactMap { l -> String? in
            guard let c = l.capturer else { return nil }
            defer { c.resetCounts() }
            return "\(l.id): \(c.frames) passed, \(c.skippedUnchanged) unchanged, \(c.droppedMoved) moved, \(c.droppedEdge) shifted, \(c.excludedCount) excluded"
        }
        if !caps.isEmpty { log("window captures, last 30 s: " + caps.joined(separator: " | ")) }
        if statDirtyMissed > 0 { log("display: \(statDirtyMissed) changed tiles outside ScreenCaptureKit's dirty rects in the last 30 s (found by the full diff)") }
        statDirtyMissed = 0
        if statWindowAudited > 0 { log("window picture audit, last 30 s: \(statWindowAudited) window tiles fingerprinted, \(statWindowAuditRefreshed) asked for again by the viewer") }
        statWindowAudited = 0; statWindowAuditRefreshed = 0
        if statAudited > 0 { log("picture audit, last 30 s: \(statAudited) desktop tiles fingerprinted, \(statAuditRefreshed) asked for again by the viewer; \(statDirectDue) held-back changed tiles sent when due (longest wait \(statDirectWaitMaxNanos / 1_000_000) ms), \(statCopyCorrections) of them copy-rect corrections; \(statStripLossy) exposed-strip tiles sent lossy with their copy-rect") }
        if statBackdropLevels > 0 { log("moved-window backdrops, last 30 s: \(statBackdropTiles) tiles held, \(statBackdropLevels) lossy levels \(statBackdropBytes / 1000) KB, \(statBackdropReleased) tiles released to lossless refinement when idle") }
        scrollDiagBudget = 40
        statDirectDue = 0; statDirectWaitMaxNanos = 0; statCopyCorrections = 0; statStripLossy = 0; statBackdropTiles = 0; statBackdropLevels = 0; statBackdropBytes = 0; statBackdropReleased = 0
        statAudited = 0; statAuditRefreshed = 0
        for l in layers.values { l.account = Layer.Account() }
    }
    private var statWindowCommands = 0
    private var debugLayers = false
    /// The host's screen is locked (ScreenLock: any signal). Layering pauses meanwhile: window capturers stop,
    /// layers and their pixels are kept, nothing is refined for them, the display stream (the lock screen)
    /// excludes nothing; on unlock the capturers restart and each layer's first frame is diffed in full.
    private var screenLocked = false
    private var loggedChildSkip = false
    /// Capture sequence from which the display stream excludes each window (filter applied), and windows the
    /// exclusion check found visible in the display stream anyway.
    private var excludedFrom: [UInt32: UInt32] = [:]
    /// Windows the display stream could not exclude within 5 s of their still (ScreenCaptureKit does not list them):
    /// they stay part of the desktop picture for the rest of the session.
    private var unexcludable = Set<UInt32>()
    private var exposedSince: [UInt32: UInt64] = [:]
    private var exclusionFailing = Set<UInt32>()
    private var verifiedExclusions: Set<UInt32> { Set(excludedFrom.keys).subtracting(exclusionFailing) }
    /// Frames of the windows planned as layers (exposed or not yet) and, for a moment after a move, their previous
    /// frames: wherever the display stream may show a window (DisplayTaint).
    private var plannedFrames: [UInt32: PixelRect] = [:]
    private var recentFrames: [(rect: PixelRect, nanos: UInt64)] = []
    private var statTaintResent = 0, statExclusionLag = 0
    private var lastLagLogNanos: UInt64 = 0
    private func windowAreas(now: UInt64) -> [PixelRect] {
        recentFrames.removeAll { now &- $0.nanos > 600_000_000 }
        let unexposed = plannedFrames.filter { !(layers[$0.key]?.exposed ?? false) }.map(\.value)
        return unexposed + recentFrames.map(\.rect) + displayGuard.guardedRects(now: now)
    }
    /// Desktop pixels for these tiles are on their way to the viewer (from a capture taken about now).
    private func displaySent(_ tiles: [Int]) {
        guard let d = display, !tiles.isEmpty else { return }
        d.taint.sent(tiles, tracker: d.tracker, windowAreas: windowAreas(now: Clock.nowNanos()))
        d.taintScheduled.subtract(tiles)
    }
    /// DisplayGuard: desktop tiles under a shown layer, or where one was in the last second (plus a margin), are
    /// never sent; they come back from a capture taken after the window left (via the taint re-send).
    private var displayGuard = DisplayGuard(historyNanos: 1_000_000_000, margin: 128)
    private func updateDisplayHidden(now: UInt64) {
        guard let d = display else { return }
        var shown: [UInt32: PixelRect] = [:]
        if !screenLocked { for (id, f) in plannedFrames where (layers[id]?.exposed ?? false) && (compositor || excludedFrom[id] != nil) { shown[id] = f } }
        // (Compositor model: the desktop picture never holds a window, so every layer is verified and the guard keeps nothing.)
        displayGuard.update(layered: shown, verified: compositor ? Set(shown.keys) : verifiedExclusions, now: now)
        // Tiles fully under a shown window (inset by the corner radius): the underlay.
        let inset = Int(14 * (windows?.pxPerPoint ?? 2))
        let insetFrames = shown.values.map { PixelRect(x: $0.x + inset, y: $0.y + inset, width: $0.width - 2 * inset, height: $0.height - 2 * inset) }
        // A tile is under a window only where that window's own pixels are opaque (a transparent full-screen window,
        // an icons window or an overlay, hides nothing); "covered twice" means two opaque windows.
        let shownLayers = shown.keys.compactMap { layers[$0] }
        for l in shownLayers { l.refreshOpacity(now: now) }
        // A window the viewer draws as a cut-out over a layer (a menu, an alert, another app's window the host does not
        // layer) shows the display layer there: those tiles are visible, not underlay (their blocks are a level).
        let list = windows?.current?.windows ?? []
        let zIndex = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cutouts = list.enumerated().filter { shown[$1.id] == nil && Self.cutoutSafe($1, displayArea: d.width * d.height) }.map { (z: $0, frame: $1.frame) }
        var under = Set<Int>(), doubly = Set<Int>()
        for i in 0..<d.tracker.tileCount {
            let r = d.tracker.rect(of: i)
            var n = 0
            for l in shownLayers {
                guard let f = shown[l.id] else { continue }
                let core = PixelRect(x: f.x + inset, y: f.y + inset, width: f.width - 2 * inset, height: f.height - 2 * inset)
                guard core.intersection(r) == r, l.opaque(over: r) else { continue }
                let z = zIndex[l.id] ?? Int.max
                if cutouts.contains(where: { $0.z < z && $0.frame.intersects(r) }) { continue }
                n += 1
            }
            if n >= 1 { under.insert(i) }
            if n >= 2 { doubly.insert(i) }
        }
        if unifiedView { under = []; doubly = [] }   // Unified: no desktop is shown, so none is underlay
        if under != d.underLayer {
            // Uncovered tiles that went out at underlay quality are refined at the normal quality now.
            let uncoveredLossy = d.underlayLossy.subtracting(under)
            if !uncoveredLossy.isEmpty { d.upgradePending.formUnion(uncoveredLossy); d.underlayLossy.subtract(uncoveredLossy) }
            // Compositor model: desktop under a window is left for last; uncovered before it was sent (Show Desktop, a window
            // moved away), it is due now. It stayed black down the left edge for a whole Show Desktop round on mac-daddy.
            if compositor {
                let uncovered = d.underLayer.subtracting(under).filter { !d.tracker.isCrisp($0) }
                if !uncovered.isEmpty { _ = d.tracker.expedite(in: d.bounds, now: now, only: uncovered) }
            }
            d.underLayer = under
        }
        // Desktop under two or more shown windows only shows if both move: its underlay waits until one window covers it.
        // (Compositor model: nothing is held back. Desktop under two windows was, and Show Desktop, which moves every window at
        // once, revealed it as an empty canvas until refined: the black square of the fallback A/B run.)
        var hidden = compositor ? [] : displayGuard.guardedTiles(d.tracker, now: now).union(doubly)
        if unifiedView {
            // Unified: the display layer is shown only as menus, popovers, tooltips (cut-out-safe windows above the normal
            // level, known here, so a new menu costs no extra round trip) and the rects the viewer asks for (status items).
            let wanted = (interest?.displayRects ?? []) + list.filter { $0.windowLevel != 0 && $0.windowLevel != 20 && $0.windowLevel != 24 && $0.windowLevel != 25 && shown[$0.id] == nil && Self.cutoutSafe($0, displayArea: d.width * d.height) }.map(\.frame)
            for i in 0..<d.tracker.tileCount { let r = d.tracker.rect(of: i); if !wanted.contains(where: { $0.intersects(r) }) { hidden.insert(i) } }
            if Clock.elapsed(since: lastInterestLog, now: now) > 10_000_000_000 {
                lastInterestLog = now
                let ws = list.filter { w in wanted.contains(w.frame) }.map { "\($0.app ?? "?") L\($0.windowLevel) \($0.frame.width)x\($0.frame.height)" }
                log("unified: display layer shown for \(wanted.count) rects (\(d.tracker.tileCount - hidden.count) of \(d.tracker.tileCount) tiles): \(ws.prefix(8).joined(separator: ", "))")
            }
        }
        d.underlayEdge = insetFrames
        guard hidden != d.occludedTiles else { return }
        let uncovered = d.occludedTiles.subtracting(hidden)
        if !uncovered.isEmpty {
            let n = d.tracker.expedite(in: d.bounds, now: now, only: uncovered)
            if debugLayers { log("display: \(uncovered.count) tiles clear of windows for 1 s, \(n) pending made due; guarded now \(hidden.count)") }
        }
        d.occludedTiles = hidden
    }

    /// Visible tainted desktop tiles are refined from the current desktop (after motion settles, like any refinement).
    private func scheduleTaintedResends(now: UInt64) {
        guard let d = display, !screenLocked, !compositor else { return }
        let due = d.taint.due(hidden: d.occludedTiles, tracker: d.tracker, windowAreas: windowAreas(now: now)).filter { !d.taintScheduled.contains($0) }
        guard !due.isEmpty else { return }
        d.tracker.markDirect(due, now: now)   // a correction: shown on arrival, never staged
        d.taintScheduled.formUnion(due)
        statTaintResent += due.count
        if debugLayers { log("display: \(due.count) tiles may hold window pixels and are visible: re-sending from the desktop") }
    }

    /// Streamers with a connected viewer (this process): what HostStatus.viewers reports.
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live = Set<ObjectIdentifier>()
    static func liveCount() -> Int { liveLock.lock(); defer { liveLock.unlock() }; return live.count }
    private func setLive(_ on: Bool) { Self.liveLock.lock(); if on { Self.live.insert(ObjectIdentifier(self)) } else { Self.live.remove(ObjectIdentifier(self)) }; Self.liveLock.unlock() }

    public init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        hostLog = log
        // Env var, or a marker file for the LaunchAgent: ~/Library/Application Support/Mirage/debug-shift
        let marker = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mirage/debug-shift").path
        if ProcessInfo.processInfo.environment["MIRAGE_DEBUG_SHIFT"] != nil || FileManager.default.fileExists(atPath: marker) { detector.debug = { log($0) } }
        if let v = ProcessInfo.processInfo.environment["MIRAGE_MAX_LAYERS"], let n = Int(v) { maxWindowLayers = n }
        debugLayers = ProcessInfo.processInfo.environment["MIRAGE_DEBUG_LAYERS"] != nil
    }

    // MARK: DesktopStreamer

    public func start(_ req: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
        queue.sync { holdWarm(true) }
        do { return try await startStream(req, output: output) } catch { queue.sync { holdWarm(false) }; throw error }
    }
    private func startStream(_ req: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
        let t = try await ScreenCapturer.resolve(req)
        // The window list and the SCWindow catalog come first, so the display stream can exclude the
        // layered windows from its very first frame (the picture under them is part of the base picture).
        await catalog.refreshNow()
        let tracker = WindowTracker(displayID: t.display.displayID, streamWidth: t.pixelWidth)
        let now = Clock.nowNanos()
        let sample = tracker.sample(captureSeq: 0, now: now, force: true)
        let comp = Self.compositorWanted()
        let excluded: [SCWindow] = []   // a window stays in the display picture until its own still has landed
        let (cap, deskFrame) = try await startDesktop(req, t, compositor: comp, excluding: excluded)
        let (ov, overlayFrame) = comp ? try await startOverlay(req, t) : (nil, nil)
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                do {
                    self.output = output
                    self.setLive(true)
                    self.capturer = cap
                    self.compositor = comp; self.overlay = ov
                    self.target = t
                    self.request = req
                    self.windows = tracker
                    self.lastExcludedIDs = Set(excluded.map(\.windowID))
                    try self.configure(for: t, req: req)
                    self.injector = InputInjector(displayID: t.display.displayID)
                    self.ax = AXWindows(log: self.log)
                    let chrome = NativeChrome(log: self.log, send: { [weak self] m in self?.queue.async { self?.sendControlCounted(m) } })
                    if InputInjector.sinkPath != nil { chrome.sink = { [weak self] m in self?.injector?.record(m) } }
                    chrome.toPixels = { [weak tracker] r in tracker.map { $0.toPixels(r) } }
                    chrome.start()
                    self.chrome = chrome
                    let caret = CaretTracker(toPixels: { [weak tracker] r in tracker?.toPixels(r) ?? .zero },
                                             inputSeq: { [weak self] in self?.injector?.inputSeq(before: Clock.nowNanos()) ?? 0 },
                                             send: { [weak self] m in self?.queue.async { self?.sendControlCounted(m) } })
                    caret.start()
                    self.caret = caret
                    let cur = CursorMonitor(displayID: t.display.displayID)
                    cur.onShape = { [weak self] s in self?.output?.sendControl(.cursorShape(s)) }
                    cur.onPosition = { [weak self] p in self?.output?.sendControl(.cursorPosition(p)) }
                    cur.start(on: self.queue)
                    self.cursor = cur
                    cap.onStop = { [weak self] err in self?.log("capture stopped: \(err.map { "\($0)" } ?? "ok")") }
                    if let s = sample {
                        // The window list as the host sees it (levels, owners, sizes; titles only for our bench): the
                        // first thing to look at when a window does not show up on the viewer.
                        let area = t.pixelWidth * t.pixelHeight
                        for w in s.sample.windows { self.log(String(format: "window %u level %d owner %@ %dx%d at %d,%d%@%@", w.id, w.windowLevel, (w.app ?? "?") as NSString, w.frame.width, w.frame.height, w.frame.x, w.frame.y, Self.cutoutSafe(w, displayArea: area) ? " cut-out" : "", w.title.contains("Mirage Test Bench") ? " (bench)" : "")) }
                        self.reconcileLayers(s.sample, now: now); self.publishWindows(now: now, full: true)
                    }
                    self.feedWarmFrames(desktop: deskFrame, overlay: overlayFrame, t)
                    self.startTimers()
                    c.resume(returning: t.info)
                } catch { c.resume(throwing: error) }
            }
        }
    }

    /// (Re)builds everything that depends on the native stream size, and starts every layer over with a fresh picture.
    /// `keepController`: the size is unchanged (a resumed viewer that holds no picture), so the rate controller, its tier
    /// and the ladder rung carry on as they were.
    private func configure(for t: ScreenCapturer.Target, req: ControlMessage.StreamRequest, trigger: FreshPictureTrigger = .streamStart, keepController: Bool = false) throws {
        let w = t.pixelWidth, h = t.pixelHeight
        let now = Clock.nowNanos()
        if keepController, var kept = rc {
            kept.maxKbps = req.bitrateKbps
            rc = kept
        } else {
            loadHostTunables()
            var controller = RateController(initialKbps: min(req.bitrateKbps, Int(hostTunables[.startKbps])), maxKbps: req.bitrateKbps, nativePixels: w * h)
            if let old = rc { controller = RateController(initialKbps: old.targetKbps, maxKbps: req.bitrateKbps, nativePixels: w * h) }
            else if let k = Self.priorDelivery(for: output?.peerID, network: req.networkFingerprint) {
                controller.resume(fromKbps: k)
                log("careful resume: this pairing's last estimate on this network \(k) kbps; starting at \(controller.targetKbps) kbps")
            }
            rc = controller
        }
        let controller = rc!
        // Every layer starts over: the display at the new size, the windows at the new scale (their
        // capturers are rebuilt by the next window-list reconcile).
        for (id, l) in layers where id != 0 { let cap = l.capturer; l.capturer = nil; Task { await cap?.stop() } }
        layers = [:]
        let d = Layer(id: 0, width: w, height: h, frame: PixelRect(x: 0, y: 0, width: w, height: h), now: now)
        d.canvas = try Self.makeBuffer(width: w, height: h)
        d.announced = true; d.exposed = true
        layers[0] = d
        ensureOverlayLayer()
        lastBudget = controller.budget(videoActive: false)
        try rebuildEncoder(d)
        tokens = bucketCapacity(); tileTokens = Double(lastBudget.tileKbps * 1000 / 8) * 0.5
        windows?.setDisplay(t.display.displayID, streamWidth: w)
        pacer.reset()
        sendTileMessage(.reset(layer: 0, width: w, height: h), captureNanos: now)
        beginFreshPicture(trigger)
        if let s = windows?.sample(captureSeq: captureSeq, now: now, force: true) { reconcileLayers(s.sample, now: now) }
        ensureUnderlay(t)
        loadHostTunables()
        loggedChrome = nil   // logged again once known for this stream
    }
    private var loggedChrome: [PixelRect]?

    private func loadHostTunables() {
        let (t, error) = Tunables.load(from: Tunables.hostFileURL(try? Store()))
        hostTunables = t
        if let error { log(error) }
    }

    // MARK: The compositor model (DESIGN "The compositor model"; host flag, default off)

    /// On: the display layer is the desktop alone (desktop-level windows), everything above the normal level is one overlay
    /// layer on top, and every normal window is a layer as soon as it has a picture (no exclusion wait, no seam machinery).
    private(set) var compositor = false
    private var overlay: ScreenCapturer?
    private var overlayExcludedIDs: Set<UInt32> = []
    private var desktopLevelIDs: Set<UInt32> = []
    static let compositorEnv = ProcessInfo.processInfo.environment["MIRAGE_COMPOSITOR"]
    static func compositorWanted() -> Bool {
        if let e = compositorEnv { return e != "0" }
        return Tunables.load(from: Tunables.hostFileURL(try? Store())).tunables[.compositorModel] >= 0.5
    }
    /// The windows the overlay leaves out: the desktop-level ones, every normal window on the display, and floating app
    /// windows (they are layers).
    private func overlayExclusion(_ display: SCDisplay) -> [SCWindow] { Self.overlayExclusion(catalog.all, display) }
    static func overlayExclusion(_ windows: [SCWindow], _ display: SCDisplay) -> [SCWindow] {
        windows.filter { $0.frame.intersects(display.frame) && ($0.windowLayer <= 0 || floatingLevels.contains($0.windowLayer) && !systemOwners.contains($0.owningApplication?.applicationName ?? "")) }
    }
    /// Floating app windows (stay-on-top panels, utility windows: levels 1–19) are layers of their own in the compositor model,
    /// hit-testable like any window. In the overlay (which hit-testing passes over) they could not be clicked (phrz, 08:46Z:
    /// "stay on top windows are not interactable"). The menu bar, the Dock and system UI stay in the overlay.
    static let floatingLevels = 1...19
    static let systemOwners: Set<String> = ["Window Server", "Dock", "Control Center", "Notification Center", "SystemUIServer", "WindowManager", "Spotlight", "loginwindow"]
    static func isFloatingAppWindow(_ w: ControlMessage.WindowInfo) -> Bool { floatingLevels.contains(w.windowLevel) && !systemOwners.contains(w.app ?? "") }
    /// The display stream (layer 0): the desktop alone in the compositor model, else the display minus `excluding`. The warm
    /// pool's running desktop capture is adopted when there is one (no ScreenCaptureKit start), with its latest frame.
    private func startDesktop(_ req: ControlMessage.StreamRequest, _ t: ScreenCapturer.Target, compositor comp: Bool, excluding: [SCWindow], forceFirst: Bool = false) async throws -> (ScreenCapturer, CVPixelBuffer?) {
        let onFrame: (CVPixelBuffer, UInt64, [PixelRect]) -> Void = { [weak self] pb, nanos, dirty in self?.queue.async { self?.captured(pb, nanos, dirtyRects: dirty, layerID: 0) } }
        if comp, let (warm, last) = queue.sync(execute: { WarmPool.shared.takeDisplay(.desktop, displayID: t.display.displayID) }) {
            do {
                _ = try await warm.adopt(req, target: t, onFrame: onFrame)
                log("desktop: warm capture adopted\(last == nil ? " (no frame yet)" : "")")
                return (warm, last)
            } catch { log("desktop: warm capture not adopted (\(error))"); await warm.stop() }
        }
        let cap = ScreenCapturer(queue: queue)
        cap.forceNextFrame = forceFirst
        if comp { cap.source = .desktop }   // the compositor model: the desktop alone, never an app window
        _ = try await cap.start(req, target: t, excluding: excluding, onFrame: onFrame)
        return (cap, nil)
    }
    /// On `queue`: the warm captures' latest frames as the desktop's and the overlay's first, where they are the stream's size.
    private func feedWarmFrames(desktop: CVPixelBuffer?, overlay: CVPixelBuffer?, _ t: ScreenCapturer.Target) {
        func fits(_ pb: CVPixelBuffer) -> Bool { CVPixelBufferGetWidth(pb) == t.pixelWidth && CVPixelBufferGetHeight(pb) == t.pixelHeight }
        let now = Clock.nowNanos()
        if let pb = desktop {
            if fits(pb) { captured(pb, now, dirtyRects: [PixelRect(x: 0, y: 0, width: t.pixelWidth, height: t.pixelHeight)], layerID: 0) }
            else { log("desktop: warm frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) is not the stream's \(t.pixelWidth)x\(t.pixelHeight); waiting for the next") }
        }
        if let pb = overlay, fits(pb) { captured(pb, now, dirtyRects: [], layerID: ControlMessage.WindowInfo.overlayID) }
    }

    /// Starts the overlay capture (frames go to the overlay layer), or adopts the warm pool's, with its latest frame.
    private func startOverlay(_ req: ControlMessage.StreamRequest, _ t: ScreenCapturer.Target) async throws -> (ScreenCapturer, CVPixelBuffer?) {
        let excl = overlayExclusion(t.display)
        let onFrame: (CVPixelBuffer, UInt64, [PixelRect]) -> Void = { [weak self] pb, nanos, _ in self?.queue.async { self?.captured(pb, nanos, dirtyRects: [], layerID: ControlMessage.WindowInfo.overlayID) } }
        var ov: ScreenCapturer? = nil, last: CVPixelBuffer? = nil
        if let (warm, frame) = queue.sync(execute: { WarmPool.shared.takeDisplay(.overlay, displayID: t.display.displayID) }) {
            do {
                _ = try await warm.adopt(req, target: t, onFrame: onFrame)
                warm.requestExcluded(excl, log: { [weak self] in self?.log($0) })
                ov = warm; last = frame
                log("overlay: warm capture adopted\(frame == nil ? " (no frame yet)" : "")")
            } catch { log("overlay: warm capture not adopted (\(error))"); await warm.stop() }
        }
        if ov == nil {
            let c = ScreenCapturer(queue: queue)
            c.source = .overlay
            _ = try await c.start(req, target: t, excluding: excl, onFrame: onFrame)
            ov = c
        }
        let result = ov!
        queue.async { self.overlayExcludedIDs = Set(excl.map(\.windowID)); self.desktopLevelIDs = Set(excl.filter { $0.windowLayer < 0 }.map(\.windowID)) }
        compositorSinceNanos = Clock.nowNanos()
        queue.async { self.placeholdersDone = false }
        log("compositor model: desktop-only display layer, overlay layer above the normal level (\(excl.count) windows left out of it)")
        return (result, last)
    }
    /// The overlay layer (full display, alpha, topmost), created with the stream in the compositor model.
    private func ensureOverlayLayer() {
        guard compositor, let d = display else { return }
        let id = ControlMessage.WindowInfo.overlayID
        if let l = layers[id], l.width == d.width, l.height == d.height { return }
        layers[id] = Layer(id: id, width: d.width, height: d.height, frame: d.bounds, now: Clock.nowNanos())
    }
    /// Keeps the overlay's exclusion (new normal windows) and the desktop layer's windows (a widget added) current.
    private func reconcileCompositor(_ s: WindowTracker.Sample, needCatalog: inout [UInt32]) {
        guard compositor, let t = target else { return }
        for w in s.windows where w.windowLevel <= 0 && catalog.window(w.id) == nil { needCatalog.append(w.id) }
        let excl = overlayExclusion(t.display)
        let ids = Set(excl.map(\.windowID))
        if ids != overlayExcludedIDs, let ov = overlay {
            overlayExcludedIDs = ids
            ov.requestExcluded(excl, log: { [weak self] in self?.log($0) })
        }
        let desk = Set(excl.filter { $0.windowLayer < 0 }.map(\.windowID))
        if desk != desktopLevelIDs { desktopLevelIDs = desk; capturer?.refreshDesktop(log: { [weak self] in self?.log($0) }) }
    }

    /// The desktop-only capture (DesktopUnderlay) for this display, at half the stream size; restarted with the stream.
    private var underlay: DesktopUnderlay?
    private var underlayFor: (display: CGDirectDisplayID, w: Int, h: Int)?
    private func ensureUnderlay(_ t: ScreenCapturer.Target) {
        guard !compositor else { return }   // the display layer is the desktop itself: no second desktop capture
        let w = t.pixelWidth / 2, h = t.pixelHeight / 2
        if underlay != nil, let f = underlayFor, f.display == t.display.displayID, f.w == w, f.h == h { return }
        let old = underlay
        let u = DesktopUnderlay(log: log)
        underlay = u; underlayFor = (t.display.displayID, w, h); underlaySent = [:]
        let display = t.display
        let desk = catalog.all.filter { $0.windowLayer < 0 && $0.frame.intersects(display.frame) }
        let log = self.log
        Task {
            if let old { await Self.bounded("desktop underlay", log: log) { await old.stop() } }
            do { try await u.start(display: display, desktopWindows: desk, width: w, height: h); log("desktop underlay: \(desk.count) desktop-level windows at \(w)x\(h), every 2 s") }
            catch { log("desktop underlay unavailable: \(error)") }
        }
    }

    private func rebuildEncoder(_ l: Layer) throws {
        guard let rc else { return }
        // A session replaced while a frame is inside it never calls that frame's completion (its
        // invalidation drops the frame), which left `encoding` stuck forever (seen in the M2.5 burst runs).
        // Callers set wantKeyframe anyway, and the keyframe path rebuilds once the encoder is idle.
        guard !l.encoding else { return }
        let scale = rc.scale
        let ew = max(64, Int(Double(l.width) * scale)) & ~1, eh = max(64, Int(Double(l.height) * scale)) & ~1
        l.encoder = try HEVCEncoder(width: ew, height: eh, bitrateKbps: max(100, lastBudget.videoKbps), expectedFPS: plannedFPS())
        if scale < 1 {
            l.scaled = try Self.makeBuffer(width: ew, height: eh)
            var s: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else { throw MirageError.transport("VTPixelTransferSessionCreate failed") }
            VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            l.transfer = s
        } else {
            l.scaled = nil; l.transfer = nil
        }
        l.ackedLTR = []
        l.encoderUseNanos = Clock.nowNanos()
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
                if old?.pixelWidth != t.pixelWidth || old?.pixelHeight != t.pixelHeight || self.display?.encoder == nil {
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
            guard self.output != nil else { return }
            guard let f = self.sentFrames[nack.frameSeq] else {
                // Not in the ring (older than ~2 s, or lost during a burst): a resend is impossible, so the
                // viewer gets a recovery frame now instead of after its own timeout.
                self.log("nack for frame \(nack.frameSeq) outside the resend ring: recovery frame")
                self.requestRecovery(layer: nil)
                return
            }
            // An empty list asks for the whole frame (a sequence gap); only datagrams that have actually
            // left the pacer are resent (H5), and the resends are paced like everything else (H6).
            let wanted = nack.fragments.isEmpty ? Array(0..<f.datagrams.count) : nack.fragments
            let resend = wanted.filter { $0 >= 0 && $0 < min(f.sent, f.datagrams.count) }.map { f.datagrams[$0] }
            guard !resend.isEmpty else { return }
            self.statNackResent += resend.count
            _ = self.pace(resend, frame: nil, ahead: true)
        }
    }

    /// Schedules datagrams on the pacer at 1.25× the video budget; returns when the last one leaves.
    /// `ahead`: do not queue behind what is already scheduled (resends).
    private func pace(_ datagrams: [Data], frame: SentFrame?, ahead: Bool = false) -> UInt64 {
        guard let out = output, !datagrams.isEmpty else { return Clock.nowNanos() }
        let bytesPerSec = Double(max(150, lastBudget.videoKbps)) * 1000 / 8 * 1.25
        let now = Clock.nowNanos()
        if ahead && datagrams.count <= 12 { for d in datagrams { out.sendDatagram(d) }; return now }
        let offsets = FrameAssembler.paceOffsets(count: datagrams.count, payloadBytes: out.maxDatagramSize, bytesPerSecond: bytesPerSec)
        let start = ahead ? now : max(now, paceCursorNanos)
        for (i, d) in datagrams.enumerated() {
            let at = start &+ offsets[i]
            let delay = Double(at &- now) / 1e9
            if delay < 0.0005 { out.sendDatagram(d); frame?.sent += 1 }
            else { paceQueue.asyncAfter(deadline: .now() + delay) { out.sendDatagram(d); if let frame { self.queue.async { frame.sent += 1 } } } }
        }
        let end = start &+ (offsets.last ?? 0)
        if !ahead { paceCursorNanos = end } else { paceCursorNanos = max(paceCursorNanos, end) }
        return end
    }

    public func handle(tileAck: ControlMessage.TileAck) {
        queue.async {
            guard let sent = self.tileSent.removeValue(forKey: tileAck.msgSeq) else { return }
            let now = Clock.nowNanos()
            self.tileInflightBytes = max(0, self.tileInflightBytes - sent.bytes)
            self.rc?.streamAcked(bytes: sent.bytes, receivedNanos: tileAck.receivedNanos, now: now)
            self.refinementInFlight = max(0, self.refinementInFlight - sent.refinement)
            if sent.block != nil, self.pacer.acked(msgSeq: tileAck.msgSeq) { self.refine(now: now) }
            self.rc?.delaySample(sentNanos: sent.nanos, receivedNanos: tileAck.receivedNanos, bytes: sent.bytes, now: now)
            // Prune by age (a big refinement block legitimately outlives dozens of interactive acks).
            for (k, v) in self.tileSent where Clock.elapsed(since: v.nanos, now: now) > 20_000_000_000 { self.tileSent[k] = nil; self.refinementInFlight = max(0, self.refinementInFlight - v.refinement); self.tileInflightBytes = max(0, self.tileInflightBytes - v.bytes) }
        }
    }

    public func handle(input: ControlMessage) {
        if case .windowCommand(let c) = input { queue.async { self.handle(windowCommand: c) }; return }
        switch input {
        case .menuRequest(let r): chrome?.menu(r); return
        case .menuPress(let p): chrome?.press(p, locked: InputInjector.consoleLocked()); return
        case .iconRequest(let r): chrome?.icon(r); return
        case .appCommand(let c): chrome?.app(c, locked: InputInjector.consoleLocked()); return
        case .viewInterest(let v):
            queue.async {
                guard v != self.interest else { return }
                let was = self.unifiedView
                self.interest = v
                if was != v.unified { self.log(v.unified ? "viewer: Unified mode (window layers by the viewer's arrangement, display layer only where shown)" : "viewer: Desktop mode") }
                if let s = self.windows?.current { self.reconcileLayers(s, now: Clock.nowNanos()) }
            }
            return
        default: break
        }
        if case .refreshTiles(let r) = input {
            queue.async {
                if r.layer != 0, let l = self.layers[r.layer] {
                    // A window layer's tiles the viewer holds wrong: direct changes, due now.
                    let tiles = r.tiles.map(Int.init).filter { $0 >= 0 && $0 < l.tracker.tileCount && !l.occludedTiles.contains($0) }
                    self.statWindowAuditRefreshed += tiles.count
                    l.tracker.markDirect(tiles, now: Clock.nowNanos())
                    l.correctionTiles.formUnion(tiles)
                    return
                }
                guard r.layer == 0, let d = self.display else { return }
                let tiles = r.tiles.map(Int.init).filter { $0 >= 0 && $0 < d.tracker.tileCount }
                self.statAuditRefreshed += tiles.count
                d.taint.mark(tiles); d.taintScheduled.subtract(tiles)
                if self.debugLayers { self.log("viewer asks for \(tiles.count) desktop tiles it holds no clean pixels for") }
            }
            return
        }
        switch input { case .key, .mouseButton: caret?.kick(); default: break }
        inputQueue.async {
            self.injector?.handle(input)
            if case .scroll(let s) = input, let t = self.target, let w = self.windows {
                let x = Int(s.x * Double(t.pixelWidth)), y = Int(s.y * Double(t.pixelHeight))
                if let win = w.appWindow(at: x, y) {
                    w.queryAXScrollArea(at: x, y, windowID: win.id)
                    let ppp = w.pxPerPoint, ddx = Int((s.dx * ppp).rounded()), ddy = Int((s.dy * ppp).rounded())
                    self.scrollLock.lock()
                    let prior = self.pendingScroll.flatMap { $0.windowID == win.id ? $0 : nil }
                    self.pendingScroll = PendingScroll(x: x, y: y, windowID: win.id, nanos: Clock.nowNanos(), dxPx: (prior?.dxPx ?? 0) + ddx, dyPx: (prior?.dyPx ?? 0) + ddy)
                    self.scrollLock.unlock()
                }
            }
            self.queue.async { self.statInput += 1 }
        }
    }

    /// A window-management decision the client already shows: apply it through Accessibility, and
    /// count it as an input so the next window list can say it reflects it.
    private func handle(windowCommand c: ControlMessage.WindowCommand) {
        guard let windows, let ax, let s = windows.current else { return }
        // A window minimized from the viewer is no longer listed: its restore goes to the last target it had.
        if s.byID[c.id] == nil, c.action == .restore || c.action == .raise, let last = lastTargets[c.id], !InputInjector.consoleLocked() {
            if InputInjector.sinkPath != nil { injector?.record(.windowCommand(c)); return }
            statWindowCommands += 1
            ax.apply(c, target: last.target, origin: nil)
            return
        }
        guard let w = s.byID[c.id], let bounds = s.pointBounds[c.id] else { return }
        lastTargets[c.id] = (.init(id: w.id, pid: w.pid, title: w.title, bounds: bounds), Clock.nowNanos())
        if lastTargets.count > 64 { let now = Clock.nowNanos(); lastTargets = lastTargets.filter { Clock.elapsed(since: $0.value.nanos, now: now) < 3_600_000_000_000 } }
        statWindowCommands += 1
        // The same guards as injected input: nothing while the console is locked; in input-sink mode the
        // command is recorded, not applied, except for the measurement bench's own windows (a loopback
        // drag run moves nothing but them).
        if InputInjector.consoleLocked() { return }
        if InputInjector.sinkPath != nil, w.app != "Mirage Test Bench" || ![.move, .raise, .resize].contains(c.action) { injector?.record(.windowCommand(c)); return }
        // Whole points: a fractional origin (stream pixels ÷ 1.89 on mac-daddy) made the window list report a size that
        // wobbled by a pixel as the window moved, and every wobble re-sent the layer (~400 KB per Finder drag).
        let origin = (c.x != nil && c.y != nil) ? { let p = windows.originInPoints(x: c.x!, y: c.y!); return CGPoint(x: p.x.rounded(), y: p.y.rounded()) }() : nil
        let size = (c.width != nil && c.height != nil) ? CGSize(width: Double(c.width!) / windows.pxPerPoint, height: Double(c.height!) / windows.pxPerPoint) : nil
        if c.action == .move || c.action == .raise { lastMotionNanos = Clock.nowNanos() }
        if c.action == .move { layers[c.id]?.movedNanos = Clock.nowNanos() }
        if let seq = c.inputSeq { injector?.noteApplied(seq: seq) }
        ax.apply(c, target: .init(id: w.id, pid: w.pid, title: w.title, bounds: bounds), origin: origin, size: size) { [weak self] ok in
            guard let self else { return }
            self.queue.async {
                if !ok, c.action == .move || c.action == .raise || c.action == .resize { self.log("window command \(c.action) for \(c.id) failed (no accessibility window?)") }
                // Make the list reflect it as soon as it happened, not at the next 50 ms tick.
                if let w = self.windows?.sample(captureSeq: self.captureSeq, now: Clock.nowNanos(), force: true) { self.reconcileLayers(w.sample, now: Clock.nowNanos()); self.pendingMoved += w.moved; self.publishWindows(now: Clock.nowNanos(), full: false) }
            }
        }
    }

    // Input with redundancy (InputPacket): applied exactly once, in order, whatever the loss. The receiver's
    // state lives here, in the session, so a resumed connection continues the same sequence.
    private var inputReceiver = InputReceiver()
    private let inputReceiverLock = NSLock()
    public func handle(inputPacket p: InputPacket) -> InputAck? {
        guard injector != nil else { return nil }
        inputReceiverLock.lock()
        let r = inputReceiver.receive(p)
        inputReceiverLock.unlock()
        for m in r.apply { handle(input: m) }
        return r.ack
    }

    public func handle(probeEcho sentNanos: UInt64, receivedNanos: UInt64) {
        queue.async {
            if self.trainSent.contains(sentNanos) { self.trainEcho(receivedNanos: receivedNanos); return }
            self.rc?.probeSample(sentNanos: sentNanos, receivedNanos: receivedNanos, now: Clock.nowNanos()); self.applyBudget(now: Clock.nowNanos())
        }
    }
    private var probeSeq: UInt64 = 0

    /// The connection went away: capture and sending stop, every piece of session state stays (layers
    /// and their trackers, controller and tier, encoder rung, frame and tile sequences, input sequence).
    /// Whatever was in flight is treated as lost: unacked tile messages have their rects queued for a
    /// lossless resend, unacked video frames are forgotten (the resume keyframe replaces them).
    public func suspend() async {
        queue.sync { holdWarm(false) }
        queue.sync { Self.savePriorDelivery(self.rc?.measuredPeakKbps ?? 0, for: self.output?.peerID, network: self.request?.networkFingerprint) }   // the next connect starts there
        // The session is cut loose first (output, timers, captures detached), then the captures are stopped, each within 3 s:
        // ScreenCaptureKit's stopCapture can fail to return, and awaiting it before the cut left a suspended streamer
        // capturing, refining and sending into the dead connection for good (mac-daddy 2026-10-21: a second streamer
        // alongside the next session's, its exclusion checks every 10 s, tile sends failing for minutes).
        let (cap, caps): (ScreenCapturer?, [WindowCapturer]) = await withCheckedContinuation { c in
            queue.async {
                let now = Clock.nowNanos()
                let cap = self.capturer
                let caps = self.layers.values.compactMap { l in let w = l.capturer; l.capturer = nil; return w }
                let und = self.underlay; self.underlay = nil; self.underlayFor = nil
                if let und { Task { await Self.bounded("desktop underlay", log: self.log) { await und.stop() } } }
                let ov = self.overlay; self.overlay = nil
                if let ov { Task { await Self.bounded("overlay capture", log: self.log) { await ov.stop() } } }
                let fb = self.fallbackCapture; self.fallbackCapture = nil; self.fallbackPools = [:]; self.pendingFallback = []
                if let fb { Task { await Self.bounded("fallback capture", log: self.log) { await fb.stop() } } }
                self.cursor?.stop(); self.cursor = nil
                self.statTimer?.cancel(); self.statTimer = nil
                self.refineTimer?.cancel(); self.refineTimer = nil
                self.rateTimer?.cancel(); self.rateTimer = nil
                self.capturer = nil; self.output = nil; self.setLive(false)
                self.unacked = [:]; self.sentFrames = [:]; self.recentlyPurged = [:]; self.paceCursorNanos = 0
                var resent = 0
                for (_, v) in self.tileSent {
                    guard let l = self.layers[v.layer] else { continue }
                    let tiles = l.tracker.tiles(covering: v.rects)
                    l.tracker.markVideo(tiles, now: now)
                    resent += tiles.count
                }
                if resent > 0 { self.log("suspend: \(resent) tiles of unacked tile messages queued for resend") }
                self.tileSent = [:]; self.refinementInFlight = 0; self.tileInflightBytes = 0; self.pacer.reset()
                for l in self.layers.values { l.stagedOpenSince = nil }   // the viewer drops staged levels on the resume reset
                for l in self.layers.values {
                    switch l.fresh {
                    case .base, .climb: l.fresh = .base(seq: 0)       // the resume keyframe becomes the base
                    default: break
                    }
                    l.encoding = false; l.submitted = nil
                    l.forceFullDiff = true
                }
                self.suspendedAt = now
                let inj = self.injector
                self.inputQueue.async { inj?.releaseAll() }   // nothing stays held while nobody is connected
                c.resume(returning: (cap, caps))
            }
        }
        await stopCaptures(cap, caps)
    }
    private var suspendedAt: UInt64 = 0

    /// Stops the captures in parallel, giving each up to 3 s (a stopCapture that never returns is logged and left behind).
    private func stopCaptures(_ display: ScreenCapturer?, _ windows: [WindowCapturer]) async {
        let log = self.log
        await withTaskGroup(of: Void.self) { g in
            if let display { g.addTask { await Self.bounded("display capture", log: log) { await display.stop() } } }
            for w in windows { g.addTask { await Self.bounded("window capture", log: log) { await w.stop() } } }
        }
    }
    /// Runs `op` and returns when it finishes or after `seconds`, whichever comes first (op keeps running unawaited then).
    static func bounded(_ what: String, seconds: Double = 3, log: @escaping @Sendable (String) -> Void, _ op: @escaping @Sendable () async -> Void) async {
        final class Once: @unchecked Sendable {
            private let lock = NSLock(); private var k: CheckedContinuation<Bool, Never>?
            init(_ k: CheckedContinuation<Bool, Never>) { self.k = k }
            func resume(_ v: Bool) { lock.lock(); let c = k; k = nil; lock.unlock(); c?.resume(returning: v) }
        }
        let finished = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            let once = Once(k)
            Task { await op(); once.resume(true) }
            Task { try? await Task.sleep(for: .seconds(seconds)); once.resume(false) }
        }
        if !finished { log("\(what): stop did not return within \(Int(seconds)) s; left behind") }
    }

    public func cachedBytes() async -> Int {
        await withCheckedContinuation { c in queue.async {
            func b(_ p: CVPixelBuffer?) -> Int { p.map { CVPixelBufferGetDataSize($0) } ?? 0 }
            c.resume(returning: self.layers.values.reduce(0) { $0 + b($1.lastFrame) + b($1.canvas) + b($1.scaled) })
        } }
    }
    public func shedCaches() async {
        await withCheckedContinuation { c in queue.async {
            let before = self.layers.values.reduce(0) { $0 + ($1.lastFrame.map { CVPixelBufferGetDataSize($0) } ?? 0) }
            for l in self.layers.values {
                l.lastFrame = nil; l.canvas = nil; l.scaled = nil; l.transfer = nil; l.encoder = nil
                l.forceFullDiff = true
            }
            self.log("suspended session: pixel caches shed (\(before >> 20) MB of last frames); a resume sends every layer's picture again")
            c.resume()
        } }
    }

    /// A new connection presented this session's token. The viewer kept its picture, so: rebind the
    /// output, restart capture (display and window layers), and bring the picture current with a keyframe
    /// masked to the tiles the viewer does not have crisp plus the diff of each layer's first capture
    /// against the last frame it saw. The ladder rung, tier, controller target and all sequences continue.
    public func resume(_ req: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
        // Taken over from a connection the host had not yet noticed was dead: suspend that side first.
        if capturer != nil { await suspend() }
        queue.sync { holdWarm(true) }
        do { return try await resumeStream(req, output: output) } catch { queue.sync { holdWarm(false) }; throw error }
    }
    private func resumeStream(_ req: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
        await catalog.refreshNow()
        let comp = Self.compositorWanted()
        let excluded = await withCheckedContinuation { c in queue.async { c.resume(returning: self.layers.values.filter { $0.exposed && !$0.isDisplay }.flatMap { l in [l.id] + (self.windows?.current?.children[l.id] ?? []) }.compactMap { self.catalog.window($0) }) } }
        let t = try await ScreenCapturer.resolve(req)
        let (cap, deskFrame) = try await startDesktop(req, t, compositor: comp, excluding: comp ? [] : excluded, forceFirst: true)
        let (ov, overlayFrame) = comp ? try await startOverlay(req, t) : (nil, nil)
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                do {
                    let now = Clock.nowNanos()
                    let gapMs = self.suspendedAt > 0 ? (Clock.elapsed(since: self.suspendedAt, now: now)) / 1_000_000 : 0
                    self.output = output
                    self.setLive(true)
                    self.capturer = cap
                    self.compositor = comp; self.overlay = ov
                    self.ensureOverlayLayer()
                    self.ensureUnderlay(t)
                    if !self.fallbackLayers.isEmpty { self.ensureFallbackCapture() }
                    self.loadHostTunables()
                    self.lastExcludedIDs = Set(excluded.map(\.windowID))
                    let old = self.target
                    self.target = t
                    self.request = req
                    cap.onStop = { [weak self] err in self?.log("capture stopped: \(err.map { "\($0)" } ?? "ok")") }
                    let plan = ResumePicture.plan(sizeChanged: old?.pixelWidth != t.pixelWidth || old?.pixelHeight != t.pixelHeight,
                                                  viewerHoldsPicture: req.holdsPicture, hasEncoder: self.display?.encoder != nil)
                    if case .fresh(let trigger) = plan {
                        // A new size, or a viewer that holds nothing (an app relaunched with its saved token): every layer
                        // starts over. Same size: the controller, tier and rung carry on (no reconnect penalty).
                        try self.configure(for: t, req: req, trigger: trigger, keepController: plan.keepsController)
                        self.log("resumed after \(gapMs) ms (\(trigger.rawValue)) at \(t.pixelWidth)x\(t.pixelHeight): fresh picture of every layer; rung \(self.rc?.rung ?? -1), tier \(self.rc?.tier.name ?? "?"), target \(self.rc?.targetKbps ?? 0) kbps")
                    } else {
                        self.rc?.maxKbps = req.bitrateKbps
                        if let d = self.display { d.wantKeyframe = true; d.keyframeArmed = false; d.ackedLTR = [] }
                        self.tokens = self.bucketCapacity(); self.lastRefill = now; self.lastTileRefill = now
                        for l in self.layers.values { l.lastSendNanos = 0 }
                        self.log("resumed after \(gapMs) ms: rung \(self.rc?.rung ?? -1), tier \(self.rc?.tier.name ?? "?"), target \(self.rc?.targetKbps ?? 0) kbps, fresh \(self.display?.fresh.description ?? "?"), \(self.layers.count - 1) window layers; masked keyframe next")
                    }
                    self.injector?.setDisplay(t.display.displayID)
                    self.feedWarmFrames(desktop: deskFrame, overlay: overlayFrame, t)
                    let cur = CursorMonitor(displayID: t.display.displayID)
                    cur.onShape = { [weak self] s in self?.output?.sendControl(.cursorShape(s)) }
                    cur.onPosition = { [weak self] p in self?.output?.sendControl(.cursorPosition(p)) }
                    cur.start(on: self.queue)
                    self.cursor = cur
                    // Window layers the viewer already holds are announced again (their pixel size), then
                    // their capturers restart and the first frame's full diff sends whatever changed.
                    for l in self.layers.values where !l.isDisplay && l.announced { self.sendTileMessage(.reset(layer: l.id, width: l.width, height: l.height), captureNanos: now) }
                    self.chrome?.resend(); self.caret?.resend()
                    if let s = self.windows?.sample(captureSeq: self.captureSeq, now: now, force: true) { self.reconcileLayers(s.sample, now: now) }
                    self.publishWindows(now: now, full: true)
                    self.startTimers()
                    c.resume(returning: t.info)
                } catch { c.resume(throwing: error) }
            }
        }
    }

    public func stop() async {
        queue.sync { holdWarm(false) }
        queue.sync { Self.savePriorDelivery(self.rc?.measuredPeakKbps ?? 0, for: self.output?.peerID, network: self.request?.networkFingerprint) }
        // Cut loose first, then stop the captures within 3 s each (suspend()).
        let (cap, caps): (ScreenCapturer?, [WindowCapturer]) = await withCheckedContinuation { c in
            queue.async {
                let cap = self.capturer
                let caps = self.layers.values.compactMap { l in let w = l.capturer; l.capturer = nil; return w }
                let und = self.underlay; self.underlay = nil; self.underlayFor = nil
                if let und { Task { await Self.bounded("desktop underlay", log: self.log) { await und.stop() } } }
                let ov = self.overlay; self.overlay = nil
                if let ov { Task { await Self.bounded("overlay capture", log: self.log) { await ov.stop() } } }
                let fb = self.fallbackCapture; self.fallbackCapture = nil; self.fallbackPools = [:]; self.pendingFallback = []
                if let fb { Task { await Self.bounded("fallback capture", log: self.log) { await fb.stop() } } }
                self.cursor?.stop(); self.cursor = nil
                self.statTimer?.cancel(); self.statTimer = nil
                self.refineTimer?.cancel(); self.refineTimer = nil
                self.rateTimer?.cancel(); self.rateTimer = nil
                self.capturer = nil; self.output = nil; self.setLive(false)
                self.layers = [:]
                self.chrome?.stop(); self.chrome = nil
                self.caret?.stop(); self.caret = nil
                let inj = self.injector; self.injector = nil
                self.inputQueue.async { inj?.releaseAll() }
                c.resume(returning: (cap, caps))
            }
        }
        await stopCaptures(cap, caps)
    }

    // MARK: Layers

    /// Which windows of a list get their own capture: normal-level windows of real apps, front first,
    /// within the count and pixel bounds. The rest (menus, the dock, the menu bar, overflow) stay in the
    /// display layer and the client draws them as cut-outs.
    private func plannedLayers(in list: [ControlMessage.WindowInfo], displayPixels: Int) -> [ControlMessage.WindowInfo] {
        var out: [ControlMessage.WindowInfo] = []
        var pixels = 0
        // Compositor model: a window entirely covered by normal windows (or off the display) captures nothing until it shows,
        // so the stream and pixel caps go to what can be seen; a visible window that still misses them is logged.
        let normals = list.filter { $0.windowLevel == 0 }
        let screen = display?.bounds
        for w in list where (w.windowLevel == 0 || compositor && Self.isFloatingAppWindow(w)) && w.app != "Window Server" && w.app != "Dock" && w.frame.width >= 64 && w.frame.height >= 64
                            && (Self.layerApps.map { apps in apps.contains(w.app ?? "") || apps.contains { w.title.contains($0) } } ?? true) && (compositor || !unexcludable.contains(w.id)) {
            if compositor, let screen, WindowTracker.occlusion(of: w, in: normals, display: screen).visibleFraction < 0.002 { continue }
            guard out.count < maxWindowLayers, pixels + w.frame.area <= maxLayerPixels else {
                if compositor, !loggedCapMiss.contains(w.id) { loggedCapMiss.insert(w.id); log("compositor model: visible window \(w.id) (\(w.app ?? "?")) is over the layer caps (\(maxWindowLayers) layers, \(maxLayerPixels / 1_000_000) MP): not shown") }
                continue
            }
            out.append(w); pixels += w.frame.area
        }
        return out
    }

    /// Creates, resizes, stops and reprioritises window layers after a window-list sample; computes
    /// occlusion; keeps the display stream's exclusion list in step with the layers the viewer shows.
    private func reconcileLayers(_ s: WindowTracker.Sample, now: UInt64) {
        guard let t = target, let d = display else { return }
        let displayRect = d.bounds
        InputInjector.shieldWindow = ScreenLock.shieldPresent(s.windows, display: displayRect)
        let signals = InputInjector.lockSignals()
        if signals.locked != screenLocked {
            screenLocked = signals.locked
            log(screenLocked ? "screen locked (\(signals.description)): window layers paused, the display shows the lock screen" : "screen unlocked: window layers resume")
            lastHostStatusNanos = 0   // announce it at the next status tick
        }
        let planned = screenLocked ? [] : plannedLayers(in: s.windows, displayPixels: t.pixelWidth * t.pixelHeight)
        for w in planned { if let f = plannedFrames[w.id], f != w.frame { recentFrames.append((f, now)) } }
        for w in planned where excludedFrom[w.id] != nil { exposedSince[w.id] = nil }   // excluded: the wait is over
        for w in planned where !compositor && (layers[w.id]?.exposed ?? false) && excludedFrom[w.id] == nil {
            let since = exposedSince[w.id] ?? now; exposedSince[w.id] = since
            if Clock.elapsed(since: since, now: now) > 5_000_000_000 {
                unexcludable.insert(w.id)
                log("layer \(w.id) (\(w.app ?? "?")): the display stream cannot exclude it (ScreenCaptureKit does not list it); it stays part of the desktop picture")
            }
        }
        plannedFrames = Dictionary(planned.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let plannedIDs = Set(planned.map(\.id))
        var needCatalog: [UInt32] = []
        let frontID = s.windows.first(where: { $0.windowLevel == 0 })?.id
        for w in planned {
            if let l = layers[w.id] {
                l.absentSince = 0
                if l.frame.x != w.frame.x || l.frame.y != w.frame.y { l.movedNanos = now; windowMovedThisSession = true }
                l.frame = w.frame
                // Resized only when its size in points changed by a point or more: pixel rounding of a moving window's
                // frame at a fractional scale is not a resize (each one re-announced and re-sent the whole layer).
                let ps = s.pointBounds[w.id]?.size ?? .zero
                let pointResize = l.pointSize == .zero || abs(ps.width - l.pointSize.width) >= 1 || abs(ps.height - l.pointSize.height) >= 1
                if l.pointSize == .zero { l.pointSize = ps }
                if pointResize, Layer.even(w.frame.width) != l.width || Layer.even(w.frame.height) != l.height {
                    l.pointSize = ps
                    // Resized on the host: the layer starts over at the new size (a still, then blocks).
                    l.resize(width: w.frame.width, height: w.frame.height)
                    log("layer \(w.id) resized to \(w.frame.width)x\(w.frame.height)")
                }
                if l.capturer == nil, !fallbackLayers.contains(l.id) { startCapturer(for: l, sample: s, needCatalog: &needCatalog) }
            } else {
                let l = Layer(id: w.id, width: w.frame.width, height: w.frame.height, frame: w.frame, now: now)
                layers[w.id] = l
                // A new layer's wait for its exclusion starts now: a stale start (the layer of a stream before a resume
                // with a fresh picture) marked every window unexcludable within a frame of being exposed again, and
                // after an app relaunch every window stayed in the desktop picture for good.
                exposedSince[w.id] = nil
                startCapturer(for: l, sample: s, needCatalog: &needCatalog)
            }
        }
        // Layers no longer planned (window gone, minimized, dropped out of the cap): capture stops; the
        // pixels stay for a while in case it comes right back (a Space switch, a restore).
        for (id, l) in layers where id != 0 && id != ControlMessage.WindowInfo.overlayID && !plannedIDs.contains(id) {
            // Compositor model: a window covered by others (or pushed aside by Show Desktop) keeps its layer, and the viewer
            // its picture, for as long as it is in the list. Released after 10 s, it came back as a new layer whose capture
            // took 8 s to deliver, and nothing owned its rectangle meanwhile (phrz's first compositor session: Music's mini
            // player shown as wallpaper). Its capture runs on for 10 s, all of it held back as covered, so a quick return
            // (a Show Desktop round trip, a window raised and lowered) needs no restart: restarts took up to 12 s there.
            if compositor, !screenLocked, s.byID[id] != nil {
                pendingFallback.remove(id)
                if l.absentSince == 0 { l.absentSince = now; l.occludedTiles = Set(0..<l.tracker.tileCount) }
                if let cap = l.capturer, Clock.elapsed(since: l.absentSince, now: now) > layerRetainNanos {
                    l.capturer = nil; l.awaitingOwnSince = 0; Task { await cap.stop() }
                }
                continue
            }
            if let cap = l.capturer { l.capturer = nil; Task { await cap.stop() } }
            if screenLocked { l.absentSince = 0; continue }   // paused, not gone: kept for the unlock
            if l.absentSince == 0 { l.absentSince = now }
            else if Clock.elapsed(since: l.absentSince, now: now) > layerRetainNanos { layers[id] = nil; ax?.forget(id); log("layer \(id) released") }
        }
        // Compositor model: a shown window whose own capture has not delivered within 400 ms (a new window, one uncovered
        // again) is cut from the full display capture until it does, so its rectangle always has its window.
        // (The 400 ms full-display stopgap for windows whose own capture had not delivered is gone: cut every 100 ms at the
        // list's frame, a window jiggled inside its frame and carried transparent holes where windows in front of it were,
        // the desktop showing through: phrz, 08:46Z, "window contents jiggle inside, artifacting galore". A window keeps its
        // last picture until its own capture delivers; the stream's first windows get placeholders.)
        if compositor, Self.pendingFallbackEnabled {
            for w in planned {
                guard let l = layers[w.id], l.awaitingOwnSince != 0, !fallbackLayers.contains(w.id), !pendingFallback.contains(w.id),
                      Clock.elapsed(since: l.awaitingOwnSince, now: now) > 400_000_000,
                      Clock.elapsed(since: compositorSinceNanos, now: now) > 10_000_000_000 else { continue }
                pendingFallback.insert(w.id)
                if debugLayers { log("layer \(w.id): own capture not delivering yet; cut from the full display capture meanwhile") }
                ensureFallbackCapture()
            }
        }
        // Occlusion on the host, frontmost flag, and the capture rate per layer. Only windows that are opaque for
        // sure occlude: other layers and cut-out-safe windows (menus, the dock, app windows). A transparent
        // overlay in front of everything (the M3.1 field regression) must not hold every layer's pixels back.
        let displayArea = displayRect.area
        let occluders = s.windows.filter { plannedIDs.contains($0.id) || Self.cutoutSafe($0, displayArea: displayArea) }
        for w in planned {
            guard let l = layers[w.id] else { continue }
            var (fraction, covering) = WindowTracker.occlusion(of: w, in: occluders, display: displayRect)
            let hiddenHere = interest?.hiddenLayers?.contains(w.id) ?? false
            if unifiedView {
                // Unified: the viewer stacks windows itself; only the part off this display (not capturable) and a
                // window minimized there count as hidden.
                covering = []
                let on = w.frame.intersection(displayRect).area
                fraction = hiddenHere ? 0 : Double(on) / Double(max(1, w.frame.area))
            }
            l.visibleFraction = fraction
            l.frontmost = w.id == frontID
            // Tiles of the layer fully inside a covering rect (or wholly outside the display) are occluded. A tile across the
            // display's edge is partly visible: counted as occluded, it was never sent again, and a window over the left edge
            // showed a black column after Show Desktop (mac-daddy, compositor, 8249cda).
            var occluded = Set<Int>(), offDisplay = Set<Int>()
            let onScreen = l.local(w.frame.intersection(displayRect))
            for i in 0..<l.tracker.tileCount {
                let r = l.tracker.rect(of: i)
                if r.intersection(onScreen).isEmpty { offDisplay.insert(i) }
                if r.intersection(onScreen).isEmpty || hiddenHere && unifiedView { occluded.insert(i); continue }
                let rd = r.offset(l.frame.x, l.frame.y)
                if covering.contains(where: { $0.intersection(rd) == rd }) { occluded.insert(i) }
            }
            l.onScreenLocal = onScreen
            cropOffDisplay(l, onScreen: onScreen, now: now)
            let exposedNow = l.occludedTiles.subtracting(occluded)
            if !exposedNow.isEmpty {
                let n = l.tracker.expedite(in: l.bounds, now: now, only: exposedNow)
                if debugLayers { log("layer \(l.id): \(exposedNow.count) tiles uncovered on the host, \(n) made due, \(exposedNow.filter { l.tracker.isCrisp($0) }.count) crisp, pending total \(l.tracker.pendingTotal)") }
            }
            l.occludedTiles = occluded
            // Back on the display (Show Desktop's return): tiles held as a moved window's backdrop are sent now. A window's
            // tiles are its own, wherever it sits; held until the window went idle, a busy window's first column stayed black
            // after every Show Desktop round on mac-daddy (its backdrop level was taken mid-slide).
            let returned = l.offDisplayTiles.subtracting(offDisplay)
            if compositor, !returned.isEmpty { l.tracker.releaseHeld(returned, now: now) }
            l.offDisplayTiles = offDisplay
            let fps = l.frontmost ? 30 : (fraction <= 0.001 ? 2 : 10)
            if let cap = l.capturer {
                // The capture follows the window (sourceRect on its frame) and leaves out every window that comes over it.
                if let pf = s.pointBounds[w.id] { cap.follow(pointFrame: pf, width: l.width, height: l.height, fps: fps) }
                let own = Set([w.id] + (s.children[w.id] ?? []))
                let area = cap.pointFrame.insetBy(dx: -64, dy: -64)
                var add: [SCWindow] = []
                for (id, r) in s.pointBounds where !own.contains(id) && !cap.isExcluded(id) && r.intersects(area) {
                    if let sc = catalog.window(id) { add.append(sc); catalogMissNanos[id] = nil }
                    else if let first = catalogMissNanos[id] {
                        // Not listed by ScreenCaptureKit even after a refresh: it cannot be excluded (it stays in the capture).
                        if catalog.refreshedNanos < first &+ 300_000_000 { needCatalog.append(id) }
                    } else { catalogMissNanos[id] = now; needCatalog.append(id) }
                }
                if !add.isEmpty {
                    cap.exclude(add)
                    if debugLayers { log("layer \(w.id): capture now also leaves out \(add.map(\.windowID))") }
                }
            }
        }
        if catalogMissNanos.count > 256 { catalogMissNanos = catalogMissNanos.filter { s.pointBounds[$0.key] != nil } }
        updateDisplayHidden(now: now)
        if !needCatalog.isEmpty {
            catalog.ensure(needCatalog) { [weak self] in self?.queue.async { guard let self, let s = self.windows?.current else { return }; self.reconcileLayers(s, now: Clock.nowNanos()) } }
        }
        // The compositor model: the display stream is the desktop alone; only the overlay's exclusion follows the windows.
        if compositor {
            reconcileCompositor(s, needCatalog: &needCatalog)
            if !needCatalog.isEmpty { catalog.ensure(needCatalog) { [weak self] in self?.queue.async { guard let self, let s = self.windows?.current else { return }; self.reconcileLayers(s, now: Clock.nowNanos()) } } }
            return
        }
        // The display stream leaves out exactly the layers the viewer shows (exposed): a layer the viewer
        // does not hold yet stays in the display picture (the client draws it as a cut-out meanwhile).
        var exposedIDs = Set(layers.values.filter { !$0.isDisplay && $0.exposed && plannedIDs.contains($0.id) }.map(\.id))
        for id in exposedIDs { for c in s.children[id] ?? [] { exposedIDs.insert(c) } }
        if exposedIDs != lastExcludedIDs, let cap = capturer {
            // Every layer's own window must be excluded; its folded child windows (the traffic lights) only if
            // ScreenCaptureKit lists them, which it does not: requiring them (d5a233b–b7fda04) meant the display
            // stream never excluded such a window and kept its pixels in the desktop layer (the ghost).
            let parents = Set(layers.keys).intersection(exposedIDs)
            let missingParents = parents.filter { catalog.window($0) == nil }
            // Exclude every window ScreenCaptureKit lists; one it does not list must not hold the others back (it is
            // not presented as a layer until excluded, and is given up after 5 s).
            if !missingParents.isEmpty { catalog.ensure(Array(missingParents)) { [weak self] in self?.queue.async { guard let self, let s = self.windows?.current else { return }; self.reconcileLayers(s, now: Clock.nowNanos()) } } }
            do {
                let scWindows = exposedIDs.compactMap { catalog.window($0) }
                // Parents missing from the catalog are left out of what counts as applied, so finding them later re-applies.
                lastExcludedIDs = exposedIDs.subtracting(missingParents)
                let skipped = exposedIDs.count - scWindows.count
                if debugLayers || skipped > 0 && !loggedChildSkip { loggedChildSkip = true; log("display excludes \(scWindows.count) windows (\(skipped) windows ScreenCaptureKit does not list stay in the display stream)") }
                cap.requestExcluded(scWindows, log: { [weak self] in self?.log($0) }, applied: { [weak self] ids in
                    self?.queue.async {
                        guard let self else { return }
                        let set = Set(ids)
                        for id in Array(self.excludedFrom.keys) where !set.contains(id) { self.excludedFrom[id] = nil }
                        for id in ids where self.excludedFrom[id] == nil { self.excludedFrom[id] = self.captureSeq &+ 1; self.excludedAtNanos[id] = Clock.nowNanos() }
                        self.updateDisplayHidden(now: Clock.nowNanos())
                        if let s = self.windows?.current { self.publishWindows(now: Clock.nowNanos(), full: false); _ = s }
                    }
                })
            }
        }
    }

    /// Window ids ScreenCaptureKit did not list when first seen over a layer (retried once after a catalog refresh).
    private var catalogMissNanos: [UInt32: UInt64] = [:]

    private func startCapturer(for l: Layer, sample s: WindowTracker.Sample, needCatalog: inout [UInt32]) {
        if compositor, let app = Self.testFallbackApp, s.byID[l.id]?.app == app { useFallback(l, why: "MIRAGE_TEST_FALLBACK"); return }
        if l.awaitingOwnSince == 0 { l.awaitingOwnSince = Clock.nowNanos() }
        guard let sc = catalog.window(l.id) else { needCatalog.append(l.id); return }
        let pointFrame = s.pointBounds[l.id] ?? sc.frame
        guard let display = catalog.display(for: pointFrame) else { needCatalog.append(l.id); return }
        // Every other window ScreenCaptureKit lists is left out (the desktop picture too): the layer is the window alone,
        // on transparency, and macOS does not badge a window that a capture merely leaves in.
        let own = Set([l.id] + (s.children[l.id] ?? []))
        let others = catalog.all.filter { !own.contains($0.windowID) }
        // Warm host: the pool's running capture of this window, reconfigured for the layer, with its latest frame as the
        // layer's first; no ScreenCaptureKit start to wait for.
        if let (cap, last) = WarmPool.shared.take(l.id) {
            l.capturer = cap
            l.forceFullDiff = true
            cap.onStop = { [weak self, weak l] err in self?.queue.async {
                guard let l, l.capturer === cap else { return }; l.capturer = nil; self?.log("layer \(l.id) capture stopped: \(err.map { "\($0)" } ?? "ok")")
                if let err { self?.useFallback(l, why: "its own capture stopped (\(err))") }
            } }
            cap.adopt { [weak self] pb, nanos in self?.queue.async { self?.ownFrame(pb, nanos, layer: l) } }
            cap.exclude(others)
            cap.follow(pointFrame: pointFrame, width: l.width, height: l.height, fps: 10)
            let fits = last.map { CVPixelBufferGetWidth($0) == cap.width && CVPixelBufferGetHeight($0) == cap.height } ?? false
            log("layer \(l.id): warm capture adopted\(fits ? " with its frame" : last == nil ? " (no frame yet)" : " (its frame is another size)")")
            if fits, let last, l.lastFrame == nil { captured(last, Clock.nowNanos(), dirtyRects: [], layerID: l.id) }
            return
        }
        let cap = WindowCapturer(window: sc, display: display, pointFrame: pointFrame, width: l.width, height: l.height, fps: 10, queue: queue)
        l.capturer = cap
        l.forceFullDiff = true
        cap.onStop = { [weak self, weak l] err in self?.queue.async {
            guard let l, l.capturer === cap else { return }; l.capturer = nil; self?.log("layer \(l.id) capture stopped: \(err.map { "\($0)" } ?? "ok")")
            if let err { self?.useFallback(l, why: "its own capture stopped (\(err))") }
        } }
        // The window's first frame from a snapshot with the stream's own filter, while ScreenCaptureKit queues the stream.
        if compositor {
            let independent = hostTunables[.windowShotIndependent] >= 0.5
            Task { [weak self] in
                guard let pb = await cap.snapshot(excluding: others, independent: independent) else { return }
                let nanos = Clock.nowNanos()
                self?.queue.async { guard let self, l.capturer === cap, l.lastFrame == nil else { return }; l.snapshotFrame = pb; self.captured(pb, nanos, dirtyRects: [], layerID: l.id) }
            }
        }
        Task { [weak self] in
            do { try await cap.start(excluding: others) { [weak self] pb, nanos in self?.queue.async { self?.ownFrame(pb, nanos, layer: l) } } }
            catch { self?.queue.async { if l.capturer === cap { l.capturer = nil }; self?.log("layer \(l.id) capture failed: \(error)"); self?.useFallback(l, why: "its own capture failed") } }
        }
    }

    // MARK: Fallback (compositor model): a window cut from the full display capture

    /// Layers whose own capture failed (or MIRAGE_TEST_FALLBACK names their app): their frames are cut at their frame from one
    /// full display capture (the composited screen, nothing left out), started while any layer needs it. Soft, and partly
    /// covered where a window is in front, but still a layer: never baked into the desktop.
    private var fallbackLayers = Set<UInt32>()
    // MARK: Placeholders (DESIGN §3.0b)

    private var placeholdersDone = false
    /// Every visible window at once: one small screenshot of the composited display, each planned window that has no picture
    /// yet cut from it (windows in front left transparent) and sent as a 32-px still with its layer's announcement. The
    /// viewer draws it upscaled (soft) until the window's own still replaces it. Without it, windows appeared one by one as
    /// their captures started (~0.6 s apart on mac-daddy; the last ~5 s after the first on Japan bus).
    private func sendPlaceholders() {
        guard let t = target else { return }
        // Half the stream's width in the compositor model: the windows' stage-1 stills are cut from it (M-FIVE).
        // Half the stream's width in the compositor model (the windows' stage-1 stills); 800 px otherwise.
        // (Full size, with each cut as the window's first frame, was tried in 26ae000: the window's own capture then differed
        // from the composited cut in most tiles, which went again, and windows changed 4-6 times: 20 Mbps crisp 15.8 s.)
        // Warm host: the idle snapshot, while the window layout is the one it was taken in (no screenshot to wait for).
        if let (snap, age) = WarmPool.shared.freshSnapshot(displayID: t.display.displayID) {
            log("placeholders and stage 1 from the warm snapshot (\(age / 1000) s old)")
            placeholders(from: snap.px, width: snap.width, height: snap.height, streamWidth: t.pixelWidth)
            return
        }
        let shotW = compositor ? max(800, t.pixelWidth / 2) : 800, shotH = max(1, shotW * t.pixelHeight / max(1, t.pixelWidth))
        Task { [weak self] in
            guard let px = await Self.displayShot(t.display, width: shotW, height: shotH) else { return }
            self?.queue.async { self?.placeholders(from: px, width: shotW, height: shotH, streamWidth: t.pixelWidth) }
        }
    }
    /// One screenshot of the composited display at `width`x`height`, premultiplied BGRA.
    static func displayShot(_ display: SCDisplay, width shotW: Int, height shotH: Int) async -> [UInt8]? {
        let c = SCStreamConfiguration()
        c.width = shotW; c.height = shotH; c.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: c) else { return nil }
        var px = [UInt8](repeating: 0, count: shotW * shotH * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: shotW, height: shotH, bitsPerComponent: 8, bytesPerRow: shotW * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: shotW, height: shotH)); return true
        }
        return ok ? px : nil
    }
    private func placeholders(from px: [UInt8], width sw: Int, height sh: Int, streamWidth: Int) {
        guard let s = windows?.current else { return }
        let k = Double(sw) / Double(max(1, streamWidth))
        var sent = 0, bytes = 0
        // The desktop's: the whole screen (the seam design's desktop picture carries the windows, so this stands in for
        // all of it); in the compositor model with the normal windows left transparent (they have their own). 64 px long.
        // Not over a still already sent: with warm captures the desktop's own still can land before this screenshot returns,
        // and the 64-px placeholder then replaced it (a regression on the viewer, wm1 20 Mbps run).
        if let d = display, d.fresh != .done, !d.stillSent {
            // The whole screen in both models: in the compositor model the windows' stage-1 stills land over it a moment later.
            let shot = px
            let ow = 64, oh = max(4, 64 * sh / max(1, sw))
            if let data = shot.withUnsafeBytes({ TileCodec.encodeLossy(base: $0.baseAddress!, width: sw, height: sh, stride: sw * 4, outWidth: ow, outHeight: oh, quality: 40) }) {
                let now = Clock.nowNanos()
                sendTileMessage(.tiles(.init(header: header(layer: 0, nanos: now), refinement: false, tiles: [.init(rect: d.bounds, format: .lossy, data: data)])), captureNanos: now)
                sent += 1; bytes += data.count
            }
        }
        // Windows: only in the compositor model (the seam design's desktop placeholder shows them).
        if !compositor { if sent > 0 { log("placeholders: the desktop at once, \(bytes) bytes") }; return }
        for (id, l) in layers where !l.isDisplay && id != ControlMessage.WindowInfo.overlayID && !l.announced && !l.exposed && plannedFrames[id] != nil {
            guard s.byID[id] != nil else { continue }
            // The window's rect in the screenshot, and the covered parts transparent.
            let r = PixelRect(x: Int(Double(l.frame.x) * k), y: Int(Double(l.frame.y) * k), width: max(1, Int(Double(l.width) * k)), height: max(1, Int(Double(l.height) * k)))
            let shot = PixelRect(x: 0, y: 0, width: sw, height: sh)
            let vis = r.intersection(shot)
            guard !vis.isEmpty else { continue }
            var cut = [UInt8](repeating: 0, count: r.width * r.height * 4)
            for y in 0..<vis.height {
                let srcOff = ((vis.y + y) * sw + vis.x) * 4, dstOff = ((vis.y - r.y + y) * r.width + (vis.x - r.x)) * 4
                cut.replaceSubrange(dstOff..<dstOff + vis.width * 4, with: px[srcOff..<srcOff + vis.width * 4])
            }
            for f in fallbackCovers(of: id, frame: l.frame) {
                let fr = PixelRect(x: Int(Double(f.x) * k), y: Int(Double(f.y) * k), width: Int((Double(f.width) * k).rounded(.up)), height: Int((Double(f.height) * k).rounded(.up))).intersection(r)
                guard !fr.isEmpty else { continue }
                for y in 0..<fr.height { let o = ((fr.y - r.y + y) * r.width + (fr.x - r.x)) * 4; for i in o..<o + fr.width * 4 { cut[i] = 0 } }
            }
            // M-FIVE stage 1: the window's coherent still, cut from the stream-start screenshot (its own capture starts ~0.6 s
            // after the previous window's), sized to its share of the 0.5 s budget, staged behind the barrier. Its own capture
            // then goes straight to lossless (no second still: at most three changes).
            let rateBytes = Double(lastBudget.tileKbps * 1000 / 8)
            let budget = max(4_000, rateBytes * 0.5 * l.visibleFraction * Double(l.frame.area) / Double(max(1, display?.bounds.area ?? 1)))
            let scale = min(1.0, (budget / 0.1 / Double(r.width * r.height)).squareRoot())
            let ow = max(16, Int(Double(r.width) * scale)), oh = max(16, Int(Double(r.height) * scale))
            guard let data = cut.withUnsafeBytes({ TileCodec.encodeLossy(base: $0.baseAddress!, width: r.width, height: r.height, stride: r.width * 4, outWidth: ow, outHeight: oh, quality: 60) }) else { continue }
            // Paced: queued, and sent as the tile budget allows (refine), not as one blast.
            l.cutStill = true
            stage1Queue.append((id, data))
            sent += 1; bytes += data.count
            continue
        }
        if sent > 0 { log("placeholders and stage-1 cuts: the desktop and \(sent - 1) windows, \(bytes) bytes (cuts paced)"); sendStage1Queue(now: Clock.nowNanos()); checkStage1(now: Clock.nowNanos()); publishWindows(now: Clock.nowNanos(), full: false) }
    }

    /// Layers cut from the full display capture only until their own capture delivers (off: see reconcileLayers).
    private var pendingFallback = Set<UInt32>()
    static let pendingFallbackEnabled = false
    /// When the compositor model's layers were set up for this stream.
    private var compositorSinceNanos: UInt64 = 0
    /// A window has moved this session (a drag, Show Desktop): the desktop under windows may be seen.
    private var windowMovedThisSession = false
    /// Compositor model: the desktop under shown windows is refined (at underlay quality) only where it may be seen: on
    /// fast tiers, or once a window has moved this session. On Constrained/Extreme it was 950 KB nobody saw on a 650 kbps
    /// link (Japan bus); when a window does move away, the uncovered tiles are expedited (updateDisplayHidden).
    private var underlayWanted: Bool { windowMovedThisSession || (rc?.tier.rawValue ?? 0) < LinkTier.constrained.rawValue }
    private var fallbackCapture: ScreenCapturer?
    private var fallbackStarting = false
    private var fallbackPools: [UInt32: (pool: CVPixelBufferPool, w: Int, h: Int)] = [:]
    static let testFallbackApp = ProcessInfo.processInfo.environment["MIRAGE_TEST_FALLBACK"]
    private func useFallback(_ l: Layer, why: String) {
        guard compositor, !l.isDisplay, !fallbackLayers.contains(l.id) else { return }
        fallbackLayers.insert(l.id); l.forceFullDiff = true
        log("layer \(l.id): \(why); cut from the full display capture at its frame")
        ensureFallbackCapture()
    }
    private func ensureFallbackCapture() {
        guard compositor, fallbackCapture == nil, !fallbackStarting, let t = target, let req = request else { return }
        fallbackStarting = true
        let cap = ScreenCapturer(queue: queue)   // .display, nothing excluded: the screen as composited
        Task { [weak self] in
            do {
                _ = try await cap.start(req, target: t, excluding: []) { [weak self] pb, nanos, _ in self?.queue.async { self?.fallbackFrame(pb, nanos) } }
                self?.queue.async { self?.fallbackCapture = cap; self?.fallbackStarting = false; self?.log("fallback capture started (full display)") }
            } catch { self?.queue.async { self?.fallbackStarting = false; self?.log("fallback capture failed: \(error)") } }
        }
    }
    /// A frame from a layer's own capture: it no longer needs the full display capture.
    private func ownFrame(_ pb: CVPixelBuffer, _ nanos: UInt64, layer l: Layer) {
        guard l.capturer != nil else { return }
        l.awaitingOwnSince = 0
        // How far the window's snapshot was from its own first frame (the snapshot filter's correctness; M-FIVE).
        if let snap = l.snapshotFrame {
            l.snapshotFrame = nil
            log("layer \(l.id): snapshot vs own first frame: \(Self.meanDifference(snap, pb).map { String(format: "%.2f levels", $0) } ?? "sizes differ")\(Self.differenceCluster(snap, pb).map { "; " + $0 } ?? "")")
            // Test only (MIRAGE_TEST_SNAPSHOT_DUMP=dir): the bench window's snapshot and own first frame as PNGs, never another window's.
            if let dir = Self.snapshotDumpDir, windows?.current?.byID[l.id]?.title.contains("Mirage Test Bench") == true {
                for (name, f) in [("snapshot", snap), ("own", pb)] {
                    if let img = CGImage.fromBGRA(f), let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/bench-\(l.id)-\(name).png") as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
                }
            }
        }
        if pendingFallback.remove(l.id) != nil { l.forceFullDiff = true }
        captured(pb, nanos, dirtyRects: [], layerID: l.id)
    }
    static let snapshotDumpDir = ProcessInfo.processInfo.environment["MIRAGE_TEST_SNAPSHOT_DUMP"]
    /// Where two same-size frames differ: 32-px cells whose mean difference is over 8 levels, their count, bounding box
    /// (in the window's pixels) and the worst cell; a capture badge drawn into one of them shows as a small cluster.
    static func differenceCluster(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> String? {
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        guard w == CVPixelBufferGetWidth(b), h == CVPixelBufferGetHeight(b), w >= 32, h >= 32 else { return nil }
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddress(a), let pb = CVPixelBufferGetBaseAddress(b) else { return nil }
        let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
        var hot = 0, total = 0, box = PixelRect.zero, worst = 0.0, worstAt = (0, 0)
        for cy in stride(from: 0, to: h - 31, by: 32) { for cx in stride(from: 0, to: w - 31, by: 32) {
            var sum = 0
            for y in stride(from: cy, to: cy + 32, by: 2) {
                let ra = pa.advanced(by: y * sa).assumingMemoryBound(to: UInt8.self), rb = pb.advanced(by: y * sb).assumingMemoryBound(to: UInt8.self)
                for x in stride(from: cx * 4, to: (cx + 32) * 4, by: 8) { for c in 0..<4 { sum += abs(Int(ra[x + c]) - Int(rb[x + c])) } }
            }
            let m = Double(sum) / (16 * 16 * 4)
            total += 1
            if m > worst { worst = m; worstAt = (cx, cy) }
            if m > 8 { hot += 1; box = box.isEmpty ? PixelRect(x: cx, y: cy, width: 32, height: 32) : box.union(PixelRect(x: cx, y: cy, width: 32, height: 32)) }
        } }
        return String(format: "%d of %d cells over 8 levels", hot, total) + (hot > 0 ? " in \(box.x),\(box.y) \(box.width)x\(box.height)" : "") + String(format: ", worst %.1f at %d,%d (window %dx%d)", worst, worstAt.0, worstAt.1, w, h)
    }
    /// Mean absolute difference per channel (B, G, R, A) between two BGRA frames of the same size, sampled; nil otherwise.
    static func meanDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double? {
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        guard w == CVPixelBufferGetWidth(b), h == CVPixelBufferGetHeight(b) else { return nil }
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddress(a), let pb = CVPixelBufferGetBaseAddress(b) else { return nil }
        let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
        var sum = 0, n = 0
        for y in stride(from: 0, to: h, by: 3) {
            let ra = pa.advanced(by: y * sa).assumingMemoryBound(to: UInt8.self), rb = pb.advanced(by: y * sb).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w * 4, by: 12) { for c in 0..<4 { sum += abs(Int(ra[x + c]) - Int(rb[x + c])) }; n += 4 }
        }
        return n > 0 ? Double(sum) / Double(n) : nil
    }
    /// Frames of the windows in front of `id` that overlap it (its own child windows, and desktop-sized transparent windows
    /// such as the Dock's, excepted), in stream pixels.
    private func fallbackCovers(of id: UInt32, frame: PixelRect) -> [PixelRect] {
        guard let s = windows?.current, let i = s.windows.firstIndex(where: { $0.id == id }) else { return [] }
        let own = Set(s.children[id] ?? [])
        let displayArea = display?.bounds.area ?? Int.max
        return s.windows[..<i].filter { !own.contains($0.id) && $0.windowLevel >= 0 && $0.frame.area * 10 < displayArea * 9 && $0.frame.intersects(frame) }.map(\.frame)
    }
    private func fallbackFrame(_ pb: CVPixelBuffer, _ nanos: UInt64) {
        fallbackLayers = fallbackLayers.filter { layers[$0] != nil }
        pendingFallback = pendingFallback.filter { layers[$0] != nil }
        let live = fallbackLayers.union(pendingFallback).filter { plannedFrames[$0] != nil }
        if fallbackLayers.isEmpty, pendingFallback.isEmpty, let cap = fallbackCapture {
            fallbackCapture = nil; fallbackPools = [:]
            let log = self.log
            Task { await Self.bounded("fallback capture", log: log) { await cap.stop() } }
            log("fallback capture stopped (no layer needs it)")
            return
        }
        // While windows move (and 300 ms after), the list's frames lag the screen: a cut then took the window from where it
        // was a moment ago, other windows' and the desktop's pixels included (a shifted bench with a widget's ghost over it
        // after each Show Desktop return, mac-daddy). The layers keep their last picture until things settle.
        let now = Clock.nowNanos()
        if Clock.elapsed(since: lastWindowsMoveNanos, now: now) < 300_000_000 { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let src = frameView(pb)
        let screen = PixelRect(x: 0, y: 0, width: src.width, height: src.height)
        for id in live.sorted() {
            if let l = layers[id], Clock.elapsed(since: l.movedNanos, now: now) < 300_000_000 { continue }
            guard let l = layers[id] else { continue }
            let w = l.width, h = l.height
            if fallbackPools[id].map({ $0.w != w || $0.h != h }) ?? true {
                let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attrs as CFDictionary, &pool)
                guard let pool else { continue }
                fallbackPools[id] = (pool, w, h)
            }
            var out: CVPixelBuffer?
            guard let pool = fallbackPools[id]?.pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { continue }
            CVPixelBufferLockBaseAddress(out, [])
            let dst = CVPixelBufferGetBaseAddress(out)!, ds = CVPixelBufferGetBytesPerRow(out)
            memset(dst, 0, ds * h)   // transparent where the window is off the display
            let r = PixelRect(x: l.frame.x, y: l.frame.y, width: w, height: h).intersection(screen)
            if !r.isEmpty {
                for y in 0..<r.height {
                    memcpy(dst.advanced(by: (r.y - l.frame.y + y) * ds + (r.x - l.frame.x) * 4), src.base.advanced(by: (r.y + y) * src.stride + r.x * 4), r.width * 4)
                }
                // Where a window in front covers this one, the composited screen shows that window, not this one: those
                // pixels are left transparent. Kept, they were the front window's picture inside this layer, a ghost of
                // it once it moved away (a fallback-cut window's corner on the desktop during Show Desktop, mac-daddy).
                for f in fallbackCovers(of: id, frame: l.frame) {
                    let c = f.intersection(r)
                    guard !c.isEmpty else { continue }
                    for y in 0..<c.height { memset(dst.advanced(by: (c.y - l.frame.y + y) * ds + (c.x - l.frame.x) * 4), 0, c.width * 4) }
                }
            }
            CVPixelBufferUnlockBaseAddress(out, [])
            captured(out, nanos, dirtyRects: [], layerID: id)
        }
    }

    /// Host-side crop (DESIGN §3.0): a window layer's tiles wholly off the display are sent transparent once (one small solid
    /// message), so every viewer, builds without the display clip included, shows nothing outside the display there. They
    /// stay pending as direct changes; the uncover path resends them when they come back on screen. Tile-aligned: a tile
    /// straddling the edge keeps its pixels (the viewer's own clip covers that sliver).
    private func cropOffDisplay(_ l: Layer, onScreen: PixelRect, now: UInt64) {
        l.needsCrop = false
        // Only for viewers that do not clip to the display themselves (no tunables: builds before 0d0651f). Blanked tiles come
        // back only as fast as they are resent: on phrz's iPhone (which clips) Show Desktop left the returning Finder window
        // full of holes, the desktop showing through behind its icons, its chrome and sidebar partly missing.
        guard request?.tunablesVersion == nil, !l.isDisplay, !unifiedView, l.announced else { return }
        var off = Set<Int>()
        for i in 0..<l.tracker.tileCount where l.tracker.rect(of: i).intersection(onScreen).isEmpty { off.insert(i) }
        let newlyOff = off.subtracting(l.blankedOffDisplay).sorted()
        l.blankedOffDisplay = off
        guard !newlyOff.isEmpty else { return }
        let clear = l.tracker.mergedRects(newlyOff).map { TileMessage.Tile(rect: $0, format: .solid, data: Data([0, 0, 0, 0])) }
        sendTileMessage(.tiles(.init(header: header(layer: l.id, nanos: now), refinement: false, tiles: clear)), captureNanos: now)
        l.tracker.defer(newlyOff, now: now, delayNanos: 3_600_000_000_000, direct: true)
        if debugLayers { log("layer \(l.id): \(newlyOff.count) tiles off the display sent transparent") }
    }

    /// Layers in the order refinement serves them (DESIGN §3.3): the window under the pointer, the focused (frontmost normal-level) window, then
    /// the other visible windows by visible area, then the hidden ones, then the display (its visible part before
    /// its underlay: planBlocks).
    private func layersByPriority() -> [Layer] {
        guard let d = display else { return [] }
        if screenLocked { return [d] }
        let list = windows?.current?.windows ?? []
        var ordered: [Layer] = []
        // The window under the pointer first (what the person is looking at), then the focused one.
        if let p = injector?.locus, let w = windows?.appWindow(at: Int(p.x * Double(d.width)), Int(p.y * Double(d.height))),
           let l = layers[w.id], l.visibleFraction > 0.001 { ordered.append(l) }
        if let w = list.first(where: { $0.windowLevel == 0 && (layers[$0.id]?.visibleFraction ?? 0) > 0.001 }), let l = layers[w.id], !ordered.contains(where: { $0 === l }) { ordered.append(l) }
        let visible = list.compactMap { w in layers[w.id].map { (w, $0) } }.filter { _, l in l.visibleFraction > 0.001 && !ordered.contains { $0 === l } }
        ordered += visible.sorted { a, b in Double(a.0.frame.area) * a.1.visibleFraction > Double(b.0.frame.area) * b.1.visibleFraction }.map(\.1)
        for w in list { if let l = layers[w.id], !ordered.contains(where: { $0 === l }) { ordered.append(l) } }
        if compositor, let ov = layers[ControlMessage.WindowInfo.overlayID] { ordered.insert(ov, at: 0) }   // the menu bar, the Dock, menus first
        ordered.append(d)
        return ordered
    }

    // MARK: Capture pipeline

    private func frameView(_ pb: CVPixelBuffer) -> ShiftDetector.Frame {
        ShiftDetector.Frame(base: CVPixelBufferGetBaseAddress(pb)!, stride: CVPixelBufferGetBytesPerRow(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
    }

    /// Per-channel difference below which a tile counts as unchanged: whole-screen ±1–2 level flickers
    /// and anti-aliasing re-renders are invisible, but through an exact diff they would turn into a
    /// video frame plus a full lossless refinement pass (measured: ~400 KB per flicker).
    private static let diffTolerance: Int32 = 4

    private func tileChangedBox(_ a: ShiftDetector.Frame, _ b: ShiftDetector.Frame, _ r: PixelRect, alphaLayer: Bool = false) -> PixelRect? {
        TileDiff.changedBox(a, b, r, tolerance: Int32(Self.diffTolerance), alphaLayer: alphaLayer)
    }

    /// One captured frame of one layer (on `queue`). `dirtyRects` are SCK's (display layer) or empty
    /// (window layers: the whole frame is a candidate; the diff decides).
    private func captured(_ pb: CVPixelBuffer, _ nanos: UInt64, dirtyRects: [PixelRect], layerID: UInt32) {
        guard request != nil, output != nil, let windows, let layer = layers[layerID] else { return }
        captureSeq &+= 1
        let now = Clock.nowNanos()
        statCaptures += 1; effortCaptures += 1
        defer { let dt = Clock.elapsed(since: now, now: Clock.nowNanos()); statCaptureNanos += dt; effortCaptureNanos += dt }
        // Inputs injected less than ~40 ms before the capture are not in these pixels yet (window server + app render).
        lastInputSeq = injector?.inputSeq(before: nanos &- 40_000_000) ?? 0
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let new = frameView(pb)
        guard new.width == layer.width, new.height == layer.height else { return }   // a stale frame around a resize
        if !layer.isDisplay, layer.id != ControlMessage.WindowInfo.overlayID, new.width >= 8, new.height >= 8 {
            // Show Desktop: a pushed-aside window is captured blank; the layer keeps its last real picture (it slides with its
            // frame) and the frames after the return match it again.
            let pts = [(new.width / 2, new.height / 2), (new.width / 4, new.height / 2), (new.width * 3 / 4, new.height / 2), (new.width / 2, new.height / 4), (new.width / 2, new.height * 3 / 4)]
            let alphas = pts.map { new.base.advanced(by: $0.1 * new.stride + $0.0 * 4 + 3).assumingMemoryBound(to: UInt8.self).pointee }
            guard layer.blanking.keep(alphas: alphas) else {
                layer.blankDropped += 1
                if debugLayers, layer.blankDropped == 1 { log("layer \(layer.id): blank capture (Show Desktop); kept the last picture") }
                return
            }
            layer.blankDropped = 0
        }
        // Debug (layers debug on): the overlay's first tile column, mean alpha and colour, every 10 s; numbers only. On the
        // viewer that column showed opaque black over everything (mac-daddy, compositor); this tells host from viewer.
        if debugLayers, layer.id == ControlMessage.WindowInfo.overlayID, Clock.elapsed(since: lastEdgeLogNanos, now: now) > 10_000_000_000 {
            lastEdgeLogNanos = now
            var a = 0, rgb = 0, n = 0
            for y in Swift.stride(from: 128, to: min(new.height, 1600), by: 16) { for x in Swift.stride(from: 0, to: 64, by: 8) {
                let p = new.base.advanced(by: y * new.stride + x * 4).assumingMemoryBound(to: UInt8.self)
                a += Int(p[3]); rgb += Int(p[0]) + Int(p[1]) + Int(p[2]); n += 1 } }
            if n > 0 { log("overlay edge column: mean alpha \(a / n), mean rgb \(rgb / n / 3) over \(n) samples") }
        }
        var tracker = layer.tracker
        // Every tile is a candidate, the display's too: ScreenCaptureKit's dirty rects can leave out a change (the Dock's
        // tooltips on macOS 27 vanish without one, phrz's tile-aligned ghost labels: the vacated tiles were never diffed,
        // and the next capture already held the cleared desktop, so nothing ever found them). The tolerant diff below
        // starts with a row-wise memcmp, so unchanged tiles cost little; changes outside the reported rects are counted.
        let reported = layer.isDisplay ? Set(tracker.tiles(covering: dirtyRects)) : []
        var dirty = Array(0..<tracker.tileCount)
        layer.forceFullDiff = false
        let prev = layer.lastFrame
        var old: ShiftDetector.Frame? = nil
        if let prev { CVPixelBufferLockBaseAddress(prev, .readOnly); old = frameView(prev) }
        defer { if let prev { CVPixelBufferUnlockBaseAddress(prev, .readOnly) } }

        var tightBoxes: [Int: PixelRect] = [:]
        if let old {
            // CPU diff inside SCK's dirty rects (they over-report ~1.7x, experiments/probes) or over the whole
            // window (window streams report no useful dirty rects); the exact changed box inside a tile is
            // what a sparse lossless update needs.
            let before = dirty.count
            let wantBoxes = effort.tightBoxes
            let alphaLayer = !layer.isDisplay
            dirty.removeAll { i in
                if let box = tileChangedBox(old, new, tracker.rect(of: i), alphaLayer: alphaLayer) { if wantBoxes { tightBoxes[i] = box }; return false }
                return true
            }
            statDiffPruned += before - dirty.count
            if layer.isDisplay, !layer.forceFullDiff {
                let missed = dirty.filter { !reported.contains($0) }.count
                if missed > 0 { statDirtyMissed += missed }
            }
        } else {
            // First frame of the layer: the display goes through one keyframe then refines lossless; a
            // window layer is announced, gets one lossy still, then refines lossless.
            dirty = Array(0..<tracker.tileCount)
            if !layer.isDisplay {
                layer.announced = true
                log("layer \(layer.id): first frame \(layer.width)x\(layer.height) after \((Clock.elapsed(since: layer.createdNanos, now: now)) / 1_000_000) ms; announced")
                // A stage-1 cut already stands for it (announced with it; a second `.reset` would discard it if still staged).
                if !layer.cutStill { sendTileMessage(.reset(layer: layer.id, width: layer.width, height: layer.height), captureNanos: nanos) }
                tracker.markVideo(dirty, now: now)
                layer.fresh = layer.cutStill ? .blocks(remaining: []) : .still
                if layer.cutStill { layer.tracker = tracker; layer.fresh = .blocks(remaining: planBlocks(layer)) }
                layer.tracker = tracker
                layer.lastFrame = pb
                refine(now: now)
                return
            }
        }
        statDirtyTiles += dirty.count
        layer.frames += 1
        layer.account.dirtyTiles += dirty.count
        if dirty.isEmpty { layer.lastFrame = pb; layer.tracker = tracker; refine(now: now); return }
        // A window moving (or 300 ms after it moved) whose pixels changed widely: its translucent parts (Liquid Glass
        // toolbars and sidebars) show the blurred desktop behind it, which a move changes everywhere. Nothing goes now:
        // the tiles are held, the window settles, one lossy whole-layer level shows it (sendBackdropLevels), and lossless
        // refinement waits for idle. Lossless per move resent ~386 tiles, 374–487 KB per Finder drag at 800 kbps.
        if Self.backdropHold, !compositor, !layer.isDisplay, layer.movedNanos > 0, layer.backdropDirty || Clock.elapsed(since: layer.movedNanos, now: now) < Self.backdropSettleNanos,
           dirty.count >= max(12, (tracker.tileCount - layer.occludedTiles.count) / 20) {
            tracker.holdUntilIdle(dirty, now: now)
            layer.backdropDirty = true; layer.backdropHeldNanos = now
            statBackdropTiles += dirty.count
            layer.tracker = tracker; layer.lastFrame = pb
            refine(now: now)
            return
        }
        if debugLayers, dirty.count >= 4 { log("layer \(layer.id) capture \(captureSeq): \(dirty.count) dirty tiles, bb \(tracker.boundingRect(dirty))" + (dirty.count <= 8 ? " boxes " + dirty.map { "\(tightBoxes[$0].map { "\($0.x),\($0.y) \($0.width)x\($0.height)" } ?? "?")" }.joined(separator: " | ") : "")) }

        // Copy-rects: window drags (display layer, for windows it still carries) from the window list,
        // scrolls from line signatures.
        var explained = Set<Int>()
        // Destination tiles a copy-rect fills with pixels that do not match the host's: wrong on the viewer even where the host
        // saw no change (a static path bar inside the copied rect: phrz's doubled Finder path bar on mac-daddy). Direct changes.
        var wrongAfterCopy = Set<Int>()
        // Rows and columns a copy-rect left out (ShiftDetector.trimmed): a translucent toolbar over scrolling content changes
        // every frame; it goes once, 300 ms after it last changed, not at every capture (2 MB per scroll phase on c9f678d).
        var trimmedEdges = Set<Int>()
        // Everything a copy-rect touches: changed tiles there that it does not explain are the scroll's new content (the exposed
        // strip). They go with the copy-rect, whatever the rate limit or budget: held back, the next copy-rect copied the
        // not-yet-updated rows on and the viewer showed them smeared (one label row repeated 7 times in a Finder scroll).
        var copyRegion = Set<Int>()
        // Everything this capture's copy-rects leave wrong on the viewer (destinations that failed verification, copies of wrong
        // pixels): it goes with them, lossy, whatever the budget (waiting for budget showed gaps and repeated rows for up to 1 s).
        var copyWrong = Set<Int>()
        var copies: [(tiles: [Int], dx: Int, dy: Int)] = []
        let dirtyBeforeCopies = dirty.count
        var copyRectsThisCapture = 0
        if let old, prev != nil {
            if layer.isDisplay {
                let moved = pendingMoved; pendingMoved = []
                for d in moved where layers[d.id] == nil {
                    let dx0 = d.new.x - d.old.x, dy0 = d.new.y - d.old.y
                    guard abs(dx0) + abs(dy0) > 0, abs(dx0) < 600, abs(dy0) < 600 else { continue }
                    var r = detector.verify(old: old, new: new, rect: d.old, dx: dx0, dy: dy0)
                    if r == nil, let (rdx, rdy) = detector.refine(old: old, new: new, rect: d.old, dx: dx0, dy: dy0, radius: effort.shiftSearch.refineRadius), (rdx, rdy) != (dx0, dy0) {
                        r = detector.verify(old: old, new: new, rect: d.old, dx: rdx, dy: rdy)
                    }
                    guard let r0 = r, let r = ShiftDetector.trimmed(r0) else { continue }
                    trimmedEdges.formUnion(Set(tracker.tiles(covering: [r0.rect.offset(r0.dx, r0.dy)])).subtracting(tracker.tiles(covering: [r.rect.offset(r.dx, r.dy)])))
                    copyRegion.formUnion(tracker.tiles(covering: [r.rect.union(r.rect.offset(r.dx, r.dy))]))
                    let dest = tracker.tiles(covering: [r.rect.offset(r.dx, r.dy)])
                    let mismatched = Set(tracker.tiles(covering: r.mismatchedTiles))
                    wrongAfterCopy.formUnion(mismatched)
                    explained.formUnion(dest.filter { !mismatched.contains($0) }); copies.append((dest.filter { !mismatched.contains($0) }, r.dx, r.dy))
                    sendTileMessage(.copyRect(.init(header: header(layer: 0, nanos: nanos), rect: r.rect, dx: r.dx, dy: r.dy)), captureNanos: nanos)
                    if debugLayers { log("layer 0 drag copy-rect for window \(d.id) \(r.rect) by (\(r.dx), \(r.dy)) (layers: \(layers.keys.sorted()))") }
                    statCopyRects += 1; copyRectsThisCapture += 1
                }
            }
            let unexplained = dirty.filter { !explained.contains($0) }
            scrollLock.lock(); let scroll = pendingScroll; scrollLock.unlock()
            // The wheel event belongs to this layer if it fell on its window (display layer: a window it carries).
            var scrollHere: PendingScroll? = nil
            if let s = scroll, now &- s.nanos < 500_000_000 {   // review L4: an old wheel event is not attributed to an unrelated capture
                let onLayer = layers[s.windowID] != nil ? s.windowID : 0
                if onLayer == layer.id { scrollHere = s; scrollLock.lock(); pendingScroll = nil; scrollLock.unlock() }
            }
            let bb = tracker.boundingRect(unexplained)
            if unexplained.count >= 12, bb.height >= 128 || bb.width >= 128 {
                var known: PixelRect? = nil
                var win: ControlMessage.WindowInfo? = nil
                if layer.isDisplay {
                    win = scrollHere.flatMap { s in windows.appWindow(at: s.x, s.y) } ?? windows.appWindow(at: bb.x + bb.width / 2, bb.y + bb.height / 2)
                    known = win.flatMap { windows.scrollRect(for: $0.id) }
                } else {
                    known = windows.scrollRect(for: layer.id).map { layer.local($0) }
                }
                var region = (known ?? (layer.isDisplay ? win?.frame : nil) ?? bb).intersection(bb)
                if region.width < 64 || region.height < 64 { region = bb }
                let diag = scrollHere != nil && scrollDiagBudget > 0
                if diag { shiftDiag = []; detector.debug = { [weak self] in self?.shiftDiag.append($0) } }
                let detected = region.height >= 96 || region.width >= 96 ? detector.detect(old: old, new: new, rect: region, hint: scrollHere.map { ($0.dxPx, $0.dyPx) }) : nil
                if diag {
                    detector.debug = nil; scrollDiagBudget -= 1
                    logScrollDiag(layer: layer, region: region, hint: scrollHere.map { ($0.dxPx, $0.dyPx) }, result: detected, old: old, new: new, unexplained: unexplained.count)
                }
                if let r0 = detected, let r = ShiftDetector.trimmed(r0) {
                    trimmedEdges.formUnion(Set(tracker.tiles(covering: [r0.rect.offset(r0.dx, r0.dy)])).subtracting(tracker.tiles(covering: [r.rect.offset(r.dx, r.dy)])))
                    copyRegion.formUnion(tracker.tiles(covering: [r.rect.union(r.rect.offset(r.dx, r.dy))]))
                    let dest = tracker.tiles(covering: [r.rect.offset(r.dx, r.dy)])
                    let mismatched = Set(tracker.tiles(covering: r.mismatchedTiles))
                    wrongAfterCopy.formUnion(mismatched)
                    explained.formUnion(dest.filter { !mismatched.contains($0) }); copies.append((dest.filter { !mismatched.contains($0) }, r.dx, r.dy))
                    sendTileMessage(.copyRect(.init(header: header(layer: layer.id, nanos: nanos), rect: r.rect, dx: r.dx, dy: r.dy)), captureNanos: nanos)
                    if debugLayers { log("layer \(layer.id) copy-rect \(r.rect) by (\(r.dx), \(r.dy)) confidence \(r.confidence)") }
                    // (No scroll rect is learned from copy-rects any more: one bad copy taught the whole window, and every later
                    // detection ran over the window body, sidebar included. The AX scroll area under the pointer, else the changed
                    // tiles' bounding box.)
                    statCopyRects += 1; copyRectsThisCapture += 1
                    // A window scrolling: its other changes are the translucent toolbar and bottom bar re-blurring the content that
                    // moves under them (mac-daddy diagnostics: every mismatch in the top and bottom rows, none inside; the rest of
                    // the bytes were those bars resent lossless at every capture). They go lossy with the strip too.
                    if !layer.isDisplay { copyRegion.formUnion(0..<tracker.tileCount) }
                } else if scrollHere != nil {
                    // A wheel scroll no copy-rect verified (byte-exact) for: its changes in the scroll region go lossy like an
                    // exposed strip, not lossless tile by tile.
                    copyRegion.formUnion(tracker.tiles(covering: [region]))
                }
            }
        }
        var edgesDeferred = 0
        if !trimmedEdges.isEmpty {
            let edges = trimmedEdges.subtracting(explained).intersection(dirty)
            edgesDeferred = edges.count
            // They go with the exposed strip (lossy, half size): deferred, a trimmed bottom row lagged behind a scroll and smeared.
            copyRegion.formUnion(edges)
        }
        if !explained.isEmpty {
            dirty.removeAll { explained.contains($0) }
            for c in copies { tracker.markCopied(c.tiles, dx: c.dx, dy: c.dy, now: now) }
            for c in copies { for i in c.tiles where tracker.isDirectPending(i) { copyWrong.insert(i) } }   // copied from pixels the viewer holds wrong
            // Copy-rect gate: a copy-rect explained at least half of this frame's change; for 300 ms nothing here is motion.
            if (explained.count + edgesDeferred) * 2 >= dirtyBeforeCopies { layer.copyGateNanos = now }   // deferred edges are handled too
        }
        // Occluded on the host (covered by a window in front, or off the display): tracked, not sent. They
        // become due when uncovered (reconcileLayers expedites them) and are then sent from the frame of that moment.
        if !layer.occludedTiles.isEmpty {
            let hidden = dirty.filter { layer.occludedTiles.contains($0) }
            if !hidden.isEmpty {
                dirty.removeAll { layer.occludedTiles.contains($0) }
                tracker.defer(hidden, now: now, delayNanos: 3_600_000_000_000, direct: false)   // uncovered later: a level, not a change
                statOccluded += hidden.count
            }
        }

        // A tight box is the change against the host's previous frame: it is enough only where the viewer holds that frame. A tile
        // still owing an update (held back by the rate limit, shown through video, a correction) goes whole, or what the
        // earlier change left stays wrong while the tile counts as sent (a vacated Dock tooltip "…aude" for ~12 s on mac-daddy).
        for i in Array(tightBoxes.keys) where !tracker.isCrisp(i) { tightBoxes[i] = nil }
        let inputQuiet = Clock.elapsed(since: injector?.lastInputNanos ?? 0, now: now) > 1_000_000_000
        var plan = tracker.classify(dirty: dirty, now: now, copyGate: Clock.elapsed(since: layer.copyGateNanos, now: now) < 300_000_000 && layer.copyGateNanos > 0, smallRegions: inputQuiet)
        var withCopy: [Int] = []
        if !copyRegion.isEmpty {
            // The scroll's new content: rate-limited ones (classify held them back) go now too.
            let held = dirty.filter { copyRegion.contains($0) && tracker.isDirectPending($0) && !layer.occludedTiles.contains($0) }
            if !held.isEmpty { tracker.sent(lossless: held, now: now); plan.lossless.append(contentsOf: held) }
            withCopy = plan.lossless.filter { copyRegion.contains($0) }
        }
        if !wrongAfterCopy.isEmpty {
            // Wrong pixels never wait for video, refinement or budget.
            let wrong = wrongAfterCopy.subtracting(layer.occludedTiles)
            copyWrong.formUnion(wrong)
            statCopyCorrections += wrong.count
        }
        if !copyWrong.isEmpty {
            // Out of video and the lossless plan: they go with the exposed strip below.
            let w = copyWrong.subtracting(layer.occludedTiles)
            plan.lossless.removeAll { w.contains($0) }
            let videoBefore = plan.video.count
            plan.video.removeAll { w.contains($0) }
            if plan.video.count != videoBefore { if plan.video.isEmpty { plan.videoRegion = .zero; plan.wholeFrame = false } else if !plan.wholeFrame { plan.videoRegion = tracker.boundingRect(plan.video) } }
            withCopy.append(contentsOf: w.filter { !withCopy.contains($0) })
        }
        // A small animation (under 2 % of the layer: a bouncing Dock icon, a spinner) is not worth video: lossy half-size tiles at
        // a capped rate (host tunables, default 3 fps q50, ~40 kbps for an icon), refined lossless once it stops (classify left
        // the tiles pending). As video, one Dock icon took ~230 kbps of an 800 kbps link on mac-daddy, and its frames were the
        // rate controller's only delay samples: they read a queue that was not there and held the target at 150 kbps.
        // The overlay never goes as video: HEVC has no alpha, and a keyframe over the overlay painted its transparent tiles
        // opaque black, a column of which stayed over the left edge of everything (mac-daddy, compositor: the host's
        // capture there was alpha 0 throughout). Its changes take the small-animation path (lossy WebP keeps alpha).
        let isOverlay = layer.id == ControlMessage.WindowInfo.overlayID
        if isOverlay { plan.wholeFrame = false }
        let smallVideo = !plan.video.isEmpty && (isOverlay || !plan.wholeFrame && !MotionGate.counts(videoTiles: plan.video.count, layerTiles: tracker.tileCount, screenTiles: display?.tracker.tileCount ?? 0))
        if smallVideo || !plan.flicker.isEmpty {
            let small = ((smallVideo ? plan.video : []) + plan.flicker).filter { !layer.occludedTiles.contains($0) }
            if smallVideo { plan.video = []; plan.videoRegion = .zero }
            let interval = UInt64(1e9 / hostTunables[.smallAnimationFps])
            if !small.isEmpty, Clock.elapsed(since: layer.smallAnimNanos, now: now) >= interval {
                layer.smallAnimNanos = now
                if layer.isDisplay { displaySent(small) }
                tileTokens -= Double(submitLossless(layer: layer, tiles: small, from: new, refinement: false, nanos: nanos, tracker: tracker, lossy: Float(hostTunables[.smallAnimationQuality])))
                statSmallAnimTiles += small.count
            }
        }
        // Motion bookkeeping for the refinement freeze: classified video, copy-rects, or the input stream.
        // Sustained motion freezes all refinement, so only motion that matters counts: copy-rects, or video over at least 2 %
        // of the layer. A bouncing Dock icon (192x192 px, 9 tiles) froze every layer's refinement for 2 min on mac-daddy.
        if copyRectsThisCapture > 0 || MotionGate.counts(videoTiles: plan.video.count, layerTiles: tracker.tileCount, screenTiles: display?.tracker.tileCount ?? 0) { lastMotionNanos = now }
        if let hint = injector?.motionHintNanos, hint > lastMotionNanos { lastMotionNanos = hint }
        let motion = motionSustained(now)
        if motion != wasMotion { wasMotion = motion; lastBudgetApply = 0; applyBudget(now: now) }
        if let fov = fovea(layer) {
            // Fovea: motion inside it is carried as native tiles while the tile budget holds; the base
            // layer (video) takes the rest. A fovea that moved refines its new ground first.
            if !plan.video.isEmpty, tileTokens > 0 {
                let inside = plan.video.filter { tracker.rect(of: $0).intersects(fov) }
                if !inside.isEmpty, inside.count <= 120 {
                    let set = Set(inside)
                    plan.video.removeAll { set.contains($0) }
                    plan.lossless.append(contentsOf: inside)
                    if plan.video.isEmpty { plan.videoRegion = .zero; plan.wholeFrame = false } else { plan.videoRegion = tracker.boundingRect(plan.video) }
                    statFoveaTiles += inside.count
                }
            }
            if layer.isDisplay, abs(fov.x - lastFovea.x) > fov.width / 4 || abs(fov.y - lastFovea.y) > fov.height / 4 {
                lastFovea = fov
                let n = tracker.expedite(in: fov, now: now)
                if n > 0 { log("fovea moved to \(fov): \(n) tiles refine first") }
            }
        }
        if let rc, !rc.policy.videoEnabled, !plan.video.isEmpty {
            // Extreme tier: no video; motion goes lossless at the tier's frame cap through the refinement queue.
            tracker.markVideo(plan.video, now: now)
            plan.video = []; plan.videoRegion = .zero; plan.wholeFrame = false
        }
        if !plan.video.isEmpty, !layer.isDisplay, layer.encoder == nil, !ensureEncoder(layer) {
            // No encoder to spare for this layer: its motion is refined lossless once it settles.
            tracker.markVideo(plan.video, now: now)
            plan.video = []; plan.videoRegion = .zero; plan.wholeFrame = false
        }
        refillTiles(now: now)
        if !withCopy.isEmpty {
            // The exposed strip and what the copy-rects left wrong: lossy now, on the stream right behind its copy-rect, refined
            // lossless once it settles.
            let w = Set(withCopy)
            plan.lossless.removeAll { w.contains($0) }
            if layer.isDisplay { displaySent(withCopy) }
            tileTokens -= Double(submitLossless(layer: layer, tiles: withCopy, from: new, refinement: false, nanos: nanos, tracker: tracker, lossy: 60))
            tracker.markVideo(withCopy, now: now)
            statStripLossy += withCopy.count
        }
        if !plan.lossless.isEmpty {
            // Priority 1: changed pixels near the input locus (pointer or caret) always go, now, on the
            // interactive stream, whatever the budget; they are small and they are what the person is
            // looking at. Priority 2: other changed pixels, budget permitting. Refinement yields to change that
            // uses the link (RefinementPacer), not to a caret blink, a menu-bar clock or a few animating windows.
            let (near, far) = splitByLocus(plan.lossless, layer: layer, tracker: tracker)
            if !near.isEmpty {
                if layer.isDisplay { displaySent(near) }
                let bytes = submitLossless(layer: layer, tiles: near, from: new, refinement: false, nanos: nanos, tracker: tracker, tight: tightBoxes)
                tileTokens -= Double(bytes)
                pacer.noteDirect(bytes: bytes, now: now)
                plan.lossless = far
            }
        }
        if !plan.lossless.isEmpty {
            if tileTokens > 0 {
                if layer.isDisplay { displaySent(plan.lossless) }
                let bytes = submitLossless(layer: layer, tiles: plan.lossless, from: new, refinement: false, nanos: nanos, tracker: tracker, tight: tightBoxes)
                tileTokens -= Double(bytes)
                pacer.noteDirect(bytes: bytes, now: now)
            } else if plan.lossless.count >= 12, rc?.policy.videoEnabled ?? true, !(layer.copyGateNanos > 0 && Clock.elapsed(since: layer.copyGateNanos, now: now) < 300_000_000),
                      layer.encoder != nil || ensureEncoder(layer) {
                // (Not while copy-rects carry this layer: video and copy-rects travel separately, and a frame overtaken by the
                // next copy-rect lands its pixels where the content has already moved. Those tiles wait as direct changes.)
                // The tile budget is spent and this is a lot of fresh content (a scroll's exposed strip at
                // native scale is megapixels per second): show it through video now, refine it later.
                plan.video.append(contentsOf: plan.lossless)
                plan.videoRegion = plan.videoRegion.union(tracker.boundingRect(plan.lossless))
                tracker.markVideo(plan.lossless, now: now)
                statTileSkipped += plan.lossless.count
            } else {
                tracker.defer(plan.lossless, now: now, direct: true); statTileSkipped += plan.lossless.count
            }
        }
        if !plan.video.isEmpty, let canvas = ensureCanvas(layer) {
            copyToCanvas(canvas, tiles: plan.video, from: new, tracker: tracker)
            layer.pendingVideoTiles.formUnion(plan.video)
            layer.pendingVideoRegion = layer.pendingVideoRegion.union(plan.videoRegion)
            layer.pendingWholeFrame = layer.pendingWholeFrame || plan.wholeFrame
            layer.videoActiveNanos = now
            // Only video that matters moves the budget to video (tiles 45 % of the target instead of 90 %): an animated Dock
            // icon held the tile budget at 360 of 800 kbps on mac-daddy, the full picture unfinished after 108 s. Small video
            // still gets the remainder (at least 100 kbps).
            if MotionGate.counts(videoTiles: plan.video.count, layerTiles: tracker.tileCount, screenTiles: display?.tracker.tileCount ?? 0) { videoActiveNanos = now }
        }
        layer.tracker = tracker
        layer.lastFrame = pb
        if layer.hasVideoPending { tryEncode(layer, now: now, latest: new) }
        refine(now: now)
    }

    /// Exclusion check (once a second): does the display stream show a window that should be excluded? For each
    /// shown layer, the 6 most textured 32×32 blocks of the layer's own capture are compared with the display
    /// capture at the same place (mean absolute difference per channel). Textured blocks only: a white window over
    /// a white window matches without proving anything. Logged when the display shows the window, and every 10 s.
    private var lastExclusionLogNanos: UInt64 = 0
    private func checkExclusion(now: UInt64) {
        guard let d = display, let dsrc = d.lastFrame else { return }
        CVPixelBufferLockBaseAddress(dsrc, .readOnly); defer { CVPixelBufferUnlockBaseAddress(dsrc, .readOnly) }
        let disp = frameView(dsrc)
        for l in layers.values where !l.isDisplay && l.exposed && !screenLocked {
            // Only once the display filter that excludes it is in force: before, the display stream shows it by design
            // (phrz's session: a false "SHOWS THIS WINDOW" 3 ms before the filter applied, and the window guarded for it).
            guard excludedFrom[l.id] != nil, Clock.elapsed(since: excludedAtNanos[l.id] ?? now, now: now) >= 1_000_000_000,
                  let src = l.lastFrame, l.width >= 96, l.height >= 96 else { continue }
            CVPixelBufferLockBaseAddress(src, .readOnly); defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            let w = frameView(src)
            func lum(_ f: ShiftDetector.Frame, _ x: Int, _ y: Int) -> Int { let p = f.base.advanced(by: y * f.stride + x * 4).assumingMemoryBound(to: UInt8.self); return Int(p[0]) + 2 * Int(p[1]) + Int(p[2]) }
            var candidates: [(x: Int, y: Int, v: Int)] = []
            for gy in 0..<5 { for gx in 0..<7 {
                let x = 16 + (w.width - 64) * gx / 6, y = 40 + (w.height - 80) * gy / 4
                var sum = 0, sq = 0, n = 0
                for yy in stride(from: y, to: y + 32, by: 4) { for xx in stride(from: x, to: x + 32, by: 4) { let v = lum(w, xx, yy); sum += v; sq += v * v; n += 1 } }
                candidates.append((x, y, sq / n - (sum / n) * (sum / n)))
            } }
            let textured = candidates.filter { $0.v > 200 }.sorted { $0.v > $1.v }.prefix(6)
            var mad = 0.0, blocks = 0
            for c in textured {
                let dx = l.frame.x + c.x, dy = l.frame.y + c.y
                guard dx >= 0, dy >= 0, dx + 32 <= disp.width, dy + 32 <= disp.height else { continue }
                var diff = 0, n = 0
                for yy in stride(from: 0, to: 32, by: 2) { for xx in stride(from: 0, to: 32, by: 2) {
                    let a = w.base.advanced(by: (c.y + yy) * w.stride + (c.x + xx) * 4).assumingMemoryBound(to: UInt8.self)
                    let b = disp.base.advanced(by: (dy + yy) * disp.stride + (dx + xx) * 4).assumingMemoryBound(to: UInt8.self)
                    diff += abs(Int(a[0]) - Int(b[0])) + abs(Int(a[1]) - Int(b[1])) + abs(Int(a[2]) - Int(b[2])); n += 3
                } }
                mad += Double(diff) / Double(n); blocks += 1
            }
            guard blocks >= 2 else { continue }
            mad /= Double(blocks)
            let shows = mad < 24   // measured: 12 when the stream shows the window (two resamplings of it), 44–90 when excluded
            if shows { statExclusionLag += 1; if exclusionFailing.insert(l.id).inserted { updateDisplayHidden(now: now) } }
            else if exclusionFailing.remove(l.id) != nil { updateDisplayHidden(now: now) }
            if shows || debugLayers || Clock.elapsed(since: lastExclusionLogNanos, now: now) > 10_000_000_000 {
                lastExclusionLogNanos = now
                log(String(format: "exclusion check: layer %u at %d,%d: display vs layer MAD %.1f over %d textured blocks → %@", l.id, l.frame.x, l.frame.y, mad, blocks,
                           shows ? "THE DISPLAY STREAM SHOWS THIS WINDOW (exclusion not in effect; DisplayGuard keeps it out of the desktop layer)" : "excluded"))
            }
        }
    }

    private func ensureCanvas(_ l: Layer) -> CVPixelBuffer? {
        if l.canvas == nil { l.canvas = try? Self.makeBuffer(width: l.width, height: l.height) }
        return l.canvas
    }

    /// A window layer's encoder, created on first motion; at most `maxLayerEncoders` live at once, the
    /// idle one longest unused making room. False if none can be had right now.
    private func ensureEncoder(_ l: Layer) -> Bool {
        if l.encoder != nil { return true }
        let live = layers.values.filter { $0.encoder != nil && !$0.isDisplay }
        if live.count >= maxLayerEncoders {
            let now = Clock.nowNanos()
            guard let victim = live.filter({ !$0.encoding && now - $0.videoActiveNanos > 2_000_000_000 }).min(by: { $0.videoActiveNanos < $1.videoActiveNanos }) else { return false }
            victim.encoder = nil; victim.scaled = nil; victim.transfer = nil; victim.canvas = nil
            victim.pendingVideoTiles = []; victim.pendingVideoRegion = .zero; victim.pendingWholeFrame = false
            log("layer \(victim.id): encoder released for layer \(l.id)")
        }
        do { try rebuildEncoder(l); l.wantKeyframe = true; return true } catch { log("layer \(l.id): encoder failed: \(error)"); return false }
    }

    /// Tiles within ~200 px (native) of the last input event, and the rest (TileScheduler, unit-tested).
    private func splitByLocus(_ tiles: [Int], layer: Layer, tracker: TileTracker) -> ([Int], [Int]) {
        let l = locus(in: layer)
        let o = TileScheduler.order(changed: tiles, refinement: [], locus: l, tracker: tracker)
        return (o.locus, o.changed)
    }
    /// The input locus in a layer's coordinates (nil when unknown).
    private func locus(in layer: Layer) -> (x: Int, y: Int)? {
        guard let d = display, let l = injector?.locus else { return nil }
        let p = layer.local(x: Int(l.x * Double(d.width)), y: Int(l.y * Double(d.height)))
        return (p.0, p.1)
    }
    /// Sustained motion (classified video, copy-rects, or a drag/scroll/press on the input stream) in
    /// the last 300 ms: refinement sends nothing and its queue is frozen; video has the whole target.
    private var lastMotionNanos: UInt64 = 0
    private func motionSustained(_ now: UInt64) -> Bool { now &- lastMotionNanos < 300_000_000 }
    private var wasMotion = false
    private var videoActiveNanos: UInt64 = 0
    private var secInteractiveBytes = 0
    private var interactiveKbpsEWMA = 0.0

    // Foveated two-layer mode (DESIGN §3.3): on Constrained/Extreme tiers a window of about a third
    // of the screen around the input locus gets native lossless tiles and copy-rects at top priority
    // and refines first; the base layer is the ladder's low rung. Inert on Local/Normal.
    private var foveaActive: Bool { (rc?.tier.rawValue ?? 0) >= LinkTier.constrained.rawValue }
    private var lastFovea: PixelRect = .zero
    private func fovea(_ layer: Layer) -> PixelRect? {
        guard foveaActive, let d = display else { return nil }
        let l = injector?.locus ?? (0.5, 0.5)
        let w = Int(Double(d.width) * 0.577), h = Int(Double(d.height) * 0.577)   // a third of the area
        let x = min(max(0, Int(l.x * Double(d.width)) - w / 2), d.width - w)
        let y = min(max(0, Int(l.y * Double(d.height)) - h / 2), d.height - h)
        let f = PixelRect(x: x, y: y, width: w, height: h)
        return layer.isDisplay ? f : layer.local(f)
    }
    private func locusTile(_ layer: Layer) -> (col: Int, row: Int)? {
        guard foveaActive, let l = locus(in: layer) else { return nil }
        let t = layer.tracker
        return (min(t.cols - 1, max(0, l.x / TileTracker.tile)), min(t.rows - 1, max(0, l.y / TileTracker.tile)))
    }

    // MARK: Stage 1, coherent stills presented together (DESIGN M-FIVE)

    /// From a fresh picture's start until every visible layer's still has gone (or 0.7 s), stills are staged and held; then
    /// one commit per layer presents them all in the same frame on the viewer (a whole-layer crossfade each), instead of
    /// windows popping in one by one as their captures start.
    private var stage1Active = false
    /// Stage-1 cuts waiting for the tile budget (layer, lossy still), sent in order by `sendStage1Queue`.
    private var stage1Queue: [(id: UInt32, data: Data)] = []
    private func sendStage1Queue(now: UInt64) {
        refillTiles(now: now)
        while let next = stage1Queue.first, tileTokens > 0 || freshTokens > 0 {
            stage1Queue.removeFirst()
            guard let l = layers[next.id], !l.stillSent || l.cutStill else { continue }
            sendTileMessage(.reset(layer: next.id, width: l.width, height: l.height), captureNanos: now)
            sendTileMessage(.tiles(.init(header: header(layer: next.id, nanos: now), refinement: false, staged: true, tiles: [.init(rect: l.bounds, format: .lossy, data: next.data)])), captureNanos: now)
            if tileTokens > 0 { tileTokens -= Double(next.data.count) } else { freshTokens -= Double(next.data.count); tileTokens -= Double(next.data.count) }
            l.stillSent = true
            if stage1Active { stage1Staged.insert(next.id) } else { sendTileMessage(.commit(layer: next.id), captureNanos: now); l.exposed = true }
        }
    }
    private var stage1Staged = Set<UInt32>()
    private var stage1Deadline: UInt64 = 0
    private func checkStage1(now: UInt64) {
        guard stage1Active else { return }
        let waiting = layers.values.filter { l in
            !l.stillSent && (l.isDisplay || (plannedFrames[l.id] != nil && l.visibleFraction > 0.002)) && l.id != ControlMessage.WindowInfo.overlayID
        }
        guard waiting.isEmpty || now >= stage1Deadline else { return }
        stage1Active = false
        for id in stage1Staged.sorted() {
            sendTileMessage(.commit(layer: id), captureNanos: now)
            layers[id]?.exposed = true
        }
        log("stage 1: \(stage1Staged.count) stills presented together\(waiting.isEmpty ? "" : " (\(waiting.count) layers not ready by 0.7 s: they follow on their own)")")
        stage1Staged = []
        publishWindows(now: now, full: false)
    }

    // MARK: Connect probe (DESIGN M-FIVE)

    /// A packet train at stream start: 40 pings padded to 1.2 KB, back to back. The viewer stamps each with its clock and
    /// returns the header; the spread of the stamps gives the link's rate before anything else is sized.
    private var trainSent = Set<UInt64>()
    private var trainReceived: [UInt64] = []
    private var trainStartNanos: UInt64 = 0
    static let trainCount = 40, trainSize = 1200
    private func sendProbeTrain() {
        guard let out = output else { return }
        trainSent = []; trainReceived = []; trainStartNanos = Clock.nowNanos()
        for _ in 0..<Self.trainCount {
            probeSeq += 1
            let d = DatagramPing.encode(seq: probeSeq, size: Self.trainSize)
            if let s = DatagramPing.decode(d)?.sentNanos { trainSent.insert(s) }
            out.sendDatagram(d)
        }
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finishTrain() }
    }
    private func trainEcho(receivedNanos: UInt64) {
        trainReceived.append(receivedNanos)
        if trainReceived.count >= Self.trainCount { finishTrain() }
    }
    private func finishTrain() {
        guard !trainSent.isEmpty else { return }
        let r = trainReceived.sorted()
        trainSent = []
        guard let kbps = RateController.trainRate(r, packetBytes: Self.trainSize + 40) else {
            log("connect probe: \(r.count) of \(Self.trainCount) echoes; no burst to read"); return
        }
        // A cross-check that can only raise the start (careful resume and the doubling startup lead), and by at most 4 x the
        // start rate: receive-side batching can still flatter a burst.
        rc?.seedFromProbe(kbps: min(kbps, 4 * Int(hostTunables[.startKbps])))
        log("connect probe: \(r.count) of \(Self.trainCount) echoes: \(kbps) kbps from the densest burst; target \(rc?.targetKbps ?? 0) kbps")
        applyBudget(now: Clock.nowNanos())
    }
    /// Per pairing and viewer network (the request's fingerprint), the last session's delivery estimate in kbit/s, if from
    /// the last 24 h (the host's store, delivery.json).
    struct PriorDelivery: Codable { var kbps: Int; var at: Date }
    static func priorDelivery(for peer: String?, network: String?) -> Int? {
        guard let peer, let network, let url = (try? Store())?.url("delivery.json"), let d = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: PriorDelivery].self, from: d), let e = m[peer + "|" + network],
              Date().timeIntervalSince(e.at) < 24 * 3600, e.kbps > 0 else { return nil }
        return e.kbps
    }
    static func savePriorDelivery(_ kbps: Int, for peer: String?, network: String?) {
        guard let peer, let network, kbps > 0, let url = (try? Store())?.url("delivery.json") else { return }
        var m = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: PriorDelivery].self, from: $0) } ?? [:]
        m[peer + "|" + network] = PriorDelivery(kbps: kbps, at: Date())
        m = m.filter { Date().timeIntervalSince($0.value.at) < 7 * 24 * 3600 }
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Fresh pictures (DESIGN §3.3 "lossy first")

    /// Starts the display layer's fresh-picture sequence; the next keyframe is its base.
    private func beginFreshPicture(_ trigger: FreshPictureTrigger, detail: String = "") {
        guard trigger.restartsWholePicture else { return }
        if trigger == .streamStart || trigger == .viewerEmpty {
            if hostTunables[.connectProbe] >= 1 { sendProbeTrain() }   // kill switch: tunables.json {"connectProbe": 0}
            if hostTunables[.placeholders] >= 1 { sendPlaceholders() }   // M-FIVE stage 0, both models
        }
        if compositor {
            // M-FIVE: the desktop's first picture is a still like every window's (no tiny keyframe and ladder climb: the
            // "very noisy start"), presented with the others behind the stage-1 barrier.
            display?.fresh = .still
            for l in layers.values { l.stillSent = false; l.cutStill = false }
            stage1Active = true; stage1Staged = []; stage1Deadline = Clock.nowNanos() + 700_000_000
            log("fresh picture (\(trigger.rawValue)\(detail)): stage 1, one coherent still per visible layer, presented together")
            return
        }
        display?.fresh = .base(seq: 0)
        log("fresh picture (\(trigger.rawValue)\(detail)): tiny keyframe first, then ladder climb, then large lossless blocks")
    }

    /// Called when a video frame is acked as decoded.
    private func freshAcked(_ l: Layer, seq: UInt32, now: UInt64) {
        guard let rc else { return }
        switch l.fresh {
        case .base(let s) where seq >= s && s != 0, .climb(let s) where seq >= s && s != 0:
            // Climb to the highest rung the target affords in one step: one whole-frame keyframe, the layer's middle level
            // (DESIGN §3.3: at most three presentation steps; a rung-by-rung climb was one crossfade per rung).
            let kpix = Double(l.width * l.height) / 1000
            // Review H4: the same test tryEncode applies (the keyframe at the next rung fits one second of the
            // video budget), plus the P-frame density rule and no standing queue.
            func affords(_ next: Int) -> Bool {
                let nextW = max(64, Int(Double(l.width) * RateController.scales[max(0, next)])) & ~1, nextH = max(64, Int(Double(l.height) * RateController.scales[max(0, next)])) & ~1
                return next >= rc.policy.minRung && FrameAssembler.keyframeFits(encodedWidth: nextW, encodedHeight: nextH, videoKbps: lastBudget.videoKbps)
                    && Double(rc.targetKbps) >= kpix * RateController.scales[next] * RateController.scales[next] * rc.tuning.kbpsPerKpixelDown && rc.queueMs < 90
            }
            var steps = 0
            if case .base = l.fresh { while affords(rc.rung - 1 - steps) { steps += 1 } }
            if steps > 0 {
                for _ in 0..<steps { self.rc!.climbOneRung(now: now) }
                lastRebuildNanos = now
                rebuildAllEncoders(keyframes: false)
                if (try? rebuildEncoder(l)) != nil { l.wantKeyframe = true; l.progressiveKeyframe = true; l.fresh = .climb(seq: 0); log("fresh picture: one step up \(steps) rungs to rung \(self.rc!.rung) (scale \(self.rc!.scale))") }
                else { l.fresh = .done }
            } else {
                // Lossless in large blocks sized to ~1 s of the refinement budget, centre-first.
                let blocks = planBlocks(l)
                l.fresh = .blocks(remaining: blocks)
                log("fresh picture: rung \(rc.rung) is the top the target affords; \(blocks.count) lossless blocks, first: \(blocks.prefix(3).map { "\($0.x),\($0.y)" }.joined(separator: " "))")
            }
        default: break
        }
    }

    /// Large lossless blocks (~1 s of the refinement budget each, 64-px aligned so no tile straddles two
    /// blocks, review M3) over everything the viewer does not hold crisp, ordered by distance to the input
    /// locus (or the centre).
    private func planBlocks(_ l: Layer) -> [PixelRect] {
        let tracker = l.tracker
        let blockArea = RefinementPacer.blockArea(tileBytesPerSecond: blockRate, layerArea: tracker.width * tracker.height)
        let side = max(64, (Int(blockArea.squareRoot()) + 63) / 64 * 64)
        let cols = max(1, (tracker.width + side - 1) / side), rows = max(1, (tracker.height + side - 1) / side)
        var blocks: [PixelRect] = []
        for r in 0..<rows { for c in 0..<cols {
            let rect = PixelRect(x: c * side, y: r * side, width: min(side, tracker.width - c * side), height: min(side, tracker.height - r * side))
            guard !rect.isEmpty else { continue }
            let tiles = tracker.tiles(covering: [rect])
            // Compositor model: desktop under a shown window is per-tile refinement's, after everything visible.
            let underOK = compositor && l.isDisplay
            if !tiles.allSatisfy({ tracker.isCrisp($0) || tracker.isHeld($0) || l.occludedTiles.contains($0) || underOK && l.underLayer.contains($0) }) { blocks.append(rect) }
        } }
        var cx = tracker.width / 2, cy = tracker.height / 2
        if let p = locus(in: l) { cx = p.x; cy = p.y }
        // Visible blocks first (locus first among them), then the underlay (the desktop under shown windows).
        func hiddenUnder(_ b: PixelRect) -> Bool { l.isDisplay && tracker.tiles(covering: [b]).allSatisfy { l.underLayer.contains($0) } }
        // Underlay edge-first: a move uncovers the desktop along a window's edges first; inner areas last.
        func edgeDistance(_ b: PixelRect) -> Int {
            let px = b.x + b.width / 2, py = b.y + b.height / 2
            return l.underlayEdge.filter { $0.contains(px, py) }.map { min(px - $0.x, $0.maxX - px, py - $0.y, $0.maxY - py) }.min() ?? 0
        }
        // Compositor model: the desktop's fresh picture is what can be seen; the desktop under windows (clean, but hidden)
        // follows at underlay quality through per-tile refinement, after every window (it made the full picture 6 s later).
        if compositor && l.isDisplay { blocks.removeAll(where: hiddenUnder) }
        blocks.sort { a, b in
            let ha = hiddenUnder(a), hb = hiddenUnder(b)
            if ha != hb { return !ha }
            if ha { return edgeDistance(a) < edgeDistance(b) }
            return abs(a.x + a.width / 2 - cx) + abs(a.y + a.height / 2 - cy) < abs(b.x + b.width / 2 - cx) + abs(b.y + b.height / 2 - cy)
        }
        return blocks
    }

    // MARK: Presentation levels (DESIGN §3.3)

    /// Whether a window layer gets a middle level between its still and its lossless level: only when the lossless
    /// level of its visible part takes more than about a second at the current tile rate (on a fast link the
    /// lossless level follows the still directly: two steps).
    private func intermediateWorthwhile(_ l: Layer) -> Bool {
        // The middle level is the whole layer: for a window mostly covered it is mostly bytes nobody sees (Japan bus on
        // mac-daddy: 240 KB of middle levels for windows 6–25 % visible, ~3 s of a 650 kbps link in the fresh picture). Its
        // visible tiles go as blocks instead.
        guard l.visibleFraction >= 0.5 else { return false }
        let visible = l.tracker.tileCount - l.occludedTiles.count
        let losslessBytes = Double(visible * 64 * 64) * 0.5        // UI at 2x: ~0.5 B/px lossless
        let rate = Double(max(100, lastBudget.tileKbps) * 1000 / 8)
        return losslessBytes / rate > 1.0
    }

    /// A window layer's middle level: the whole layer as one lossy WebP at full size (q90 class), sized to ~0.6 s of
    /// the tile rate, crossfaded in over the whole layer in one step on the viewer.
    /// `backdrop`: a moved window's backdrop level (sendBackdropLevels): not a block (nothing waits for its ack), at most
    /// ~50 KB, and retried if it went stale before it left.
    private func submitIntermediate(_ layer: Layer, from f: ShiftDetector.Frame, nanos: UInt64, backdrop: Bool = false) -> Int {
        let rect = layer.bounds
        let rate = Double(lastBudget.tileKbps * 1000 / 8) * 0.6
        let targetBytes = backdrop ? min(50_000, max(20_000, rate)) : max(20_000.0, rate)
        var d = Data(count: rect.width * rect.height * 4)
        d.withUnsafeMutableBytes { dst in for y in 0..<rect.height { memcpy(dst.baseAddress!.advanced(by: y * rect.width * 4), f.base.advanced(by: y * f.stride), rect.width * 4) } }
        let hdr = header(layer: layer.id, nanos: nanos)
        let layerID = layer.id
        let block: Int? = backdrop ? nil : pacer.start(layer: layer.id, estimate: Int(targetBytes), now: nanos)
        tileQueue.async { [weak self] in
            guard let self else { return }
            let (data, q, ow, oh) = d.withUnsafeBytes { p -> (Data?, Float, Int, Int) in
                let base = p.baseAddress!
                var best: (Data?, Float, Int, Int) = (nil, 0, rect.width, rect.height)
                for q: Float in [90, 75] {
                    let data = TileCodec.encodeLossy(base: base, width: rect.width, height: rect.height, stride: rect.width * 4, outWidth: rect.width, outHeight: rect.height, quality: q)
                    best = (data, q, rect.width, rect.height)
                    if let data, Double(data.count) <= targetBytes * 1.6 { return best }
                }
                // Still too large: a smaller picture at q80, upscaled on the viewer.
                guard let big = best.0 else { return best }
                let scale = max(0.5, min(1, (targetBytes / Double(big.count)).squareRoot() * 1.3))
                let ow = max(32, Int(Double(rect.width) * scale)), oh = max(32, Int(Double(rect.height) * scale))
                return (TileCodec.encodeLossy(base: base, width: rect.width, height: rect.height, stride: rect.width * 4, outWidth: ow, outHeight: oh, quality: 80), 80, ow, oh)
            }
            guard let data else { self.queue.async { if backdrop { self.layers[layerID]?.backdropDirty = true } else if let block { self.pacer.dropped(id: block) } }; return }
            self.queue.async {
                // Stale before it left (the window changed meanwhile): not sent; the lossless level follows (a backdrop
                // level is tried again once the window is quiet).
                if let l = self.layers[layerID], l.tracker.changedSince(nanos: nanos, in: [rect]) {
                    if backdrop { l.backdropDirty = true; self.tileTokens += targetBytes } else if let block { self.pacer.dropped(id: block) }
                    return
                }
                self.tileQueue.async { self.send(tile: .tiles(.init(header: hdr, refinement: true, tiles: [.init(rect: rect, format: .lossy, data: data)])), captureNanos: nanos, fast: false, refinementBytes: data.count, block: block, layer: layerID) }
                // The level covers the whole layer, off-display part included: cropped again on the next tick (after it on the stream).
                if let l = self.layers[layerID] { l.blankedOffDisplay = []; l.needsCrop = true }
                self.tileTokens -= Double(data.count) - targetBytes
                self.statTileBytes += data.count; self.statTileRects += 1; self.secTileBytes += data.count
                if let l = self.layers[layerID] { if backdrop { l.account.backdrop += data.count } else { l.account.still += data.count } }
                if backdrop { self.statBackdropLevels += 1; self.statBackdropBytes += data.count }
                if !backdrop || self.debugLayers { self.log("layer \(layerID): \(backdrop ? "backdrop" : "middle") level \(ow)x\(oh) q\(Int(q)) \(data.count) bytes for a \(rect.width)x\(rect.height) window (target \(Int(targetBytes)))") }
            }
        }
        return Int(targetBytes)
    }

    /// Presents each layer's staged level once the visible part of the layer is complete: nothing visible still owes
    /// refinement, no planned block of the visible part is left, every staged message is on the tile stream. Pixels
    /// that just changed are waited for (their refinement joins this level: one step after a burst, not three); once
    /// the level has been open 2 s, a region still changing within the last second is dropped from it instead (it is
    /// a direct change, refined in a later level). A level open 20 s that nothing was added to for 3 s is presented
    /// anyway (a refinement the budget cannot finish must not hide forever).
    private func presentLevels(now: UInt64) {
        for l in layers.values {
            guard let since = l.stagedOpenSince, l.stagedEncoding == 0 else { continue }
            // The guard may have let go of desktop a window left since the last pass: count those tiles as visible now.
            if l.isDisplay { updateDisplayHidden(now: now) }
            var complete = true
            switch l.fresh {
            case .still, .intermediate: complete = false
            case .blocks(let remaining):
                let tracker = l.tracker
                if remaining.contains(where: { b in tracker.tiles(covering: [b]).contains { !l.occludedTiles.contains($0) && !l.underLayer.contains($0) && !tracker.isCrisp($0) } }) { complete = false }
            default: break
            }
            if complete {
                let excluded = l.isDisplay ? l.occludedTiles.union(l.underLayer) : l.occludedTiles
                let stableBefore = Clock.elapsed(since: since, now: now) < 2_000_000_000 ? now : now &- 1_000_000_000
                if l.tracker.refinementOutstanding(excluding: excluded, stableBefore: stableBefore) > 0 { complete = false }
                if l.isDisplay, !l.upgradePending.subtracting(l.underLayer).subtracting(l.occludedTiles).isEmpty { complete = false }
                // Desktop a window just left is released by the guard within a second: its refinement joins this level
                // (one step per uncovered region, not one now and one when the guard lets go).
                if l.isDisplay, displayGuard.releasing(now: now), Clock.elapsed(since: since, now: now) < 3_000_000_000 { complete = false }
            }
            // A level that cannot complete (something visible keeps owing refinement) is presented anyway: after 20 s during
            // the first picture, after 4 s in steady state, where activity anywhere on the desktop otherwise held a settled
            // region's refinement back for 20 s (phrz: desktop widgets never settling between their clear and colour states).
            let stuckAfter: UInt64 = l.fresh == .done ? 4_000_000_000 : 20_000_000_000
            let stuck = Clock.elapsed(since: since, now: now) > stuckAfter && Clock.elapsed(since: l.lastStagedNanos, now: now) > min(3_000_000_000, stuckAfter / 4)
            guard complete || stuck else { continue }
            l.stagedOpenSince = nil
            l.levelsCommitted += 1
            sendTileMessage(.commit(layer: l.id), captureNanos: now)
            if debugLayers || l.levelsCommitted <= 2 { log("layer \(l.id): level \(l.levelsCommitted) presented after \(Clock.elapsed(since: since, now: now) / 1_000_000) ms\(complete ? "" : " (incomplete: refinement stalled)")") }
        }
    }

    /// Large refinement items (blocks, window stills and middle levels) in flight across all layers, and when refinement
    /// yields to changed pixels (RefinementPacer).
    private var pacer = RefinementPacer()
    /// The host's own tunables (small-animation caps), from tunables.json in the store directory at each stream start.
    private var hostTunables = Tunables.defaults
    private var statSmallAnimTiles = 0

    /// Sends the next large lossless block of a layer (pipelined: RefinementPacer), within budget.
    private func freshStep(_ l: Layer, now: UInt64) {
        // A block whose ack never comes (a viewer that dropped the message, a stale ack) must not freeze the picture:
        // after ~3 RTT + 2 s it stops counting.
        if pacer.expire(now: now, srttNanos: srttNanos) > 0 { log("fresh picture: block ack timed out; continuing") }
        guard pacer.canStartBlock(tileBytesPerSecond: Double(lastBudget.tileKbps * 1000 / 8)) else { return }
        guard let src = l.lastFrame else { return }
        refillTiles(now: now)
        // One block in flight and budget-limited: it does not yield to motion (that would starve the
        // base picture whenever something animates), it takes the leftover tokens or its own reserve.
        let fromReserve = tileTokens <= 0
        guard !fromReserve || freshTokens > 0 else { return }
        let charged = tileTokens
        defer { if fromReserve { freshTokens -= charged - tileTokens } }
        switch l.fresh {
        case .still:
            CVPixelBufferLockBaseAddress(src, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            let est = submitStill(l, from: frameView(src), nanos: now)
            tileTokens -= Double(est)
            l.fresh = intermediateWorthwhile(l) ? .intermediate : .blocks(remaining: planBlocks(l))
            statStills += 1
        case .intermediate:
            CVPixelBufferLockBaseAddress(src, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            let f = frameView(src)
            guard f.width == l.width, f.height == l.height else { return }
            let est = submitIntermediate(l, from: f, nanos: now)
            tileTokens -= Double(est)
            l.fresh = .blocks(remaining: planBlocks(l))
        case .blocks(var remaining):
            guard !remaining.isEmpty else { l.fresh = .done; if l.isDisplay { log("fresh picture: complete") }; return }
            let rect = remaining.removeFirst()
            CVPixelBufferLockBaseAddress(src, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            let f = frameView(src)
            guard f.width == l.width else { return }
            // Tiles nobody can see (a window layer covers that part of the display, another window covers that part
            // of this one) are left out of the block; they are sent when uncovered.
            let all = l.tracker.tiles(covering: [rect])
            var visible = all.filter { !l.occludedTiles.contains($0) }
            // Compositor model: the desktop under a shown window is left for per-tile refinement after the fresh picture. The
            // plan is made before any window shows (nothing is under a window then), and those blocks went out inside the
            // fresh picture: 2.2 MB of hidden desktop on mac-daddy, the full picture at 56 s instead of 30.
            if compositor && l.isDisplay { visible.removeAll { l.underLayer.contains($0) } }
            l.fresh = .blocks(remaining: remaining)
            guard !visible.isEmpty else { return }
            let rects = visible.count == all.count ? [rect] : l.tracker.mergedRects(visible)
            if l.isDisplay { displaySent(visible) }
            let underlay = l.isDisplay && visible.allSatisfy { l.underLayer.contains($0) }
            // A block is part of the layer's lossless level, presented whole on its commit; the underlay (nobody sees
            // it until a window moves) lands at once, so a move uncovers it already there.
            let est = submitRects(l, rects, from: f, refinement: true, nanos: now, photoQuality: underlay ? 75 : 90, staged: !underlay)
            tileTokens -= Double(est)
            l.tracker.sent(lossless: visible, now: now)
            let hidden = all.filter { l.occludedTiles.contains($0) && !l.tracker.isCrisp($0) }
            if !hidden.isEmpty { l.tracker.defer(hidden, now: now, delayNanos: 3_600_000_000_000) }
        default: break
        }
    }
    /// Refinement bytes sent but not yet acked by the viewer (bounded so refinement cannot fill the link's queue).
    private var refinementInFlight = 0

    // Window list publication: the client holds the last full list; the host sends coalesced deltas
    // at most every 33 ms while something moves (100 ms otherwise) and a full list every 10 s (and on start). Review §2.2.
    private var publishedWindows: [ControlMessage.WindowInfo] = []
    private var lastWindowsSendNanos: UInt64 = 0
    private var lastFullWindowsNanos: UInt64 = 0
    private var statControlBytes = 0
    private var lastWindowsMoveNanos: UInt64 = 0

    /// The current window list as the client should see it: `layered` is true for windows whose layer
    /// the viewer holds (announced and with its still sent).
    private func currentList() -> [ControlMessage.WindowInfo] {
        guard let s = windows?.current else { return publishedWindows }
        let displayArea = display?.bounds.area ?? 1
        if compositor {
            // Every normal window is a layer once it has a picture; everything above the normal level is drawn by the
            // overlay layer (listed first, on top), so nothing is a cut-out of the desktop. Layers are published as verified
            // (the desktop under them is clean), so older viewers' guards let the desktop through.
            var out: [ControlMessage.WindowInfo] = []
            if !screenLocked, let ov = layers[ControlMessage.WindowInfo.overlayID], ov.exposed, let d = display {
                out.append(.init(id: ControlMessage.WindowInfo.overlayID, pid: 0, title: "", frame: d.bounds, z: -1, level: ControlMessage.WindowInfo.overlayLevel,
                                 layered: true, app: "Mirage overlay", excludedFrom: 1))
            }
            return out + s.windows.map { w in
                var w = w
                let exposed = !screenLocked && (w.windowLevel == 0 || Self.isFloatingAppWindow(w)) && (layers[w.id]?.exposed ?? false)
                w.layered = exposed
                if exposed, let l = layers[w.id], let r = w.scrollRect { w.scrollRect = l.local(r) }
                w.cutout = nil
                w.excludedFrom = exposed ? 1 : nil
                w.opaque = exposed && !(layers[w.id]?.opaque ?? true) ? false : nil
                return w
            }
        }
        return s.windows.map { w in
            var w = w
            // A window is a layer for the viewer only once the display stream excludes it: until then (and for good,
            // if ScreenCaptureKit cannot exclude it) the desktop picture carries it and the viewer draws it from there.
            let exposed = !screenLocked && (layers[w.id]?.exposed ?? false) && excludedFrom[w.id] != nil
            w.layered = exposed
            if exposed, let l = layers[w.id], let r = w.scrollRect { w.scrollRect = l.local(r) }
            w.cutout = exposed ? nil : (Self.cutoutSafe(w, displayArea: displayArea) ? true : nil)
            w.excludedFrom = exposed ? excludedFrom[w.id] : nil
            w.opaque = exposed && !(layers[w.id]?.opaque ?? true) ? false : nil
            return w
        }
    }
    /// Test only: MIRAGE_LAYER_APPS="App A,title part" layers only those apps' windows (or windows whose title contains an entry) (a loopback run then sees the
    /// rest of the person's screen as part of the display layer, like a bare desktop under the bench).
    static let layerApps: Set<String>? = ProcessInfo.processInfo.environment["MIRAGE_LAYER_APPS"].map { Set($0.split(separator: ",").map { String($0) }) }

    /// Whether a window the display layer carries may be drawn by the client as a cut-out over window layers:
    /// pop-up menus, popovers, tooltips, the dock and the menu bar (owned by apps or the system UI agents),
    /// and normal app windows; never Window Server's own windows and never something desktop-sized above
    /// the normal level (screen shields and transparent overlays, which would paint the display layer, minus
    /// the layered windows, over everything).
    static func cutoutSafe(_ w: ControlMessage.WindowInfo, displayArea: Int) -> Bool {
        if w.app == "Window Server" && w.windowLevel != 24 && w.windowLevel != 25 { return false }
        if w.windowLevel != 0 && w.frame.area * 10 >= displayArea * 6 { return false }
        if w.windowLevel == 0 { return w.app != "Dock" && w.frame.area * 10 < displayArea * 9 }
        return w.windowLevel > 0 && w.windowLevel < 1000
    }
    private func publishWindows(now: UInt64, full: Bool) {
        let list = currentList()
        let moving = list.contains { w in publishedWindows.first { $0.id == w.id }.map { $0.frame != w.frame } ?? false }
        if moving { lastWindowsMoveNanos = now }
        let interval: UInt64 = Clock.elapsed(since: lastWindowsMoveNanos, now: now) < 500_000_000 ? 33_000_000 : 100_000_000
        guard full || Clock.elapsed(since: lastWindowsSendNanos, now: now) >= interval else { return }
        lastWindowsSendNanos = now
        let inputSeq = injector?.inputSeq(before: now) ?? 0
        if full || Clock.elapsed(since: lastFullWindowsNanos, now: now) > 10_000_000_000 {
            publishedWindows = list; lastFullWindowsNanos = now
            sendControlCounted(.windowList(.init(captureSeq: captureSeq, windows: list, inputSeq: inputSeq)))
        } else if let d = ControlMessage.WindowList.delta(from: publishedWindows, to: list, captureSeq: captureSeq, inputSeq: inputSeq) {
            if debugLayers {
                let old = Dictionary(publishedWindows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
                let ch = list.filter { old[$0.id] != nil && old[$0.id] != $0.frame }.map { "\($0.id) \($0.frame.x),\($0.frame.y)" }
                if !ch.isEmpty { log("window list delta: " + ch.joined(separator: " | ")) }
            }
            publishedWindows = list
            sendControlCounted(.windowList(d))
        }
    }
    /// Control-stream sends with byte accounting (the stream is outside the datagram budget; measure it).
    private func sendControlCounted(_ m: ControlMessage) {
        if let d = try? Frame.encode(m) { statControlBytes += d.count }
        output?.sendControl(m)
    }

    private func header(layer: UInt32, nanos: UInt64) -> TileMessage.Header {
        .init(captureSeq: captureSeq, inputSeq: lastInputSeq, windowID: layer, captureNanos: nanos)
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

    /// Copies rects' pixels out of a frame for the tile queue.
    private func copyOut(_ rects: [PixelRect], from f: ShiftDetector.Frame) -> ([(PixelRect, Data)], Int) {
        var jobs: [(PixelRect, Data)] = []
        var estimate = 0
        for r in rects where !r.isEmpty {
            var d = Data(count: r.width * r.height * 4)
            d.withUnsafeMutableBytes { dst in
                for y in 0..<r.height { memcpy(dst.baseAddress!.advanced(by: y * r.width * 4), f.base.advanced(by: (r.y + y) * f.stride + r.x * 4), r.width * 4) }
            }
            jobs.append((r, d)); estimate += r.area / 5
        }
        return (jobs, estimate)
    }

    /// Encodes copied rects on the tile queue and sends them (review L13: one body for tiles and blocks).
    /// `lossy`: every rect as lossy WebP at that quality (a scroll's exposed strip: lossy first on the stream, in order with
    /// its copy-rect; refined lossless once it settles).
    private func encodeAndSend(_ jobs: [(PixelRect, Data)], estimate: Int, layer: Layer, refinement: Bool, block: Int?, nanos: UInt64, photoQuality: Float = 90, staged: Bool = false, lossy: Float? = nil, correction: Bool = false) {
        let hdr = header(layer: layer.id, nanos: nanos)
        if staged { layer.stagedEncoding += 1; layer.lastStagedNanos = nanos; if layer.stagedOpenSince == nil { layer.stagedOpenSince = nanos } }
        // On `queue`: this message is on the tile stream (or dropped), so a commit sent after it follows it.
        let settled: (Layer?) -> Void = { l in if staged, let l { l.stagedEncoding = max(0, l.stagedEncoding - 1) } }
        let webp = effort.webpEffort
        let alpha = !layer.isDisplay
        let layerID = layer.id
        let photoLossy = photographicFinalIsLossy
        tileQueue.async { [weak self] in
            guard let self else { return }
            var out: [TileMessage.Tile] = []
            for (r, d) in jobs {
                let encoded: (TileCodec.Format, Data)? = d.withUnsafeBytes { p -> (TileCodec.Format, Data)? in
                    let base = p.baseAddress!
                    if !alpha, let solid = TileCodec.solidColour(base: base, width: r.width, height: r.height, stride: r.width * 4) { return (.solid, solid) }
                    // At half size (the viewer draws a lossy rect scaled onto it): soft for a moment, refined lossless once it settles.
                    if let q = lossy, let data = TileCodec.encodeLossy(base: base, width: r.width, height: r.height, stride: r.width * 4, outWidth: max(16, r.width / 2), outHeight: max(16, r.height / 2), quality: q, alpha: alpha) { return (.lossy, data) }
                    let photographic = TileCodec.colourCount(base: base, width: r.width, height: r.height, stride: r.width * 4, limit: 4096) > 4096
                    // Review #22: on constrained links a photographic rect (a wallpaper, a photo) ends at visually
                    // lossless (lossy WebP q90 at full size, ~4x under near-lossless on a 2x desktop picture), not at
                    // bit-exact; text and UI (≤ 4096 colours) stay lossless everywhere.
                    if photographic, photoLossy || photoQuality < 90, let data = TileCodec.encodeLossy(base: base, width: r.width, height: r.height, stride: r.width * 4, outWidth: r.width, outHeight: r.height, quality: photoQuality, alpha: alpha) { return (.lossy, data) }
                    let fmt: TileCodec.Format = photographic ? .nearLossless : .lossless
                    return TileCodec.encode(base: base, width: r.width, height: r.height, stride: r.width * 4, format: fmt, effort: webp, alpha: alpha).map { (fmt, $0) }
                }
                if let (fmt, data) = encoded { out.append(.init(rect: r, format: fmt, data: data)) }
            }
            guard !out.isEmpty else { self.queue.async { if let block { self.pacer.dropped(id: block) }; settled(self.layers[layerID]) }; return }
            let bytes = out.reduce(0) { $0 + $1.data.count }
            // Changed pixels go on the stream from here, in order with copy-rects: the hop through `queue` let the next
            // capture's copy-rect overtake them, so the viewer shifted its pixels first and then dropped or misplaced these
            // tiles while the host counted them delivered (striped Finder icons through a scroll on mac-daddy, c9f678d).
            let early = !refinement
            if early { self.send(tile: .tiles(.init(header: hdr, refinement: false, staged: staged, tiles: out)), captureNanos: nanos, fast: true, refinementBytes: 0, block: block, layer: layerID) }
            self.queue.async {
                // Encoded while the region moved on (a drag, a scroll): stale, never sent (the viewer would
                // drop it too, but the bytes are better not spent).
                if refinement, let l = self.layers[layerID], l.tracker.changedSince(nanos: nanos, in: out.map(\.rect)) {
                    // Not sent: whatever the viewer held there stays, so the desktop tiles count as possibly holding a window.
                    if l.isDisplay { let ts = l.tracker.tiles(covering: out.map(\.rect)); l.taint.sent(ts, tracker: l.tracker, windowAreas: [l.bounds]); l.taintScheduled.subtract(ts) }
                    self.statStaleDropped += out.count; self.tileTokens += Double(estimate); if let block { self.pacer.dropped(id: block) }; settled(self.layers[layerID]); return
                }
                if !early { self.tileQueue.async { self.send(tile: .tiles(.init(header: hdr, refinement: refinement, staged: staged, tiles: out)), captureNanos: nanos, fast: !refinement, refinementBytes: refinement ? bytes : 0, block: block, layer: layerID) } }
                settled(self.layers[layerID])
                self.tileTokens -= Double(bytes - estimate)   // true up the estimate
                self.statTileBytes += bytes; self.statTileRects += out.count; self.secTileBytes += bytes
                if refinement { self.statRefineBytes += bytes }
                if let l = self.layers[layerID] {
                    l.sentBytes += bytes; if refinement { l.sentRefine += out.count } else { l.sentDirect += out.count }
                    if lossy != nil { l.account.strip += bytes } else if correction { l.account.correction += bytes }
                    else if photoQuality < 90 { l.account.underlay += bytes } else if !refinement { l.account.direct += bytes } else if block != nil { l.account.blocks += bytes } else { l.account.refine += bytes }
                }
                if photoQuality < 90, let l = self.layers[layerID] { for t in out where t.format == .lossy { l.underlayLossy.formUnion(l.tracker.tiles(covering: [t.rect])) } }
                if self.debugLayers { self.log("layer \(layerID): sent \(out.count) \(staged ? "staged " : "")\(refinement ? (block != nil ? "block" : "refinement") : "direct") rects \(bytes) B: \(out.prefix(3).map { "\($0.rect.x),\($0.rect.y) \($0.rect.width)x\($0.rect.height)" }.joined(separator: " "))") }
            }
        }
    }

    /// Photographic rects end visually lossless (q90) on a constrained link: the cap or the controller's target
    /// at or under 2 Mbps, or the Constrained/Extreme tier.
    private var photographicFinalIsLossy: Bool {
        guard let rc else { return false }
        return rc.maxKbps <= 2000 || rc.targetKbps <= 2000 || rc.tier.rawValue >= LinkTier.constrained.rawValue
    }

    /// Copies the tiles' pixels out and encodes them on the tile queue. Returns the byte estimate charged to the budget.
    @discardableResult
    private func submitLossless(layer: Layer, tiles: [Int], from f: ShiftDetector.Frame, refinement: Bool, nanos: UInt64, tracker: TileTracker, tight: [Int: PixelRect]? = nil, photoQuality: Float = 90, staged: Bool = false, lossy: Float? = nil, correction: Bool = false) -> Int {
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
        let (jobs, estimate) = copyOut(rects, from: f)
        encodeAndSend(jobs, estimate: lossy == nil ? estimate : estimate / 12, layer: layer, refinement: refinement, block: nil, nanos: nanos, photoQuality: photoQuality, staged: staged, lossy: lossy, correction: correction)
        return lossy == nil ? estimate : estimate / 12
    }

    /// Encodes arbitrary rects (large lossless blocks) on the tile queue, one block in flight. Returns the byte estimate charged.
    @discardableResult
    private func submitRects(_ layer: Layer, _ rects: [PixelRect], from f: ShiftDetector.Frame, refinement: Bool, nanos: UInt64, photoQuality: Float = 90, staged: Bool = false) -> Int {
        let (jobs, estimate) = copyOut(rects, from: f)
        let block = pacer.start(layer: layer.id, estimate: estimate, now: nanos)
        encodeAndSend(jobs, estimate: estimate, layer: layer, refinement: refinement, block: block, nanos: nanos, photoQuality: photoQuality, staged: staged)
        return estimate
    }

    /// A window layer's first picture: one lossy WebP still, scaled so it costs about a tenth of a second
    /// of the link, upscaled on the client; lossless blocks follow (DESIGN §3.3 "lossy first, always").
    private func submitStill(_ layer: Layer, from f: ShiftDetector.Frame, nanos: UInt64) -> Int {
        let rect = layer.bounds
        // M-FIVE stage 1 (compositor model): all the visible layers' stills together take ~0.5 s of the measured rate, each its
        // share of what can be seen; the seam design keeps its old size.
        let rateBytes = Double(lastBudget.tileKbps * 1000 / 8)
        let targetBytes: Double
        if compositor, let d = display {
            let visible = layer.isDisplay ? Double(d.tracker.tileCount - d.underLayer.count) / Double(max(1, d.tracker.tileCount)) * Double(d.bounds.area)
                                          : layer.visibleFraction * Double(rect.area)
            targetBytes = max(4_000, rateBytes * 0.5 * visible / Double(max(1, d.bounds.area)))
        } else {
            targetBytes = max(6_000.0, rateBytes * 0.15)
        }
        let staged = compositor
        layer.stillSent = true
        // ~0.1 B/px for UI at quality 60 after rescale.
        let area = Double(rect.area)
        let scale = min(1.0, (targetBytes / 0.1 / area).squareRoot())
        let ow = max(32, Int(Double(rect.width) * scale)), oh = max(32, Int(Double(rect.height) * scale))
        var d = Data(count: rect.width * rect.height * 4)
        d.withUnsafeMutableBytes { dst in for y in 0..<rect.height { memcpy(dst.baseAddress!.advanced(by: y * rect.width * 4), f.base.advanced(by: y * f.stride), rect.width * 4) } }
        let hdr = header(layer: layer.id, nanos: nanos)
        let estimate = Int(targetBytes)
        let layerID = layer.id
        let block = pacer.start(layer: layer.id, estimate: estimate, now: nanos)
        layer.blankedOffDisplay = []; layer.needsCrop = true   // the still covers the whole layer: cropped again next tick
        tileQueue.async { [weak self] in
            guard let self else { return }
            let data = d.withUnsafeBytes { TileCodec.encodeLossy(base: $0.baseAddress!, width: rect.width, height: rect.height, stride: rect.width * 4, outWidth: ow, outHeight: oh, quality: 60) }
            guard let data else { self.queue.async { self.pacer.dropped(id: block) }; return }
            // On the stream from here, in order with the layer's copy-rects (DESIGN §3.3 ordering invariant).
            self.send(tile: .tiles(.init(header: hdr, refinement: false, staged: staged, tiles: [.init(rect: rect, format: .lossy, data: data)])), captureNanos: nanos, fast: false, refinementBytes: data.count, block: block, layer: layerID)
            self.queue.async {
                self.tileTokens -= Double(data.count - estimate)
                self.statTileBytes += data.count; self.statTileRects += 1; self.secTileBytes += data.count
                if let l = self.layers[layerID] {
                    l.account.still += data.count
                    // Staged: presented by its commit, with the other stage-1 stills (the barrier) or at once after it.
                    if !staged { l.exposed = true }
                    else if self.stage1Active { self.stage1Staged.insert(layerID); self.checkStage1(now: Clock.nowNanos()) }
                    else { self.sendTileMessage(.commit(layer: layerID), captureNanos: nanos); l.exposed = true }
                }
                self.log("layer \(layerID): still \(ow)x\(oh) \(data.count) bytes for a \(rect.width)x\(rect.height) window")
                if let s = self.windows?.current { self.reconcileLayers(s, now: Clock.nowNanos()); self.publishWindows(now: Clock.nowNanos(), full: false) }
            }
        }
        return estimate
    }

    /// Sends a tile-stream message in order (all sends go through the tile queue). Copy-rects and resets are interactive.
    private func sendTileMessage(_ m: TileMessage, captureNanos: UInt64) {
        var layer: UInt32 = 0
        switch m { case .tiles(let t): layer = t.header.windowID; case .copyRect(let c): layer = c.header.windowID; case .reset(let l, _, _): layer = l; case .commit(let l): layer = l }
        tileQueue.async { [weak self] in self?.send(tile: m, captureNanos: captureNanos, fast: true, refinementBytes: 0, layer: layer) }
    }
    /// On tileQueue.
    private func send(tile m: TileMessage, captureNanos: UInt64, fast: Bool, refinementBytes: Int, block: Int? = nil, layer: UInt32) {
        guard let out = output else { return }
        tileMsgSeq &+= 1
        let seq = tileMsgSeq
        let d = m.encode(msgSeq: seq)
        out.sendTiles(d, fast: fast)
        let rects: [PixelRect]
        switch m {
        case .tiles(let t): rects = t.tiles.map(\.rect)
        case .copyRect(let c): rects = [c.rect, c.rect.offset(c.dx, c.dy)]
        case .reset, .commit: rects = []
        }
        queue.async {
            self.tileSent[seq] = (Clock.nowNanos(), d.count, refinementBytes, block, layer, rects); self.refinementInFlight += refinementBytes; self.tileInflightBytes += d.count
            if let block { self.pacer.sent(id: block, msgSeq: seq, bytes: d.count, now: Clock.nowNanos()) }
            if refinementBytes == 0 { self.secInteractiveBytes += d.count }
        }
    }

    private func refillTiles(now: UInt64) {
        let cap = Double(lastBudget.tileKbps * 1000 / 8)
        let dt = Double(now &- lastTileRefill) / 1e9
        lastTileRefill = now
        tileTokens = min(cap * 0.5, tileTokens + dt * cap)
        tileTokens = max(tileTokens, -cap)
        freshTokens = min(cap * 0.2, freshTokens + dt * cap * Self.freshShare)
    }
    private var lastTileRefill = Clock.nowNanos()
    /// First pictures (stills, middle levels, fresh blocks) have 40 % of the tile budget to themselves: live activity in one
    /// window (the Claude app on mac-daddy, ~240 kbps of changes) drove the shared tokens negative and held every other
    /// window's first picture back. What they take from this reserve is also charged to the shared tokens.
    static let freshShare = 0.4
    private var freshTokens = 0.0

    /// Refinement across layers: fresh pictures first (stills and blocks, one in flight), then settled
    /// video tiles and rate-limited sparse tiles, oldest first, locus first, within the tile budget.
    private func refine(now: UInt64) {
        guard display != nil else { return }
        if !stage1Queue.isEmpty { sendStage1Queue(now: now) }
        checkStage1(now: now)
        presentLevels(now: now)
        refillTiles(now: now)
        sendDueDirect(now: now)
        sendBackdropLevels(now: now)
        // (No gate on due direct tiles here: they borrow past the budget after 150 ms, and the debt holds refinement back by
        // itself. Blocking refinement while any were due starved it through a whole Dock hover: a scrolled Finder window's
        // stale bottom rows stayed ~10 s on mac-daddy.)
        // Priority 4: refinement runs on leftover budget only. It yields while changed pixels use the link (RefinementPacer),
        // keeps 30 % of the tile budget in reserve for them, and keeps ~0.3 s (tiles) or ~0.5 s (blocks) of the link in
        // flight at most (so it cannot build the queue the next keystroke would wait in).
        // Sustained motion: refinement sends nothing and its queue is frozen (the blocks too). Video has
        // the whole target meanwhile; refinement resumes 300 ms after the motion stops, locus first.
        guard !motionSustained(now) else {
            // Video under half its budget (a small moving region) is the picture's rate, not the link's.
            if let rc, rc.recentVideoKbps * 2 < lastBudget.videoKbps { self.rc?.noteIdle(now: now) }
            return
        }
        // In flight: at most twice the bandwidth-delay product the acks show (RateController). A still screen gives the
        // controller no video delay to back off on; refinement then queued megabytes in QUIC's buffers on phrz's 4G, acks
        // came seconds late, and parts of windows stayed lossy. Changed pixels above are not held by this.
        // Refinement may fill the cap (2 x the bandwidth-delay product) by itself; changed pixels count toward a total of twice
        // that but must not starve it (Show Desktop at 800 kbps after e9c56d4: a busy menu bar's small-animation tiles kept a
        // shared cap full, refinement waited two minutes, and tiles never sent showed black). Half the cap (one BDP), as
        // before, let refinement deliver no faster than it already measured: on Japan bus (420 ms) the link stayed 44 % used
        // and the connect took 58 s to crisp.
        if let rc {
            let cap = rc.inflightCapBytes
            let pendingEncode = pacer.blocks.reduce(0) { $1.msgSeq == nil ? $0 + $1.bytes : $0 }
            if refinementInFlight + pendingEncode >= cap || tileInflightForCap >= cap * 2 { self.rc?.noteCapped(now: now); return }
        }
        let ordered = layersByPriority()
        // Fresh pictures: the display's ladder gates everything until its base is acked; window stills
        // and lossless blocks go one at a time, locus layer first.
        // (Unified mode shows no desktop: its base may never go out, and must not hold the windows back.)
        if let d = display, !unifiedView { switch d.fresh { case .base, .climb: return; default: break } }
        // Every window's still before any window's lossless blocks: with many large windows (a real desktop)
        // one window's blocks would otherwise hold every other window's first picture back for tens of seconds.
        if let l = ordered.first(where: { if case .still = $0.fresh { return true }; return false }) { freshStep(l, now: now); return }
        // Then the desktop's menu bar and Dock: on screen whatever the windows do, they waited at the first picture's lowest
        // rung behind every window's levels and the desktop's centre-first blocks (~45 s after a connect on an iPhone).
        if let d = display, !unifiedView, chromeStep(d, now: now) { return }
        // The desktop a window just uncovered (or under windows, when idle) from the window-free underlay (own budget).
        if let d = display { underlayStep(d, now: now) }
        // The rest yields while changed pixels use most of the link (the menu bar and Dock above do not: a desktop with a few
        // animating apps kept them at the lowest rung for 20 s on mac-daddy).
        guard !pacer.yields(now: now, tileBytesPerSecond: Double(lastBudget.tileKbps * 1000 / 8)) else { return }
        // Then every window's middle level (where it gets one), in the same order.
        if let l = ordered.first(where: { if case .intermediate = $0.fresh { return true }; return false }) { freshStep(l, now: now); return }
        // Then what people can see before what they cannot: window layers (blocks, backlog, per-tile refinement,
        // locus window first) before the display layer, whose fresh picture includes the underlay under every
        // window (field run: a window's last uncovered column waited 14 s behind the desktop's blocks).
        // The upgrade of uncovered q75 underlay runs on its own 15 % budget alongside the rest (not only when all
        // else is idle: a desktop with an animating app would starve it).
        if let d = display { upgradeStep(d, now: now) }
        let windowLayers = ordered.filter { !$0.isDisplay }
        // The desktop and the windows take turns: windows always first starved the desktop whenever one window had live
        // activity (the Claude app on mac-daddy), and desktop revealed by a moved window stayed black for good.
        refineDesktopFirst.toggle()
        if refineDesktopFirst, let d = display, refineStep([d], now: now) { return }
        if refineStep(windowLayers, now: now) { return }
        if !refineDesktopFirst, let d = display, refineStep([d], now: now) { return }
        // Nothing to refine with budget and room in flight: the acks that follow say what we sent, not what the link carries.
        if tileTokens > 0 { rc?.noteIdle(now: now) }
    }

    /// One scroll capture's diagnostics: wheel delta, the detector's candidates (shift, verified fraction), and where and how the
    /// mismatched tiles differ (top/bottom row, right column, interior; share of differing pixels, mean/max difference, and the
    /// same share at the shift ±1 px).
    private func logScrollDiag(layer: Layer, region: PixelRect, hint: (Int, Int)?, result: ShiftDetector.Result?, old: ShiftDetector.Frame, new: ShiftDetector.Frame, unexplained: Int) {
        var line = "scroll diag layer \(layer.id) region \(region.x),\(region.y) \(region.width)x\(region.height) wheel \(hint.map { "\($0.0),\($0.1)" } ?? "-") px, \(unexplained) changed tiles; "
        line += shiftDiag.filter { $0.contains("verify") }.map { $0.replacingOccurrences(of: "shift ", with: "") }.joined(separator: "; ")
        if let r = result {
            let dst = r.rect.offset(r.dx, r.dy)
            var top = 0, bottom = 0, right = 0, inner = 0
            var fr: [Double] = [], means: [Double] = [], maxes: [Int] = [], better = 0
            for t in r.mismatchedTiles {
                if t.y <= dst.y + 1 { top += 1 } else if t.maxY >= dst.maxY - 1 { bottom += 1 } else if t.maxX >= dst.maxX - 1 { right += 1 } else { inner += 1 }
                if fr.count < 24 {
                    let st = ShiftDetector.diffStats(old: old, new: new, tile: t, dx: r.dx, dy: r.dy)
                    fr.append(st.fraction); means.append(st.mean); maxes.append(st.max)
                    if min(st.fractionMinus, st.fractionPlus) < st.fraction { better += 1 }
                }
            }
            func med(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
            line += String(format: " | chosen (%d,%d) conf %.2f, %d mismatched: top %d bottom %d right %d inner %d; differing px median %.0f%%, mean diff median %.0f, max diff max %d; ±1 px better for %d of %d",
                           r.dx, r.dy, r.confidence, r.mismatchedTiles.count, top, bottom, right, inner, med(fr) * 100, med(means), maxes.max() ?? 0, better, fr.count)
        } else { line += " | no copy-rect" }
        log(line)
    }

    /// The menu bar and Dock tiles the viewer does not hold crisp (visible, settled for 300 ms), sent lossless and shown on
    /// arrival (not staged: they replace the lowest-rung picture at once), one block's worth at a time. True while any are
    /// waiting (nothing behind them goes meanwhile).
    private func chromeStep(_ d: Layer, now: UInt64) -> Bool {
        guard let bands = windows?.chromeRects(width: d.width, height: d.height), !bands.isEmpty, let src = d.lastFrame else { return false }
        let t = d.tracker
        let soft = t.tiles(covering: bands).filter {
            !t.isCrisp($0) && !t.isDirectPending($0) && !t.isHeld($0) && !d.occludedTiles.contains($0) && !d.underLayer.contains($0)
                && Clock.elapsed(since: t.lastDirty($0), now: now) > 300_000_000
        }
        guard !soft.isEmpty else { return false }
        let perSecond = Double(lastBudget.tileKbps * 1000 / 8)
        if pacer.expire(now: now, srttNanos: srttNanos) > 0 { log("chrome: block ack timed out; continuing") }
        guard pacer.canStartBlock(tileBytesPerSecond: perSecond), tileTokens > 0 else { return true }
        let area = RefinementPacer.blockArea(tileBytesPerSecond: min(perSecond, blockRate), layerArea: d.width * d.height)
        var take: [Int] = [], sum = 0.0
        for i in soft { take.append(i); sum += Double(t.rect(of: i).area); if sum >= area { break } }
        CVPixelBufferLockBaseAddress(src, .readOnly); defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        let f = frameView(src)
        guard f.width == d.width, f.height == d.height else { return false }
        displaySent(take)
        tileTokens -= Double(submitRects(d, t.mergedRects(take), from: f, refinement: true, nanos: now, staged: false))
        d.tracker.sent(lossless: take, now: now)
        if debugLayers { log("chrome: \(take.count) tiles lossless, \(soft.count - take.count) left") }
        return true
    }

    /// The q75 underlay of areas a move uncovered, refined to the normal quality: after everything else, from its
    /// own budget (15 % of the tile budget), so it never competes with the interactive or refinement traffic.
    private var upgradeTokens = 0.0
    private var lastUpgradeRefill: UInt64 = 0
    private func upgradeStep(_ d: Layer, now: UInt64) {
        let rate = Double(lastBudget.tileKbps * 1000 / 8) * 0.15
        upgradeTokens = min(rate * 0.5, upgradeTokens + Double(now &- (lastUpgradeRefill == 0 ? now : lastUpgradeRefill)) / 1e9 * rate)
        lastUpgradeRefill = now
        d.upgradePending.subtract(d.underLayer)   // covered again: nothing to upgrade there now
        guard !d.upgradePending.isEmpty, upgradeTokens > 0, let src = d.lastFrame else { return }
        var take: [Int] = []
        var est = 0.0
        for i in d.upgradePending.sorted() where !d.occludedTiles.contains(i) {
            take.append(i); est += Double(d.tracker.rect(of: i).area) / 8
            if est >= upgradeTokens || take.count >= 24 { break }
        }
        guard !take.isEmpty else { return }
        CVPixelBufferLockBaseAddress(src, .readOnly); defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        let f = frameView(src)
        guard f.width == d.width, f.height == d.height else { return }
        displaySent(take)
        let bytes = submitLossless(layer: d, tiles: take, from: f, refinement: true, nanos: now, tracker: d.tracker, staged: true)
        upgradeTokens -= Double(bytes)
        d.tracker.sent(lossless: take, now: now)
        d.upgradePending.subtract(take)
        d.account.upgrade += bytes
    }

    /// The desktop under windows the viewer has never seen, sent ahead from the desktop-only capture (DesktopUnderlay): lossy,
    /// at half size, window-free (the viewer's guard lets it through), on its own 10 % of the tile budget and only when nothing
    /// moved for 2 s. Desktop tiles the host guards (a layered window is or just was there) and the viewer does not hold crisp
    /// are the candidates; a tile is sent again only when its picture in the underlay changed. The tiles stay pending, so the
    /// real desktop follows when a window uncovers them; until then Show Desktop reveals this instead of a flat fill.
    private var underlaySent: [Int: UInt64] = [:]
    private var underlayTokens = 0.0
    private var lastUnderlayRefill: UInt64 = 0
    private var statUnderlayTiles = 0, statUnderlayBytes = 0
    private func underlayStep(_ d: Layer, now: UInt64) {
        guard !compositor else { return }   // the display layer is the desktop itself
        // Guarded tiles no window covers any more (a window just left them: Show Desktop, a move) are what the viewer shows
        // right now: they take the underlay at once, on 40 % of the tile budget. Tiles under layers wait for 2 s without
        // motion, on 10 %. Nothing goes where any window in the current list is, a layer or a window the desktop picture
        // carries (UnderlayRule: 5440d44 filled a desktop-carried Finder window with wallpaper on phrz's iPhone).
        let list = currentList()
        let displayArea = d.width * d.height
        let layeredFrames = list.filter(\.isLayered).map(\.frame)
        let carried = list.filter { w in
            !w.isLayered && w.windowLevel >= 0 && w.app != "Dock" && w.frame.area * 10 < displayArea * 9 && (w.windowLevel == 0 || Self.cutoutSafe(w, displayArea: displayArea))
        }.map(\.frame)
        let (urgent, underLayers) = UnderlayRule.candidates(guarded: d.occludedTiles, tracker: d.tracker, layered: layeredFrames, carried: carried)
        // A window back over tiles that took the underlay: they owe that window's pixels again, as a direct change (sent as
        // soon as the guard lets them go).
        let recovered = underlaySent.keys.filter { i in let r = d.tracker.rect(of: i); return carried.contains { $0.intersects(r) } }
        if !recovered.isEmpty { for i in recovered { underlaySent[i] = nil }; d.tracker.markDirect(recovered, now: now) }
        let idle = Clock.elapsed(since: lastMotionNanos, now: now) > 2_000_000_000
        let rate = Double(lastBudget.tileKbps * 1000 / 8) * (urgent.isEmpty ? 0.10 : 0.40)
        underlayTokens = min(rate * 0.5, underlayTokens + Double(now &- (lastUnderlayRefill == 0 ? now : lastUnderlayRefill)) / 1e9 * rate)
        lastUnderlayRefill = now
        // Viewers of this build or later only (they announce tunables, and let window-free tiles past their guard).
        guard request?.tunablesVersion != nil, underlayTokens > 0, !unifiedView, idle || !urgent.isEmpty,
              !d.occludedTiles.isEmpty, let (pb, _) = underlay?.frame else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let u = frameView(pb)
        let sx = Double(u.width) / Double(d.width), sy = Double(u.height) / Double(d.height)
        guard sx > 0.2, sy > 0.2 else { return }
        func region(_ r: PixelRect) -> PixelRect {
            let x0 = Int(Double(r.x) * sx), y0 = Int(Double(r.y) * sy)
            let x1 = min(u.width, Int((Double(r.maxX) * sx).rounded(.up))), y1 = min(u.height, Int((Double(r.maxY) * sy).rounded(.up)))
            return PixelRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
        }
        func hash(_ r: PixelRect) -> UInt64 {
            var h: UInt64 = 1469598103934665603
            for y in Swift.stride(from: r.y, to: r.maxY, by: 2) {
                let row = u.base.advanced(by: y * u.stride).assumingMemoryBound(to: UInt32.self)
                for x in Swift.stride(from: r.x, to: r.maxX, by: 2) { h = (h ^ UInt64(row[x] & 0xF0F0F0)) &* 1099511628211 }
            }
            return h
        }
        var take: [Int] = [], hashes: [Int: UInt64] = [:]
        var est = 0.0
        let candidates = urgent + (idle ? underLayers.filter { !d.tracker.isCrisp($0) } : [])
        for i in candidates {
            let rr = region(d.tracker.rect(of: i))
            let h = hash(rr)
            guard underlaySent[i] != h else { continue }
            take.append(i); hashes[i] = h; est += Double(rr.area) * 0.15
            if est >= underlayTokens || take.count >= 48 { break }
        }
        guard !take.isEmpty else { return }
        var jobs: [(PixelRect, PixelRect, Data)] = []
        for r in d.tracker.mergedRects(take) {
            let rr = region(r)
            var data = Data(count: rr.width * rr.height * 4)
            data.withUnsafeMutableBytes { dst in for y in 0..<rr.height { memcpy(dst.baseAddress!.advanced(by: y * rr.width * 4), u.base.advanced(by: (rr.y + y) * u.stride + rr.x * 4), rr.width * 4) } }
            jobs.append((r, rr, data))
        }
        underlayTokens -= est
        for (i, h) in hashes { underlaySent[i] = h }
        // The viewer holds window-free pixels there now; the real desktop follows once the guard releases them (pending).
        d.taint.clear(take)
        d.tracker.defer(take, now: now, delayNanos: 3_600_000_000_000, direct: false)
        let hdr = header(layer: 0, nanos: now)
        tileQueue.async { [weak self] in
            guard let self else { return }
            let tiles: [TileMessage.Tile] = jobs.compactMap { r, rr, data in
                data.withUnsafeBytes { p in TileCodec.encodeLossy(base: p.baseAddress!, width: rr.width, height: rr.height, stride: rr.width * 4, outWidth: rr.width, outHeight: rr.height, quality: 70, alpha: false) }
                    .map { TileMessage.Tile(rect: r, format: .lossy, data: $0) }
            }
            guard !tiles.isEmpty else { return }
            let bytes = tiles.reduce(0) { $0 + $1.data.count }
            self.send(tile: .tiles(.init(header: hdr, refinement: true, windowFree: true, tiles: tiles)), captureNanos: now, fast: false, refinementBytes: bytes, layer: 0)
            self.queue.async {
                self.underlayTokens -= Double(bytes) - est
                self.statUnderlayTiles += take.count; self.statUnderlayBytes += bytes
                self.layers[0]?.account.underlay += bytes
            }
        }
    }

    /// Changed pixels the rate limit held back (a tile changed again within 80 ms) are a direct change, not refinement:
    /// they go when due, presented on arrival, before any refinement and whatever gates it. They used to wait in the
    /// refinement pass, which yields 150 ms after every direct change (forever while the pointer moves), freezes during
    /// motion, waits for the first picture and serves every window's backlog before the desktop: the tiles a moving
    /// Dock tooltip had just left stayed stale until another tooltip repainted them (phrz's ghost labels, traced on
    /// mac-daddy with real Dock hovers: each label update covered its new place, the place it left was rate-limited).
    private var statDirectDue = 0, statDirectWaitMaxNanos: UInt64 = 0, statCopyCorrections = 0, statStripLossy = 0
    private func sendDueDirect(now: UInt64) {
        let perSecond = Double(lastBudget.tileKbps * 1000 / 8)
        for l in layers.values {
            guard let src = l.lastFrame else { continue }
            if !l.correctionTiles.isEmpty { l.correctionTiles = l.correctionTiles.filter { l.tracker.isDirectPending($0) } }   // sent another way meanwhile
            let due = l.tracker.dueDirect(now: now, limit: 64).filter { !l.occludedTiles.contains($0) }
            guard !due.isEmpty else { continue }
            // From the reserve the refinement pass keeps for changed pixels: may go down to -30 % of a second's budget. A tile
            // due for 150 ms or more borrows further, up to a second's budget of debt: a hover's own tiles (or refinement)
            // spending the budget held a vacated tooltip tile back ~6 s on mac-daddy; it must land within ~300 ms.
            let waited = l.tracker.oldestDueDirect(now: now).map { Clock.elapsed(since: $0, now: now) } ?? 0
            guard tileTokens > -perSecond * 0.3 || waited >= Self.directBorrowAfterNanos && tileTokens > -perSecond else { continue }
            statDirectWaitMaxNanos = max(statDirectWaitMaxNanos, waited)
            CVPixelBufferLockBaseAddress(src, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            let f = frameView(src)
            guard f.width == l.width, f.height == l.height else { continue }
            if l.isDisplay { displaySent(due) }
            let corrections = due.filter { l.correctionTiles.contains($0) }, changes = due.filter { !l.correctionTiles.contains($0) }
            var bytes = 0
            if !changes.isEmpty { bytes += submitLossless(layer: l, tiles: changes, from: f, refinement: false, nanos: now, tracker: l.tracker) }
            if !corrections.isEmpty { bytes += submitLossless(layer: l, tiles: corrections, from: f, refinement: false, nanos: now, tracker: l.tracker, correction: true); l.correctionTiles.subtract(corrections) }
            tileTokens -= Double(bytes)
            l.tracker.sent(lossless: due, now: now)
            pacer.noteDirect(bytes: bytes, now: now)
            statDirectDue += due.count
        }
    }

    /// Moved windows whose backdrop changed (captured() holds those tiles): once the window has been still 300 ms and no
    /// held capture came for 150 ms, one lossy whole-layer level (~50 KB) shows the new picture, presented on arrival.
    /// The held tiles are refined lossless only when the session is idle: no window moved for 5 s and no motion or
    /// input for 2 s (a few drags in a row cost a level each, not a lossless resend each).
    static let backdropSettleNanos: UInt64 = 300_000_000
    /// Test knob MIRAGE_TEST_NO_BACKDROP: moves resend the backdrop as before (A/B).
    static let backdropHold = ProcessInfo.processInfo.environment["MIRAGE_TEST_NO_BACKDROP"] == nil
    static let backdropIdleNanos: UInt64 = 5_000_000_000
    static let directBorrowAfterNanos: UInt64 = 150_000_000
    private var statBackdropTiles = 0, statBackdropLevels = 0, statBackdropBytes = 0, statBackdropReleased = 0
    private func sendBackdropLevels(now: UInt64) {
        let perSecond = Double(lastBudget.tileKbps * 1000 / 8)
        for l in layers.values where !l.isDisplay {
            if l.backdropDirty {
                guard Clock.elapsed(since: l.movedNanos, now: now) >= Self.backdropSettleNanos,
                      Clock.elapsed(since: l.backdropHeldNanos, now: now) >= 150_000_000,
                      tileTokens > -perSecond * 0.3, l.announced, let src = l.lastFrame else { continue }
                CVPixelBufferLockBaseAddress(src, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
                let f = frameView(src)
                guard f.width == l.width, f.height == l.height else { continue }
                l.backdropDirty = false
                let bytes = submitIntermediate(l, from: f, nanos: now, backdrop: true)
                tileTokens -= Double(bytes)
                pacer.noteDirect(bytes: bytes, now: now)
            } else if Clock.elapsed(since: l.movedNanos, now: now) >= Self.backdropIdleNanos, Clock.elapsed(since: lastMotionNanos, now: now) >= 2_000_000_000, l.tracker.heldCount > 0 {
                let n = l.tracker.releaseHeld(now: now)
                statBackdropReleased += n
                if debugLayers { log("layer \(l.id): idle; \(n) backdrop tiles released to lossless refinement") }
            }
        }
    }

    /// One refinement step over `layers` in order: a fresh picture's next block, a large-backlog block plan, or a
    /// batch of due tiles. True if something was started (or a block is pending for one of them).
    private func refineStep(_ layers: [Layer], now: UInt64) -> Bool {
        for l in layers {
            switch l.fresh {
            case .still, .intermediate, .blocks: freshStep(l, now: now); return true
            default: continue
            }
        }
        // A backlog of more than 40 % of a layer (after a drag or a full-screen change) is refined
        // as large locus-first blocks, one in flight, not as a march of a thousand tiles.
        // (Compositor model: the desktop under shown windows does not count; it is refined per tile, and counted it re-planned
        // blocks with nothing to send in a loop: d75b1d0 on phrz's iPhone, "fresh picture: complete" 100 times in 24 s.)
        func backlog(_ l: Layer) -> Int {
            guard compositor, l.isDisplay else { return l.tracker.pendingUnheld }
            return l.tracker.pendingUnheld - l.underLayer.filter { l.tracker.isPending($0) && !l.tracker.isHeld($0) }.count
        }
        for l in layers where backlog(l) * 10 > l.tracker.tileCount * 4 && l.lastFrame != nil {
            let blocks = planBlocks(l)
            if !blocks.isEmpty {
                l.fresh = .blocks(remaining: blocks)
                log("layer \(l.id) refinement backlog \(l.tracker.pendingUnheld) tiles: \(blocks.count) large blocks, locus first")
                freshStep(l, now: now); return true
            }
        }
        let perSecond = Double(lastBudget.tileKbps * 1000 / 8)
        for l in layers {
            guard let src = l.lastFrame else { continue }
            var due = l.tracker.due(now: now, limit: 96, centre: locusTile(l))
            // Tiles covered on the host (or off the display) wait until they are uncovered (reconcileLayers expedites them then).
            if !l.occludedTiles.isEmpty {
                let hidden = due.filter { l.occludedTiles.contains($0) }
                if !hidden.isEmpty { l.tracker.defer(hidden, now: now, delayNanos: 3_600_000_000_000); due.removeAll { l.occludedTiles.contains($0) } }
            }
            if compositor, l.isDisplay, !underlayWanted {
                let under = due.filter { l.underLayer.contains($0) }
                if !under.isEmpty { l.tracker.defer(under, now: now, delayNanos: 3_600_000_000_000); due.removeAll { l.underLayer.contains($0) } }
            }
            guard !due.isEmpty else { continue }
            // Something visible is waiting: it goes when the refinement budget allows (and nothing behind it meanwhile).
            guard tileTokens > perSecond * 0.3 * 0.5, Double(refinementInFlight) < perSecond * 0.3 else { return true }
            // Take tiles until the budget is spent (allowed to go negative once).
            var take: [Int] = []
            var est = 0.0
            for i in due {
                take.append(i); est += Double(l.tracker.rect(of: i).area) / 5
                if est >= tileTokens { break }
            }
            CVPixelBufferLockBaseAddress(src, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            let f = frameView(src)
            guard f.width == l.width, f.height == l.height else { continue }
            if l.isDisplay { displaySent(take) }
            // Changed pixels the rate limit or the budget held back (and corrections) are direct: presented on arrival.
            // Refinement is staged into the layer's next level; the underlay lands at once (nobody sees it).
            let direct = take.filter { l.tracker.isDirectPending($0) }
            let refine = take.filter { !l.tracker.isDirectPending($0) }
            let underlayTiles = l.isDisplay ? refine.filter { l.underLayer.contains($0) } : []
            let stagedTiles = l.isDisplay ? refine.filter { !l.underLayer.contains($0) } : refine
            var bytes = 0
            if !direct.isEmpty { bytes += submitLossless(layer: l, tiles: direct, from: f, refinement: false, nanos: now, tracker: l.tracker) }
            if !underlayTiles.isEmpty { bytes += submitLossless(layer: l, tiles: underlayTiles, from: f, refinement: true, nanos: now, tracker: l.tracker, photoQuality: 75) }
            if !stagedTiles.isEmpty { bytes += submitLossless(layer: l, tiles: stagedTiles, from: f, refinement: true, nanos: now, tracker: l.tracker, staged: true) }
            tileTokens -= Double(bytes)
            l.tracker.sent(lossless: take, now: now)
            return true
        }
        return false
    }

    // MARK: Video

    private func plannedFPS() -> Int {
        let bytesPerSec = Double(max(100, lastBudget.videoKbps) * 1000 / 8)
        return max(5, min(request?.maxFPS ?? 30, Int(bytesPerSec / 6000)))
    }
    private func bucketCapacity() -> Double { Double(max(100, lastBudget.videoKbps) * 1000 / 8) * 0.35 }

    private func refill() {
        let now = Clock.nowNanos()
        let dt = Double(Clock.elapsed(since: lastRefill, now: now)) / 1e9
        lastRefill = now
        tokens = min(bucketCapacity(), tokens + dt * Double(max(100, lastBudget.videoKbps) * 1000 / 8))
        tokens = max(tokens, -3 * bucketCapacity())   // bound the debt a huge keyframe can create
    }

    /// Purges frames unacked for too long (review H3) and asks for recovery; shared across layers.
    private func purgeStale(now: UInt64) {
        for (s, f) in unacked where now > FrameAssembler.staleDeadlineNanos(paceEndNanos: f.paceEndNanos, sentNanos: f.sentNanos, srttNanos: srttNanos) {
            unacked[s] = nil; recentlyPurged[s] = f; statLost += 1
            guard let l = layers[f.layer] else { continue }
            if !l.wantKeyframe { log("frame \(s) (layer \(f.layer)) unacked \((Clock.elapsed(since: f.sentNanos, now: now)) / 1_000_000) ms after it was queued (srtt \(Int(srttNanos / 1e6)) ms): stale, recovery frame") }
            // The frame the fresh-picture sequence waits on is purged like any other (a base keyframe
            // swallowed whole by a loss burst produces no ack of any kind, and the in-flight cap would
            // otherwise wait for it forever); the next keyframe takes its place.
            if case .base(let fs) = l.fresh, fs == s { l.fresh = .base(seq: 0) }
            if case .climb(let fs) = l.fresh, fs == s { l.fresh = .climb(seq: 0) }
            requestRecovery(layer: l)
        }
        if recentlyPurged.count > 16 { for k in recentlyPurged.keys.sorted().prefix(recentlyPurged.count - 16) { recentlyPurged[k] = nil } }
    }

    private func tryEncode(_ l: Layer, now: UInt64, latest: ShiftDetector.Frame) {
        guard var enc = l.encoder, let req = request, let canvas = ensureCanvas(l) else { return }
        refill()
        purgeStale(now: now)
        if l.encoding { statDropped += 1; return }
        let inflightBytes = unacked.values.reduce(0) { $0 + $1.bytes }
        // In flight may not exceed what the link drains in one base RTT plus a little: the controller
        // backs off on queuing delay, so this cap only keeps our own burst from building a queue.
        let inflightBudget = Double(max(100, lastBudget.videoKbps) * 1000 / 8) * (srttNanos / 1e9 + 0.05)
        if !unacked.isEmpty && Double(inflightBytes) > inflightBudget { statSkippedBudget += 1; secSkippedBudget += 1; return }
        if tokens < 0 { statSkippedBudget += 1; secSkippedBudget += 1; return }
        let fraction = Double(l.pendingVideoRegion.area) / Double(l.width * l.height)
        let tierFPS = Double(rc?.policy.maxVideoFPS ?? req.maxFPS)
        let fpsCap: Double = min(tierFPS, fraction < 0.03 ? 15 : Double(req.maxFPS))
        l.lastFpsCap = fpsCap
        let minInterval = UInt64(1e9 / min(fpsCap, Double(max(1, req.maxFPS))))
        if Clock.elapsed(since: l.lastSendNanos, now: now) < minInterval * 9 / 10 && !l.wantKeyframe { statDropped += 1; return }

        var opts = HEVCEncoder.FrameOptions()
        var region = l.pendingWholeFrame ? l.bounds : l.pendingVideoRegion
        var tiles = l.pendingVideoTiles
        if l.wantKeyframe, !l.progressiveKeyframe, var rc, rc.rung != RateController.tinyRung, l.isDisplay {
            // Lossy-first on recovery too: a keyframe at the current rung that would take more than ~1 s
            // of the video budget goes out on the tiny rung instead (the ladder climbs back afterwards).
            // The fresh-picture climb approved its keyframe with the same test (review H4), so it is exempt.
            if !FrameAssembler.keyframeFits(encodedWidth: enc.width, encodedHeight: enc.height, videoKbps: lastBudget.videoKbps) {
                rc.dropToTinyRung(now: now); self.rc = rc
                lastRebuildNanos = now
                rebuildAllEncoders(keyframes: false)
                log("lossy-first: recovery keyframe on the tiny rung (\(Int(Double(enc.width * enc.height) * 0.025 / 1000)) KB estimated at rung \(rc.rung))")
            }
        }
        if l.wantKeyframe {
            // Recovery: the canvas must be the whole current picture. The mask leaves out tiles the
            // client already has pixel-exact, so a keyframe does not degrade crisp text elsewhere.
            CVPixelBufferLockBaseAddress(canvas, [])
            let dst = CVPixelBufferGetBaseAddress(canvas)!, ds = CVPixelBufferGetBytesPerRow(canvas)
            for y in 0..<latest.height { memcpy(dst.advanced(by: y * ds), latest.base.advanced(by: y * latest.stride), latest.width * 4) }
            CVPixelBufferUnlockBaseAddress(canvas, [])
            region = l.bounds
            tiles = Set((0..<l.tracker.tileCount).filter { !l.tracker.isCrisp($0) })
            tiles.formUnion(l.pendingVideoTiles)
            l.tracker.markVideo(Array(tiles), now: now)
            // Review #6: tiles the client already has crisp are masked out of this keyframe, so their
            // pixels are wasted bits; flatten each to its mean colour before encoding.
            flattenCanvas(canvas, except: tiles, tracker: l.tracker)
            // A forced keyframe ignores MinAllowedFrameQP (measured: ~125 KB regardless); a fresh
            // session's first IDR honours it (~18 KB). Recovery therefore replaces the session.
            if (try? rebuildEncoder(l)) != nil, let fresh = l.encoder { enc = fresh } else { opts.forceKeyframe = true }
            l.wantKeyframe = false; l.wantLTRRefresh = false
            l.keyframeArmed = true
        } else if enc.coarse && seq > 0 { enc.setCoarse(false) }
        if !l.keyframeArmed && l.wantLTRRefresh { opts.forceLTRRefresh = true }
        opts.acknowledgedLTRTokens = l.ackedLTR
        let recovery = l.keyframeArmed || l.wantLTRRefresh
        if recovery { l.lastRecoveryWasLTR = l.wantLTRRefresh && !l.keyframeArmed }
        l.keyframeArmed = false; l.wantLTRRefresh = false

        // Host-side crop: a window layer's tiles off the display stay transparent on the viewer (cropOffDisplay).
        if !l.isDisplay, !l.blankedOffDisplay.isEmpty { tiles.subtract(l.blankedOffDisplay) }
        // Build the mask over the region's tile grid.
        let grid = TileMask.grid(for: region)
        var mask = TileMask(cols: grid.cols, rows: grid.rows)
        let c0 = region.x / TileTracker.tile, r0 = region.y / TileTracker.tile
        for i in tiles {
            let c = i % l.tracker.cols - c0, r = i / l.tracker.cols - r0
            if c >= 0, r >= 0, c < grid.cols, r < grid.rows { mask[c, r] = true }
        }
        // Encoder input: the canvas, scaled down at lower rungs.
        var input = canvas
        if let scaled = l.scaled, let transfer = l.transfer {
            guard VTPixelTransferSessionTransferImage(transfer, from: canvas, to: scaled) == noErr else { log("pixel transfer failed"); return }
            input = scaled
        }
        if l.isDisplay, !l.occludedTiles.isEmpty {
            // DisplayGuard: no desktop pixels where a layered window is or just was, keyframes included.
            let held = tiles.intersection(l.occludedTiles)
            if !held.isEmpty {
                tiles.subtract(held)
                for i in held { let c = i % l.tracker.cols - c0, r = i / l.tracker.cols - r0; if c >= 0, r >= 0, c < grid.cols, r < grid.rows { mask[c, r] = false } }
                l.tracker.defer(Array(held), now: now, delayNanos: 3_600_000_000_000)
            }
            // Unified mode: desktop motion nobody sees is not encoded at all (recovery frames still go: the decoder needs them).
            if tiles.isEmpty, !recovery, unifiedView {
                l.pendingVideoTiles = []; l.pendingVideoRegion = .zero; l.pendingWholeFrame = false
                return
            }
        }
        if l.isDisplay { displaySent(Array(tiles)) }
        l.submitted = (tiles, region, l.pendingWholeFrame)
        l.pendingVideoTiles = []; l.pendingVideoRegion = .zero; l.pendingWholeFrame = false
        l.encoding = true; l.encodingSince = now
        l.lastSendNanos = now
        l.encoderUseNanos = now
        let captureSeq = self.captureSeq, inputSeq = self.lastInputSeq
        let progressive = l.progressiveKeyframe
        enc.encode(input, captureNanos: now, options: opts) { [weak self, weak l] result in
            guard let self, let l else { return }
            self.queue.async {
                l.encoding = false
                switch result {
                case .failure(let e):
                    // A rate-limited drop keeps the reference chain intact; the pending tiles ride the next frame.
                    if let s = l.submitted { l.pendingVideoTiles.formUnion(s.tiles); l.pendingVideoRegion = l.pendingVideoRegion.union(s.region); l.pendingWholeFrame = l.pendingWholeFrame || s.whole }
                    if case MirageError.transport(let t) = e, t.contains("dropped") { self.statDropped += 1 }
                    else { self.log("encode (layer \(l.id)): \(e)"); l.wantKeyframe = true }
                case .success(let f):
                    self.send(l, f, recovery: recovery, progressive: progressive, region: region, mask: mask, captureSeq: captureSeq, inputSeq: inputSeq)
                }
                l.submitted = nil
            }
        }
    }

    private func send(_ l: Layer, _ f: HEVCEncoder.Encoded, recovery: Bool, progressive: Bool, region: PixelRect, mask: TileMask, captureSeq: UInt32, inputSeq: UInt64) {
        guard let out = output else { return }
        seq &+= 1
        var flags: VideoFragment.Flags = [.tileMask]
        if f.keyframe { flags.insert(.keyframe); flags.insert(.recovery) }
        if progressive && f.keyframe { flags.insert(.progressive); l.progressiveKeyframe = false }
        if recovery { flags.insert(.recovery) }
        if flags.contains(.recovery) { l.recoverySeq = seq; l.recoverySentNanos = Clock.nowNanos() }
        if !f.parameterSets.isEmpty { flags.insert(.parameterSets) }
        let payload = VideoFramePayload.encode(parameterSets: f.parameterSets, tileMask: mask.bits, sample: f.sample)
        let maxPayload = out.maxDatagramSize - VideoFragment.headerSize
        var frags = VideoFragment.fragments(frameSeq: seq, flags: flags, captureNanos: f.captureNanos, payload: payload, maxPayload: maxPayload,
                                            captureSeq: captureSeq, inputSeq: inputSeq, region: region, layerID: l.id)
        // XOR parity on every frame of two or more datagrams (§4a loss: recovery by parity before NACK,
        // keyframe last): one lost datagram per group is rebuilt by the viewer without a round trip. The
        // group is 8 normally and 4 above 2 % measured loss; a 2–3 datagram frame pays a third for it,
        // which is still far cheaper than the round trip or the keyframe it avoids.
        if frags.count >= 2 {
            let payloads = (0..<frags.count).map { i -> Data in let lo = payload.startIndex + i * maxPayload; return payload.subdata(in: lo..<min(lo + maxPayload, payload.endIndex)) }
            frags.append(contentsOf: ParityFragment.parity(frameSeq: seq, payloads: payloads, groupSize: rc?.parityGroupSize ?? 8))
        }
        let sent = SentFrame(nanos: Clock.nowNanos(), datagrams: frags)
        sentFrames[seq] = sent
        for (k, v) in sentFrames where Clock.elapsed(since: v.nanos, now: Clock.nowNanos()) > 2_000_000_000 { sentFrames[k] = nil }
        // Intra-frame pacing (review §2.1, H6): datagrams leave at ~1.25× the video budget, interval from
        // the rate, so a 25 KB frame or a keyframe never builds a queue on a 1 Mbps hop.
        let paceEnd = pace(frags, frame: sent)
        tokens -= Double(payload.count)
        unacked[seq] = InFlight(layer: l.id, sentNanos: Clock.nowNanos(), bytes: payload.count, ltrToken: f.ltrToken, paceEndNanos: paceEnd)
        statFrames += 1; statBytes += payload.count; statEncodeNanos += f.encodeNanos; secVideoBytes += payload.count; secVideoFrames += 1
        l.account.video += payload.count
        if f.keyframe {
            log("keyframe \(payload.count) bytes (layer \(l.id), \(frags.count) datagrams, \(mask.count) tiles masked, paced over \(paceEnd > Clock.nowNanos() ? (paceEnd - Clock.nowNanos()) / 1_000_000 : 0) ms)")
            switch l.fresh {
            case .base: l.fresh = .base(seq: seq)
            case .climb: l.fresh = .climb(seq: seq)
            default:
                // A keyframe outside a fresh picture (loss recovery, an encoder rebuilt for a rung change) is just that,
                // however much it covers: it never restarts the whole picture (FreshPictureTrigger).
                break
            }
        }
    }

    private func acked(_ ack: ControlMessage.FrameAck) {
        let now = Clock.nowNanos()
        var layer: Layer? = nil
        if let f = unacked.removeValue(forKey: ack.seq) ?? recentlyPurged.removeValue(forKey: ack.seq) {
            layer = layers[f.layer]
            if !ack.lost { rc?.streamAcked(bytes: f.bytes, receivedNanos: ack.receivedNanos, now: now) }   // delivery rate: video bytes count with the tiles
            // Loss acks come after the assembler's timeout; they say nothing about the path's RTT.
            if !ack.lost {
                // RTT and one-way delay are measured from when the frame's last datagram left the pacer, not
                // from when it was queued: pacing time is ours, not the link's queue. A paced train says
                // nothing about capacity either (it reads 1.25× our own budget), so it gives no rate sample.
                let left = max(f.sentNanos, min(f.paceEndNanos, now))
                let rtt = Double(now &- left)
                // Paced = more than one 2 ms batch (FrameAssembler.paceOffsets). `> sent + 2 ms` let a two-batch train through
                // (its end is 2 ms after a start taken just before `sentNanos`): its spread read our own pacing, and the
                // ceiling (0.7 × that "capacity") held an automatic-bitrate loopback stream at 4.6 Mbps.
                let paced = f.paceEndNanos > f.sentNanos &+ 1_000_000
                let recovered = (ack.fragmentsLost ?? 0) > 0
                if !recovered { srttNanos = srttNanos * 0.8 + rtt * 0.2 }
                rc?.frameAcked(sentNanos: left, firstReceived: ack.firstReceivedNanos ?? ack.receivedNanos, lastReceived: ack.receivedNanos,
                               fragments: paced ? 1 : (ack.fragments ?? 1), bytes: f.bytes, now: now, rttNanos: rtt, recovered: recovered)
                if let total = ack.fragments { rc?.fragmentLoss(lost: ack.fragmentsLost ?? 0, total: total, now: now) }
            }
            if let l = layer {
                if !ack.lost, ack.decodedNanos != 0, ack.seq >= l.recoverySeq { l.lastRecoveryWasLTR = false }
                if !ack.lost, ack.decodedNanos != 0 { freshAcked(l, seq: ack.seq, now: now) }
                if !ack.lost, ack.decodedNanos != 0, let tok = f.ltrToken {
                    l.ackedLTR.append(tok)
                    if l.ackedLTR.count > 8 { l.ackedLTR.removeFirst(l.ackedLTR.count - 8) }
                }
            }
        }
        for s in unacked.keys where s < ack.seq { unacked[s] = nil }
        if ack.lost {
            statLost += 1
            // Review L3: a stale "late lost" verdict for a frame older than the layer's recovery is not a loss.
            if let l = layer { if ack.seq >= l.recoverySeq { rc?.lossDetected(now: now); requestRecovery(layer: l) } }
            else { rc?.lossDetected(now: now); requestRecovery(layer: nil) }
        }
        // Safety net: a viewer still skipping (not decoding) frames newer than the last recovery for
        // over a second did not get that recovery frame; send another.
        if let l = layer {
            let recoveryPaceEnd = unacked[l.recoverySeq]?.paceEndNanos ?? l.recoverySentNanos
            if !ack.lost, ack.decodedNanos == 0, ack.seq > l.recoverySeq, now > max(l.recoverySentNanos, recoveryPaceEnd) &+ 1_500_000_000, !l.wantKeyframe {
                log("viewer skipping frames of layer \(l.id) after recovery \(l.recoverySeq); resending keyframe")
                requestRecovery(layer: l); l.recoverySentNanos = now
            }
        }
        applyBudget(now: now)
    }

    /// Pushes the controller's decisions into the encoders (rate, rung) at most every 500 ms.
    private var lastBudgetApply: UInt64 = 0
    private var lastRebuildNanos: UInt64 = 0
    private func applyBudget(now: UInt64) {
        guard let rc, let d = display, Clock.elapsed(since: lastBudgetApply, now: now) > 500_000_000 else { return }
        lastBudgetApply = now
        // During sustained motion refinement is frozen, so only the interactive tile bytes (changed
        // pixels near the locus, copy-rects) are reserved and video gets the rest of the target.
        let b = rc.budget(videoActive: Clock.elapsed(since: videoActiveNanos, now: now) < 500_000_000, recentTileKbps: Int(motionSustained(now) ? interactiveKbpsEWMA : tileKbpsEWMA))
        let wantedWidth = max(64, Int(Double(d.width) * rc.scale)) & ~1
        let rungChanged = d.encoder.map { wantedWidth != $0.width } ?? false
        // A rung change costs a keyframe: at most one per 5 s, and never to a *larger* picture while the link is queuing.
        let growing = d.encoder.map { wantedWidth > $0.width } ?? false
        if rungChanged, d.fresh == .done, Clock.elapsed(since: lastRebuildNanos, now: now) > 5_000_000_000, !(growing && rc.queueMs > 60) {
            lastBudget = b
            lastRebuildNanos = now
            rebuildAllEncoders(keyframes: true)
            log("ladder: rung \(rc.rung) (scale \(rc.scale)), target \(rc.targetKbps) kbps")
        } else if abs(b.videoKbps - lastBudget.videoKbps) > lastBudget.videoKbps / 10 || b.tileKbps != lastBudget.tileKbps {
            lastBudget = b
            for l in layers.values { l.encoder?.setRate(bitrateKbps: b.videoKbps, expectedFPS: plannedFPS()) }
        }
    }

    /// The rung changed: every live encoder is rebuilt at the new scale (each costs a keyframe).
    private func rebuildAllEncoders(keyframes: Bool) {
        for l in layers.values where l.encoder != nil {
            if (try? rebuildEncoder(l)) != nil, keyframes { l.wantKeyframe = true }
        }
    }

    /// Recovery defaults to a (QP-floored) keyframe from a fresh session. LTR refresh is opt-in (MIRAGE_LTR=1); see DESIGN §6 M1.
    private static let ltrEnabled = ProcessInfo.processInfo.environment["MIRAGE_LTR"] != nil
    /// `layer` nil: the lost frame could not be attributed, so every layer with a live encoder recovers.
    private func requestRecovery(layer: Layer?) {
        let targets = layer.map { [$0] } ?? layers.values.filter { $0.encoder != nil }
        for l in targets {
            if Self.ltrEnabled && !l.ackedLTR.isEmpty && !l.lastRecoveryWasLTR { l.wantLTRRefresh = true } else { l.wantKeyframe = true }
        }
    }

    // MARK: Timers and stats

    private func startTimers() {
        let r = DispatchSource.makeTimerSource(queue: queue)
        r.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
        r.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Clock.nowNanos()
            // The window list drives layers and the client's composition; it must not depend on captures
            // (the display layer is mostly static now that the windows are not in it).
            if let w = self.windows?.sample(captureSeq: self.captureSeq, now: now) {
                self.pendingMoved += w.moved
                if w.changed { self.reconcileLayers(w.sample, now: now); if !w.moved.isEmpty { self.lastMotionNanos = now } }
                self.publishWindows(now: now, full: false)
            }
            for l in self.layers.values {
                if l.encoding, Clock.elapsed(since: l.encodingSince, now: now) > 2_000_000_000 {
                    // Safety net: an encode whose completion never came (encoder replaced underneath it).
                    self.log("encoder (layer \(l.id)): no completion for \((Clock.elapsed(since: l.encodingSince, now: now)) / 1_000_000) ms; releasing the pipeline and asking for a keyframe")
                    l.encoding = false; l.wantKeyframe = true
                    if let s = l.submitted { l.pendingVideoTiles.formUnion(s.tiles); l.pendingVideoRegion = l.pendingVideoRegion.union(s.region); l.pendingWholeFrame = l.pendingWholeFrame || s.whole; l.submitted = nil }
                }
                if l.hasVideoPending, let src = l.lastFrame {
                    CVPixelBufferLockBaseAddress(src, .readOnly)
                    self.tryEncode(l, now: now, latest: self.frameView(src))
                    CVPixelBufferUnlockBaseAddress(src, .readOnly)
                }
                // An encoder idle for 10 s is released (another layer may want one).
                if !l.isDisplay, l.encoder != nil, !l.encoding, Clock.elapsed(since: l.encoderUseNanos, now: now) > 10_000_000_000, !l.hasVideoPending { l.encoder = nil; l.scaled = nil; l.transfer = nil; l.canvas = nil }
            }
            for l in self.layers.values where l.needsCrop { if let r = l.onScreenLocal { self.cropOffDisplay(l, onScreen: r, now: now) } }
            self.updateDisplayHidden(now: now)
            self.scheduleTaintedResends(now: now)
            self.refine(now: now)
            self.applyBudget(now: now)
        }
        r.resume(); refineTimer = r

        let s = DispatchSource.makeTimerSource(queue: queue)
        s.schedule(deadline: .now() + 1, repeating: 1)
        s.setEventHandler { [weak self] in
            guard let self, let rc = self.rc else { return }
            // Delay estimate upkeep: decay a stale estimate (probes lost), and send the 32-byte delay
            // probe: every second, unconditionally. Probe and video acks are the only path-delay inputs.
            let tnow = Clock.nowNanos()
            self.rc?.tick(now: tnow)
            self.probeSeq += 1
            self.output?.sendDatagram(DatagramPing.encode(seq: self.probeSeq))
            self.output?.sendControl(.rateState(.init(targetKbps: rc.targetKbps, capacityKbps: rc.capacityKbps, queueMs: rc.queueMs, rung: rc.rung, scale: rc.scale,
                                                      tileBudgetKbps: self.lastBudget.tileKbps, videoKbps: self.secVideoBytes * 8 / 1000, tileKbps: self.secTileBytes * 8 / 1000, tier: rc.tier)))
            if rc.tier != self.lastTier {
                let first = self.lastTier == nil
                let previous = self.lastTier
                self.lastTier = rc.tier; self.log("link tier: \(rc.tier.name) (capacity \(rc.capacityKbps) kbps, srtt \(Int(rc.srttMs)) ms, loss \(String(format: "%.1f", rc.lossPercent)) %)")
                // A worse tier restarts lossy-first from the tiny rung; a better one just lets the ladder climb.
                // Only when the worse tier's policy differs (Normal and Constrained share one: a restart between them
                // bought nothing and dropped the whole screen to the tiny rung, phrz's session 22:48:22Z).
                if !first, let d = self.display, d.fresh == .done, rc.tier.rawValue > (previous?.rawValue ?? 0), rc.tier.policy != previous?.policy {
                    self.rc?.dropToTinyRung(now: tnow); self.lastRebuildNanos = tnow
                    self.rebuildAllEncoders(keyframes: true)
                    self.beginFreshPicture(.tierChange, detail: " to \(rc.tier.name)")
                }
            }
            self.checkExclusion(now: tnow)
            self.tileKbpsEWMA = self.tileKbpsEWMA * 0.5 + Double(self.secTileBytes * 8 / 1000) * 0.5
            self.interactiveKbpsEWMA = self.interactiveKbpsEWMA * 0.5 + Double(self.secInteractiveBytes * 8 / 1000) * 0.5
            self.secInteractiveBytes = 0
            let capMs = self.effortCaptures > 0 ? Double(self.effortCaptureNanos) / Double(self.effortCaptures) / 1e6 : 0
            self.effortCaptureNanos = 0; self.effortCaptures = 0
            let pressure = HostEffort.measure(captureMs: capMs)
            if pressure.level != self.effort || !self.effortLogged {
                self.effortLogged = true
                self.effort = pressure.level
                self.detector.maxShift = self.effort.shiftSearch.maxShift
                self.log(String(format: "host effort: %@ (load/core %.2f, thermal %d, capture %.1f ms)", self.effort.rawValue, pressure.loadPerCore, pressure.thermal.rawValue, capMs))
            }
            let active = Clock.elapsed(since: self.videoActiveNanos, now: tnow) < 1_000_000_000
            // Review H7: compare with the cap the host actually applied, and only when budget held frames back.
            let fpsCap = self.layers.values.filter { tnow - $0.videoActiveNanos < 1_000_000_000 }.map(\.lastFpsCap).min() ?? 30
            self.rc?.videoRate(achievedFPS: Double(self.secVideoFrames), wantedFPS: min(Double(min(self.request?.maxFPS ?? 30, rc.policy.maxVideoFPS)), fpsCap),
                               active: active, budgetLimited: self.secSkippedBudget > 0, now: tnow)
            self.secSkippedBudget = 0
            self.secVideoBytes = 0; self.secTileBytes = 0; self.secVideoFrames = 0
            if InputInjector.consoleLocked() != self.screenLocked, let cur = self.windows?.current { self.reconcileLayers(cur, now: tnow); self.publishWindows(now: tnow, full: false) }
            if Clock.elapsed(since: self.lastAuditNanos, now: tnow) >= 5_000_000_000 { self.lastAuditNanos = tnow; self.sendAudit(now: tnow); self.sendWindowAudits(now: tnow) }
            let front: (app: String, id: UInt32, title: String) = self.windows?.frontmost() ?? (app: "", id: 0, title: "")
            let chrome = self.display.flatMap { d in self.windows?.chromeRects(width: d.width, height: d.height) }
            if let chrome, chrome != self.loggedChrome {
                self.loggedChrome = chrome
                self.log("desktop chrome (menu bar, Dock): " + chrome.map { "\($0.x),\($0.y) \($0.width)x\($0.height)" }.joined(separator: " | "))
            }
            let status = ControlMessage.HostStatus(consoleLocked: self.screenLocked || InputInjector.consoleLocked(), frontmostApp: front.app, frontmostWindowID: front.id, frontmostWindowTitle: front.title, inputSink: InputInjector.sinkPath != nil, viewers: Self.liveCount(), chrome: chrome)
            // On change, and every 10 s regardless (sparse when idle; the viewer's keepalive is its own datagram).
            if status != self.lastHostStatus || Clock.elapsed(since: self.lastHostStatusNanos, now: tnow) > 10_000_000_000 {
                self.lastHostStatus = status; self.lastHostStatusNanos = tnow
                self.output?.sendControl(.hostStatus(status))
            }
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
            let backlog = layers.values.reduce(0) { $0 + $1.tracker.pendingTotal }
            let d = display
            let windowLayers = layers.values.filter { !$0.isDisplay }
            log(String(format: "video %.1f fps %.0f kbps (%dx%d) | tiles %.0f kbps %d rects (refine %.0f kbps) copy-rects %d backlog %d skipped %d | captures %d (%.1f ms each) dirty %d pruned %d | target %d cap %d queue %.0f ms rung %d srtt %.0f ms | inflight %d skipped %d dropped %d lost %d encode %.1f ms input %d",
                       fps, vkbps, d?.encoder?.width ?? 0, d?.encoder?.height ?? 0, tkbps, statTileRects, Double(statRefineBytes) * 8 / 5 / 1000, statCopyRects, backlog, statTileSkipped,
                       statCaptures, capMs, statDirtyTiles, statDiffPruned, rc?.targetKbps ?? 0, rc?.capacityKbps ?? 0, rc?.queueMs ?? 0, rc?.rung ?? 0, srttNanos / 1e6,
                       unacked.count, statSkippedBudget, statDropped, statLost, enc, statInput)
                + (statNacks > 0 ? " nacks \(statNacks) resent \(statNackResent)" : "") + " fresh \(d?.fresh.description ?? "-")"
                + " delivery \(rc?.deliveryKbps ?? 0) kbps\(rc?.inStartup ?? false ? " (startup)" : "") tile-inflight \(tileInflightBytes / 1000)/\((rc?.inflightCapBytes ?? 0) / 1000) KB"
                + String(format: " control %.0f kbps effort %@ fovea %@%@", Double(statControlBytes) * 8 / 5 / 1000, effortLevel, foveaActive ? "on" : "off", statFoveaTiles > 0 ? " (\(statFoveaTiles) tiles)" : "")
                + String(format: " delay src %@ age %d ms tile-backlog %.0f ms motion %@ interactive %.0f kbps stale-dropped %d", rc?.lastSampleSource ?? "none", Int((rc?.sampleAgeNanos(now: Clock.nowNanos()) ?? 0) / 1_000_000), rc?.tileDelayMs ?? 0, motionSustained(Clock.nowNanos()) ? "yes" : "no", interactiveKbpsEWMA, statStaleDropped)
                + " | layers \(windowLayers.count) (\(windowLayers.filter { $0.capturer != nil }.count) capturing, \(windowLayers.filter { $0.encoder != nil }.count) encoders, \(windowLayers.filter { !$0.exposed }.count) pending) stills \(statStills) occluded \(statOccluded) window-cmds \(statWindowCommands) taint-resent \(statTaintResent) exclusion-lag \(statExclusionLag)"
                + " [0:\(display?.sentBytes ?? 0 / 1000 > 0 ? (display!.sentBytes / 1000) : 0)KB(\(display?.sentDirect ?? 0)d+\(display?.sentRefine ?? 0)r) " + windowLayers.sorted { $0.id < $1.id }.map { "\($0.id):\($0.frames)f/\(Int($0.visibleFraction * 100))%/\($0.sentBytes / 1000)KB(\($0.sentDirect)d+\($0.sentRefine)r)\($0.exposed ? "" : "/\($0.fresh)")" }.joined(separator: " ") + "]")
            for l in layers.values { l.frames = 0; l.sentBytes = 0; l.sentDirect = 0; l.sentRefine = 0 }
            accountTicks += 1
            if accountTicks >= 6 { accountTicks = 0; logAccount() }
            auditVisibleUnsent(now: Clock.nowNanos())
            statStaleDropped = 0; statStills = 0; statOccluded = 0; statWindowCommands = 0; statTaintResent = 0; statExclusionLag = 0
            statControlBytes = 0; statFoveaTiles = 0
            statFrames = 0; statBytes = 0; statDropped = 0; statSkippedBudget = 0; statLost = 0; statEncodeNanos = 0; statInput = 0; statCaptures = 0; statCaptureNanos = 0; statNacks = 0; statNackResent = 0
            statTileBytes = 0; statTileRects = 0; statRefineBytes = 0; statCopyRects = 0; statDirtyTiles = 0; statDiffPruned = 0; statTileSkipped = 0
        }
        t.resume()
        statTimer = t
    }
}

/// TCC state the host needs; prompting adds `miraged` to the System Settings lists.
public enum HostPermissions {
    /// The last ScreenCaptureKit probe succeeded (CGPreflightScreenCaptureAccess can stay stale inside a running process).
    nonisolated(unsafe) public static var screenProbeOK = false
    public static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() || screenProbeOK }
    /// Whether screen capture works now: preflight, else asking ScreenCaptureKit for the shareable content (it throws
    /// without the grant).
    public static func probeScreenRecording() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let ok = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
        screenProbeOK = ok
        return ok
    }
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }
    public static func accessibilityGranted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
    }
}
