import Foundation
import ScreenCaptureKit
import CoreMedia
import IOKit.pwr_mgt
import MirageCore

/// One SCStream on one display, scaled by SCK to the requested size, frames only on change.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Target {
        let display: SCDisplay
        let info: ControlMessage.StreamInfo
        let pixelWidth: Int, pixelHeight: Int
    }

    private var stream: SCStream?
    private let queue: DispatchQueue
    /// (pixel buffer, capture clock, dirty rects in output pixels)
    private var onFrame: ((CVPixelBuffer, UInt64, [PixelRect]) -> Void)?
    private(set) var target: Target?
    var onStop: ((Error?) -> Void)?
    /// Deliver the next frame as fully dirty even if SCK reports no change (a resumed stream diffs it
    /// against the last frame sent before the gap, so whatever changed meanwhile is found).
    var forceNextFrame = false
    /// While a viewer is connected the host's display stays awake (it would otherwise sleep ~90 s
    /// after the wake we trigger, and SCK then delivers nothing).
    private var displayAssertion: IOPMAssertionID = 0

    init(queue: DispatchQueue) { self.queue = queue }

    /// Resolves the display and the stream size (display aspect fitted into the request).
    static func resolve(_ req: ControlMessage.StreamRequest) async throws -> Target {
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        func wanted() -> SCDisplay? { content.displays.first { $0.displayID == (req.displayID ?? CGMainDisplayID()) } }
        if wanted() == nil {
            // Displays asleep: SCK lists none, or only a virtual one (Astropad's) while the physical panels
            // wake. Wake them like a local user would (ARD does the same) and wait for the wanted display.
            var id: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Mirage viewer connected" as CFString, kIOPMUserActiveLocal, &id)
            for _ in 0..<16 where wanted() == nil {
                try await Task.sleep(for: .milliseconds(500))
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
        }
        // Fallback: the largest display listed (never a tiny virtual one if a real panel is there).
        guard let display = wanted() ?? content.displays.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            throw MirageError.transport("no display to capture (displays asleep?)")
        }
        var pw = Double(CGDisplayPixelsWide(display.displayID)), ph = Double(CGDisplayPixelsHigh(display.displayID))
        if pw < 64 || ph < 64 { pw = Double(display.width); ph = Double(display.height) }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let scale = mode.map { Double($0.pixelWidth) / Double($0.width) } ?? 1
        // Fit the display aspect into the requested box; even dimensions keep the encoder happy.
        let aspect = pw / ph
        var w = Double(max(req.width, 64)), h = Double(max(req.height, 64))
        if w / h > aspect { w = h * aspect } else { h = w / aspect }
        w = min(w, pw * scale); h = min(h, ph * scale)   // never upscale beyond native pixels
        if req.snapNative == true, StreamScale.snapsToNative(requestedWidth: w, nativeWidth: pw * scale) { w = pw * scale; h = ph * scale }
        let ew = Int(w) & ~1, eh = Int(h) & ~1
        let name = "display \(display.displayID) (\(display.width)x\(display.height) pt, \(Int(pw))x\(Int(ph)) px)"
        let info = ControlMessage.StreamInfo(width: ew, height: eh, displayID: display.displayID, displayWidth: display.width, displayHeight: display.height,
                                             displayScale: scale, displayName: name)
        return Target(display: display, info: info, pixelWidth: ew, pixelHeight: eh)
    }

    private static func configuration(for t: Target, maxFPS: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = t.pixelWidth; c.height = t.pixelHeight
        // BGRA: the tile path reads pixels and the HEVC encoder accepts it directly. Deeper queue:
        // the streamer retains the previous frame for diffing and the latest for refinement.
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        // Windows captured as their own layers are left out of this stream, and so must their shadows
        // be (a moving window's shadow would otherwise paint the display layer); the client draws shadows.
        c.ignoreShadowsDisplay = true
        c.queueDepth = 6
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(maxFPS, 120))))
        c.capturesAudio = false
        return c
    }

    /// Windows left out of the display capture: the ones captured as their own layers (DESIGN §3.2).
    private(set) var excluded: [SCWindow] = []

    func start(_ req: ControlMessage.StreamRequest, target: Target? = nil, excluding: [SCWindow] = [], onFrame: @escaping (CVPixelBuffer, UInt64, [PixelRect]) -> Void) async throws -> Target {
        let t: Target
        if let target { t = target } else { t = try await Self.resolve(req) }
        self.onFrame = onFrame
        self.target = t
        excluded = excluding
        let filter = try await Self.displayFilter(t.display, excluding: excluding)
        let s = SCStream(filter: filter, configuration: Self.configuration(for: t, maxFPS: req.maxFPS), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        if displayAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Mirage viewer connected" as CFString, &displayAssertion)
        }
        return t
    }

    /// Changes the set of windows left out of the display picture (layers started or stopped). Updates are
    /// applied one at a time, latest wish wins: concurrent `updateContentFilter` calls can finish out of order,
    /// leaving an older (empty) exclusion in force while the host believes the window is excluded (the
    /// suspected cause of the M3.1 ghosts on mac-daddy).
    func requestExcluded(_ windows: [SCWindow], log: @escaping (String) -> Void, applied: (([UInt32]) -> Void)? = nil) {
        filterLock.lock()
        wantedExcluded = windows
        let start = !applying
        applying = true
        filterLock.unlock()
        guard start else { return }
        Task { [weak self] in
            while let self {
                self.filterLock.lock()
                guard let want = self.wantedExcluded else { self.applying = false; self.filterLock.unlock(); return }
                self.wantedExcluded = nil
                self.filterLock.unlock()
                guard let stream = self.stream, let t = self.target else { continue }
                let ids = want.map(\.windowID).sorted()
                if Self.testNoExclude { log("TEST: display exclusion disabled (MIRAGE_TEST_NO_EXCLUDE); would exclude \(ids)"); self.excluded = []; applied?([]); continue }
                do {
                    try await stream.updateContentFilter(Self.displayFilter(t.display, excluding: want))
                    self.excluded = want
                    log("display filter applied: excluding windows \(ids)")
                    applied?(ids)
                } catch { log("display exclusion update failed: \(error)") }
            }
        }
    }
    private let filterLock = NSLock()
    private var wantedExcluded: [SCWindow]? = nil
    private var applying = false
    static let testNoExclude = ProcessInfo.processInfo.environment["MIRAGE_TEST_NO_EXCLUDE"] != nil
    /// Test only: MIRAGE_TEST_ONLY_APP=<bundle ID> puts that app's windows alone in the display picture (everything else
    /// on the display is left out, black), for screenshots of a client against a person's own Mac. Pair it with
    /// MIRAGE_LAYER_APPS naming the same app so no other window becomes a layer. Fails closed: no such app, no capture.
    static let testOnlyApp = ProcessInfo.processInfo.environment["MIRAGE_TEST_ONLY_APP"]

    /// The display picture's filter: the display minus `excluding` (window layers), or under MIRAGE_TEST_ONLY_APP that app only.
    static func displayFilter(_ display: SCDisplay, excluding: [SCWindow]) async throws -> SCContentFilter {
        guard let id = testOnlyApp else { return SCContentFilter(display: display, excludingWindows: excluding) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.bundleIdentifier == id }) else {
            throw MirageError.transport("MIRAGE_TEST_ONLY_APP: \(id) is not running; capturing nothing")
        }
        return SCContentFilter(display: display, including: [app], exceptingWindows: excluding)
    }

    func update(_ req: ControlMessage.StreamRequest) async throws -> Target {
        guard let stream, let old = target else { throw MirageError.transport("not capturing") }
        var t = try await Self.resolve(req)
        if t.display.displayID != old.display.displayID {
            try await stream.updateContentFilter(Self.displayFilter(t.display, excluding: excluded))
        } else {
            t = Target(display: old.display, info: t.info, pixelWidth: t.pixelWidth, pixelHeight: t.pixelHeight)
        }
        try await stream.updateConfiguration(Self.configuration(for: t, maxFPS: req.maxFPS))
        target = t
        return t
    }

    func stop() async {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // dirtyRects are in output pixels (the configured size), not display points.
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var dirty: [PixelRect] = []
        if let rects = attachments.first?[.dirtyRects] as? [Any] {
            for r in rects {
                guard let d = r as? NSDictionary, let rect = CGRect(dictionaryRepresentation: d) else { dirty = [PixelRect(x: 0, y: 0, width: w, height: h)]; break }
                let x0 = max(0, Int(rect.minX.rounded(.down))), y0 = max(0, Int(rect.minY.rounded(.down)))
                let x1 = min(w, Int(rect.maxX.rounded(.up))), y1 = min(h, Int(rect.maxY.rounded(.up)))
                if x1 > x0 && y1 > y0 { dirty.append(PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) }
            }
        } else {
            dirty = [PixelRect(x: 0, y: 0, width: w, height: h)]
        }
        if forceNextFrame { forceNextFrame = false; dirty = [PixelRect(x: 0, y: 0, width: w, height: h)] }
        if dirty.isEmpty { return }   // nothing changed; SCK still delivers these around the first frames
        onFrame?(pb, Clock.nowNanos(), dirty)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}


