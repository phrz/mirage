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
    /// False for the warm pool's captures (no viewer: the display may sleep); a streamer adopting one turns it on.
    var keepsDisplayAwake = true

    init(queue: DispatchQueue) { self.queue = queue }

    /// What this stream captures (the compositor model, DESIGN "The compositor model"): the whole display minus the layers
    /// (`display`, the seam design), only the desktop-level windows (`desktop`: wallpaper, desktop icons, widgets; never an
    /// app window), or everything above the normal level (`overlay`: the menu bar, the Dock, menus, popovers, tooltips,
    /// notifications) on a clear background, for a layer of its own on top of the window layers.
    enum Source { case display, desktop, overlay }
    var source: Source = .display

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
        return target(for: display, requested: (req.width, req.height), snapNative: req.snapNative == true)
    }

    /// The stream size for `display`: its aspect fitted into `requested` (nil: native pixels).
    static func target(for display: SCDisplay, requested: (Int, Int)?, snapNative: Bool) -> Target {
        var pw = Double(CGDisplayPixelsWide(display.displayID)), ph = Double(CGDisplayPixelsHigh(display.displayID))
        if pw < 64 || ph < 64 { pw = Double(display.width); ph = Double(display.height) }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let scale = mode.map { Double($0.pixelWidth) / Double($0.width) } ?? 1
        // Fit the display aspect into the requested box, never beyond native pixels; even dimensions keep the encoder happy.
        let (ew, eh) = StreamScale.resolve(requested: requested ?? (Int(pw * scale), Int(ph * scale)), nativePixels: (pw * scale, ph * scale), snapNative: requested == nil || snapNative)
        // (CGDisplayPixelsWide reports points on current macOS; the mode's scale gives the backing pixels.)
        let name = "display \(display.displayID) (\(display.width)x\(display.height) pt, \(Int(pw * scale))x\(Int(ph * scale)) px)"
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
        return try await start(maxFPS: req.maxFPS, target: t, excluding: excluding, onFrame: onFrame)
    }
    final class StartOnce: @unchecked Sendable { private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true } }
    struct StartTimeout: Error, CustomStringConvertible { var seconds: Double; var description: String { "not started after \(seconds) s" } }
    /// `op` with a deadline: past it, StartTimeout is thrown and a result that still comes goes to `late` (to be stopped).
    /// ScreenCaptureKit's start has no timeout of its own: once a display start never returned (Fast 4G run, 15:38Z), and
    /// the stream kept its provisional desktop and had no menu bar or Dock for good.
    static func bounded<T>(seconds: Double, _ op: @escaping () async throws -> T, late: @escaping (T) -> Void) async throws -> T {
        let once = StartOnce()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            Task { do { let v = try await op(); if once.claim() { c.resume(returning: v) } else { late(v) } } catch { if once.claim() { c.resume(throwing: error) } } }
            Task { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))); if once.claim() { c.resume(throwing: StartTimeout(seconds: seconds)) } }
        }
    }

    func start(maxFPS: Int, target t: Target, excluding: [SCWindow] = [], onFrame: @escaping (CVPixelBuffer, UInt64, [PixelRect]) -> Void) async throws -> Target {
        self.onFrame = onFrame
        self.target = t
        excluded = excluding
        let filter = source == .desktop ? try await Self.desktopFilter(t.display) : try await Self.displayFilter(t.display, excluding: excluding)
        let config = configuration(for: t, maxFPS: maxFPS)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        if keepsDisplayAwake { holdDisplayAwake() }
        return t
    }
    private func holdDisplayAwake() {
        if displayAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Mirage viewer connected" as CFString, &displayAssertion)
        }
    }
    /// This source's configuration (the overlay's on a clear background, its menus' shadows kept).
    private func configuration(for t: Target, maxFPS: Int) -> SCStreamConfiguration {
        let config = Self.configuration(for: t, maxFPS: maxFPS)
        if source == .overlay {
            // Clear where no overlay window is (the window layers show through), and the menus' own shadows kept.
            config.backgroundColor = CGColor.clear
            config.ignoreShadowsDisplay = false
        }
        return config
    }

    /// A running capture changes hands (the warm pool's, taken over by a streamer, WarmPool): frames go to `onFrame`, the
    /// display is kept awake, and the stream is reconfigured for `req` (size, frame rate). Returns the stream's target.
    func adopt(_ req: ControlMessage.StreamRequest, target t: Target, onFrame: @escaping (CVPixelBuffer, UInt64, [PixelRect]) -> Void) async throws -> Target {
        queue.sync { self.onFrame = onFrame; self.forceNextFrame = true; self.target = t }
        keepsDisplayAwake = true; holdDisplayAwake()
        guard let stream else { throw MirageError.transport("warm capture not running") }
        try await stream.updateConfiguration(configuration(for: t, maxFPS: req.maxFPS))
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
    /// What `includeMenuBar` was before displayFilter set it (nil before the first filter, or before macOS 14.2): logged by the
    /// sharpness knob.
    nonisolated(unsafe) static var menuBarDefault: Bool?
    /// Test knob MIRAGE_TEST_MENUBAR_IN_DESKTOP=1: the menu bar's window (level 24) goes in the desktop capture, composited
    /// over the wallpaper, and out of the overlay: whether the menu titles' vibrancy, lost when the bar is captured alone over
    /// transparency, comes back (check 5: titles at 0.03-0.23 of the screen in the host's model, status items exact).
    static let testMenuBarInDesktop = ProcessInfo.processInfo.environment["MIRAGE_TEST_MENUBAR_IN_DESKTOP"] == "1"
    static let menuBarLevel = 24

    /// The desktop alone: the display's desktop-level windows (window layer below zero: the wallpaper, the desktop icons and
    /// widgets). No app window can ever be in it.
    static func desktopFilter(_ display: SCDisplay) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let desk = content.windows.filter { ($0.windowLayer < 0 || testMenuBarInDesktop && $0.windowLayer == menuBarLevel) && $0.frame.intersects(display.frame) }
        guard !desk.isEmpty else { throw MirageError.transport("no desktop-level windows on display \(display.displayID)") }
        return SCContentFilter(display: display, including: desk)
    }
    /// Re-reads the desktop-level windows (a widget added or removed) and applies them; desktop sources only.
    func refreshDesktop(log: @escaping (String) -> Void) {
        guard source == .desktop, let stream, let t = target else { return }
        Task {
            do { try await stream.updateContentFilter(Self.desktopFilter(t.display)) } catch { log("desktop filter update failed: \(error)") }
        }
    }

    /// The display picture's filter: the display minus `excluding` (window layers), or under MIRAGE_TEST_ONLY_APP that app only.
    static func displayFilter(_ display: SCDisplay, excluding: [SCWindow]) async throws -> SCContentFilter {
        guard let id = testOnlyApp else {
            let f = SCContentFilter(display: display, excludingWindows: excluding)
            // The menu bar's own content (the frontmost app's menu titles) is not a window in the list: without this the
            // overlay held the status items and the bar but not the titles (check 5: menu-bar left at 0.03-0.23 of the screen
            // in the host's own model, the viewer showing the connect's half-size still there for good: phrz's "permablur").
            if #available(macOS 14.2, *) { menuBarDefault = f.includeMenuBar; f.includeMenuBar = true }
            return f
        }
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
        try await stream.updateConfiguration(configuration(for: t, maxFPS: req.maxFPS))
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
