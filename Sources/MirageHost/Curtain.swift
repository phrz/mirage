import Foundation
import AppKit
import CoreImage
import ScreenCaptureKit
import MirageCore
import Synchronization

/// The curtain (DESIGN §3.12): while a remote session streams, the host's own screens show what looks like a lock screen (the
/// blurred desktop, the app icon, "This Mac is in use remotely", "Click to log in"), left out of every capture, so the
/// remote person never sees it. Nothing local is blocked beyond the input that triggers the lock: the windows ignore the
/// mouse, and the first genuine local click, key or scroll (a hardware event, untagged) locks the Mac for real. Someone at
/// the Mac then signs in as they always would; the remote person unlocks through Mirage and the curtain comes back.
///
/// Never reaching the stream rests on three things: every capture filter leaves out `CurtainExclusion.windows`; every capture
/// drops its frames while its filter predates the curtain's current generation (ScreenCapturer / WindowCapturer); and the
/// curtain stays invisible (alpha 0) until every streaming session has acknowledged filters with that generation.
public final class Curtain: @unchecked Sendable {
    public static let shared = Curtain()

    /// Posted when the curtain's windows change (the generation in `object`): every streamer re-applies its capture filters
    /// and acknowledges (`acknowledge(_:generation:)`).
    public static let windowsChanged = Notification.Name("MirageCurtainWindowsChanged")
    /// Whether this process may show a curtain at all: off for test instances (`serve --no-local-control`) unless
    /// MIRAGE_TEST_CURTAIN=1, so a passive test run never curtains (or locks) the Mac someone is using. Set by miraged.
    nonisolated(unsafe) public static var allowed = true
    /// The curtain windows' title, so any miraged's curtain is recognisable (WindowTracker leaves them out of window lists).
    public static let windowTitle = "Mirage Curtain"

    private let log: (String) -> Void = { hostLog($0) }
    // All of the following on the main queue.
    private var machine = CurtainLogic.Machine()
    private var windows: [NSWindow] = []
    private var generation = 0
    /// Streaming sessions and the curtain generation each has acknowledged (its filters leave the curtain out).
    private var acked: [String: Int] = [:]
    private var lockTimer: DispatchSourceTimer?
    private var screenLayout: [CGRect] = []
    private var lockRequested: UInt64 = 0
    private var retry: DispatchWorkItem?

    // MARK: Sessions

    /// A client's stream started or resumed, before its captures are built (the streamer then acknowledges each curtain
    /// generation). `enabled`: the host's `curtain` tunable.
    /// `curtain`: the host's Curtain setting (and the tunable); `lockWhenFinished`: lock the Mac when the last session ends.
    /// Sessions are tracked either way (the lock and who signed in matter for both), never in a test instance.
    /// A resumed session keeps the settings it began with; a new one takes these.
    public func sessionBegan(_ id: String, curtain: Bool, lockWhenFinished: Bool) {
        DispatchQueue.main.async {
            guard Self.allowed else { return }
            self.acked[id] = 0
            self.machine.sessionBegan(id, .init(curtain: curtain, lockWhenFinished: lockWhenFinished), now: Clock.nowNanos())
            self.startWatchingLock()
            self.update(reason: "session \(id) streaming")
            // A session joining a curtain already up: invisible until it, too, has acknowledged.
            if !self.windows.isEmpty, CurtainExclusion.generation == self.generation { self.setVisible(false); self.publish(self.generation) }
        }
    }
    /// An agent's session (DESIGN §3.13: an unlock an agent asked for): like a streaming session that captures nothing, so
    /// no acknowledgement is waited for.
    public func agentSessionBegan(_ id: String, curtain: Bool, lockWhenFinished: Bool) {
        DispatchQueue.main.async {
            guard Self.allowed else { return }
            self.machine.sessionBegan(id, .init(curtain: curtain, lockWhenFinished: lockWhenFinished), now: Clock.nowNanos())
            self.machine.sessionStreamed(id)
            self.startWatchingLock()
            self.update(reason: "agent session \(id)")
            self.tryOpaque()
        }
    }
    /// An agent session an earlier miraged left open (AgentSessions' record, same boot, nobody at the Mac lately): opened and
    /// stopped in the state machine now, so the usual rules decide the lock after the debounce (not already locked, nobody
    /// signed in at it).
    public func endRecoveredAgentSession(_ id: String) {
        DispatchQueue.main.async {
            guard Self.allowed else { return }
            let now = Clock.nowNanos()
            self.machine.sessionBegan(id, .init(curtain: false, lockWhenFinished: true), now: now)
            self.machine.sessionStreamed(id)
            self.startWatchingLock()
            self.machine.sessionStopped(id, now: now)
        }
    }
    /// miraged is stopping with an agent session open: the session ends and its lock is decided now (no debounce: the
    /// process is going); `done` once the lock, if any, is posted.
    public func endAgentSessionNow(_ id: String, done: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            guard Self.allowed else { done(); return }
            let now = Clock.nowNanos()
            self.machine.lockChanged(InputInjector.consoleLocked())
            self.machine.sessionStopped(id, now: now)
            if self.machine.tick(now: now &+ self.machine.debounceNanos &+ 1), !InputInjector.consoleLocked() {
                self.log("curtain: miraged is stopping with an agent session open: locking this Mac")
                self.lockNow(endOfSessions: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() }
        }
    }
    /// Its stream started (a connect that fails before this never locks the Mac at the end).
    public func sessionStreamed(_ id: String) { DispatchQueue.main.async { if Self.allowed { self.machine.sessionStreamed(id) } } }
    /// A client's stream ended: `stopped` for good, or suspended (a backgrounded phone, a roam, a dropped viewer: the curtain
    /// stays up, and local input still locks, until it resumes or is stopped). "Lock when finished" acts in `lockTick`.
    public func sessionEnded(_ id: String, stopped: Bool) {
        DispatchQueue.main.async {
            guard Self.allowed else { return }
            self.acked.removeValue(forKey: id)
            let now = Clock.nowNanos()
            let wasIdle = self.machine.allSuspended
            if stopped { self.machine.sessionStopped(id, now: now) } else { self.machine.sessionSuspended(id, now: now) }
            if self.machine.allSuspended, !wasIdle {
                self.log("curtain: nothing streams (every session suspended): the display may sleep per this Mac's Energy settings; the curtain stays up")
            }
            if !self.machine.needsWatching { self.stopWatchingLock() }
            self.update(reason: "session \(id) \(stopped ? "stopped" : "suspended")")
            self.tryOpaque()
        }
    }
    /// A streamer's capture filters leave out the curtain's windows of `generation` (or newer).
    public func acknowledge(_ id: String, generation g: Int) {
        DispatchQueue.main.async {
            guard self.acked[id] != nil else { return }
            self.acked[id] = max(self.acked[id] ?? 0, g)
            self.tryOpaque()
        }
    }
    /// InputInjector, for each key-down and mouse-down it posts: the remote person's input (whose unlock is it).
    public func noteInjectedDown() { DispatchQueue.main.async { self.machine.injectedDown() } }

