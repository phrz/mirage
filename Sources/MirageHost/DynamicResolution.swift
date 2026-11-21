import Foundation
import CoreGraphics
import ScreenCaptureKit
import MirageCore

/// Dynamic Resolution (the viewer's View menu): while a viewer asks, the Mac shows one display the size of its window.
/// A virtual display (CoreGraphics' CGVirtualDisplay, as display utilities make) is created at the window's points, at
/// the viewer's pixels per point, and every real display mirrors it, so the whole desktop is that one screen and the stream
/// is its pixels one to one. A resized window changes its mode; the end of the stream (or the option turned off) ends the
/// mirroring and removes it. It lives in this process: if the host quits or crashes, macOS drops it and the real displays
/// come back by themselves.
///
/// The classes are private CoreGraphics API, reached through the Objective-C runtime; where they are missing nothing changes.
final class DynamicResolution: @unchecked Sendable {
    static let shared = DynamicResolution()

    private let lock = NSLock()
    private var display: NSObject?
    private var displayID: CGDirectDisplayID = 0
    private var mirrored: [CGDirectDisplayID] = []
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

    /// The request to capture with: for a fit, the virtual display (made or resized first) at its own pixels; without one,
    /// the real displays back (if this streamer made the virtual one, which stays until `settle`) and the request aimed at
    /// the real main display.
    func prepare(_ req: ControlMessage.StreamRequest, owner: AnyObject) async -> ControlMessage.StreamRequest {
        let me = ObjectIdentifier(owner)
        guard let fit = req.fitDisplay, fit.width >= 320, fit.height >= 200 else {
            let mine = lock.withLock { () -> Bool in let m = self.owner == me; if m { self.owner = nil }; return m }
            guard mine else { return req }
            let main = await MainActor.run { () -> CGDirectDisplayID in self.unmirror() }
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
        let id = await MainActor.run { () -> CGDirectDisplayID? in self.make(fit, width: w, height: h, scale: scale) }
        guard let id else { lock.withLock { if self.owner == me, self.display == nil { self.owner = nil } }; return req }
        await waitForCapture(id, width: w, height: h)
        var r = req
        r.displayID = id
        r.width = w * scale; r.height = h * scale
        return r
    }

    /// Removes a virtual display that was let go of (`prepare` without a fit), once nothing captures it.
    func settle() async {
        guard lock.withLock({ releasing }) else { return }
        await MainActor.run { self.remove() }
    }

    /// The real displays back, if `owner` asked for the virtual one (the stream has ended).
    func end(owner: AnyObject) async {
        let mine = lock.withLock { () -> Bool in let m = self.owner == ObjectIdentifier(owner); if m { self.owner = nil }; return m }
        if mine { await MainActor.run { _ = self.unmirror() } }
        await settle()
    }

    // MARK: The display

    @MainActor private func make(_ fit: ControlMessage.FitDisplay, width w: Int, height h: Int, scale: Int) -> CGDirectDisplayID? {
        if fit == current, display != nil, !lock.withLock({ releasing }) { return displayID }
        if lock.withLock({ releasing }) { remove() }   // let go of a moment ago: a fresh one, mirrored again
        if display == nil {
            guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
                  let dispCls = NSClassFromString("CGVirtualDisplay") else { log("dynamic resolution: virtual displays are not available"); return nil }
            let desc = descCls.init()
            desc.setValue("Mirage", forKey: "name")
            desc.setValue(8192, forKey: "maxPixelsWide")
            desc.setValue(8192, forKey: "maxPixelsHigh")
            // About a Retina laptop's density (sizes macOS reports in the display's info, nothing more).
            desc.setValue(NSValue(size: NSSize(width: 8192 / 8.66, height: 8192 / 8.66)), forKey: "sizeInMillimeters")
            desc.setValue(0x4D49, forKey: "vendorID")
            desc.setValue(0x5247, forKey: "productID")
            desc.setValue(1, forKey: "serialNum")
            desc.setValue(DispatchQueue.main, forKey: "queue")
            guard let made = Self.call(dispCls, "alloc", initWith: "initWithDescriptor:", desc) else {
                log("dynamic resolution: the virtual display was not made"); return nil
            }
            display = made
            displayID = (made.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
            guard displayID != 0 else { display = nil; log("dynamic resolution: the virtual display has no ID"); return nil }
        }
        guard let display, let settingsCls = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeCls = NSClassFromString("CGVirtualDisplayMode") else { return nil }
        let settings = settingsCls.init()
        settings.setValue(scale > 1 ? 1 : 0, forKey: "hiDPI")
        // The window's pixels: shown Retina (half in points) when hiDPI.
        guard let mode = Self.mode(modeCls, width: UInt32(w * scale), height: UInt32(h * scale)) else { return nil }
        settings.setValue([mode], forKey: "modes")
        guard Self.apply(display, settings) else { log("dynamic resolution: \(w)x\(h) was refused"); return nil }
        pick(width: w, height: h, scale: scale)
        if mirrored.isEmpty { mirror() }
        current = fit
        log("dynamic resolution: one display of \(w)x\(h) points\(scale > 1 ? " (Retina)" : "")")
        return displayID
    }

    /// The display's mode at the window's points and pixels (its HiDPI one when Retina).
    @MainActor private func pick(width: Int, height: Int, scale: Int) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let m = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * scale })
                ?? modes.first(where: { $0.pixelWidth == width * scale && $0.pixelHeight == height * scale }) else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayWithDisplayMode(cfg, displayID, m, nil)
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    /// Every real display shows the virtual one.
    @MainActor private func mirror() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        // Displays already mirroring another follow it; only those are left as the person set them.
        let real = ids.prefix(Int(count)).filter { $0 != displayID && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        var cfg: CGDisplayConfigRef?
        realMain = CGMainDisplayID()
        guard !real.isEmpty, CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for id in real { CGConfigureDisplayMirrorOfDisplay(cfg, id, displayID) }
        if CGCompleteDisplayConfiguration(cfg, .forSession) == .success { mirrored = Array(real) }
        else { log("dynamic resolution: the displays could not mirror it") }
    }

