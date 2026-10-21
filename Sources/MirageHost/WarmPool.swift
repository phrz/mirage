import Foundation
import ScreenCaptureKit
import CoreVideo
import MirageCore
import IOKit.ps

/// "Warm host" (DESIGN M-FIVE): while nobody is connected, the visible windows' captures keep running at 1 fps with exactly
/// the filter a stream uses, each with its latest frame in memory. ScreenCaptureKit starts window captures one after
/// another (~0.75 s each, snapshots included: measured on mac-daddy), so a connect that starts them waits ~4-6 s for its
/// last window; a warm host hands its streamer running captures and their frames at once.
/// Privacy: frames are held in memory only, never written anywhere, and everything is dropped while the screen is locked.
/// Tunable `warmCapture` (host tunables.json; default on): a Mac on battery never warms (laptops on AC only); nothing runs
/// while the display sleeps. In the compositor model the desktop and overlay display captures are warmed too (first).
public final class WarmPool: @unchecked Sendable {
    public static let shared = WarmPool()
    /// Everything here runs on the host's shared queue (the streamers' too), so an adopted capturer stays on its queue.
    let queue = MacDesktopStreamer.hostQueue
    private struct Entry { var cap: WindowCapturer; var last: CVPixelBuffer? }
    private var entries: [UInt32: Entry] = [:]
    private struct DisplayEntry { var cap: ScreenCapturer; var displayID: UInt32; var last: CVPixelBuffer? }
    /// The compositor model's display captures: the desktop alone and the overlay (DesktopStreamer).
    private var desk: DisplayEntry?, overlay: DisplayEntry?
    private var activeStreams = 0
    private var timer: DispatchSourceTimer?
    private var refreshing = false
    private var log: (@Sendable (String) -> Void)?
    static let maxWindows = 12