/// The SCWindow objects ScreenCaptureKit needs for per-window filters, by CGWindow id. Refreshed from
/// `SCShareableContent` (tens of ms, async) when the window list names an id we do not hold.
final class WindowCatalog: @unchecked Sendable {
    private var windows: [UInt32: SCWindow] = [:]
    private var displays: [SCDisplay] = []
    private let lock = NSLock()
    private var refreshing = false
    private var lastRefreshNanos: UInt64 = 0

    func window(_ id: UInt32) -> SCWindow? { lock.lock(); defer { lock.unlock() }; return windows[id] }
    /// Every window ScreenCaptureKit listed at the last refresh (a window layer's capture excludes all but its own).
    var all: [SCWindow] { lock.lock(); defer { lock.unlock() }; return Array(windows.values) }
    /// The display that holds most of `rect` (global points).
    func display(for rect: CGRect) -> SCDisplay? {
        lock.lock(); defer { lock.unlock() }
        return displays.max { a, b in a.frame.intersection(rect).width * a.frame.intersection(rect).height < b.frame.intersection(rect).width * b.frame.intersection(rect).height } ?? displays.first
    }
    /// When the catalog was last refreshed.
    var refreshedNanos: UInt64 { lock.lock(); defer { lock.unlock() }; return lastRefreshNanos }

    /// Refreshes if any of `ids` is unknown and no refresh ran in the last 250 ms; `done` runs after a refresh.
    func ensure(_ ids: [UInt32], done: @escaping @Sendable () -> Void) {
        lock.lock()
        let missing = ids.contains { windows[$0] == nil }
        let now = Clock.nowNanos()
        guard missing, !refreshing, Clock.elapsed(since: lastRefreshNanos, now: now) > 250_000_000 else { lock.unlock(); return }
        refreshing = true; lastRefreshNanos = now
        lock.unlock()
        Task.detached { [self] in
            defer { lock.lock(); refreshing = false; lock.unlock() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            store(content)
            done()
        }
    }
    func refreshNow() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        store(content)
    }
    private func store(_ content: SCShareableContent) {
        lock.lock()
        windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        displays = content.displays
        lastRefreshNanos = Clock.nowNanos()
        lock.unlock()
    }
}