    /// The real displays stop mirroring the virtual one (which stays, unused, until `remove`). Returns the main display
    /// to capture again.
    @MainActor private func unmirror() -> CGDirectDisplayID {
        guard display != nil else { return 0 }
        if !mirrored.isEmpty {
            var cfg: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&cfg) == .success {
                for id in mirrored { CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay) }
                CGCompleteDisplayConfiguration(cfg, .forSession)
            }
            mirrored = []
        }
        lock.withLock { releasing = true }
        current = nil
        return realMain
    }

    @MainActor private func remove() {
        if !mirrored.isEmpty { _ = unmirror() }
        lock.withLock { releasing = false }
        guard display != nil else { return }
        display = nil   // released: macOS removes it
        displayID = 0; current = nil
        log("dynamic resolution: displays back as they were")
    }

    /// Until ScreenCaptureKit lists the display at its new size (a few hundred milliseconds), 3 s at most.
    private func waitForCapture(_ id: CGDirectDisplayID, width: Int, height: Int) async {
        for _ in 0..<30 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               content.displays.contains(where: { $0.displayID == id && $0.width == width && $0.height == height }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Objective-C runtime

    private static func call(_ cls: AnyClass, _ alloc: String, initWith sel: String, _ arg: AnyObject) -> NSObject? {
        guard let a = (cls as AnyObject).perform(NSSelectorFromString(alloc))?.takeUnretainedValue() else { return nil }
        return a.perform(NSSelectorFromString(sel), with: arg)?.takeRetainedValue() as? NSObject
    }

    private static func mode(_ cls: AnyClass, width: UInt32, height: UInt32) -> NSObject? {
        typealias Init = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let a = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let imp = (a as? NSObject)?.method(for: sel) else { return nil }
        return unsafeBitCast(imp, to: Init.self)(a, sel, width, height, 60)?.takeRetainedValue() as? NSObject
    }

    private static func apply(_ display: NSObject, _ settings: NSObject) -> Bool {
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let sel = NSSelectorFromString("applySettings:")
        guard let imp = display.method(for: sel) else { return false }
        return unsafeBitCast(imp, to: Apply.self)(display, sel, settings)
    }
}
