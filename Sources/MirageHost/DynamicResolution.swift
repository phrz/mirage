import Foundation
import Darwin
import CoreGraphics
import ScreenCaptureKit
import MirageCore

/// Dynamic Resolution (the viewer's View menu): while a viewer asks, the Mac shows one display the size of its window.
/// A virtual display (CoreGraphics' CGVirtualDisplay, as display utilities make) is created at the window's points, at
/// the viewer's pixels per point, and every real display mirrors it, so the whole desktop is that one screen and the stream
/// is its pixels one to one. A resized window changes its mode; the end of the stream (or the option turned off) ends the
/// mirroring and removes it.
///
/// A helper process (`miraged virtual-display`, `VirtualDisplayHelper`) owns the display: macOS removes a virtual display
/// when the process that made it exits, and not reliably when it is released (macOS 27 kept released ones online, holding
/// the desktop, until the session locked). So the display goes when the helper does: when the stream lets it go, and when
/// this host quits or crashes (the helper reads its input to the end and exits). Its CoreGraphics calls, which can block for
/// seconds while a display comes up, stay out of this process too.
///
/// The classes are private CoreGraphics API, reached through the Objective-C runtime; where they are missing nothing changes.
final class DynamicResolution: @unchecked Sendable {
    static let shared = DynamicResolution()

    private let lock = NSLock()
    private var helper: Helper?
    private var displayID: CGDirectDisplayID = 0
    /// The main display before the mirroring: where a stream goes back to.
    private var realMain: CGDirectDisplayID = 0
    private var current: ControlMessage.FitDisplay?
    private var owner: ObjectIdentifier?
    /// Unmirrored, still existing: removed once the capture has moved off it (`settle`).
    private var releasing = false
    private let logLock = NSLock()
    private var _log: (String) -> Void = { _ in }
    var log: (String) -> Void {
        get { logLock.withLock { _log } }
        set { logLock.withLock { _log = newValue } }
    }
    /// On unless turned off (`defaults write com.paulherz.mirage MacDynamicResolution -bool NO`, or
    /// MIRAGE_DYNAMIC_RESOLUTION=0). On a real Mac (M4 Pro mini, macOS 27.2) the helper's display mirrored cleanly every
    /// time; in a macOS 27 VM mirroring a new virtual display sometimes failed while taking effect and left it holding the
    /// desktop, so the switch stays for hosts where that happens.
    static var enabled: Bool {
        if let env = ProcessInfo.processInfo.environment["MIRAGE_DYNAMIC_RESOLUTION"] { return env != "0" }
        return UserDefaults.standard.object(forKey: "MacDynamicResolution") as? Bool ?? true
    }

    /// One change at a time: the helper answers each line in order.
    private let queue = DispatchQueue(label: "mirage-dynamic-resolution")

    /// The request to capture with: for a fit, the virtual display (made or resized first) at its own pixels; without one,
    /// the real displays back (if this streamer made the virtual one, which stays until `settle`) and the request aimed at
    /// the real main display.
    func prepare(_ req: ControlMessage.StreamRequest, owner: AnyObject) async -> ControlMessage.StreamRequest {
        let me = ObjectIdentifier(owner)
        guard Self.enabled, let fit = req.fitDisplay, fit.width >= 320, fit.height >= 200 else {
            let mine = lock.withLock { () -> Bool in let m = self.owner == me; if m { self.owner = nil }; return m }
            guard mine else { return req }
            let main = await run { self.unmirror() }
            var r = req
            if main != 0 { r.displayID = main }
            return r
        }
        // Claimed before the display is made: a second viewer starting at the same moment finds it taken.
        let mine = lock.withLock { () -> Bool in
            if let o = self.owner, o != me { return false }
            self.owner = me; return true
        }
        guard mine else { return req }   // another viewer has the display sized to its window
        let scale = fit.scale >= 1.5 ? 2 : 1
        let w = min(fit.width, 8192 / scale), h = min(fit.height, 8192 / scale)
        guard let id = await run({ self.make(fit, width: w, height: h, scale: scale) }) else {
            lock.withLock { if self.owner == me, self.helper == nil { self.owner = nil } }
            return req
        }
        let shown = await waitForCapture(id, width: w, height: h, scale: scale)
        log("dynamic resolution: one display of \(w)x\(h) points\(scale > 1 ? (shown == .points ? " (Retina)" : shown == .pixels ? " (at 1x: no Retina mode)" : " (not seen yet)") : "")")
        var r = req
        r.displayID = id
        r.width = w * scale; r.height = h * scale
        return r
    }

