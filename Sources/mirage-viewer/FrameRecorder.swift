import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MirageCore

/// Test knob `MIRAGE_TEST_FRAMES=<dir>`: renders the composited scene (what the window would show) off-screen at a
/// quarter of the display's pixel size five times a second and writes `frame-NNNN.png` plus one `frames.jsonl` line
/// per frame (time, layer rects in frame pixels). The frame-sheet check of DESIGN §3.3 (presentation steps) reads them.
final class FrameRecorder {
    static let directory: URL? = ProcessInfo.processInfo.environment["MIRAGE_TEST_FRAMES"].map { URL(fileURLWithPath: $0) }
    let dir: URL
    let scale = 0.25
    private var index = 0
    private let start = Clock.nowNanos()
    private var log: FileHandle?
    private var target: MTLTexture?

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("frames.jsonl").path
        FileManager.default.createFile(atPath: path, contents: nil)
        log = FileHandle(forWritingAtPath: path)
    }

    struct Line: Codable { var i: Int; var ms: Int; var clock: Int = 0; var width: Int; var height: Int; var layers: [L] }
    struct L: Codable { var id: UInt32; var x: Int; var y: Int; var w: Int; var h: Int }

    /// On the viewer's video queue (where every canvas write happens).
    func capture(scene: LayerScene, layers: [(UInt32, PixelRect)], context: MetalContext) {
        guard let bg = scene.background, bg.width > 0 else { return }
        let w = max(1, Int(Double(bg.width) * scale)), h = max(1, Int(Double(bg.height) * scale))
        if target == nil || target!.width != w || target!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            target = context.device.makeTexture(descriptor: d)
        }
        guard let target else { return }
        SceneRenderer.render(scene, context: context, target: target, dest: CGRect(x: 0, y: 0, width: w, height: h))
        let stride = w * 4
        guard let buf = context.device.makeBuffer(length: stride * h, options: .storageModeShared), let cb = context.commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * h)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let i = index; index += 1
        let ms = Int(Clock.elapsed(since: start, now: Clock.nowNanos()) / 1_000_000)
        let data = Data(bytes: buf.contents(), count: stride * h)
        let line = Line(i: i, ms: ms, clock: Int(Clock.nowNanos() / 1_000_000), width: w, height: h, layers: layers.map { id, r in L(id: id, x: Int(Double(r.x) * scale), y: Int(Double(r.y) * scale), w: Int(Double(r.width) * scale), h: Int(Double(r.height) * scale)) })
        if let j = try? JSONEncoder().encode(line) { log?.write(j + Data("\n".utf8)) }
        let url = dir.appendingPathComponent(String(format: "frame-%04d.png", i))
        DispatchQueue.global(qos: .utility).async {
            guard let provider = CGDataProvider(data: data as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

/// Test knob `MIRAGE_TEST_UNIFIED_SHOTS=<dir>` (Unified mode): every 2 s, each remote window's content as its native
/// window draws it (`win-<id>-NNN.png`, full size, alpha kept), plus `unified.jsonl` with the local frames. Only
/// windows the host captures as layers, so a loopback run with MIRAGE_LAYER_APPS shows nothing of the person's screen.
enum UnifiedShots {
    static let directory: URL? = ProcessInfo.processInfo.environment["MIRAGE_TEST_UNIFIED_SHOTS"].map { URL(fileURLWithPath: $0) }
    static func write(_ c: Compositor, source: PixelRect, context: MetalContext, to url: URL) {
        render(context: context, width: source.width, height: source.height, to: url) { target in
            SceneRenderer.renderCrop(c, source: source, displacements: [], bandColors: [:], context: context, target: target, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        }
    }
    /// Test knob `MIRAGE_TEST_BENCH_SHOTS=<dir>` (any mode, `--scenario` runs): the composited scene cropped to the bench
    /// window plus a margin, `bench-NNNN.png` at `MIRAGE_TEST_BENCH_FPS` (default 2): what the person sees of our own
    /// window and its corners and shadow, and nothing of the rest of the screen.
    static func write(scene: LayerScene, crop: PixelRect, context: MetalContext, to url: URL) {
        guard let bg = scene.background, bg.width > 0 else { return }
        render(context: context, width: crop.width, height: crop.height, to: url) { target in
            SceneRenderer.render(scene, context: context, target: target, dest: CGRect(x: -crop.x, y: -crop.y, width: bg.width, height: bg.height))
        }
    }
    private static func render(context: MetalContext, width: Int, height: Int, to url: URL, draw: (MTLTexture) -> Void) {
        let w = max(1, width), h = max(1, height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        guard let target = context.device.makeTexture(descriptor: d) else { return }
        draw(target)
        let stride = w * 4
        guard let buf = context.device.makeBuffer(length: stride * h, options: .storageModeShared), let cb = context.commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * h)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let data = Data(bytes: buf.contents(), count: stride * h)
        DispatchQueue.global(qos: .utility).async {
            guard let provider = CGDataProvider(data: data as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
