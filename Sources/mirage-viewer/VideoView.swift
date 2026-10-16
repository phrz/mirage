import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import MirageCore

/// Presents decoded frames, draws the host cursor at the local pointer, forwards input.
final class VideoNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    let cursorLayer = CALayer()
    var session: ViewerSession?
    var model: ViewerModel?
    private var blankCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: img, hotSpot: .zero)
    }()
    private var aspect: CGFloat = 16.0 / 9.0
    private var resizeWork: DispatchWorkItem?
    private var pointerInside = false
    private var localPointer: CGPoint = .zero
    private var lastRequested: (Int, Int) = (0, 0)
    var onToggleStats: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        layer?.addSublayer(cursorLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }   // top-left origin, like the host display

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
        scheduleStreamRequest()
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); scheduleStreamRequest() }

    private func scheduleStreamRequest() {
        resizeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sendStreamRequest() }
        resizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: w)
    }

    func sendStreamRequest() {
        guard let session, let model, bounds.width > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale * model.pixelFactor), h = Int(bounds.height * scale * model.pixelFactor)
        guard (w, h) != lastRequested else { return }
        lastRequested = (w, h)
        session.requestStream(width: w, height: h)
    }

    // MARK: Presentation

    func present(_ image: CVImageBuffer, _ frame: VideoFrame) {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &fd) == noErr, let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let newAspect = CGFloat(dims.width) / CGFloat(dims.height)
        if displayLayer.sampleBufferRenderer.status == .failed { displayLayer.sampleBufferRenderer.flush() }
        displayLayer.sampleBufferRenderer.enqueue(sb)
        if abs(newAspect - aspect) > 0.001 { DispatchQueue.main.async { self.aspect = newAspect } }
    }

    /// Where the video actually is inside the view (letterboxed).
    var videoRect: CGRect {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return b }
        if b.width / b.height > aspect {
            let w = b.height * aspect
            return CGRect(x: (b.width - w) / 2, y: 0, width: w, height: b.height)
        } else {
            let h = b.width / aspect
            return CGRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
        }
    }

    private func normalized(_ e: NSEvent) -> (Double, Double) {
        let p = convert(e.locationInWindow, from: nil)
        let r = videoRect
        return (Double((p.x - r.minX) / r.width), Double((p.y - r.minY) / r.height))
    }

    // MARK: Cursor

    func updateCursorLayer() {
        guard let model else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let c = model.cursor else { cursorLayer.isHidden = true; return }
        var pos: CGPoint? = nil
        if pointerInside { pos = localPointer }
        else if let rc = model.remoteCursor {
            let r = videoRect
            pos = CGPoint(x: r.minX + rc.x * r.width, y: r.minY + rc.y * r.height)
        }
        guard let pos else { cursorLayer.isHidden = true; return }
        cursorLayer.isHidden = false
        cursorLayer.contents = c.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cursorLayer.frame = CGRect(x: pos.x - c.hotspot.x, y: pos.y - c.hotspot.y, width: c.size.width, height: c.size.height)
    }

    override func cursorUpdate(with event: NSEvent) { blankCursor.set() }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; blankCursor.set(); updateCursorLayer() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; NSCursor.arrow.set(); updateCursorLayer() }

    // MARK: Input forwarding

    private func flags(_ e: NSEvent) -> UInt64 { e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue) }

    private func moved(_ e: NSEvent) {
        localPointer = convert(e.locationInWindow, from: nil)
        pointerInside = bounds.contains(localPointer)
        updateCursorLayer()
        let (x, y) = normalized(e)
        session?.sendMouseMove(x: x, y: y)
    }
    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseDragged(with event: NSEvent) { moved(event) }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }

    private func button(_ e: NSEvent, _ b: Int, down: Bool) {
        if down { window?.makeFirstResponder(self) }
        let (x, y) = normalized(e)
        session?.send(.mouseButton(.init(button: b, down: down, x: x, y: y, clickCount: e.clickCount, modifiers: flags(e))))
    }
    override func mouseDown(with event: NSEvent) { button(event, 0, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, 0, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, 1, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, 1, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, max(2, event.buttonNumber), down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, max(2, event.buttonNumber), down: false) }

    override func scrollWheel(with event: NSEvent) {
        let (x, y) = normalized(event)
        let precise = event.hasPreciseScrollingDeltas
        session?.send(.scroll(.init(x: x, y: y, dx: precise ? event.scrollingDeltaX : event.deltaX, dy: precise ? event.scrollingDeltaY : event.deltaY,
                                    precise: precise, modifiers: flags(event))))
    }

    /// Viewer-local shortcuts: ⌃⌥⌘ + S (stats), ↑/↓ (bitrate), Q (quit). Everything else goes to the host.
    private func handleLocal(_ e: NSEvent) -> Bool {
        let local: NSEvent.ModifierFlags = [.control, .option, .command]
        guard e.modifierFlags.intersection([.control, .option, .command, .shift]) == local else { return false }
        switch e.keyCode {
        case 1: onToggleStats?(); return true                       // S
        case 126: Task { @MainActor in session?.adjustBitrate(by: 200) }; return true   // ↑
        case 125: Task { @MainActor in session?.adjustBitrate(by: -200) }; return true  // ↓
        case 12: session?.stop(); NSApp.terminate(nil); return true  // Q
        default: return false
        }
    }

    private func key(_ e: NSEvent, down: Bool) {
        session?.send(.key(.init(keyCode: e.keyCode, down: down, isRepeat: down && e.isARepeat, modifiers: flags(e),
                                 characters: down ? e.characters : nil)))
    }
    override func keyDown(with event: NSEvent) { if !handleLocal(event) { key(event, down: true) } }
    override func keyUp(with event: NSEvent) { key(event, down: false) }
    override func flagsChanged(with event: NSEvent) { session?.send(.modifiers(.init(keyCode: event.keyCode, modifiers: flags(event)))) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Swallow ⌘-shortcuts so the viewer's own menu does not eat them; forward to the host.
        guard window?.firstResponder === self else { return false }
        if handleLocal(event) { return true }
        if event.type == .keyDown { key(event, down: true) } else if event.type == .keyUp { key(event, down: false) }
        return true
    }
}

struct VideoView: NSViewRepresentable {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel

    func makeNSView(context: Context) -> VideoNSView {
        let v = VideoNSView(frame: .zero)
        v.session = session; v.model = model
        v.onToggleStats = { model.showStats.toggle() }
        session.present = { [weak v] image, frame in v?.present(image, frame) }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ v: VideoNSView, context: Context) {
        v.updateCursorLayer()
        v.sendStreamRequest()
    }
}
