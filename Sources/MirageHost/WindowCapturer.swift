import Foundation
import ScreenCaptureKit
import CoreMedia
import MirageCore

/// One `desktopIndependentWindow` SCStream: the window's own pixels, whole and unoccluded, at the
/// stream's pixel scale, shadow left out (the client draws its own), the off-screen part included.
/// SCK delivers a frame per interval for these whether or not anything changed (measured: a static
/// window at 30 fps, alternating two IOSurfaces, and the dirty rect is always the whole window), so the
/// streamer's tolerant CPU diff is the change detector and the interval is the cost knob.
final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let windowID: UInt32
    private(set) var window: SCWindow
    private var stream: SCStream?
    private let queue: DispatchQueue
    private var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    private(set) var width: Int, height: Int
    private(set) var fps: Int
    var onStop: ((Error?) -> Void)?
    private(set) var frames = 0
    private var sizeMismatchLogged = false, statusLogged = false

    init(window: SCWindow, width: Int, height: Int, fps: Int, queue: DispatchQueue) {
        self.window = window; windowID = window.windowID; self.width = max(2, width) & ~1; self.height = max(2, height) & ~1; self.fps = fps; self.queue = queue
    }

    private func configuration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = width; c.height = height
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(fps, 60))))
        c.capturesAudio = false
        c.ignoreShadowsSingleWindow = true
        c.ignoreGlobalClipSingleWindow = true
        c.shouldBeOpaque = false
        // macOS 26/27 draws a titled window's traffic lights in a 66×20 child window of their own; the
        // layer must include it, and the window list folds such children into their parent.
        c.includeChildWindows = true
        return c
    }

    func start(onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) async throws {
        self.onFrame = onFrame
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration(), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    /// New pixel size (the window was resized) and/or frame interval.
    func update(width: Int, height: Int, fps: Int) async throws {
        let w = max(2, width) & ~1, h = max(2, height) & ~1
        guard w != self.width || h != self.height || fps != self.fps else { return }
        self.width = w; self.height = h; self.fps = fps
        guard let stream else { return }
        try await stream.updateConfiguration(configuration())
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw) else { return }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else {
            if !statusLogged { statusLogged = true; hostLog("layer \(windowID): frame status \(statusRaw) (\(status == .idle ? "idle" : status == .blank ? "blank" : status == .suspended ? "suspended" : status == .started ? "started" : status == .stopped ? "stopped" : "?"))") }
            return
        }
        // A frame delivered at the old size around a reconfiguration is skipped (the content is scaled into it).
        guard CVPixelBufferGetWidth(pb) == width, CVPixelBufferGetHeight(pb) == height else {
            if !sizeMismatchLogged { sizeMismatchLogged = true; hostLog("layer \(windowID): frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) does not match the configured \(width)x\(height)") }
            return
        }
        frames += 1
        onFrame?(pb, Clock.nowNanos())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}
