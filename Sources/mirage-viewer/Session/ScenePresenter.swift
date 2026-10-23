import Foundation
import CoreGraphics
import QuartzCore
import Metal
import ImageIO
import MirageCore

/// One display-link tick of the picture, the same on the Mac (`VideoNSView`) and iOS (`DesktopUIView`): the session's
/// scene (the display layer, every window layer back to front, the overlay layer on top), drawn into the view's
/// CAMetalLayer when anything in it changed, with the display layer at `videoRect` (view points; the views differ only in
/// where they put the picture: the Mac letterboxes it, iOS zooms and pans it).
final class ScenePresenter {
    private var lastDisplacementCount = 0
    private var lastArrangement = -1
    /// Draw at the next tick even if the scene looks unchanged (the session's canvases changed, the view moved the picture).
    var forceRedraw = false
    /// Frames presented (stats and tests).
    private(set) var presented = 0
    /// Test knob MIRAGE_TEST_PRESENT_DUMP=<dir>: what the window actually presented (the drawable), every 2 s, as PNG with
    /// the picture's rect in the name's sidecar line (dumps.txt). The scene recorder renders the scene off-screen at its own
    /// scale; this is the window's own pixels (phrz: display layers soft in the Mac app while the scene was sharp).
    static let dumpDirectory: URL? = ProcessInfo.processInfo.environment["MIRAGE_TEST_PRESENT_DUMP"].map { URL(fileURLWithPath: $0) }
    private var lastDump: UInt64 = 0, dumped = 0
    static func dump(_ tex: MTLTexture, context: MetalContext, to url: URL, dest: CGRect) {
        let w = tex.width, h = tex.height, stride = w * 4
        guard let buf = context.device.makeBuffer(length: stride * h, options: .storageModeShared), let cb = context.commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * h)
        blit.endEncoding()
        cb.addCompletedHandler { _ in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(bytes: buf.contents(), count: stride * h)
            guard let provider = CGDataProvider(data: data as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
            let line = "\(url.lastPathComponent) \(w)x\(h) dest \(Int(dest.minX)),\(Int(dest.minY)) \(Int(dest.width))x\(Int(dest.height)) at \(Clock.nowNanos() / 1_000_000)\n"
            if let fh = try? FileHandle(forWritingTo: url.deletingLastPathComponent().appendingPathComponent("dumps.txt")) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
            else { try? line.write(to: url.deletingLastPathComponent().appendingPathComponent("dumps.txt"), atomically: true, encoding: .utf8) }
        }
        cb.commit()
    }

    /// Draws the scene if it changed since the last tick; returns whether it did.
    @discardableResult
    func tick(_ session: ViewerSession, layer: CAMetalLayer, videoRect r: CGRect) -> Bool {
        guard let comp = session.compositor, comp.width > 0, let context = session.context else { return false }
        let ppp = MainActor.assumeIsolated { session.pixelsPerPoint }
        guard let scene = session.scene(pxPerPoint: ppp) else { return false }
        let arrangement = session.arrangementGeneration
        var layersDirty = false
        for it in scene.items { if case .layer(let c, _, _, _) = it, c.needsRender { layersDirty = true; break } }
        let changed = comp.needsRender || layersDirty || !scene.displacements.isEmpty || lastDisplacementCount != scene.displacements.count
            || arrangement != lastArrangement || session.hasPendingPredictions || forceRedraw
        lastDisplacementCount = scene.displacements.count; lastArrangement = arrangement; forceRedraw = false
        guard changed, let drawable = layer.nextDrawable() else { return false }
        let scale = layer.contentsScale
        let dest = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        session.lastDest = dest
        SceneRenderer.render(scene, context: context, to: drawable, dest: dest)
        presented += 1
        if let dir = Self.dumpDirectory, Clock.elapsed(since: lastDump, now: Clock.nowNanos()) >= 2_000_000_000 {
            lastDump = Clock.nowNanos(); dumped += 1
            Self.dump(drawable.texture, context: context, to: dir.appendingPathComponent(String(format: "present-%03d.png", dumped)), dest: dest)
        }
        return true
    }
}
