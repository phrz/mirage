import Foundation
import ScreenCaptureKit
import CoreMedia
import VideoToolbox
import MirageCore

/// One window layer's capture: a *display* SCStream whose filter excludes every other window (the desktop picture,
/// the wallpaper and icon windows included), with `sourceRect` on the window's frame and the output at the layer's
/// pixel size. The window renders whole and unoccluded, with transparency around its rounded corners, and macOS
/// does not badge it: a `desktopIndependentWindow` filter (or a display filter that *includes* the window) makes
/// macOS paint the purple screen-sharing pill over its traffic lights (phrz, 2026-10-19; `probe-layers --mode badge`).
///
/// The capture follows the window: when the window list reports a new frame, `follow` moves `sourceRect` there.
/// Frames are only passed on when they show the window where it is: the frame's screen rect must be the window's
/// current frame, and for a window that is opaque to its edges, its edge midpoints must be opaque (a frame captured
/// after the window moved but before the window list said so shows it shifted). The exclusion list grows as windows
/// appear over the layer. Filter and configuration changes are serialized, latest wins. The part of a window outside
/// the display is not captured (those tiles are occluded for the streamer anyway).
final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let windowID: UInt32
    private(set) var window: SCWindow
    private let display: SCDisplay
    private var stream: SCStream?
    private let queue: DispatchQueue
    private var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    private(set) var width: Int, height: Int
    private(set) var fps: Int
    /// The window's frame the capture follows (global points).
    private(set) var pointFrame: CGRect
    var onStop: ((Error?) -> Void)?
    private(set) var frames = 0
    /// Frames dropped: captured for a frame the window has left (stale configuration), or showing it shifted.
    private(set) var droppedMoved = 0, droppedEdge = 0, skippedUnchanged = 0
    private var statusLogged = false
    static let debug = !(ProcessInfo.processInfo.environment["MIRAGE_DEBUG_CAPTURE"] ?? "").isEmpty

    // State below is touched on `queue` only (frames arrive there, and the streamer calls in on it).
    private var excluded: [UInt32: SCWindow] = [:]
    private var appliedFilter = Set<UInt32>()
    private var appliedConfig: ConfigKey?
    private var updating = false, dirtyAgain = false
    private var needFull = true                 // the next accepted frame is passed on whatever its dirty rects say
    private var edgeOpaque: Bool? = nil         // learned from the first frames at rest
    private var edgeMisses = 0
    private var lastMoveNanos: UInt64 = 0

    struct ConfigKey: Equatable { var w: Int; var h: Int; var fps: Int; var rect: CGRect }

    /// The display's own backing scale (pixels per point). ScreenCaptureKit scales the display *before* it crops the
    /// source rect, so at any other output scale the window's pixels are resampled with a phase that depends on where the
    /// window is: a window moved by a few points came back with every tile different (a quarter megabyte per move on
    /// mac-daddy's 1.89 px/pt stream). The capture is therefore taken at the native scale, where it is position-
    /// independent, and scaled to the layer's size here with a fixed transform (VTPixelTransfer).
    private lazy var nativeScale: CGFloat = {
        guard let m = CGDisplayCopyDisplayMode(display.displayID), m.width > 0 else { return 2 }
        return CGFloat(m.pixelWidth) / CGFloat(m.width)
    }()
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    /// Captured pixel size: native when the layer's scale differs from it, else the layer size.
    private var captureSize: (Int, Int) {
        if warm != nil { return (width, height) }   // the warm pool's low-cost size, captured as is
        let nw = Int((pointFrame.width * nativeScale).rounded()), nh = Int((pointFrame.height * nativeScale).rounded())
        if abs(nw - width) <= 2 && abs(nh - height) <= 2 { return (width, height) }
        return (max(2, nw) & ~1, max(2, nh) & ~1)
    }

    init(window: SCWindow, display: SCDisplay, pointFrame: CGRect, width: Int, height: Int, fps: Int, queue: DispatchQueue) {
        self.window = window; self.display = display; windowID = window.windowID
        self.pointFrame = pointFrame
        self.width = max(2, width) & ~1; self.height = max(2, height) & ~1; self.fps = fps; self.queue = queue
    }

    private var key: ConfigKey { let c = captureSize; return ConfigKey(w: c.0, h: c.1, fps: fps, rect: pointFrame) }

    private func configuration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let size = captureSize
        c.width = size.0; c.height = size.1
        c.sourceRect = pointFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        // The window-alone filter's content is the window itself: its source rect is window-local (the display offset
        // shifted the picture up and left by the window's position, mac-daddy 02:13Z).
        if warm?.independent == true { c.sourceRect = CGRect(origin: .zero, size: pointFrame.size) }
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(fps, 60))))
        c.capturesAudio = false
        c.shouldBeOpaque = false
        c.ignoreShadowsDisplay = true      // the client draws the shadow
        return c
    }

    private func filter() -> SCContentFilter {
        if warm?.independent == true { return SCContentFilter(desktopIndependentWindow: window) }
        return SCContentFilter(display: display, excludingWindows: Array(excluded.values))
    }

    /// The warm pool's low-cost mode (WarmPool, tunables warmScale/warmIndependent): captured at the given (small) size as
    /// is, optionally with the window-alone filter; adoption switches to the stream's own filter and size.
    struct Warm { var independent: Bool }
    var warm: Warm?
    private var adoptedNanos: UInt64 = 0

    /// `others`: every window ScreenCaptureKit lists except this one and its child windows.
    /// Window capture starts in progress (all instances).
    static let starting = AtomicCounter()
    /// One frame now, with exactly the stream's filter and configuration (the same pixels its frames will have), from a
    /// screenshot: ScreenCaptureKit starts window streams one after another (~0.75 s each on mac-daddy, measured: eight
    /// started at once, done one by one), so the stream's first frame can be seconds away (M-FIVE).
    /// `independent`: with the window-alone filter (desktopIndependentWindow) instead of the stream's.
    func snapshot(excluding others: [SCWindow], independent: Bool = false) async -> CVPixelBuffer? {
        let (f, cfg): (SCContentFilter, SCStreamConfiguration) = queue.sync {
            for w in others where w.windowID != windowID { excluded[w.windowID] = w }
            let cfg = configuration()
            if independent { cfg.sourceRect = CGRect(origin: .zero, size: pointFrame.size) }   // window-local (see configuration())
            return (independent ? SCContentFilter(desktopIndependentWindow: window) : filter(), cfg)
        }
        let t0 = Clock.nowNanos()
        guard let sb = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: f, configuration: cfg), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        hostLog("capture \(windowID): \(independent ? "window-alone " : "")snapshot in \(Clock.elapsed(since: t0, now: Clock.nowNanos()) / 1_000_000) ms")
        return pb
    }
    func start(excluding others: [SCWindow], onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) async throws {
        self.onFrame = onFrame
        let (f, cfg, ids, k): (SCContentFilter, SCStreamConfiguration, Set<UInt32>, ConfigKey) = queue.sync {
            for w in others where w.windowID != windowID { excluded[w.windowID] = w }
            return (filter(), configuration(), Set(excluded.keys), key)
        }
        let s = SCStream(filter: f, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        // Timing (M-FIVE): window captures' first frames came ~0.75 s apart; how long each start takes, and how many overlap.
        let t0 = Clock.nowNanos()
        let inFlight = Self.starting.add(1)
        defer { _ = Self.starting.add(-1) }
        try await s.startCapture()
        hostLog("capture \(windowID): startCapture took \(Clock.elapsed(since: t0, now: Clock.nowNanos()) / 1_000_000) ms (\(inFlight) starting at once)")
        queue.sync { stream = s; appliedFilter = ids; appliedConfig = k; needFull = true; apply() }
    }

    /// On `queue`: a running capture changes hands (the warm pool's, taken over by a streamer): frames go to `onFrame` now.
    func adopt(onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) {
        self.onFrame = onFrame; needFull = true; adoptedNanos = Clock.nowNanos()
        if warm != nil { warm = nil; appliedFilter = [UInt32.max]; appliedConfig = nil; edgeOpaque = nil }   // the stream's own filter and size at the next apply
    }

    /// On `queue`: the window's current frame (global points), pixel size and frame interval.
    func follow(pointFrame f: CGRect, width: Int, height: Int, fps: Int) {
        let w = max(2, width) & ~1, h = max(2, height) & ~1
        if f != pointFrame { lastMoveNanos = Clock.nowNanos(); if Self.debug { hostLog("capture \(windowID): follow \(f)") } }
        if w != self.width || h != self.height { edgeOpaque = nil }
        pointFrame = f; self.width = w; self.height = h; self.fps = fps
        apply()
    }

    /// On `queue`: windows to leave out (new ones over the layer). Already excluded ones stay excluded.
    func exclude(_ windows: [SCWindow]) {
        var changed = false
        for w in windows where w.windowID != windowID && excluded[w.windowID] == nil { excluded[w.windowID] = w; changed = true }
        if changed { apply() }
    }
    func isExcluded(_ id: UInt32) -> Bool { excluded[id] != nil }
    var excludedCount: Int { excluded.count }
    /// On `queue`: counters restart (the streamer logs them every 30 s).
    func resetCounts() { frames = 0; droppedMoved = 0; droppedEdge = 0; skippedUnchanged = 0 }

    /// Pushes the desired filter and configuration to the stream, one update at a time, latest wins.
    private func apply() {
        guard let stream else { return }
        let ids = Set(excluded.keys), k = key
        guard ids != appliedFilter || k != appliedConfig else { return }
        if updating { dirtyAgain = true; return }
        updating = true
        let f: SCContentFilter? = ids != appliedFilter ? filter() : nil
        let cfg: SCStreamConfiguration? = k != appliedConfig ? configuration() : nil
        Task { [weak self] in
            var ok = true
            if let cfg { do { try await stream.updateConfiguration(cfg) } catch { ok = false } }
            if let f { do { try await stream.updateContentFilter(f) } catch { ok = false } }
            guard let self else { return }
            self.queue.async {
                self.updating = false
                if ok { if f != nil { self.appliedFilter = ids }; if cfg != nil { self.appliedConfig = k } }
                self.needFull = true
                if self.dirtyAgain || !ok { self.dirtyAgain = false; self.apply() }
            }
        }
    }

    func stop() async {
        let s: SCStream? = queue.sync { let s = stream; stream = nil; return s }
        guard let s else { return }
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw) else { return }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else {
            if !statusLogged, status != .idle { statusLogged = true; hostLog("layer \(windowID): frame status \(statusRaw)") }
            return
        }
        // Captured for the frame the window is at now, at the configured size; otherwise the window is moving or the
        // new configuration is not applied yet, and the frame would show it shifted or scaled.
        let size = captureSize
        guard CVPixelBufferGetWidth(pb) == size.0, CVPixelBufferGetHeight(pb) == size.1 else { droppedMoved += 1; return }
        let sr = (info[.screenRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        if Self.debug { hostLog("capture \(windowID): frame screenRect \(sr.map { "\($0)" } ?? "none") following \(pointFrame) dirty \(((info[.dirtyRects] as? [Any]) ?? []).compactMap { ($0 as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } })") }
        if display.frame.contains(pointFrame), let d = info[.screenRect] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d) {
            guard abs(r.minX - pointFrame.minX) < 0.5, abs(r.minY - pointFrame.minY) < 0.5, abs(r.width - pointFrame.width) < 0.5, abs(r.height - pointFrame.height) < 0.5 else { droppedMoved += 1; needFull = true; return }
        }
        guard edgesHold(pb) else { droppedEdge += 1; needFull = true; return }
        // Unchanged since the last frame passed on (a display stream reports what it redrew).
        if !needFull, let rects = info[.dirtyRects] as? [Any], rects.isEmpty || rects.allSatisfy({ ($0 as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }.map { $0.isEmpty } ?? false }) {
            skippedUnchanged += 1; return
        }
        needFull = false
        frames += 1
        if adoptedNanos > 0 { hostLog("capture \(windowID): first frame \(Clock.elapsed(since: adoptedNanos, now: Clock.nowNanos()) / 1_000_000) ms after adoption"); adoptedNanos = 0 }
        if size.0 == width && size.1 == height { onFrame?(pb, Clock.nowNanos()) }
        else if let out = scaled(pb) { onFrame?(out, Clock.nowNanos()) }
    }

    /// The native-scale capture at the layer's pixel size (alpha kept), from a small pool.
    private func scaled(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        if transfer == nil {
            var t: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t) == noErr, let t else { return nil }
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            transfer = t
        }
        if pool == nil || poolSize != (width, height) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &p)
            pool = p; poolSize = (width, height)
        }
        guard let pool, let transfer else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: pb, to: out) == noErr else { return nil }
        return out
    }

    /// For a window opaque to its edges: all four edge midpoints (outermost pixel) present (the window fills the source rect). Learned
    /// from the first frames; a window whose edges really turn transparent is relearned after a second at rest.
    private var edgeHits = 0
    private func edgesHold(_ pb: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return true }
        let stride = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let a = [base[(h / 2) * stride + 3], base[(h / 2) * stride + (w - 1) * 4 + 3], base[(w / 2) * 4 + 3], base[(h - 1) * stride + (w / 2) * 4 + 3]]
        // The outermost pixel is the window's anti-aliased border (~89 % alpha at 1x): present means ≥ 200.
        let opaque = a.allSatisfy { $0 >= 200 }
        if Self.debug { hostLog("capture \(windowID): edge alpha \(a) learned \(edgeOpaque.map { "\($0)" } ?? "-")") }
        guard let learned = edgeOpaque else { edgeOpaque = opaque; return true }
        // Edges opaque again for a while (a window back from Show Desktop's dimming): checked for a shift again.
        if !learned { edgeHits = opaque ? edgeHits + 1 : 0; if edgeHits > 10 { edgeOpaque = true; edgeHits = 0 }; return true }
        if opaque { edgeMisses = 0; return true }
        if a.allSatisfy({ $0 >= 100 }) { return true }
        edgeMisses += 1
        if edgeMisses > 10, Clock.elapsed(since: lastMoveNanos, now: Clock.nowNanos()) > 1_000_000_000 {
            edgeOpaque = false; edgeMisses = 0
            hostLog("layer \(windowID): edges no longer opaque at rest; frames are not checked for a shift any more")
            return true
        }
        return false
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}


/// A small thread-safe counter.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// Adds `d` and returns the new value.
    func add(_ d: Int) -> Int { lock.lock(); defer { lock.unlock() }; value += d; return value }
}
