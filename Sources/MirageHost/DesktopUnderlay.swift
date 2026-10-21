import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import MirageCore

/// The desktop as it is under every window: a capture of the display that includes only the desktop-level windows
/// (the wallpaper, the desktop icons and widgets: window layer below zero), at half size, one frame every 2 s. Window
/// pixels cannot be in it, whether or not the display stream manages to exclude a window, so the streamer can send it
/// ahead (lossy) for the desktop under windows the viewer has never seen, and Show Desktop reveals something real at once
/// (DESIGN §3.2, desktop underlay).
final class DesktopUnderlay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "mirage.desktop-underlay")
    private var stream: SCStream?
    private let lock = NSLock()
    private var latest: (frame: CVPixelBuffer, nanos: UInt64)?
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) { self.log = log }

    /// The newest frame (half the stream size) and when it arrived.
    var frame: (frame: CVPixelBuffer, nanos: UInt64)? { lock.lock(); defer { lock.unlock() }; return latest }

    /// Starts on `display` with `desktopWindows` (the catalog's windows below layer zero), `width`×`height` pixels.
    func start(display: SCDisplay, desktopWindows: [SCWindow], width: Int, height: Int) async throws {
        guard !desktopWindows.isEmpty else { throw MirageError.transport("no desktop-level windows to capture") }
        let filter = SCContentFilter(display: display, including: desktopWindows)
        let c = SCStreamConfiguration()
        c.width = max(16, width); c.height = max(16, height)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 2, timescale: 1)
        c.capturesAudio = false
        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        lock.lock(); stream = s; lock.unlock()
    }

    func stop() async {
        lock.lock(); let s = stream; stream = nil; latest = nil; lock.unlock()
        try? await s?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = CMSampleBufferGetImageBuffer(sb),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        lock.lock(); latest = (pb, Clock.nowNanos()); lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { log("desktop underlay capture stopped: \(error)") }
}
