import Foundation
import Metal
import MetalFX
import CoreVideo
import QuartzCore

/// Metal canvas compositor (macOS + iOS). The canvas is the client's current picture at native
/// stream size. Host updates write into it in arrival order: video frames (masked tiles of the
/// decoded picture, upscaled with MetalFX when the host is below native), lossless tiles, and
/// copy-rects. Presentation draws the canvas plus the Predictor's displacements (a scroll rect or
/// a dragged window shifted locally, with a neutral band where new pixels will land).
/// All methods are called from one queue (the viewer's video queue); `render` from the display link.
public final class Compositor {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private var quadPipeline: MTLRenderPipelineState
    private var fillPipeline: MTLRenderPipelineState
    private var blendPipeline: MTLRenderPipelineState
    private var yuvPipeline: MTLComputePipelineState
    private let linearSampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState

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

    struct Quad { var dst: SIMD4<Float>; var src: SIMD4<Float> }

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else { return nil }
        self.device = device; commandQueue = q
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        textureCache = cache
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let rp = MTLRenderPipelineDescriptor()
            rp.vertexFunction = lib.makeFunction(name: "quadVertex")
            rp.fragmentFunction = lib.makeFunction(name: "quadFragment")
            rp.colorAttachments[0].pixelFormat = .bgra8Unorm
            quadPipeline = try device.makeRenderPipelineState(descriptor: rp)
            rp.fragmentFunction = lib.makeFunction(name: "fillFragment")
            fillPipeline = try device.makeRenderPipelineState(descriptor: rp)
            rp.fragmentFunction = lib.makeFunction(name: "blendFragment")
            rp.colorAttachments[0].isBlendingEnabled = true
            rp.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; rp.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            rp.colorAttachments[0].sourceAlphaBlendFactor = .one; rp.colorAttachments[0].destinationAlphaBlendFactor = .zero
            blendPipeline = try device.makeRenderPipelineState(descriptor: rp)
            rp.colorAttachments[0].isBlendingEnabled = false
            yuvPipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "nv12ToBGRA")!)
        } catch { return nil }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: sd)!
        sd.minFilter = .nearest; sd.magFilter = .nearest
        nearestSampler = device.makeSamplerState(descriptor: sd)!
    }

    // MARK: Canvas

    public func configure(width: Int, height: Int) {
        guard width > 0, height > 0, width != self.width || height != self.height else { return }
        self.width = width; self.height = height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        canvas = device.makeTexture(descriptor: d)
        scratch = device.makeTexture(descriptor: d)
        incoming = device.makeTexture(descriptor: d)
        fades = []
        clear()
    }

    public func clear() {
        guard let canvas, let cb = commandQueue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = canvas; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        cb.commit()
        bump()
    }

    private func bump() { lock.lock(); generation += 1; lock.unlock() }

    /// Blocks until all work queued so far has executed (tests, teardown).
    public func waitForGPU() {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        cb.commit(); cb.waitUntilCompleted()
    }
    public var needsRender: Bool { lock.lock(); defer { lock.unlock() }; return generation != renderedGeneration || !fades.isEmpty }
    public func invalidate() { bump() }

    // MARK: Video

    /// Writes the masked tiles of a decoded NV12 frame into `region` of the canvas (scaling if the
    /// frame is smaller than the region, i.e. the host is on a lower rung).
    public func applyVideo(_ image: CVImageBuffer, region: PixelRect, mask: TileMask?, tile: Int = 64, crossfade: Bool = false) {
        guard let canvasTex = canvas, CVPixelBufferGetPlaneCount(image) == 2 else { return }
        let canvas = crossfade ? (incoming ?? canvasTex) : canvasTex
        if crossfade { beginFade(region.isEmpty ? PixelRect(x: 0, y: 0, width: width, height: height) : region) }
        let vw = CVPixelBufferGetWidthOfPlane(image, 0), vh = CVPixelBufferGetHeightOfPlane(image, 0)
        guard vw > 0, vh > 0 else { return }
        var yTex: CVMetalTexture?, cTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, image, nil, .r8Unorm, vw, vh, 0, &yTex) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, image, nil, .rg8Unorm, vw / 2, vh / 2, 1, &cTex) == kCVReturnSuccess,
              let yTex, let cTex, let y = CVMetalTextureGetTexture(yTex), let c = CVMetalTextureGetTexture(cTex) else { return }
        if videoRGB == nil || videoRGB!.width != vw || videoRGB!.height != vh {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: vw, height: vh, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
            videoRGB = device.makeTexture(descriptor: d)
        }
        guard let rgb = videoRGB, let cb = commandQueue.makeCommandBuffer() else { return }
        // YUV → BGRA.
        if let ce = cb.makeComputeCommandEncoder() {
            ce.setComputePipelineState(yuvPipeline)
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
            // Fallback: bilinear draw.
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
            guard let re = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
            re.setRenderPipelineState(quadPipeline)
            var q = Quad(dst: SIMD4(-1, 1, 1, -1), src: SIMD4(0, 0, 1, 1))
            re.setVertexBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
            re.setFragmentTexture(src, index: 0); re.setFragmentSamplerState(linearSampler, index: 0)
            re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            re.endEncoding()
        }
        lastUpscaleMs = (CACurrentMediaTime() - t0) * 1000
    }

    // MARK: Tiles and copy-rects

    /// Decodes and uploads lossless tiles. Returns the number of tiles applied.
    @discardableResult
    public func applyTiles(_ tiles: [TileMessage.Tile], crossfade: Bool = false) -> Int {
        guard let canvasTex = canvas, let cb = commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return 0 }
        let canvas = crossfade ? (incoming ?? canvasTex) : canvasTex
        if crossfade { for t in tiles { beginFade(t.rect) } }
        var n = 0
        let bounds = PixelRect(x: 0, y: 0, width: width, height: height)
        for t in tiles {
            let r = t.rect.intersection(bounds)
            guard !r.isEmpty, let (w, h) = TileCodec.size(of: t.data), w == t.rect.width, h == t.rect.height else { continue }
            let stride = w * 4
            guard let buf = device.makeBuffer(length: stride * h, options: .storageModeShared) else { continue }
            guard TileCodec.decode(t.data, into: buf.contents(), width: w, height: h, stride: stride) else { continue }
            blit.copy(from: buf, sourceOffset: 0, sourceBytesPerRow: stride, sourceBytesPerImage: stride * h, sourceSize: MTLSize(width: r.width, height: r.height, depth: 1),
                      to: canvas, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: r.x, y: r.y, z: 0))
            n += 1
        }
        blit.endEncoding()
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
    private func settleFades(now: UInt64, commandBuffer cb: MTLCommandBuffer) -> [(Fade, Float)] {
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
    public var hasActiveFades: Bool { lock.lock(); defer { lock.unlock() }; return !fades.isEmpty }

    public func applyCopyRect(_ rect: PixelRect, dx: Int, dy: Int) {
        guard let canvas, let scratch, let cb = commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
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

    // MARK: Presentation

    /// Draws the canvas into `drawable` at `dest` (drawable pixels), then each displacement.
    public func render(to drawable: CAMetalDrawable, dest: CGRect, displacements: [Predictor.Displacement], bandColors: [UInt32: SIMD4<Float>]) {
        guard let canvas, let cb = commandQueue.makeCommandBuffer() else { return }
        let activeFades = settleFades(now: Clock.nowNanos(), commandBuffer: cb)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let re = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        let dw = Float(drawable.texture.width), dh = Float(drawable.texture.height)
        let sx = Float(dest.width) / Float(width), sy = Float(dest.height) / Float(height)
        func ndc(_ r: PixelRect, dx: Int = 0, dy: Int = 0) -> SIMD4<Float> {
            let x0 = Float(dest.minX) + Float(r.x + dx) * sx, y0 = Float(dest.minY) + Float(r.y + dy) * sy
            let x1 = x0 + Float(r.width) * sx, y1 = y0 + Float(r.height) * sy
            return SIMD4(x0 / dw * 2 - 1, 1 - y0 / dh * 2, x1 / dw * 2 - 1, 1 - y1 / dh * 2)
        }
        func uv(_ r: PixelRect) -> SIMD4<Float> {
            SIMD4(Float(r.x) / Float(width), Float(r.y) / Float(height), Float(r.maxX) / Float(width), Float(r.maxY) / Float(height))
        }
        func scissor(_ r: PixelRect) {
            let x0 = max(0, Int(Float(dest.minX) + Float(r.x) * sx)), y0 = max(0, Int(Float(dest.minY) + Float(r.y) * sy))
            let x1 = min(Int(dw), Int(Float(dest.minX) + Float(r.maxX) * sx)), y1 = min(Int(dh), Int(Float(dest.minY) + Float(r.maxY) * sy))
            re.setScissorRect(MTLScissorRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0)))
        }
        let sampler = abs(sx - 1) < 0.001 && abs(sy - 1) < 0.001 ? nearestSampler : linearSampler
        let full = PixelRect(x: 0, y: 0, width: width, height: height)
        re.setRenderPipelineState(quadPipeline)
        re.setFragmentTexture(canvas, index: 0); re.setFragmentSamplerState(sampler, index: 0)
        var q = Quad(dst: ndc(full), src: uv(full))
        re.setVertexBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
        re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        // Crossfading pixels: the incoming texture over the canvas with alpha rising over 150 ms.
        if let incoming {
            re.setRenderPipelineState(blendPipeline)
            re.setFragmentTexture(incoming, index: 0); re.setFragmentSamplerState(sampler, index: 0)
            for (f, t) in activeFades {
                var alpha = SIMD4<Float>(t, t, t, t)
                var fq = Quad(dst: ndc(f.rect), src: uv(f.rect))
                re.setVertexBytes(&fq, length: MemoryLayout<Quad>.stride, index: 0)
                re.setFragmentBytes(&alpha, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        for d in displacements {
            let r = d.rect.intersection(full)
            guard !r.isEmpty else { continue }
            // Neutral fill: the whole rect (scroll: the band shows through where the shifted copy does not cover; drag: the hole).
            var color = bandColors[d.windowID] ?? SIMD4<Float>(0.5, 0.5, 0.5, 1)
            re.setRenderPipelineState(fillPipeline)
            scissor(r)
            var fq = Quad(dst: ndc(r), src: SIMD4(repeating: 0))
            re.setVertexBytes(&fq, length: MemoryLayout<Quad>.stride, index: 0)
            re.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // The shifted copy.
            re.setRenderPipelineState(quadPipeline)
            re.setFragmentTexture(canvas, index: 0); re.setFragmentSamplerState(sampler, index: 0)
            if d.kind == .scroll { scissor(r) } else { scissor(full) }
            var sq = Quad(dst: ndc(r, dx: d.dx, dy: d.dy), src: uv(r))
            re.setVertexBytes(&sq, length: MemoryLayout<Quad>.stride, index: 0)
            re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            scissor(full)
        }
        re.endEncoding()
        cb.present(drawable)
        cb.commit()
        lock.lock(); renderedGeneration = generation; lock.unlock()
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
    fragment float4 blendFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant float4& alpha [[buffer(0)]]) {
        float4 c = tex.sample(s, in.uv); return float4(c.rgb, alpha.x);
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
