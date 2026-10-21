import AVFoundation
import CoreVideo
import Metal

/// Records every presented frame of the Metal view (`--record <path.mov> --record-seconds <s>`), stamped with the
/// display link's target presentation time, so a 120 Hz display gives a true 120 fps file to step through.
final class FrameRecorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var cache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "reveal-lab.recorder")
    private var t0: CFTimeInterval? = nil
    private(set) var frames = 0
    private(set) var dropped = 0
    let width: Int, height: Int
    private var finished = false

    init?(url: URL, width: Int, height: Int, device: MTLDevice) {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000, AVVideoExpectedSourceFrameRateKey: 120],
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = true
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: attrs)
        guard w.canAdd(i) else { return nil }
        w.add(i)
        writer = w; input = i
        self.width = width; self.height = height
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard w.startWriting() else { return nil }
        w.startSession(atSourceTime: .zero)
    }

    /// Encodes a blit of `texture` into a pooled pixel buffer; the frame is appended when `cb` completes.
    func capture(_ texture: MTLTexture, at time: CFTimeInterval, in cb: MTLCommandBuffer) {
        guard !finished, texture.width == width, texture.height == height, let pool = adaptor.pixelBufferPool, let cache else { dropped += 1; return }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { dropped += 1; return }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, width, height, 0, &cvTex)
        guard let cvTex, let dst = CVMetalTextureGetTexture(cvTex), let blit = cb.makeBlitCommandEncoder() else { dropped += 1; return }
        blit.copy(from: texture, to: dst)
        blit.endEncoding()
        if t0 == nil { t0 = time }
        let pts = CMTime(seconds: time - t0!, preferredTimescale: 12000)
        cb.addCompletedHandler { [self] _ in
            queue.async { [self] in
                _ = cvTex
                if !finished && input.isReadyForMoreMediaData && adaptor.append(pb, withPresentationTime: pts) { frames += 1 } else { dropped += 1 }
            }
        }
    }

    func finish(_ done: @escaping (Int, Int) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            input.markAsFinished()
            writer.finishWriting { done(self.frames, self.dropped) }
        }
    }
}
