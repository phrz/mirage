import Foundation
import ScreenCaptureKit
import CoreMedia
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
    /// (pixel buffer, capture clock, dirty fraction 0…1 of the output frame)
    private var onFrame: ((CVPixelBuffer, UInt64, Double) -> Void)?
    private(set) var target: Target?
    var onStop: ((Error?) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// Resolves the display and the stream size (display aspect fitted into the request).
    static func resolve(_ req: ControlMessage.StreamRequest) async throws -> Target {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let main = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == (req.displayID ?? main) }) ?? content.displays.first else {
            throw MirageError.transport("no display to capture")
        }
        let pw = Double(CGDisplayPixelsWide(display.displayID)), ph = Double(CGDisplayPixelsHigh(display.displayID))
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
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(maxFPS, 120))))
        c.capturesAudio = false
        return c
    }

    func start(_ req: ControlMessage.StreamRequest, onFrame: @escaping (CVPixelBuffer, UInt64, Double) -> Void) async throws -> Target {
        let t = try await Self.resolve(req)
        self.onFrame = onFrame
        self.target = t
        let filter = SCContentFilter(display: t.display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: Self.configuration(for: t, maxFPS: req.maxFPS), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
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
        var dirty = 1.0
        if let rects = attachments.first?[.dirtyRects] as? [Any] {
            let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
            let area = rects.reduce(0.0) { acc, r in
                guard let d = r as? NSDictionary, let rect = CGRect(dictionaryRepresentation: d) else { return acc + w * h }
                return acc + Double(rect.width * rect.height)
            }
            dirty = min(1, area / (w * h))
        }
        if dirty == 0 { return }   // nothing changed; SCK still delivers these around the first frames
        onFrame?(pb, Clock.nowNanos(), dirty)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