    /// Starts the upkeep (every 3 s: the visible windows, the lock). Idempotent.
    public func start(log: @escaping @Sendable (String) -> Void) {
        queue.async {
            guard self.timer == nil else { return }
            self.log = log
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 2, repeating: 3)
            t.setEventHandler { [weak self] in self?.refresh() }
            t.resume()
            self.timer = t
        }
    }

    /// On the host queue. A stream started: it takes over the captures it needs; the rest wait until it ends.
    func streamStarted() { activeStreams += 1 }
    /// On the host queue. A stream stopped or was suspended: warming resumes at the next refresh.
    func streamStopped() { activeStreams = max(0, activeStreams - 1) }

    /// On the host queue. The running capture for `windowID` (the streamer adopts it and reconfigures it for its layer) and
    /// its latest frame, at the native scale the pool captures at.
    func take(_ windowID: UInt32) -> (WindowCapturer, CVPixelBuffer?)? {
        guard let e = entries.removeValue(forKey: windowID) else { return nil }
        e.cap.onStop = nil
        return (e.cap, e.last)
    }

    /// On the host queue. The running desktop or overlay capture of `displayID` and its latest frame.
    func takeDisplay(_ source: ScreenCapturer.Source, displayID: UInt32) -> (ScreenCapturer, CVPixelBuffer?)? {
        let e = source == .overlay ? overlay : desk
        guard let e else { return nil }
        if source == .overlay { overlay = nil } else { desk = nil }
        guard e.displayID == displayID else { Task { await e.cap.stop() }; return nil }
        e.cap.onStop = nil
        return (e.cap, e.last)
    }

    /// On AC power (always, on a Mac with no battery).
    static func onAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    private func enabled() -> Bool {
        Tunables.load(from: (try? Store())?.url("tunables.json")).tunables[.warmCapture] >= 0.5
    }

    /// The pool's state, for the log line a stream start writes.
    var summary: String { "\(entries.count) windows warm, \(entries.values.filter { $0.last != nil }.count) with a frame; desktop \(desk == nil ? "cold" : desk?.last == nil ? "starting" : "warm"), overlay \(overlay == nil ? "cold" : overlay?.last == nil ? "starting" : "warm")" }

    private func dropAll(_ why: String) {
        let displays = [desk?.cap, overlay?.cap].compactMap { $0 }
        desk = nil; overlay = nil
        for c in displays { Task { await c.stop() } }
        guard !entries.isEmpty || !displays.isEmpty else { return }
        let caps = entries.values.map(\.cap)
        entries = [:]
        for c in caps { Task { await c.stop() } }
        log?("warm host: dropped \(caps.count) window captures and \(displays.count) display captures (\(why))")
        lastSummary = ""
    }
    private var lastSummary = ""

    /// On the host queue: the desktop or overlay capture, started if missing (the frames it delivers kept as its latest).
    private func warmDisplay(_ source: ScreenCapturer.Source, _ display: SCDisplay, excluding: [SCWindow]) {
        let existing = source == .overlay ? overlay : desk
        if let existing, existing.displayID == display.displayID {
            if source == .overlay { existing.cap.requestExcluded(excluding, log: { _ in }) }
            return
        }
        let cap = ScreenCapturer(queue: queue)
        cap.source = source
        cap.keepsDisplayAwake = false
        let e = DisplayEntry(cap: cap, displayID: display.displayID, last: nil)
        if source == .overlay { overlay = e } else { desk = e }
        let t = ScreenCapturer.target(for: display, requested: nil, snapNative: true)
        func mine() -> Bool { (source == .overlay ? self.overlay : self.desk)?.cap === cap }
        cap.onStop = { [weak self] _ in self?.queue.async { guard let self, mine() else { return }; if source == .overlay { self.overlay = nil } else { self.desk = nil } } }
        Task { [weak self] in
            do {
                _ = try await cap.start(maxFPS: 1, target: t, excluding: excluding) { [weak self] pb, _, _ in
                    guard let self, mine() else { return }
                    if source == .overlay { self.overlay?.last = pb } else { self.desk?.last = pb }
                }
            } catch {
                self?.queue.async { guard let self, mine() else { return }; if source == .overlay { self.overlay = nil } else { self.desk = nil } }
                self?.log?("warm host: \(source) capture failed: \(error)")
            }
        }
    }

    private func refresh() {
        guard !refreshing else { return }
        if activeStreams > 0 { return }                       // the streamer owns the captures now
        if !enabled() { dropAll("warmCapture off"); return }
        if InputInjector.consoleLocked() { dropAll("screen locked"); return }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { dropAll("display asleep"); return }
        if !Self.onAC() { dropAll("on battery"); return }
        refreshing = true
        Task { [weak self] in
            guard let self else { return }
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            self.queue.async {
                defer {
                    self.refreshing = false
                    if self.summary != self.lastSummary { self.lastSummary = self.summary; self.log?("warm host: \(self.summary)") }
                }
                guard self.activeStreams == 0, let content, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return }
                if MacDesktopStreamer.compositorWanted() {
                    self.warmDisplay(.desktop, display, excluding: [])
                    self.warmDisplay(.overlay, display, excluding: MacDesktopStreamer.overlayExclusion(content.windows, display))
                } else if self.desk != nil || self.overlay != nil {
                    for c in [self.desk?.cap, self.overlay?.cap].compactMap({ $0 }) { Task { await c.stop() } }
                    self.desk = nil; self.overlay = nil
                }
                let normals = content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 32 && $0.frame.height >= 32 && $0.frame.intersects(display.frame) }
                let keep = Array(normals.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }.prefix(Self.maxWindows))
                let keepIDs = Set(keep.map(\.windowID))
                for (id, e) in self.entries where !keepIDs.contains(id) { self.entries[id] = nil; Task { await e.cap.stop() } }
                // The display's native scale: the capture is taken there in any case (WindowCapturer.nativeScale), so no scaling.
                let pxPerPoint = CGDisplayCopyDisplayMode(display.displayID).map { $0.width > 0 ? Double($0.pixelWidth) / Double($0.width) : 2 } ?? 2
                for w in keep where self.entries[w.windowID] == nil {
                    let width = Int((w.frame.width * pxPerPoint).rounded()), height = Int((w.frame.height * pxPerPoint).rounded())
                    let cap = WindowCapturer(window: w, display: display, pointFrame: w.frame, width: width, height: height, fps: 1, queue: self.queue)
                    self.entries[w.windowID] = Entry(cap: cap, last: nil)
                    let others = content.windows.filter { $0.windowID != w.windowID }
                    let id = w.windowID
                    cap.onStop = { [weak self] _ in self?.queue.async { if self?.entries[id]?.cap === cap { self?.entries[id] = nil } } }
                    Task { [weak self] in
                        do {
                            try await cap.start(excluding: others) { [weak self] pb, _ in
                                // On the host queue (the capturer's): the latest frame, while the pool still holds it.
                                if let self, self.entries[id]?.cap === cap { self.entries[id]?.last = pb }
                            }
                        } catch { self?.queue.async { if self?.entries[id]?.cap === cap { self?.entries[id] = nil } } }
                    }
                }
            }
        }
    }
}