    // MARK: Showing

    /// Brings the screens in line with the state machine.
    private func update(reason: String) {
        if machine.wantsCurtain { show(reason: reason) } else { hide(reason: reason) }
        syncPresenceWatch()
        wantedFlag = machine.wantsCurtain
    }
    /// Lock when finished on and no curtain up (the setting off, a suspend, no grant for the curtain, a failed lock, unconfirmed
    /// filters): a tap that never swallows and never locks notes hardware input, so the end leaves a Mac someone is using
    /// unlocked. While the curtain is up its own tap serves (local input there locks instead).
    private func syncPresenceWatch() {
        let want = machine.watchesPresence
        if want, windows.isEmpty, !installTap(listenOnly: true) {
            if Self.presenceWatch || !presenceTapMissingLogged {
                presenceTapMissingLogged = true
                log("curtain: no event tap (needs Accessibility or Input Monitoring): Lock when finished cannot tell whether someone is at this Mac")
            }
            Self.presenceWatch = false; return
        }
        if want, !Self.presenceWatch { Self.presenceNotedAt.store(0, ordering: .relaxed); presenceLogged = false }
        Self.presenceWatch = want
        if !want, windows.isEmpty, tap != nil { removeTap() }
    }
    private var presenceTapMissingLogged = false

    private func show(reason: String) {
        guard windows.isEmpty else { return }
        guard installTap() else {
            log("curtain: not shown (\(reason)): no event tap, so local input could not lock the Mac (needs Accessibility or Input Monitoring)")
            machine.curtainFailed()
            return
        }
        // miraged runs .prohibited (no Dock tile, no windows); a window needs .accessory, which has no Dock tile either.
        if NSApp.activationPolicy() == .prohibited { _ = NSApp.setActivationPolicy(.accessory) }
        generation += 1
        let gen = generation
        screenLayout = NSScreen.screens.map(\.frame)
        windows = NSScreen.screens.map { makeWindow(for: $0) }
        for w in windows { w.alphaValue = 0; w.orderFrontRegardless() }
        let ids = Set(windows.map { CGWindowID($0.windowNumber) })   // (on main, before any await)
        // A rebuild's old windows stay opaque, and left out of every capture, until these are.
        let keep = Set(retiring.map { CGWindowID($0.windowNumber) })
        let screens = NSScreen.screens.map { ($0.backingScaleFactor, Self.displayID($0)) }
        Task {
            // Never without the grant: ScreenCaptureKit would raise the prompt (DESIGN §3.7a).
            let content = HostPermissions.mayCapture ? try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) : nil
            let sc = content?.windows.filter { ids.contains($0.windowID) || keep.contains($0.windowID) } ?? []
            let found = sc.filter { ids.contains($0.windowID) }.count
            // The exclusion first, so the sessions re-filter while the picture is taken (it must not delay the curtain).
            let ready: Bool = await MainActor.run {
                guard gen == self.generation, !self.windows.isEmpty else { return false }   // superseded: never overwrite newer IDs
                guard found == ids.count else {
                    self.log("curtain: only \(found) of \(ids.count) windows found for capture exclusion; staying invisible, retrying in 5 s")
                    self.scheduleRetry(); return false
                }
                CurtainExclusion.set(sc, ids: ids.union(keep), generation: gen)
                self.publish(gen)
                self.log("curtain: windows ready (generation \(gen)), waiting for every session's filters (\(reason))")
                self.tryOpaque()   // with every session suspended nothing captures: no acknowledgement to wait for
                return true
            }
            guard ready else { return }
            // The blurred wallpaper, from a capture of the wallpaper window alone (never the picture file: reading one from
            // ~/Desktop, iCloud or another app's container would raise a privacy prompt on an unattended Mac).
            var pictures: [CGDirectDisplayID: CGImage] = [:]
            for (scale, id) in screens {
                guard let content, let d = content.displays.first(where: { $0.displayID == id }) else { continue }
                let (img, how) = await Self.wallpaper(d, content: content, scale: scale)
                pictures[id] = img
                self.log("curtain: display \(id) picture: \(how)")
                if img == nil { self.log("curtain: display \(id) has no picture: its curtain stays plain gray") }
                // Test knob MIRAGE_TEST_CURTAIN_WALLPAPER=<file.png>: the unblurred wallpaper-only shot (what goes under the blur),
                // so a person can check that no icon or widget is in it.
                if let path = ProcessInfo.processInfo.environment["MIRAGE_TEST_CURTAIN_WALLPAPER"], let img,
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); _ = CGImageDestinationFinalize(dest)
                }
            }
            await MainActor.run {
                guard gen == self.generation, !self.windows.isEmpty else { return }
                for (w, (_, id)) in zip(self.windows, screens) {
                    (w.contentView as? CurtainView)?.apply(pictures[id])
                }
                CATransaction.flush()
                // The test shot (the first window's) only of a real picture: never a gray one passed off as it.
                if pictures[screens.first?.1 ?? 0] != nil { self.pictureGen = gen }
                else if Self.testShotPath != nil { self.log("curtain: TEST shot skipped: the first screen has no picture (gray)") }
                let rel = self.shownAt > 0 ? String(format: "%.0f ms after it showed", Double(Clock.elapsed(since: self.shownAt, now: Clock.nowNanos())) / 1e6) : "before it showed"
                self.log("curtain: picture applied and drawn on \(self.windows.count) screen(s) (generation \(gen)), \(rel)")
                self.maybeShoot()
            }
        }
    }

    private func publish(_ gen: Int, since: UInt64 = Clock.nowNanos()) {
        NotificationCenter.default.post(name: Self.windowsChanged, object: gen)
        retry?.cancel()
        let r = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, !self.windows.isEmpty, !self.machine.visible else { return }
            if Clock.elapsed(since: since, now: Clock.nowNanos()) >= 10_000_000_000 {
                // A session's filters never confirmed: its gated captures would stay frozen. The curtain goes entirely (its
                // windows and their exclusion, so nothing is gated) and is tried again in 30 s.
                self.log("curtain: not every session acknowledged generation \(gen) within 10 s (\(self.acked)); hidden, trying again in 30 s")
                self.hide(reason: "filters not confirmed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.update(reason: "retry after unconfirmed filters") }
                return
            }
            self.log("curtain: not every session acknowledged generation \(gen) yet (\(self.acked)); invisible, asking again")
            self.publish(gen, since: since)
        }
        retry = r
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: r)
    }

    /// The generation whose picture is applied and drawn, and when the curtain last became visible.
    private var pictureGen = 0
    private var shownAt: UInt64 = 0
    /// The test shot, once the curtain is visible and its picture applied (it used to run before the picture landed: gray).
    private func maybeShoot() {
        // The first screen's window, the one whose picture was checked.
        guard let path = Self.testShotPath, machine.visible, pictureGen == generation, let id = windows.first.map({ CGWindowID($0.windowNumber) }),
              let first = CurtainExclusion.windows.first(where: { $0.windowID == id }) else { return }
        Task { await Self.shoot(first, to: path, log: self.log) }
    }

    /// Opaque only when every streaming session's filters leave out this generation of the curtain.
    private func tryOpaque() {
        // Every session that captures (suspended ones capture nothing and are not in `acked`).
        guard !windows.isEmpty, machine.wantsCurtain, CurtainExclusion.generation == generation,
              acked.values.allSatisfy({ $0 >= generation }) else { return }
        if !machine.visible { setVisible(true); shownAt = Clock.nowNanos(); log("curtain: shown on \(windows.count) screen(s); every session's capture leaves it out (generation \(generation))") }
        maybeShoot()
        if let secs = Self.testTriggerSeconds, !Self.triggerPosted {
            Self.triggerPosted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                guard let self, self.machine.visible else { return }
                // A modifier event with no modifiers (changes nothing in any app), untagged, posted by this process.
                self.log("curtain: TEST trigger: posting one untagged modifier event (MIRAGE_TEST_CURTAIN_TRIGGER)")
                if let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 0x38 /* shift */, keyDown: true) {
                    e.type = .flagsChanged; e.flags = []; e.post(tap: .cghidEventTap)
                }
            }
        }
    }

    private func setVisible(_ v: Bool) {
        for w in windows { w.alphaValue = v ? 1 : 0 }
        machine.visible = v && !windows.isEmpty
        if machine.visible { retire() }
    }
    /// A screens-changed rebuild's old windows, kept opaque until the new ones are (a display that dropped out during display
    /// sleep must not leave the desktop uncovered at the wake).
    private var retiring: [NSWindow] = []
    private func retire() { for w in retiring { w.orderOut(nil) }; retiring = [] }
    private func rebuild(reason: String) {
        retry?.cancel(); retry = nil
        if machine.visible { retiring += windows } else { for w in windows { w.orderOut(nil) } }
        windows = []; machine.visible = false
        log("curtain: rebuilding (\(reason)); the old windows stay until the new ones are opaque")
        update(reason: reason)
    }

    private func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.machine.wantsCurtain else { return }
            self.hide(reason: "retry", keepTap: true); self.update(reason: "retry")
        }
    }

    private func hide(reason: String, keepTap: Bool = false) {
        retry?.cancel(); retry = nil
        retire()
        // The tap stays while the curtain is wanted (its windows gone only for a retry: local input still locks) or presence
        // is watched.
        if !keepTap {
            if machine.wantsCurtain || Self.presenceWatch { Self.swallowUntil = 0; Self.lockArmed = false } else { removeTap() }
        }
        wantedFlag = machine.wantsCurtain
        guard !windows.isEmpty else { return }
        generation += 1
        setVisible(false)
        for w in windows { w.orderOut(nil) }
        windows = []
        CurtainExclusion.set([], ids: [], generation: generation)
        NotificationCenter.default.post(name: Self.windowsChanged, object: generation)
        // No windows any more: back to .prohibited (an .accessory app with nothing reading its window-server events reads as
        // "not responding", and check-host-invisible.sh expects it).
        if !keepTap, NSApp.activationPolicy() != .prohibited { _ = NSApp.setActivationPolicy(.prohibited) }
        log("curtain: hidden (\(reason))")
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        // Above every ordinary window (the screen saver is 1000) and below loginwindow's lock-screen shield (2000 and up), so
        // the lock screen always covers it.
        w.level = NSWindow.Level(rawValue: 1999)
        w.title = Self.windowTitle
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.ignoresMouseEvents = true        // injected clicks reach the apps beneath; a local click is seen by the tap
        w.isOpaque = true; w.hasShadow = false; w.isReleasedWhenClosed = false
        // Left out of every process's screen capture, not only Mirage's (measured on macOS 27, 2026-10-27: another process's
        // ScreenCaptureKit display capture sees 0 % of a sharingType-none window, 100 % of a readOnly one): an agent working
        // under an agent session (DESIGN §3.13) sees the desktop, not the curtain. The test shot needs it readable.
        w.sharingType = Self.testShotPath == nil ? .none : .readOnly
        w.backgroundColor = NSColor(white: 0.25, alpha: 1)
        w.setFrame(screen.frame, display: false)
        w.contentView = CurtainView(frame: NSRect(origin: .zero, size: screen.frame.size))
        return w
    }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }

    /// The display's wallpaper alone, at full size, through ScreenCaptureKit: one window at or below the desktop window level
    /// covering the display, owned by the Dock, the wallpaper agent, WindowManager or the window server, chosen by measurement
    /// (each candidate captured alone: opaque, with real variance, closest to the composited backdrop below the icons). Never
    /// anything at or above Finder's icon level, and never widgets (phrz). None fits: nil, and the curtain is plain gray.
    static func wallpaper(_ d: SCDisplay, content: SCShareableContent, scale: CGFloat) async -> (CGImage?, String) {
        let picks = wallpaperWindows(content.windows.map { WallpaperCandidate($0) }, display: d.frame)
        guard !picks.isEmpty else {
            // What was there (owners, levels, coverage; no titles), to put the right owner on the allowlist.
            let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            let low = content.windows.filter { $0.windowLayer < iconLevel && $0.frame.intersects(d.frame) }.prefix(8).map { w -> String in
                let i = w.frame.intersection(d.frame); let cover = Int(100 * i.width * i.height / max(1, d.frame.width * d.frame.height))
                return "\(w.windowID) \(w.owningApplication?.bundleIdentifier ?? "no owner") L\(w.windowLayer) \(cover)%"
            }
            return (nil, "no wallpaper window isolated (desktop level \(Int(CGWindowLevelForKey(.desktopWindow))); candidates: \(low.joined(separator: ", "))): plain gray")
        }
        // The reference: everything below the icon level, composited (what the desktop looks like without icons or widgets).
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let below = content.windows.filter { $0.windowLayer < iconLevel && $0.frame.intersects(d.frame) }
        let small = SCStreamConfiguration(); small.width = 320; small.height = max(2, 320 * d.height / max(1, d.width)); small.showsCursor = false
        let reference = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, including: below), configuration: small)
        var measured: [WallpaperMeasure] = []
        for p in picks.prefix(4) {
            guard let w = content.windows.first(where: { $0.windowID == p.id }),
                  let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, including: [w]), configuration: small) else { continue }
            measured.append(WallpaperMeasure.of(img, id: p.id, reference: reference))
        }
        let numbers = measured.map { "\($0.id): opaque \(Int($0.opaque * 100))% var \(String(format: "%.4f", $0.variance)) diff \(String(format: "%.1f", $0.diff))" }
            .joined(separator: "; ")
        let owners = picks.map { "\($0.id) \($0.owner.isEmpty ? $0.bundle : $0.owner) L\($0.level)" }.joined(separator: ", ")
        guard let best = chooseWallpaper(measured), let w = content.windows.first(where: { $0.windowID == best }) else {
            return (nil, "no candidate is an opaque picture (\(owners); \(numbers)): plain gray")
        }
        let c = SCStreamConfiguration()
        c.width = Int(CGFloat(d.width) * scale); c.height = Int(CGFloat(d.height) * scale); c.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, including: [w]), configuration: c) else {
            return (nil, "wallpaper capture failed (window \(best)): plain gray")
        }
        return (img, "wallpaper window \(best) (of \(owners); \(numbers)), blurred")
    }
    struct WallpaperCandidate { var id: CGWindowID; var level: Int; var bundle: String; var owner: String; var frame: CGRect
        init(id: CGWindowID, level: Int, bundle: String, owner: String = "", frame: CGRect) { self.id = id; self.level = level; self.bundle = bundle; self.owner = owner; self.frame = frame }
        init(_ w: SCWindow) { self.init(id: w.windowID, level: w.windowLayer, bundle: w.owningApplication?.bundleIdentifier ?? "", owner: w.owningApplication?.applicationName ?? "", frame: w.frame) }
    }
    /// Candidates: at or below the desktop window level (macOS 27 has nothing exactly at it: WindowManager one below, the
    /// window server's backdrops lower), covering most of the display, owned by the Dock, the wallpaper agent, WindowManager or
    /// the window server. Never at or above the icon level, never Finder or a widget host, never an unknown app.
    static let wallpaperOwners: Set<String> = ["com.apple.dock", "com.apple.wallpaper.agent", "com.apple.WallpaperAgent", "com.apple.WindowManager", "com.apple.WindowServer"]
    static func wallpaperWindows(_ all: [WallpaperCandidate], display: CGRect) -> [WallpaperCandidate] {
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        return all.filter { w in
            w.level <= desktopLevel
                && (wallpaperOwners.contains(w.bundle) || (w.bundle.isEmpty && w.owner == "Window Server"))
                && w.frame.intersection(display).width * w.frame.intersection(display).height >= display.width * display.height * 0.9
        }
    }
    /// One candidate captured alone: how much of it is opaque, how much its luminance varies (a picture, not a flat fill), and
    /// how far it is from the reference (mean absolute difference in levels; .infinity without one).
    struct WallpaperMeasure: Equatable { var id: CGWindowID; var opaque: Double; var variance: Double; var diff: Double
        static func of(_ img: CGImage, id: CGWindowID, reference: CGImage?) -> WallpaperMeasure {
            let a = pixels(img), r = reference.map(pixels)
            var opaque = 0, n = 0, sum = 0.0, sq = 0.0, diff = 0.0
            for i in stride(from: 0, to: a.count, by: 4) {
                n += 1
                if a[i + 3] >= 250 { opaque += 1 }
                let l = (0.2126 * Double(a[i]) + 0.7152 * Double(a[i + 1]) + 0.0722 * Double(a[i + 2])) / 255
                sum += l; sq += l * l
                if let r, r.count == a.count { diff += Double(abs(Int(a[i]) - Int(r[i])) + abs(Int(a[i + 1]) - Int(r[i + 1])) + abs(Int(a[i + 2]) - Int(r[i + 2]))) / 3 }
            }
            let mean = sum / Double(max(1, n))
            return WallpaperMeasure(id: id, opaque: Double(opaque) / Double(max(1, n)), variance: sq / Double(max(1, n)) - mean * mean,
                                    diff: r?.count == a.count ? diff / Double(max(1, n)) : .infinity)
        }
        private static func pixels(_ img: CGImage) -> [UInt8] {
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            px.withUnsafeMutableBytes { b in
                guard let c = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return px
        }
    }
    /// The picture: opaque (≥ 95 %) with real variance (a picture, not a flat fill or a blank surface), the closest to the
    /// reference among those; none: nil (gray).
    static func chooseWallpaper(_ m: [WallpaperMeasure]) -> CGWindowID? {
        m.filter { $0.opaque >= 0.95 && $0.variance >= 0.0005 }.min { $0.diff < $1.diff }?.id
    }

    // MARK: Local input

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapListenOnly = false
    /// The presence watch is on, and its first local input is noted (until the Mac locks or the end is decided).
    nonisolated(unsafe) fileprivate static var presenceWatch = false
    /// When the tap last passed local input to the main queue (at most every 5 s): the machine keeps the latest.
    fileprivate static let presenceNotedAt = Atomic<UInt64>(0)
    private var presenceLogged = false
    /// Until when (nanos) the active tap swallows hardware input: the lock it triggered takes hold (~2.5 s or until locked).
    nonisolated(unsafe) fileprivate static var swallowUntil: UInt64 = 0
    nonisolated(unsafe) fileprivate static var active = false
    /// The curtain is wanted (`Machine.wantsCurtain`), as the tap's thread reads it: local input then locks, whether or not the
    /// windows are opaque yet.
    nonisolated(unsafe) fileprivate var wantedFlag = false

    /// A tap on its own thread and run loop (the callback stays trivial and off the main queue). Active (it drops the triggering
    /// local events until the lock takes hold) only with the Accessibility grant; with Input Monitoring alone, listen-only.
    /// Never prompts: without either grant there is no tap, and no curtain (a "Click to log in" that did not lock would lie).
    /// `listenOnly`: for the presence watch, never swallowing. A listen-only tap needs Input Monitoring; with Accessibility
    /// alone it is an active tap that passes every event (`active` false), so it never prompts.
    private func installTap(listenOnly: Bool = false) -> Bool {
        if tap != nil, tapListenOnly == listenOnly { return true }
        if tap != nil { removeTap() }
        let trusted = AXIsProcessTrusted()
        guard trusted || CGPreflightListenEventAccess() else { return false }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown, .keyUp,
                                    .flagsChanged, .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { Curtain.shared.reenableTap(); return Unmanaged.passUnretained(event) }
            let ud = event.getIntegerValueField(.eventSourceUserData), pid = event.getIntegerValueField(.eventSourceUnixProcessID)
            // (MIRAGE_TEST_CURTAIN_TRIGGER: this process's own untagged event stands in for hardware input in a remote lock test.)
            let hw = pid == 0 || (Curtain.testTriggerSeconds != nil && pid == Int64(Curtain.ownPID))
            guard ud != CurtainLogic.injectedTag, hw, CurtainLogic.isTriggerType(type) || CurtainLogic.isSwallowedType(type)
            else { return Unmanaged.passUnretained(event) }
            let now = Clock.nowNanos()
            if CurtainLogic.isTriggerType(type) { Curtain.shared.localInput(type, now: now, pid: event.getIntegerValueField(.eventSourceUnixProcessID), userData: event.getIntegerValueField(.eventSourceUserData)) }
            if Curtain.active, now < Curtain.swallowUntil, CurtainLogic.isSwallowedType(type) { return nil }
            return Unmanaged.passUnretained(event)
        }
        let canListen = CGPreflightListenEventAccess()
        let option: CGEventTapOptions = trusted && (!listenOnly || !canListen) ? .defaultTap : .listenOnly
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: option,
                                        eventsOfInterest: mask, callback: callback, userInfo: nil) else { return false }
        Self.active = trusted && !listenOnly; tapListenOnly = listenOnly
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        tap = t; tapSource = src
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var rl: CFRunLoop?
        let thread = Thread {
            rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "mirage.curtain.tap"
        thread.start()
        ready.wait()
        tapRunLoop = rl
        return true
    }
    fileprivate func reenableTap() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }
    private func removeTap() {
        Self.swallowUntil = 0; Self.lockArmed = false
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let rl = tapRunLoop { if let s = tapSource { CFRunLoopRemoveSource(rl, s, .commonModes) }; CFRunLoopStop(rl) }
        tap = nil; tapSource = nil; tapRunLoop = nil
    }

    /// From the tap's thread: a hardware click, key, modifier or scroll. While the curtain is up, swallowing starts at once (the
    /// tap drops this event and what follows for ~2.5 s or until locked), and the main queue locks. No curtain, no lock.
    fileprivate func localInput(_ type: CGEventType, now: UInt64, pid: Int64, userData: Int64) {
        guard wantedFlag else {
            // No curtain wanted: only noted (at most every 5 s), for Lock when finished.
            let last = Self.presenceNotedAt.load(ordering: .relaxed)
            guard Self.presenceWatch, now &- last >= 5_000_000_000,
                  Self.presenceNotedAt.compareExchange(expected: last, desired: now, ordering: .relaxed).exchanged else { return }
            DispatchQueue.main.async {
                self.machine.localInputUncurtained(now: now)
                if self.machine.lastLocalInput == now, !self.presenceLogged {
                    self.presenceLogged = true
                    self.log("curtain: local \(Self.name(type)) (source pid \(pid)) with no curtain up during a session: someone may be at this Mac (Lock when finished leaves it unlocked after recent input)")
                }
            }
            return
        }
        // Armed once per lock attempt (`lockArmed` is cleared when the attempt ends, locked or not): never re-armed by the
        // swallowed input itself, so a lock that cannot land never keeps eating the Mac's own input.
        if !Self.lockArmed { Self.lockArmed = true; Self.swallowUntil = now + 2_500_000_000 }
        DispatchQueue.main.async {
            guard self.machine.lockOnLocalInput(), !InputInjector.consoleLocked() else { return }
            guard now &- self.lockRequested > 3_000_000_000 else { return }
            self.lockRequested = now
            self.log("curtain: local \(Self.name(type)) (source pid \(pid), user data \(userData)) while a remote session streams: locking this Mac")
            self.lockNow()
        }
    }
    nonisolated(unsafe) fileprivate static var lockArmed = false

    /// The lock: ⌃⌘Q (the system's Lock Screen shortcut), posted with the injection tag. If the Mac is still unlocked 2 s later
    /// with the curtain still wanted (the shortcut remapped or off), the display sleeps (`pmset displaysleepnow`), which locks
    /// when the Mac asks for its password immediately after the display sleeps (macOS's default); logged either way.
    /// `endOfSessions` ("Lock when finished"): the same verify and fallback, given up if a session begins meanwhile; if the
    /// Mac is still unlocked, logged and kept in `HostLockStatus` (the host menu, the viewer's Get Info).
    private func lockNow(endOfSessions: Bool = false) {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.userData = CurtainLogic.injectedTag
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 12 /* q */, keyDown: down) else { continue }
            e.flags = [.maskCommand, .maskControl]
            e.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if endOfSessions {
                if InputInjector.consoleLocked() { HostLockStatus.lastFailure = nil; return }
                guard !self.machine.needsWatching else { return }   // a session began meanwhile
                self.log("curtain: ⌃⌘Q did not lock this Mac (Lock when finished): sleeping the display (pmset displaysleepnow)")
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["displaysleepnow"]
                try? p.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if InputInjector.consoleLocked() { HostLockStatus.lastFailure = nil; return }
                    guard !self.machine.needsWatching else { return }
                    HostLockStatus.lastFailure = Date()
                    self.log("curtain: this Mac could not be locked when the sessions ended (⌃⌘Q and display sleep both left it unlocked; Lock when finished)")
                }
                return
            }
            guard self.machine.wantsCurtain, !InputInjector.consoleLocked() else { Self.lockArmed = false; return }
            self.log("curtain: ⌃⌘Q did not lock (shortcut remapped, or grabbed by a VM or remote-desktop app?): sleeping the display (pmset displaysleepnow)")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["displaysleepnow"]
            try? p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Self.lockArmed = false
                guard !InputInjector.consoleLocked(), self.machine.wantsCurtain else { return }
                // Neither locked the Mac: stop swallowing, and no curtain for the rest of these sessions (one that cannot lock
                // would only stand in the way of the Mac's own user).
                Self.swallowUntil = 0
                self.machine.lockFailed()
                self.hide(reason: "this Mac cannot be locked from here (⌃⌘Q and display sleep both failed): off until every session ends")
            }
        }
    }

    // MARK: Lock state

    private func startWatchingLock() {
        guard lockTimer == nil else { return }
        machine.lockChanged(InputInjector.consoleLocked())
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.lockTick() }
        t.resume()
        lockTimer = t
    }
    private func stopWatchingLock() { lockTimer?.cancel(); lockTimer = nil }
    private func lockTick() {
        let locked = InputInjector.consoleLocked()
        if locked != machine.locked {
            machine.lockChanged(locked)
            if locked { Self.swallowUntil = 0; Self.lockArmed = false; Self.presenceNotedAt.store(0, ordering: .relaxed); hide(reason: "Mac locked (the lock screen covers it, and is what the remote person unlocks)") }
            else if machine.ownedLocally { hide(reason: "unlocked at the Mac: off until a remote unlock or the session's end") }
            else { update(reason: "unlocked through Mirage") }
        }
        // "Lock when finished": the end reached (the debounce after the last stop), the Mac unlocked and
        // nobody at it.
        if machine.tick(now: Clock.nowNanos()) {
            if !InputInjector.consoleLocked() { log("curtain: the sessions ended: locking this Mac (Lock when finished)"); lockNow(endOfSessions: true) }
        }
        if !machine.needsWatching { stopWatchingLock(); update(reason: "the sessions ended"); return }
        // Screens added, removed or rearranged: rebuilt.
        if !windows.isEmpty, NSScreen.screens.map(\.frame) != screenLayout { rebuild(reason: "screens changed") }
        wantedFlag = machine.wantsCurtain
    }

    // MARK: Test

    /// Test knob MIRAGE_TEST_CURTAIN_SHOT=<file.png>: once shown, one capture of a curtain window by itself (that window only,
    /// at its full size; never the desktop), for phrz to see what the curtain looks like.
    static let testShotPath = ProcessInfo.processInfo.environment["MIRAGE_TEST_CURTAIN_SHOT"]
    /// Test knob MIRAGE_TEST_CURTAIN_TRIGGER=<seconds> (test instances only, with MIRAGE_TEST_CURTAIN=1): that long after the
    /// curtain shows, this process posts one untagged modifier event, and its own untagged events count as local: the lock,
    /// the swallow and the remote unlock tested without anyone at the Mac (real hardware input reports pid 0; this does not).
    /// Ignored outside test instances (`testInstance`, set by miraged), so production can never treat its own events as local.
    static var testTriggerSeconds: Double? { testInstance ? testTriggerEnv : nil }
    private static let testTriggerEnv: Double? = ProcessInfo.processInfo.environment["MIRAGE_TEST_CURTAIN_TRIGGER"].flatMap(Double.init)
    /// Whether this process is a test instance (`serve --no-local-control`). Set by miraged before any session.
    nonisolated(unsafe) public static var testInstance = false
    static let ownPID = getpid()
    nonisolated(unsafe) private static var triggerPosted = false
    nonisolated(unsafe) private static var shotTaken = false
    private static func shoot(_ w: SCWindow, to path: String, log: @escaping (String) -> Void) async {
        guard !shotTaken else { return }
        shotTaken = true
        try? await Task.sleep(for: .milliseconds(300))   // (the window server composites the drawn frame)
        let c = SCStreamConfiguration()
        let scale = await MainActor.run { NSScreen.screens.first(where: { $0.frame.width == w.frame.width })?.backingScaleFactor ?? 2 }
        c.width = Int(w.frame.width * scale); c.height = Int(w.frame.height * scale); c.showsCursor = false
        do {
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: c)
            guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            log(CGImageDestinationFinalize(dest) ? "curtain: test shot of window \(w.windowID) (\(img.width)x\(img.height)) saved to \(path)" : "curtain: test shot not saved")
        } catch { log("curtain: test shot failed: \(error)") }
    }

    private static func name(_ t: CGEventType) -> String {
        switch t {
        case .keyDown: return "key"; case .flagsChanged: return "modifier key"; case .scrollWheel: return "scroll"
        default: return "click"
        }
    }
}

