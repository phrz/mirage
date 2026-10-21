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
/// while the display sleeps. The desktop and overlay display captures are not warmed yet (they start once per connect).
public final class WarmPool: @unchecked Sendable {
    public static let shared = WarmPool()
    /// Everything here runs on the host's shared queue (the streamers' too), so an adopted capturer stays on its queue.
    let queue = MacDesktopStreamer.hostQueue
    private struct Entry { var cap: WindowCapturer; var last: CVPixelBuffer? }
    private var entries: [UInt32: Entry] = [:]
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

    /// On AC power (always, on a Mac with no battery).
    static func onAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    private func enabled() -> Bool {
        Tunables.load(from: (try? Store())?.url("tunables.json")).tunables[.warmCapture] >= 0.5
    }

    /// The pool's state, for the log line a stream start writes.
    var summary: String { "\(entries.count) warm, \(entries.values.filter { $0.last != nil }.count) with a frame" }

    private func dropAll(_ why: String) {
        guard !entries.isEmpty else { return }
        let caps = entries.values.map(\.cap)
        entries = [:]
        for c in caps { Task { await c.stop() } }
        log?("warm host: dropped \(caps.count) window captures (\(why))")
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
                defer { self.refreshing = false }
                guard self.activeStreams == 0, let content, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return }
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
