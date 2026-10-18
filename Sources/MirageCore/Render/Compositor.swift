import Foundation
import Metal
import MetalFX
import CoreVideo
import QuartzCore

/// Metal objects every canvas of one viewer shares: one device, one command queue (so writes into
/// different layers and the scene render that samples them are ordered for free), the pipelines.
public final class MetalContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache
    let quadPipeline: MTLRenderPipelineState        // opaque copy
    let fillPipeline: MTLRenderPipelineState        // solid colour
    let blendPipeline: MTLRenderPipelineState       // texture × alpha, premultiplied over
    let shadowPipeline: MTLRenderPipelineState      // soft rounded-rect shadow
    let yuvPipeline: MTLComputePipelineState
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else { return nil }
        self.device = device; commandQueue = q
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        textureCache = cache
        do {
            let lib = try device.makeLibrary(source: Compositor.shaderSource, options: nil)
            let rp = MTLRenderPipelineDescriptor()
            rp.vertexFunction = lib.makeFunction(name: "quadVertex")
            rp.fragmentFunction = lib.makeFunction(name: "quadFragment")
            rp.colorAttachments[0].pixelFormat = .bgra8Unorm
            quadPipeline = try device.makeRenderPipelineState(descriptor: rp)
            rp.fragmentFunction = lib.makeFunction(name: "fillFragment")
            fillPipeline = try device.makeRenderPipelineState(descriptor: rp)
            // Canvases hold premultiplied alpha (a layered window's rounded corners): "over" is one / one-minus-src-alpha.
            rp.fragmentFunction = lib.makeFunction(name: "blendFragment")
            rp.colorAttachments[0].isBlendingEnabled = true
            rp.colorAttachments[0].sourceRGBBlendFactor = .one; rp.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            rp.colorAttachments[0].sourceAlphaBlendFactor = .one; rp.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blendPipeline = try device.makeRenderPipelineState(descriptor: rp)
            rp.vertexFunction = lib.makeFunction(name: "shadowVertex")
            rp.fragmentFunction = lib.makeFunction(name: "shadowFragment")
            shadowPipeline = try device.makeRenderPipelineState(descriptor: rp)
            yuvPipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "nv12ToBGRA")!)
        } catch { FileHandle.standardError.write(Data("metal: pipeline setup failed: \(error)\n".utf8)); return nil }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: sd)!
        sd.minFilter = .nearest; sd.magFilter = .nearest
        nearestSampler = device.makeSamplerState(descriptor: sd)!
    }
}

/// Metal canvas compositor (macOS + iOS). One instance is one layer's picture at native stream size:
/// the display layer, or a window captured as its own layer (DESIGN §3.2). Host updates write into
/// it in arrival order: video frames (masked tiles of the decoded picture, upscaled with MetalFX when
/// the host is below native), lossless tiles, lossy stills, and copy-rects. `SceneRenderer` draws the
/// layers into a drawable with shadows and the Predictor's displacements.
/// All methods are called from one queue (the viewer's video queue); rendering from the display link.
public final class Compositor {
    public let context: MetalContext
    public var device: MTLDevice { context.device }
    var commandQueue: MTLCommandQueue { context.commandQueue }

    public private(set) var width = 0, height = 0
    private(set) public var canvas: MTLTexture?
    private var scratch: MTLTexture?       // copy-rect intermediate
    private var videoRGB: MTLTexture?      // decoded frame converted to BGRA (encoded size)
    private var videoUp: MTLTexture?       // upscaled to native when below native
    private var scaler: MTLFXSpatialScaler?
    private var incoming: MTLTexture?      // pixels still crossfading in (refinement, progressive steps)
    public struct Fade: Equatable { public var rect: PixelRect; public var startNanos: UInt64 }
    private var fades: [Fade] = []
    /// Crossfade length for refinement and progressive steps.
    public var crossfadeNanos: UInt64 = 150_000_000
    private var scalerSize: (Int, Int, Int, Int) = (0, 0, 0, 0)
    private let lock = NSLock()
    private var generation = 0             // bumped on every change; render() compares
    public private(set) var renderedGeneration = -1
    public var usesMetalFX: Bool { scaler != nil }
    public private(set) var lastUpscaleMs = 0.0
    /// Whether the canvas may hold transparency (a window layer: premultiplied alpha); the display layer is opaque.
    public var hasAlpha = false
    /// The layer this canvas shows (0 = the display layer); displacements are keyed by it.
    public var layerID: UInt32 = 0
    /// Receiver clock of the last write (layer cache eviction).
    public private(set) var lastWriteNanos: UInt64 = 0
    /// Bytes of texture memory this canvas holds (canvas + scratch + incoming).
    public var textureBytes: Int { (canvas == nil ? 0 : width * height * 4) * (1 + (scratch == nil ? 0 : 1) + (incoming == nil ? 0 : 1)) }