/// The curtain's windows as ScreenCaptureKit sees them, for every capture filter to leave out, and their generation
/// (thread-safe). `active` while a curtain exists on the screens.
public enum CurtainExclusion {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _windows: [SCWindow] = []
    nonisolated(unsafe) private static var _ids: Set<CGWindowID> = []
    nonisolated(unsafe) private static var _generation = 0
    public static var windows: [SCWindow] { lock.lock(); defer { lock.unlock() }; return _windows }
    public static var ids: Set<CGWindowID> { lock.lock(); defer { lock.unlock() }; return _ids }
    public static var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }
    public static var active: Bool { lock.lock(); defer { lock.unlock() }; return !_windows.isEmpty }
    /// Only ever forward: a superseded show can never overwrite a newer generation's windows.
    static func set(_ w: [SCWindow], ids: Set<CGWindowID>, generation g: Int) {
        lock.lock(); defer { lock.unlock() }
        guard g >= _generation else { return }
        _windows = w; _ids = ids; _generation = g
    }
    /// A one-off capture whose filter was built at generation `gen` predates the curtain on the screens now.
    public static func stale(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return !_windows.isEmpty && gen < _generation }
    /// Another miraged's curtain windows (a test instance's), as the streamers' window catalog lists them: left out of the
    /// display and overlay pictures too.
    nonisolated(unsafe) private static var _foreign: [SCWindow] = []
    public static var foreign: [SCWindow] { lock.lock(); defer { lock.unlock() }; return _foreign }
    static func setForeign(_ w: [SCWindow]) { lock.lock(); _foreign = w; lock.unlock() }
    /// `list` plus the curtain's windows (no duplicates).
    public static func adding(to list: [SCWindow]) -> [SCWindow] {
        let c = windows
        guard !c.isEmpty else { return list }
        let have = Set(list.map(\.windowID))
        return list + c.filter { !have.contains($0.windowID) }
    }
}