    /// Removes a virtual display that was let go of (`prepare` without a fit), once nothing captures it.
    func settle() async {
        guard lock.withLock({ releasing }) else { return }
        await run { self.remove() }
    }

    /// The real displays back, if `owner` asked for the virtual one (the stream has ended).
    func end(owner: AnyObject) async {
        let mine = lock.withLock { () -> Bool in let m = self.owner == ObjectIdentifier(owner); if m { self.owner = nil }; return m }
        if mine { _ = await run { self.unmirror() } }
        await settle()
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in queue.async { c.resume(returning: body()) } }
    }

    // MARK: The display (on `queue`)

    private func make(_ fit: ControlMessage.FitDisplay, width w: Int, height h: Int, scale: Int) -> CGDirectDisplayID? {
        let releasing = lock.withLock { self.releasing }
        if fit == current, helper != nil, !releasing { return displayID }
        if releasing { remove() }   // let go of a moment ago: a fresh one, mirrored again
        if helper == nil {
            guard let h = Helper.start(log: log) else { return nil }
            helper = h
        }
        guard let reply = helper?.ask("fit \(w) \(h) \(scale)") else { log("dynamic resolution: the display helper stopped"); remove(); return nil }
        let p = reply.split(separator: " ").map(String.init)
        guard p.first == "ok", p.count >= 3, let id = UInt32(p[1]), let main = UInt32(p[2]) else {
            log("dynamic resolution: \(reply.hasPrefix("err ") ? String(reply.dropFirst(4)) : reply)")
            if displayID == 0 { remove() }
            return nil
        }
        if displayID == 0 { realMain = main }
        displayID = id
        current = fit
        return id
    }

    /// The real displays stop mirroring the virtual one (which stays, unused, until `remove`). Returns the main display
    /// to capture again.
    private func unmirror() -> CGDirectDisplayID {
        guard let helper else { return 0 }
        _ = helper.ask("unmirror")
        lock.withLock { releasing = true }
        current = nil
        return realMain
    }

    private func remove() {
        lock.withLock { releasing = false }
        guard let h = helper else { return }
        helper = nil
        h.finish()   // the helper puts the displays back and exits: macOS removes the display with it
        displayID = 0; current = nil
        log("dynamic resolution: displays back as they were")
    }

    /// Until ScreenCaptureKit lists the display at its new size (a few hundred milliseconds), 3 s at most: in points, or,
    /// failing that, at its pixels one to one (no Retina mode).
    private enum Shown { case points, pixels }
    private func waitForCapture(_ id: CGDirectDisplayID, width: Int, height: Int, scale: Int) async -> Shown? {
        var pixels = false   // a new display shows 1x before its HiDPI mode: that only if it stays so
        for _ in 0..<30 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let d = content.displays.first(where: { $0.displayID == id }) {
                if d.width == width, d.height == height { return .points }
                if scale > 1, d.width == width * scale, d.height == height * scale { pixels = true }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return pixels ? .pixels : nil
    }

    /// The helper process: one line out, one line back.
    private final class Helper {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        var buffer = Data()

        static func start(log: (String) -> Void) -> Helper? {
            let p = Process()
            // This executable (the launch agent names it by its bundle path, so not argv[0]).
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(getpid(), &buf, UInt32(buf.count)) > 0 else { log("dynamic resolution: this executable's path is unknown"); return nil }
            p.executableURL = URL(fileURLWithPath: String(cString: buf))
            p.arguments = ["virtual-display"]
            let i = Pipe(), o = Pipe()
            p.standardInput = i; p.standardOutput = o
            do { try p.run() } catch { log("dynamic resolution: the display helper did not start: \(error)"); return nil }
            // A write to a helper that has gone is an error here, not SIGPIPE ending the host.
            _ = fcntl(i.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            return Helper(process: p, input: i.fileHandleForWriting, output: o.fileHandleForReading)
        }

        private init(process: Process, input: FileHandle, output: FileHandle) { self.process = process; self.input = input; self.output = output }

        /// Its answer, or nil once it has gone (or after 20 s: a display that takes that long is not coming).
        func ask(_ line: String) -> String? {
            guard process.isRunning, (try? input.write(contentsOf: Data((line + "\n").utf8))) != nil else { return nil }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let l = String(decoding: buffer[..<nl], as: UTF8.self); buffer.removeSubrange(...nl); return l
                }
                var pfd = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                guard poll(&pfd, 1, left) > 0 else { continue }   // the deadline, checked above
                let d = output.availableData
                guard !d.isEmpty else { return nil }   // ended
                buffer.append(d)
            }
            process.terminate()   // stuck: no later answer is waited for, and its display goes with it
            return nil
        }

        func finish() {
            try? input.close()
            let p = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        }
    }
}