    struct Quad { var dst: SIMD4<Float>; var src: SIMD4<Float> }

    public convenience init?() {
        guard let ctx = MetalContext() else { return nil }
        self.init(context: ctx)
    }
    public init(context: MetalContext) { self.context = context }

    // MARK: Canvas

    public func configure(width: Int, height: Int) {
        guard width > 0, height > 0, width != self.width || height != self.height else { return }
        self.width = width; self.height = height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        canvas = device.makeTexture(descriptor: d)
        scratch = nil
        incoming = nil
        fades = []
        clear()
    }
    private func ensureScratch() -> MTLTexture? {
        if scratch == nil, width > 0 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
            scratch = device.makeTexture(descriptor: d)
        }
        return scratch
    }
    private func ensureIncoming() -> MTLTexture? {
        if incoming == nil, width > 0 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
            incoming = device.makeTexture(descriptor: d)
        }
        return incoming
    }
    /// Frees the optional textures (memory pressure); the canvas stays.
    public func trim() { lock.lock(); let busy = !fades.isEmpty; lock.unlock(); if !busy { incoming = nil }; scratch = nil }
    /// Frees everything; the layer is gone.
    public func release() { canvas = nil; scratch = nil; incoming = nil; videoRGB = nil; videoUp = nil; scaler = nil; width = 0; height = 0; lock.lock(); fades = []; lock.unlock() }

    public func clear() {
        guard let canvas, let cb = commandQueue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = canvas; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = hasAlpha ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) : MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        cb.commit()
        bump()
    }

    private func bump() { lock.lock(); generation += 1; lock.unlock(); lastWriteNanos = Clock.nowNanos() }

    /// Blocks until all work queued so far has executed (tests, teardown).
    public func waitForGPU() {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        cb.commit(); cb.waitUntilCompleted()
    }
    public var needsRender: Bool { lock.lock(); defer { lock.unlock() }; return generation != renderedGeneration || !fades.isEmpty }
    public func invalidate() { bump() }
    func markRendered() { lock.lock(); renderedGeneration = generation; lock.unlock() }

    // MARK: Video

    /// Writes the masked tiles of a decoded NV12 frame into `region` of the canvas (scaling if the
    /// frame is smaller than the region, i.e. the host is on a lower rung).
    public func applyVideo(_ image: CVImageBuffer, region: PixelRect, mask: TileMask?, tile: Int = 64, crossfade: Bool = false) {
        guard let canvasTex = canvas, CVPixelBufferGetPlaneCount(image) == 2 else { return }
        let canvas = crossfade ? (ensureIncoming() ?? canvasTex) : canvasTex
        if crossfade { beginFade(region.isEmpty ? PixelRect(x: 0, y: 0, width: width, height: height) : region) }
        else { dropFades(intersecting: region.isEmpty ? PixelRect(x: 0, y: 0, width: width, height: height) : region) }
        let vw = CVPixelBufferGetWidthOfPlane(image, 0), vh = CVPixelBufferGetHeightOfPlane(image, 0)
        guard vw > 0, vh > 0 else { return }
        var yTex: CVMetalTexture?, cTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, context.textureCache, image, nil, .r8Unorm, vw, vh, 0, &yTex) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(nil, context.textureCache, image, nil, .rg8Unorm, vw / 2, vh / 2, 1, &cTex) == kCVReturnSuccess,
              let yTex, let cTex, let y = CVMetalTextureGetTexture(yTex), let c = CVMetalTextureGetTexture(cTex) else { return }
        if videoRGB == nil || videoRGB!.width != vw || videoRGB!.height != vh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: vw, height: vh, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
            videoRGB = device.makeTexture(descriptor: d)
        }
        guard let rgb = videoRGB, let cb = commandQueue.makeCommandBuffer() else { return }
        // YUV → BGRA.
        if let ce = cb.makeComputeCommandEncoder() {
            ce.setComputePipelineState(context.yuvPipeline)
            ce.setTexture(y, index: 0); ce.setTexture(c, index: 1); ce.setTexture(rgb, index: 2)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            ce.dispatchThreadgroups(MTLSize(width: (vw + 15) / 16, height: (vh + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
            ce.endEncoding()
        }
        // Region in frame coordinates: the decoded frame covers the full native picture at its own scale.
        let native = (width, height)
        let belowNative = vw < native.0 || vh < native.1
        var source = rgb
        if belowNative {
            if videoUp == nil || videoUp!.width != native.0 || videoUp!.height != native.1 {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: native.0, height: native.1, mipmapped: false)
                d.usage = [.shaderRead, .renderTarget]; d.storageMode = .private
                videoUp = device.makeTexture(descriptor: d)
            }
            guard let up = videoUp else { return }
            upscale(rgb, to: up, commandBuffer: cb)
            source = up
        }
        // Blit the masked tiles (or the whole region).
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        let r = region.isEmpty ? PixelRect(x: 0, y: 0, width: width, height: height) : region.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
        let grid = TileMask.grid(for: r, tile: tile)
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                if let mask, !mask[col, row] { continue }
                let t = PixelRect(x: r.x + col * tile, y: r.y + row * tile, width: tile, height: tile).intersection(r)
                guard !t.isEmpty, t.maxX <= source.width, t.maxY <= source.height else { continue }
                blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: t.x, y: t.y, z: 0), sourceSize: MTLSize(width: t.width, height: t.height, depth: 1),
                          to: canvas, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: t.x, y: t.y, z: 0))
            }
        }
        blit.endEncoding()
        cb.commit()
        bump()
    }

    private func upscale(_ src: MTLTexture, to dst: MTLTexture, commandBuffer cb: MTLCommandBuffer) {
        let key = (src.width, src.height, dst.width, dst.height)
        if scaler == nil || scalerSize != key {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = src.width; d.inputHeight = src.height; d.outputWidth = dst.width; d.outputHeight = dst.height
            d.colorTextureFormat = .bgra8Unorm; d.outputTextureFormat = .bgra8Unorm
            d.colorProcessingMode = .perceptual
            scaler = MTLFXSpatialScalerDescriptor.supportsDevice(device) ? d.makeSpatialScaler(device: device) : nil
            scalerSize = key
        }
        let t0 = CACurrentMediaTime()
        if let scaler {
            scaler.colorTexture = src; scaler.outputTexture = dst
            scaler.encode(commandBuffer: cb)
        } else {
            drawScaled(src, into: dst, rect: PixelRect(x: 0, y: 0, width: dst.width, height: dst.height), commandBuffer: cb)
        }
        lastUpscaleMs = (CACurrentMediaTime() - t0) * 1000
    }

    /// Draws `src` (whole) scaled into `rect` of `dst` (bilinear), replacing the pixels there.
    private func drawScaled(_ src: MTLTexture, into dst: MTLTexture, rect: PixelRect, commandBuffer cb: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = .load; rp.colorAttachments[0].storeAction = .store
        guard let re = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        re.setRenderPipelineState(context.quadPipeline)
        let dw = Float(dst.width), dh = Float(dst.height)
        let x0 = Float(rect.x) / dw * 2 - 1, y0 = 1 - Float(rect.y) / dh * 2, x1 = Float(rect.maxX) / dw * 2 - 1, y1 = 1 - Float(rect.maxY) / dh * 2
        var q = Quad(dst: SIMD4(x0, y0, x1, y1), src: SIMD4(0, 0, 1, 1))
        re.setVertexBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
        re.setFragmentTexture(src, index: 0); re.setFragmentSamplerState(context.linearSampler, index: 0)
        re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        re.endEncoding()
    }

    // MARK: Tiles and copy-rects

    /// Decodes and uploads lossless tiles (and lossy stills, scaled onto their rect). Returns the number applied.
    @discardableResult
    public func applyTiles(_ tiles: [TileMessage.Tile], crossfade: Bool = false) -> Int {
        guard let canvasTex = canvas, let cb = commandQueue.makeCommandBuffer() else { return 0 }
        let canvas = crossfade ? (ensureIncoming() ?? canvasTex) : canvasTex
        if crossfade { for t in tiles { beginFade(t.rect) } } else { for t in tiles { dropFades(intersecting: t.rect) } }
        var n = 0
        let bounds = PixelRect(x: 0, y: 0, width: width, height: height)
        var blit = cb.makeBlitCommandEncoder()
        for t in tiles {
            let r = t.rect.intersection(bounds)
            guard !r.isEmpty else { continue }
            let w = t.rect.width, h = t.rect.height, stride = w * 4
            if t.format == .solid {
                guard let buf = device.makeBuffer(length: stride * h, options: .storageModeShared), TileCodec.fillSolid(t.data, into: buf.contents(), width: w, height: h, stride: stride) else { continue }
                blit?.copy(from: buf, sourceOffset: 0, sourceBytesPerRow: stride, sourceBytesPerImage: stride * h, sourceSize: MTLSize(width: r.width, height: r.height, depth: 1),
                           to: canvas, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: r.x, y: r.y, z: 0))
                n += 1
                continue
            }
            guard let (dw, dh) = TileCodec.size(of: t.data) else { continue }
            if t.format == .lossy {
                // A still at its own size: decode into a shared texture and draw it scaled onto the rect.
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: dw, height: dh, mipmapped: false)
                d.usage = [.shaderRead]; d.storageMode = .shared
                guard let tex = device.makeTexture(descriptor: d) else { continue }
                var pixels = [UInt8](repeating: 0, count: dw * dh * 4)
                guard pixels.withUnsafeMutableBytes({ TileCodec.decode(t.data, into: $0.baseAddress!, width: dw, height: dh, stride: dw * 4) }) else { continue }
                tex.replace(region: MTLRegionMake2D(0, 0, dw, dh), mipmapLevel: 0, withBytes: pixels, bytesPerRow: dw * 4)
                blit?.endEncoding(); blit = nil
                drawScaled(tex, into: canvas, rect: r, commandBuffer: cb)
                blit = cb.makeBlitCommandEncoder()
                n += 1
                continue
            }
            guard dw == w, dh == h else { continue }
            guard let buf = device.makeBuffer(length: stride * h, options: .storageModeShared) else { continue }
            guard TileCodec.decode(t.data, into: buf.contents(), width: w, height: h, stride: stride) else { continue }
            blit?.copy(from: buf, sourceOffset: 0, sourceBytesPerRow: stride, sourceBytesPerImage: stride * h, sourceSize: MTLSize(width: r.width, height: r.height, depth: 1),
                       to: canvas, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: r.x, y: r.y, z: 0))
            n += 1
        }
        blit?.endEncoding()
        cb.commit()
        if n > 0 { bump() }
        return n
    }

    /// Starts a crossfade for `rect`: the new pixels live in `incoming` until the fade ends, when
    /// they are committed to the canvas. A rect still fading when overwritten is committed first.
    private func beginFade(_ rect: PixelRect) {
        let r = rect.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
        guard !r.isEmpty else { return }
        lock.lock(); fades.append(Fade(rect: r, startNanos: Clock.nowNanos())); lock.unlock()
    }

    /// Commits fades that have finished (copy incoming → canvas) and returns the ones still running.
    func settleFades(now: UInt64, commandBuffer cb: MTLCommandBuffer) -> [(Fade, Float)] {
        lock.lock(); let list = fades; lock.unlock()
        var active: [(Fade, Float)] = []
        var done: [Fade] = []
        for f in list {
            let t = Float(now &- f.startNanos) / Float(crossfadeNanos)
            if t >= 1 { done.append(f) } else { active.append((f, max(0, t))) }
        }
        if !done.isEmpty, let canvas, let incoming, let blit = cb.makeBlitCommandEncoder() {
            for f in done {
                blit.copy(from: incoming, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: f.rect.x, y: f.rect.y, z: 0), sourceSize: MTLSize(width: f.rect.width, height: f.rect.height, depth: 1),
                          to: canvas, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: f.rect.x, y: f.rect.y, z: 0))
            }
            blit.endEncoding()
            lock.lock(); fades.removeAll { d in done.contains(d) }; lock.unlock()
        }
        return active
    }
    var incomingTexture: MTLTexture? { incoming }
    public var hasActiveFades: Bool { lock.lock(); defer { lock.unlock() }; return !fades.isEmpty }

    /// Newer pixels (a copy-rect, a video frame, a direct tile) arrived under a crossfade still in
    /// progress: the fading block is stale and is dropped, never committed (review M1: committing it
    /// 150 ms later put old pixels back over the moved window, the "shattering" of a drag).
    @discardableResult
    public func dropFades(intersecting r: PixelRect) -> Int {
        lock.lock(); defer { lock.unlock() }
        let before = fades.count
        fades.removeAll { $0.rect.intersects(r) }
        return before - fades.count
    }

    public func applyCopyRect(_ rect: PixelRect, dx: Int, dy: Int) {
        dropFades(intersecting: rect.union(rect.offset(dx, dy)))
        guard let canvas, let scratch = ensureScratch(), let cb = commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        let bounds = PixelRect(x: 0, y: 0, width: width, height: height)
        let src = rect.intersection(bounds).intersection(bounds.offset(-dx, -dy))
        guard !src.isEmpty else { return }
        let size = MTLSize(width: src.width, height: src.height, depth: 1)
        blit.copy(from: canvas, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: src.x, y: src.y, z: 0), sourceSize: size,
                  to: scratch, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: src.x, y: src.y, z: 0))
        blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: src.x, y: src.y, z: 0), sourceSize: size,
                  to: canvas, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: src.x + dx, y: src.y + dy, z: 0))
        blit.endEncoding()
        cb.commit()
        bump()
    }

    /// Average colour of a one-pixel line inside the canvas, read back asynchronously (for the
    /// neutral band a local scroll exposes). `edge` 0 = top row, 1 = bottom row of `rect`.
    public func sampleEdgeColor(of rect: PixelRect, bottom: Bool, completion: @escaping (SIMD4<Float>) -> Void) {
        guard let canvas, let cb = commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        let r = rect.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
        guard r.width > 0, r.height > 0 else { return }
        let y = bottom ? r.maxY - 1 : r.y
        guard let buf = device.makeBuffer(length: r.width * 4, options: .storageModeShared) else { return }
        blit.copy(from: canvas, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: r.x, y: y, z: 0), sourceSize: MTLSize(width: r.width, height: 1, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: r.width * 4, destinationBytesPerImage: r.width * 4)
        blit.endEncoding()
        cb.addCompletedHandler { _ in
            var acc = SIMD4<Float>(repeating: 0)
            let p = buf.contents().assumingMemoryBound(to: UInt8.self)
            for i in 0..<r.width { acc += SIMD4(Float(p[i * 4 + 2]), Float(p[i * 4 + 1]), Float(p[i * 4]), 255) / 255 }
            completion(acc / Float(r.width))
        }
        cb.commit()
    }

    // MARK: Presentation (single canvas)

    /// Draws the canvas into `drawable` at `dest` (drawable pixels), then each displacement. The
    /// single-layer form of `SceneRenderer.render`.
    public func render(to drawable: CAMetalDrawable, dest: CGRect, displacements: [Predictor.Displacement], bandColors: [UInt32: SIMD4<Float>]) {
        let scene = LayerScene(background: self, items: [], displacements: displacements.map { LayerScene.Displacement(layerID: 0, displacement: $0) }, bandColors: bandColors)
        SceneRenderer.render(scene, context: context, to: drawable, dest: dest)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    struct Quad { float4 dst; float4 src; };
    vertex VOut quadVertex(uint vid [[vertex_id]], constant Quad& q [[buffer(0)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 c = corners[vid];
        VOut o;
        o.pos = float4(mix(q.dst.x, q.dst.z, c.x), mix(q.dst.y, q.dst.w, c.y), 0, 1);
        o.uv = float2(mix(q.src.x, q.src.z, c.x), mix(q.src.y, q.src.w, c.y));
        return o;
    }
    fragment float4 quadFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    fragment float4 fillFragment(VOut in [[stage_in]], constant float4& color [[buffer(0)]]) { return color; }
    // Premultiplied texture scaled by alpha.x (layer quads with transparency, crossfades).
    fragment float4 blendFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant float4& alpha [[buffer(0)]]) {
        return tex.sample(s, in.uv) * alpha.x;
    }
    // Soft shadow of a rounded rect: `box` = rect in drawable pixels (x0,y0,x1,y1), `p` = (corner radius, blur px, opacity, 0).
    struct ShadowOut { float4 pos [[position]]; float2 px; };
    struct Shadow { float4 ndc; float4 box; float4 p; };
    vertex ShadowOut shadowVertex(uint vid [[vertex_id]], constant Shadow& sh [[buffer(0)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 c = corners[vid];
        ShadowOut o;
        o.pos = float4(mix(sh.ndc.x, sh.ndc.z, c.x), mix(sh.ndc.y, sh.ndc.w, c.y), 0, 1);
        float b = sh.p.y;
        o.px = float2(mix(sh.box.x - b, sh.box.z + b, c.x), mix(sh.box.y - b, sh.box.w + b, c.y));
        return o;
    }
    fragment float4 shadowFragment(ShadowOut in [[stage_in]], constant Shadow& sh [[buffer(0)]]) {
        float2 ext = (sh.box.zw - sh.box.xy) * 0.5;
        float2 centre = (sh.box.xy + sh.box.zw) * 0.5;
        float r = sh.p.x;
        float2 q = abs(in.px - centre) - ext + r;
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        float sigma = max(sh.p.y, 1.0) * 0.45;
        float a = sh.p.z * exp(-max(d, 0.0) * max(d, 0.0) / (2.0 * sigma * sigma));
        return float4(0, 0, 0, a);
    }
    kernel void nv12ToBGRA(texture2d<float, access::read> yTex [[texture(0)]], texture2d<float, access::read> cTex [[texture(1)]],
                           texture2d<float, access::write> out [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float Y = yTex.read(gid).r;
        float2 C = cTex.read(gid / 2).rg;
        float yy = (Y - 16.0/255.0) * (255.0/219.0);
        float cb = (C.x - 128.0/255.0) * (255.0/224.0);
        float cr = (C.y - 128.0/255.0) * (255.0/224.0);
        float3 rgb = float3(yy + 1.5748 * cr, yy - 0.1873 * cb - 0.4681 * cr, yy + 1.8556 * cb);
        out.write(float4(saturate(rgb), 1), gid);
    }
    """
}

/// What to draw: the display layer at the back, then items front-ordered back to front: window layers
/// (their own canvas at a frame, with a shadow) and cut-outs (a rect of the display layer drawn again
/// on top, for windows the host does not capture separately: menus, the dock, the menu bar).
public struct LayerScene {
    public enum Item {
        case layer(Compositor, frame: PixelRect, shadow: Shadow?, dim: Float)
        /// A rect of the display layer drawn again on top (a menu, the dock, a window beyond the layer cap),
        /// optionally with a shadow (the display stream is captured without shadows).
        case cutout(PixelRect, shadow: Shadow?)
    }
    public struct Shadow: Equatable {
        public var cornerRadius: Float, blur: Float, offsetY: Float, opacity: Float
        public init(cornerRadius: Float, blur: Float, offsetY: Float, opacity: Float) { self.cornerRadius = cornerRadius; self.blur = blur; self.offsetY = offsetY; self.opacity = opacity }
        /// macOS-style shadows in display points; scale by pixels per point.
        public static func key(pxPerPoint: Float) -> Shadow { Shadow(cornerRadius: 12 * pxPerPoint, blur: 36 * pxPerPoint, offsetY: 10 * pxPerPoint, opacity: 0.55) }
        public static func inactive(pxPerPoint: Float) -> Shadow { Shadow(cornerRadius: 12 * pxPerPoint, blur: 14 * pxPerPoint, offsetY: 3 * pxPerPoint, opacity: 0.35) }
        public static func menu(pxPerPoint: Float) -> Shadow { Shadow(cornerRadius: 8 * pxPerPoint, blur: 18 * pxPerPoint, offsetY: 5 * pxPerPoint, opacity: 0.4) }
    }
    public struct Displacement { public var layerID: UInt32; public var displacement: Predictor.Displacement
        public init(layerID: UInt32, displacement: Predictor.Displacement) { self.layerID = layerID; self.displacement = displacement } }
    public var background: Compositor?
    public var items: [Item]
    /// Displacements in each layer's own coordinates (layer 0 = the display layer).
    public var displacements: [Displacement]
    public var bandColors: [UInt32: SIMD4<Float>]
    public init(background: Compositor?, items: [Item], displacements: [Displacement], bandColors: [UInt32: SIMD4<Float>]) {
        self.background = background; self.items = items; self.displacements = displacements; self.bandColors = bandColors
    }
}

public enum SceneRenderer {
    /// Draws the scene into `drawable`; `dest` is where the display layer's full rect lands (drawable
    /// pixels); every layer frame is in display-layer pixels and maps through the same transform.
    public static func render(_ scene: LayerScene, context: MetalContext, to drawable: CAMetalDrawable, dest: CGRect) {
        guard let bg = scene.background, bg.width > 0, let cb = context.commandQueue.makeCommandBuffer() else { return }
        let now = Clock.nowNanos()
        // Settle every visible canvas's crossfades first (a blit each), then one render pass.
        var fades: [ObjectIdentifier: [(Compositor.Fade, Float)]] = [:]
        fades[ObjectIdentifier(bg)] = bg.settleFades(now: now, commandBuffer: cb)
        for item in scene.items { if case .layer(let c, _, _, _) = item { fades[ObjectIdentifier(c)] = c.settleFades(now: now, commandBuffer: cb) } }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let re = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        let dw = Float(drawable.texture.width), dh = Float(drawable.texture.height)
        let sx = Float(dest.width) / Float(bg.width), sy = Float(dest.height) / Float(bg.height)
        // Display-layer pixel rect → drawable pixels / NDC.
        func px(_ r: PixelRect, dx: Int = 0, dy: Int = 0) -> SIMD4<Float> {
            let x0 = Float(dest.minX) + Float(r.x + dx) * sx, y0 = Float(dest.minY) + Float(r.y + dy) * sy
            return SIMD4(x0, y0, x0 + Float(r.width) * sx, y0 + Float(r.height) * sy)
        }
        func ndc(_ p: SIMD4<Float>) -> SIMD4<Float> { SIMD4(p.x / dw * 2 - 1, 1 - p.y / dh * 2, p.z / dw * 2 - 1, 1 - p.w / dh * 2) }
        func uv(_ r: PixelRect, in c: Compositor) -> SIMD4<Float> {
            SIMD4(Float(r.x) / Float(c.width), Float(r.y) / Float(c.height), Float(r.maxX) / Float(c.width), Float(r.maxY) / Float(c.height))
        }
        func scissor(_ p: SIMD4<Float>) {
            let x0 = min(Int(dw), max(0, Int(p.x))), y0 = min(Int(dh), max(0, Int(p.y)))
            let x1 = min(Int(dw), max(0, Int(p.z))), y1 = min(Int(dh), max(0, Int(p.w)))
            re.setScissorRect(MTLScissorRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0)))
        }
        let fullScissor = SIMD4<Float>(0, 0, dw, dh)
        let sampler = abs(sx - 1) < 0.001 && abs(sy - 1) < 0.001 ? context.nearestSampler : context.linearSampler
        let display = PixelRect(x: 0, y: 0, width: bg.width, height: bg.height)
        func drawQuad(_ tex: MTLTexture, dst: SIMD4<Float>, src: SIMD4<Float>, alpha: Float?) {
            if let alpha {
                re.setRenderPipelineState(context.blendPipeline)
                var a = SIMD4<Float>(alpha, alpha, alpha, alpha)
                re.setFragmentBytes(&a, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            } else { re.setRenderPipelineState(context.quadPipeline) }
            re.setFragmentTexture(tex, index: 0); re.setFragmentSamplerState(sampler, index: 0)
            var q = Compositor.Quad(dst: ndc(dst), src: src)
            re.setVertexBytes(&q, length: MemoryLayout<Compositor.Quad>.stride, index: 0)
            re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        /// A canvas drawn at `frame` (display coordinates), its active fades over it, then its displacements.
        func drawCanvas(_ c: Compositor, frame: PixelRect, layerID: UInt32, alpha: Float?) {
            guard let tex = c.canvas else { return }
            let r = PixelRect(x: 0, y: 0, width: c.width, height: c.height)
            drawQuad(tex, dst: px(PixelRect(x: frame.x, y: frame.y, width: c.width, height: c.height)), src: uv(r, in: c), alpha: alpha)
            if let inc = c.incomingTexture, let active = fades[ObjectIdentifier(c)], !active.isEmpty {
                for (f, t) in active { drawQuad(inc, dst: px(f.rect.offset(frame.x, frame.y)), src: uv(f.rect, in: c), alpha: t * (alpha ?? 1)) }
            }
            for d in scene.displacements where d.layerID == layerID {
                let dr = d.displacement.rect.intersection(r)
                guard !dr.isEmpty else { continue }
                let screenRect = px(dr.offset(frame.x, frame.y))
                // Neutral fill: the whole rect (scroll: the band shows through where the shifted copy does not cover; drag: the hole).
                var color = scene.bandColors[d.displacement.windowID] ?? SIMD4<Float>(0.5, 0.5, 0.5, 1)
                re.setRenderPipelineState(context.fillPipeline)
                scissor(screenRect)
                var fq = Compositor.Quad(dst: ndc(screenRect), src: SIMD4(repeating: 0))
                re.setVertexBytes(&fq, length: MemoryLayout<Compositor.Quad>.stride, index: 0)
                re.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                // The shifted copy, clipped to the scroll rect (a drag displacement may leave the rect).
                if d.displacement.kind == .scroll { scissor(screenRect) } else { scissor(layerID == 0 ? fullScissor : px(frame)) }
                drawQuad(tex, dst: px(dr.offset(frame.x, frame.y), dx: d.displacement.dx, dy: d.displacement.dy), src: uv(dr, in: c), alpha: alpha)
                scissor(fullScissor)
            }
        }
        func drawShadow(_ s: LayerScene.Shadow, box: SIMD4<Float>) {
            let scale = (sx + sy) / 2
            let shifted = SIMD4<Float>(box.x, box.y + s.offsetY * scale, box.z, box.w + s.offsetY * scale)
            let b = s.blur * scale
            let quad = SIMD4<Float>(shifted.x - b, shifted.y - b, shifted.z + b, shifted.w + b)
            struct ShadowUniform { var ndc: SIMD4<Float>; var box: SIMD4<Float>; var p: SIMD4<Float> }
            var u = ShadowUniform(ndc: ndc(quad), box: shifted, p: SIMD4(s.cornerRadius * scale, b, s.opacity, 0))
            re.setRenderPipelineState(context.shadowPipeline)
            re.setVertexBytes(&u, length: MemoryLayout<ShadowUniform>.stride, index: 0)
            re.setFragmentBytes(&u, length: MemoryLayout<ShadowUniform>.stride, index: 0)
            re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        // 1. The display layer, whole.
        drawCanvas(bg, frame: display, layerID: 0, alpha: nil)
        // 2. Items back to front.
        for item in scene.items.reversed() {
            switch item {
            case .cutout(let rect, let shadow):
                let r = rect.intersection(display)
                guard !r.isEmpty, let tex = bg.canvas else { continue }
                if let s = shadow { drawShadow(s, box: px(rect)) }
                drawQuad(tex, dst: px(r), src: uv(r, in: bg), alpha: nil)
            case .layer(let c, let frame, let shadow, let dim):
                guard c.canvas != nil else { continue }
                if let s = shadow { drawShadow(s, box: px(PixelRect(x: frame.x, y: frame.y, width: c.width, height: c.height))) }
                drawCanvas(c, frame: frame, layerID: c.layerID, alpha: c.hasAlpha || dim < 1 ? dim : nil)
            }
        }
        re.endEncoding()
        cb.present(drawable)
        cb.commit()
        bg.markRendered()
        for item in scene.items { if case .layer(let c, _, _, _) = item { c.markRendered() } }
    }
}