/// One screen's curtain: the desktop blurred, and the icon, heading and detail centred together.
final class CurtainView: NSView {
    private let image = NSImageView()
    private let heading = NSTextField(labelWithString: "This Mac is in use remotely")
    private let detail = NSTextField(labelWithString: "Click to log in")

    /// `icon`: the app's own (Mirage.app's, which miraged runs inside) unless given (a preview rendered elsewhere).
    init(frame: NSRect, icon iconImage: NSImage? = nil) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        image.frame = bounds; image.autoresizingMask = [.width, .height]; image.imageScaling = .scaleAxesIndependently
        addSubview(image)
        let icon = NSImageView(image: iconImage ?? NSApplication.shared.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        detail.font = .systemFont(ofSize: 13, weight: .regular)
        let stack = NSStackView(views: [icon, heading, detail])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10
        stack.setCustomSpacing(18, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 128), icon.heightAnchor.constraint(equalToConstant: 128),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setPicture(nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `setPicture`, then drawn now into the window, not at a display cycle that may not come (miraged's windows rarely get
    /// one): the new picture and the text colours. The caller flushes (CATransaction.flush) after the last screen.
    func apply(_ desktop: CGImage?) {
        setPicture(desktop)
        needsDisplay = true
        window?.displayIfNeeded(); window?.display()
    }
    /// Nothing waits to be drawn (the picture view included): what `apply` guarantees.
    var drawn: Bool { !needsDisplay && !image.needsDisplay && !heading.needsDisplay }

    /// The desktop capture, blurred about as the lock screen does; the text colour from the picture behind the block.
    func setPicture(_ desktop: CGImage?) {
        let blurred = desktop.flatMap(Self.blur)
        image.image = blurred.map { NSImage(cgImage: $0, size: bounds.size) }
        // The block's area in pixel rows from the top: the middle third of the width, about a quarter of the height.
        let block = CGRect(x: bounds.width * 0.33, y: bounds.height * 0.38, width: bounds.width * 0.34, height: bounds.height * 0.24)
        let style = CurtainLogic.textStyle(luminance: blurred.map { Self.luminance(of: $0, in: block, viewSize: bounds.size) } ?? 0.3)
        let color = style.white ? NSColor(white: 1, alpha: style.alpha) : NSColor(white: 0, alpha: style.alpha)
        heading.textColor = color
        detail.textColor = color.withAlphaComponent(style.alpha * 0.8)
    }

    static func blur(_ src: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: src)
        let blur = ci.clampedToExtent().applyingGaussianBlur(sigma: max(30, Double(src.width) / 60)).cropped(to: ci.extent)
        let tuned = blur.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15, kCIInputBrightnessKey: -0.04])
        return CIContext().createCGImage(tuned, from: ci.extent)
    }

    static func luminance(of image: CGImage, in rect: CGRect, viewSize: NSSize) -> Double {
        let w = image.width, h = image.height, stride = w * 4
        var px = [UInt8](repeating: 0, count: stride * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { return 0.3 }
        // CGContext rows run from the top in memory: `rect` is in top-left coordinates, as the block is centred anyway.
        let k = Double(w) / Double(max(1, viewSize.width))
        let r = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
        return px.withUnsafeBytes { CurtainLogic.meanLuminance(bgra: $0, width: w, height: h, stride: stride, rect: r) }
    }
}
