import Foundation
import ScreenCaptureKit
import CoreMedia
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

    init(window: SCWindow, display: SCDisplay, pointFrame: CGRect, width: Int, height: Int, fps: Int, queue: DispatchQueue) {
        self.window = window; self.display = display; windowID = window.windowID
        self.pointFrame = pointFrame
        self.width = max(2, width) & ~1; self.height = max(2, height) & ~1; self.fps = fps; self.queue = queue
    }

    private var key: ConfigKey { ConfigKey(w: width, h: height, fps: fps, rect: pointFrame) }

    private func configuration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = width; c.height = height
        c.sourceRect = pointFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
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
        SCContentFilter(display: display, excludingWindows: Array(excluded.values))
    }

    /// `others`: every window ScreenCaptureKit lists except this one and its child windows.
    func start(excluding others: [SCWindow], onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) async throws {
        self.onFrame = onFrame
        let (f, cfg, ids, k): (SCContentFilter, SCStreamConfiguration, Set<UInt32>, ConfigKey) = queue.sync {
            for w in others where w.windowID != windowID { excluded[w.windowID] = w }
            return (filter(), configuration(), Set(excluded.keys), key)
        }
        let s = SCStream(filter: f, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        queue.sync { stream = s; appliedFilter = ids; appliedConfig = k; needFull = true; apply() }
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
        guard CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height else { droppedMoved += 1; return }
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
        onFrame?(pb, Clock.nowNanos())
    }

    /// For a window opaque to its edges: all four edge midpoints (outermost pixel) present (the window fills the source rect). Learned
    /// from the first frames; a window whose edges really turn transparent is relearned after a second at rest.
    private func edgesHold(_ pb: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return true }
        let stride = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let a = [base[(h / 2) * stride + 3], base[(h / 2) * stride + (w - 1) * 4 + 3], base[(w / 2) * 4 + 3], base[(h - 1) * stride + (w / 2) * 4 + 3]]
        // The outermost pixel is the window's anti-aliased border (~89 % alpha at 1x): present means ≥ 200.
        let opaque = a.allSatisfy { $0 >= 200 }
        if Self.debug { hostLog("capture \(windowID): edge alpha \(a) learned \(edgeOpaque.map { "\($0)" } ?? "-")") }
        guard let learned = edgeOpaque else { edgeOpaque = opaque; return true }
        if !learned || opaque { edgeMisses = 0; return true }
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
