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
        lastRequested = excluding
        let gen = CurtainExclusion.generation
        let filter: SCContentFilter
        if Self.filterPlan(source: source, locked: locked) == .wholeDisplay { filter = try await Self.displayFilter(t.display, excluding: []); clearDesktopExcluded() }
        else if source == .desktop { let (f, ex) = try await Self.desktopFilterAndExcluded(t.display); filter = f; setDesktopExcluded(ex) }
        else { filter = try await Self.displayFilter(t.display, excluding: excluding) }
        let config = configuration(for: t, maxFPS: maxFPS)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        let plan = Self.filterPlan(source: source, locked: locked)
        appliedLocked = locked
        appliedKey = FilterKey(plan: plan, excluded: plan == .displayExcludingLayers ? excluding.map(\.windowID).sorted() : [], curtainGen: gen)
        curtainApplied(gen, ok: true)
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
    /// A rect in stream pixels as display points (a stream's sourceRect).
    static func points(_ r: PixelRect, _ t: Target) -> CGRect {
        let k = Double(t.display.width) / Double(max(1, t.pixelWidth))
        return CGRect(x: Double(r.x) * k, y: Double(r.y) * k, width: Double(r.width) * k, height: Double(r.height) * k)
    }
    /// One still of a rect of the unfiltered display (tight BGRA): the menu bar's and the Dock's bands (DesktopStreamer.Band).
    static func bandShot(_ t: Target, _ r: PixelRect) async -> [UInt8]? {
        let c = SCStreamConfiguration()
        c.width = r.width; c.height = r.height; c.showsCursor = false; c.sourceRect = points(r, t)
        let gen = CurtainExclusion.generation
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: t.display, excludingWindows: CurtainExclusion.windows + CurtainExclusion.foreign), configuration: c),
              !CurtainExclusion.stale(gen) else { return nil }
        var px = [UInt8](repeating: 0, count: r.width * r.height * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: r.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height)); return true
        }
        return ok ? px : nil
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

    /// Changes the set of windows left out of the display picture (layers started or stopped). Every filter change of this
    /// capture (this, a lock switch, the curtain's re-apply, a desktop refresh) goes through one pump (`pumpFilter`): one
    /// update at a time, built from the latest state when it is applied, so concurrent `updateContentFilter` calls can never
    /// finish out of order (an older, empty exclusion in force while the host believes the window excluded: the M3.1 ghosts;
    /// an unlock's desktop filter landing after the fresh picture's whole-display one: phrz on 537, "everything but desktop
    /// faded out").
    /// Every caller's `applied` runs once a filter at least as new as its wish is in force (a call while the loop runs used to
    /// lose its closure: a layer's exclusion applied but never acknowledged, the layer later given up as unexcludable).
    func requestExcluded(_ windows: [SCWindow], log: @escaping (String) -> Void, applied: (([UInt32]) -> Void)? = nil) {
        filterLock.lock()
        wantedExcluded = windows
        lastRequested = windows
        if let applied { wantedApplied.append(applied) }
        filterDirty = true
        filterLock.unlock()
        pumpFilter(log: log)
    }
    /// What a filter is built from (the latest state): skipped when the one in force was built from the same.
    struct FilterKey: Equatable { var plan: FilterPlan; var excluded: [UInt32]; var curtainGen: Int }
    private var appliedKey: FilterKey?
    /// The lock state the filter in force was built for.
    private var appliedLocked = false
    private var filterDirty = false
    private var forceRefresh = false
    private var lockDone: [@Sendable () -> Void] = []
    private var refreshDone: [(Bool) -> Void] = []
    private func pumpFilter(log: @escaping (String) -> Void) {
        filterLock.lock()
        let start = !applying
        applying = true
        filterLock.unlock()
        guard start else { return }
        Task { [weak self] in
            while let self {
                self.filterLock.lock()
                guard self.filterDirty, let stream = self.stream, let t = self.target else {
                    let (ld, rd) = (self.lockDone, self.refreshDone); self.lockDone = []; self.refreshDone = []
                    if self.stream == nil { self.switchingLock = false }
                    self.applying = false; self.filterLock.unlock()
                    ld.forEach { $0() }; rd.forEach { $0(true) }
                    return
                }
                self.filterDirty = false
                let want = self.wantedExcluded ?? self.lastRequested ?? self.excluded
                self.wantedExcluded = nil
                let callbacks = self.wantedApplied; self.wantedApplied = []
                let (ld, rd) = (self.lockDone, self.refreshDone); self.lockDone = []; self.refreshDone = []
                let locked = self.locked, force = self.forceRefresh; self.forceRefresh = false
                self.filterLock.unlock()
                let ids = want.map(\.windowID).sorted()
                let gen = CurtainExclusion.generation
                let plan = Self.filterPlan(source: self.source, locked: locked)
                let key = FilterKey(plan: plan, excluded: plan == .displayExcludingLayers ? ids : [], curtainGen: gen)
                if plan == .displayExcludingLayers, Self.testNoExclude {
                    log("TEST: display exclusion disabled (MIRAGE_TEST_NO_EXCLUDE); would exclude \(ids)"); self.excluded = []; callbacks.forEach { $0([]) }
                    ld.forEach { $0() }; rd.forEach { $0(true) }; continue
                }
                if !force, key == self.appliedKey, locked == self.appliedLocked {
                    if plan == .displayExcludingLayers { self.excluded = want }
                    self.filterLock.lock(); self.switchingLock = false; self.filterLock.unlock()
                    callbacks.forEach { $0(ids) }; self.curtainApplied(gen, ok: true); ld.forEach { $0() }; rd.forEach { $0(true) }
                    continue
                }
                do {
                    let f: SCContentFilter
                    var desktopEx: Set<UInt32>?
                    switch plan {
                    case .wholeDisplay: f = try await Self.displayFilter(t.display, excluding: [])
                    case .desktop: let (df, ex) = try await Self.desktopFilterAndExcluded(t.display); f = df; desktopEx = ex
                    case .displayExcludingLayers: f = try await Self.displayFilter(t.display, excluding: want)
                    }
                    // The lock state moved on while the filter was built (the desktop's reads the catalog): not applied; the next
                    // pass builds the one wanted now (539: an unlock's desktop filter landed after the whole display was wanted).
                    self.filterLock.lock()
                    if self.locked != locked {
                        self.wantedApplied.insert(contentsOf: callbacks, at: 0); if self.wantedExcluded == nil { self.wantedExcluded = want }
                        self.lockDone.insert(contentsOf: ld, at: 0); self.refreshDone.insert(contentsOf: rd, at: 0); self.filterDirty = true
                        self.filterLock.unlock()
                        continue
                    }
                    self.filterLock.unlock()
                    // Bounded: an update that never returns must not hold every later one back (applying stays true). The bound
                    // runs once ScreenCaptureKit is ours (SCKGate): queued behind window starts, updates timed out at 3 s without
                    // ever being tried (mac-daddy on 537: "not started after 3.0 s", the curtain's re-apply failing).
                    try await SCKGate.shared.run(urgent: true) { try await Self.bounded(seconds: 3, { try await stream.updateContentFilter(f) }, late: { _ in }) }
                    self.failures = 0
                    self.appliedKey = key
                    switch plan {
                    case .wholeDisplay: self.clearDesktopExcluded()
                    case .desktop: if let desktopEx { self.setDesktopExcluded(desktopEx) }
                    case .displayExcludingLayers: self.excluded = want; log("display filter applied: excluding windows \(ids)")
                    }
                    if locked != self.appliedLocked {
                        self.appliedLocked = locked
                        log("\(self.source) capture: \(locked ? "screen locked: the whole display (the lock screen)" : "screen unlocked: its own filter again")")
                        self.queue.async { self.forceNextFrame = true }
                    }
                    self.filterLock.lock(); if self.locked == self.appliedLocked { self.switchingLock = false }; self.filterLock.unlock()
                    callbacks.forEach { $0(ids) }
                    self.curtainApplied(gen, ok: true)
                    ld.forEach { $0() }; rd.forEach { $0(true) }
                } catch {
                    log("\(self.source) filter update failed (\(plan)): \(error)")
                    // Kept for the next pass, which re-applies (a curtain waiter hears the failure and retries itself).
                    self.filterLock.lock(); self.wantedApplied.insert(contentsOf: callbacks, at: 0); if self.wantedExcluded == nil { self.wantedExcluded = want }
                    self.filterDirty = true; self.lockDone.insert(contentsOf: ld, at: 0); self.filterLock.unlock()
                    self.curtainApplied(gen, ok: false)
                    rd.forEach { $0(false) }
                    // Backing off: 0.2, 0.4 … 3.2 s between attempts, not a retry every 200 ms forever.
                    self.failures = min(self.failures + 1, 5)
                    try? await Task.sleep(for: .milliseconds(100 << self.failures))
                }
            }
        }
    }
    private let filterLock = NSLock()
    private var wantedExcluded: [SCWindow]? = nil
    private var wantedApplied: [([UInt32]) -> Void] = []
    private var lastRequested: [SCWindow]? = nil
    private var applying = false
    private var failures = 0

    // MARK: The curtain's exclusion (DESIGN §3.12)

    /// The curtain generation (CurtainExclusion.generation) the filter in force was built with.
    private(set) var curtainGen = 0
    private(set) var curtainDropped = 0
    private var curtainWaiters: [(gen: Int, done: (Bool) -> Void)] = []
    private func curtainApplied(_ gen: Int, ok: Bool) {
        filterLock.lock()
        if ok { curtainGen = max(curtainGen, gen) }
        let ready = curtainWaiters.filter { !ok || $0.gen <= curtainGen }
        curtainWaiters.removeAll { w in !ok || w.gen <= curtainGen }
        filterLock.unlock()
        ready.forEach { $0.done(ok) }
    }
    /// Re-applies the filter in force with the curtain's current windows left out, the same wish as before (the latest one),
    /// and calls `done(true)` once a filter with curtain generation `gen` or newer is in force (`false` on a failure: the
    /// caller retries). A display/overlay source re-pushes its last exclusion list; a desktop source rebuilds its filter.
    func refilter(curtainGen gen: Int, log: @escaping (String) -> Void, done: @escaping (Bool) -> Void) {
        guard stream != nil, target != nil else { done(true); return }   // not capturing: nothing can show the curtain
        if source == .desktop {
            refreshDesktop(log: log, done: done)
            return
        }
        filterLock.lock()
        if curtainGen >= gen { filterLock.unlock(); done(true); return }
        curtainWaiters.append((gen, done))
        let want = wantedExcluded ?? lastRequested ?? excluded
        filterLock.unlock()
        requestExcluded(want, log: log)
    }
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
    static let testDesktopInclude = ProcessInfo.processInfo.environment["MIRAGE_TEST_DESKTOP_INCLUDE"] == "1"
    /// Desktop sources: the windows the running filter leaves out (nil: the include filter, nothing to wait for).
    private let excludedLock = NSLock()
    private var _desktopExcluded: Set<UInt32>? = nil
    var desktopExcluded: Set<UInt32>? { excludedLock.lock(); defer { excludedLock.unlock() }; return _desktopExcluded }
    private func setDesktopExcluded(_ s: Set<UInt32>) { excludedLock.lock(); _desktopExcluded = Self.testDesktopInclude ? nil : s; excludedLock.unlock() }
    private func clearDesktopExcluded() { excludedLock.lock(); _desktopExcluded = nil; excludedLock.unlock() }

    // MARK: The locked screen (phrz, 2026-10-28)

    /// What a capture's filter is: the whole display (minus the curtain), the desktop alone, or the display minus its window
    /// layers. While the host's screen is locked it is always the whole display, whatever the source: the lock screen is
    /// what the viewer must see, never the desktop beneath it (a desktop source showed the wallpaper and Finder's icons
    /// behind mac-daddy's lock screen). Pure, for tests.
    enum FilterPlan: Equatable { case wholeDisplay, desktop, displayExcludingLayers }
    static func filterPlan(source: Source, locked: Bool) -> FilterPlan {
        if locked { return .wholeDisplay }
        return source == .desktop ? .desktop : .displayExcludingLayers
    }
    private(set) var locked = false
    /// Between a lock switch's start and its filter being in force: frames are dropped (one from the old filter would show
    /// the desktop beneath the lock screen, or the lock screen after the unlock).
    private var switchingLock = false
    private(set) var lockDropped = 0
    /// Before `start`: the host is locked already, so the first filter is the whole display.
    func presetLocked(_ on: Bool) { filterLock.lock(); locked = on; filterLock.unlock() }
    /// Switches to the whole display while locked, back to this source's own filter on unlock; the first frame after it is
    /// delivered whole (`forceNextFrame`). `done` once the filter is in force (or the switch failed).
    func setLocked(_ on: Bool, log: @escaping (String) -> Void, done: (@Sendable () -> Void)? = nil) {
        filterLock.lock()
        let changed = locked != on
        locked = on
        switchingLock = stream != nil && locked != appliedLocked
        if changed { filterDirty = true }
        if let done { if changed || applying { lockDone.append(done) } }
        let now = !(changed || applying)
        filterLock.unlock()
        if now { done?() }
        if changed { pumpFilter(log: log) }
    }

    /// The desktop alone: the display minus every window at the normal level or above, from one catalog sample (the window
    /// ids it leaves out are kept in `desktopExcluded`; the streamer drops desktop frames while a window it shows is not among
    /// them, until the filter catches up). Including the desktop-level windows by name instead left Finder's desktop icons
    /// out (their window listed, captured empty: check 5, 2026-10-24, the top-right cells at 0.16-0.25 of the screen).
    /// MIRAGE_TEST_DESKTOP_INCLUDE=1: the include filter.
    static func desktopFilter(_ display: SCDisplay) async throws -> SCContentFilter { try await desktopFilterAndExcluded(display).0 }
    static func desktopFilterAndExcluded(_ display: SCDisplay) async throws -> (SCContentFilter, Set<UInt32>) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let desk = content.windows.filter { ($0.windowLayer < 0 || testMenuBarInDesktop && $0.windowLayer == menuBarLevel) && $0.frame.intersects(display.frame) }
        guard !desk.isEmpty else { throw MirageError.transport("no desktop-level windows on display \(display.displayID)") }
        if testDesktopInclude { return (SCContentFilter(display: display, including: desk), []) }
        let above = CurtainExclusion.adding(to: content.windows.filter { $0.windowLayer >= 0 })   // (the curtain is above 0 too; listed or not)
        return (SCContentFilter(display: display, excludingWindows: above), Set(above.map(\.windowID)))
    }
    /// Re-reads the desktop-level windows (a widget added or removed) and applies them; desktop sources only.
    func refreshDesktop(log: @escaping (String) -> Void, done: ((Bool) -> Void)? = nil) {
        guard source == .desktop, stream != nil, target != nil else { done?(true); return }
        filterLock.lock(); filterDirty = true; forceRefresh = true; if let done { refreshDone.append(done) }; filterLock.unlock()
        pumpFilter(log: log)
    }

    /// The display picture's filter: the display minus `excluding` (window layers), or under MIRAGE_TEST_ONLY_APP that app only.
    static func displayFilter(_ display: SCDisplay, excluding: [SCWindow]) async throws -> SCContentFilter {
        guard let id = testOnlyApp else {
            let f = SCContentFilter(display: display, excludingWindows: CurtainExclusion.adding(to: excluding) + CurtainExclusion.foreign)
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
        // The curtain (DESIGN §3.12): while it is up, nothing from a filter built before its windows were left out goes on.
        if CurtainExclusion.active { filterLock.lock(); let stale = curtainGen < CurtainExclusion.generation; filterLock.unlock(); if stale { curtainDropped += 1; return } }
        filterLock.lock(); let switching = switchingLock; filterLock.unlock()
        if switching { lockDropped += 1; return }
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
        // Another miraged's curtain (a test instance's): left out of this process's display and overlay pictures as well.
        let me = getpid()
        let foreign = content.windows.filter { $0.title == Curtain.windowTitle && $0.owningApplication?.processID != me }
        if Set(foreign.map(\.windowID)) != Set(CurtainExclusion.foreign.map(\.windowID)) {
            CurtainExclusion.setForeign(foreign)
            DispatchQueue.main.async { NotificationCenter.default.post(name: Curtain.windowsChanged, object: nil) }
        }
    }
}