/// `miraged virtual-display`: owns the Dynamic Resolution display for the host (see `DynamicResolution`). Reads lines:
/// `fit W H SCALE` (points; made, or resized, and mirrored by every real display): `ok ID MAIN`, or `err REASON`;
/// `unmirror`: `ok`. At the end of its input it puts the displays back and exits, and macOS removes the display.
public enum VirtualDisplayHelper {
    /// Starts reading its input, on a thread of its own; the process exits at its end. CoreGraphics' calls go to the main
    /// thread, whose run loop brings it the display's changes (asked from another thread, its modes never showed); the
    /// main queue must be running, as an async command's is.
    public static func start() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let state = State()
        Thread.detachNewThread {
            while let line = readLine() {
                let p = line.split(separator: " ")
                var reply: String
                if p.first == "fit", p.count == 4, let w = Int(p[1]), let h = Int(p[2]), let s = Int(p[3]) {
                    reply = DispatchQueue.main.sync { state.fit(w, h, s) }
                    if reply == "new" {
                        // Mirrored once this process has seen it come online (its run loop brings that news).
                        for _ in 0..<40 where !DispatchQueue.main.sync(execute: { state.online() }) { usleep(50_000) }
                        reply = DispatchQueue.main.sync { state.mirrorNew(s) }
                    }
                } else if p.first == "unmirror" {
                    DispatchQueue.main.sync { state.unmirror() }
                    reply = "ok"
                } else {
                    reply = "err bad request"
                }
                print(reply)
            }
            DispatchQueue.main.sync { state.unmirror() }
            exit(0)
        }
    }

    private final class State {
        /// The display's own queue (its descriptor's): never blocked by the calls about it, made on the main thread (a
        /// display coming up while its queue waited on them stalled configurations for 10 s).
        let queue = DispatchQueue(label: "mirage-virtual-display")
        var display: NSObject?
        var id: CGDirectDisplayID = 0
        var mirrored: [CGDirectDisplayID] = []
        var realMain: CGDirectDisplayID = 0

        func fit(_ w: Int, _ h: Int, _ scale: Int) -> String {
            if display == nil {
                guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
                      let dispCls = NSClassFromString("CGVirtualDisplay") else { return "err virtual displays are not available" }
                let desc = descCls.init()
                desc.setValue("Mirage", forKey: "name")
                desc.setValue(8192, forKey: "maxPixelsWide")
                desc.setValue(8192, forKey: "maxPixelsHigh")
                // About a Retina laptop's density (sizes macOS reports in the display's info, nothing more).
                desc.setValue(NSValue(size: NSSize(width: 8192 / 8.66, height: 8192 / 8.66)), forKey: "sizeInMillimeters")
                desc.setValue(0x4D49, forKey: "vendorID")
                desc.setValue(0x5247, forKey: "productID")
                desc.setValue(1, forKey: "serialNum")
                desc.setValue(queue, forKey: "queue")
                guard let made = Self.call(dispCls, "alloc", initWith: "initWithDescriptor:", desc) else { return "err the virtual display was not made" }
                display = made
                id = (made.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
                guard id != 0 else { display = nil; return "err the virtual display has no ID" }
            }
            guard let display, let settingsCls = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
                  let modeCls = NSClassFromString("CGVirtualDisplayMode") else { return "err virtual displays are not available" }
            let settings = settingsCls.init()
            settings.setValue(scale > 1 ? 1 : 0, forKey: "hiDPI")
            // The window's points: hiDPI offers each mode at twice its pixels as well.
            guard let mode = Self.mode(modeCls, width: UInt32(w), height: UInt32(h)) else { return "err no mode" }
            settings.setValue([mode], forKey: "modes")
            guard Self.apply(display, settings) else { return "err \(w)x\(h) was refused" }
            // Mirrored as soon as it is online: a new display gets its modes from that configuration (unmirrored it
            // listed none for seconds); mirrored before this process saw it, it failed.
            if mirrored.isEmpty { self.settings = settings; return "new" }
            return "ok \(id) \(realMain)"
        }
        private var settings: NSObject?

        func online() -> Bool {
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetOnlineDisplayList(count, &ids, &count)
            return ids.prefix(Int(count)).contains(id)
        }

        func mirrorNew(_ scale: Int) -> String {
            guard mirror() else { return "err the displays could not mirror it" }
            // A new display starts at 1x; given its settings again, once mirrored, it takes the HiDPI mode (as a
            // resize does). (Its modes, bounds and pixels as this process sees them never update, so the host confirms
            // it from ScreenCaptureKit.)
            if scale > 1, let display, let settings { _ = Self.apply(display, settings) }
            return "ok \(id) \(realMain)"
        }

        /// Every real display shows the virtual one; displays already mirroring another follow it, as the person set them.
        func mirror() -> Bool {
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetOnlineDisplayList(count, &ids, &count)
            let real = ids.prefix(Int(count)).filter { $0 != id && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            realMain = CGMainDisplayID()
            var cfg: CGDisplayConfigRef?
            guard !real.isEmpty, CGBeginDisplayConfiguration(&cfg) == .success else { return false }
            for r in real { CGConfigureDisplayMirrorOfDisplay(cfg, r, id) }
            guard CGCompleteDisplayConfiguration(cfg, .forSession) == .success else { return false }
            mirrored = Array(real)
            return true
        }

        func unmirror() {
            guard !mirrored.isEmpty else { return }
            var cfg: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&cfg) == .success {
                for r in mirrored { CGConfigureDisplayMirrorOfDisplay(cfg, r, kCGNullDirectDisplay) }
                CGCompleteDisplayConfiguration(cfg, .forSession)
            }
            mirrored = []
        }

        // MARK: Objective-C runtime

        static func call(_ cls: AnyClass, _ alloc: String, initWith sel: String, _ arg: AnyObject) -> NSObject? {
            guard let a = (cls as AnyObject).perform(NSSelectorFromString(alloc))?.takeUnretainedValue() else { return nil }
            return a.perform(NSSelectorFromString(sel), with: arg)?.takeRetainedValue() as? NSObject
        }

        static func mode(_ cls: AnyClass, width: UInt32, height: UInt32) -> NSObject? {
            typealias Init = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
            let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
            guard let a = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
                  let imp = (a as? NSObject)?.method(for: sel) else { return nil }
            return unsafeBitCast(imp, to: Init.self)(a, sel, width, height, 60)?.takeRetainedValue() as? NSObject
        }

        static func apply(_ display: NSObject, _ settings: NSObject) -> Bool {
            typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
            let sel = NSSelectorFromString("applySettings:")
            guard let imp = display.method(for: sel) else { return false }
            return unsafeBitCast(imp, to: Apply.self)(display, sel, settings)
        }
    }
}
