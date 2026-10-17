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
        c.queueDepth = 6
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(maxFPS, 120))))
        c.capturesAudio = false
        return c
    }

    func start(_ req: ControlMessage.StreamRequest, onFrame: @escaping (CVPixelBuffer, UInt64, [PixelRect]) -> Void) async throws -> Target {
        let t = try await Self.resolve(req)
        self.onFrame = onFrame
        self.target = t
        let filter = SCContentFilter(display: t.display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: Self.configuration(for: t, maxFPS: req.maxFPS), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        if displayAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Mirage viewer connected" as CFString, &displayAssertion)
        }
        return t
    }

    func update(_ req: ControlMessage.StreamRequest) async throws -> Target {
        guard let stream, let old = target else { throw MirageError.transport("not capturing") }
        var t = try await Self.resolve(req)
        if t.display.displayID != old.display.displayID {
            try await stream.updateContentFilter(SCContentFilter(display: t.display, excludingWindows: []))
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
