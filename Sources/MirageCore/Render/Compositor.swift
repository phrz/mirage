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
    public struct Fade: Equatable { public var rect: PixelRect; public var startNanos: UInt64; public var durationNanos: UInt64 }
    private var fades: [Fade] = []
    /// Crossfade length for a whole-layer level sent as one message (DESIGN §3.3: 200–250 ms).
    public var crossfadeNanos: UInt64 = 220_000_000
    private var staging: MTLTexture?       // the next presentation level, assembled off-screen
    private var stagedMask: [Bool] = []    // per 64-px tile: staged and not yet presented
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
    /// A window layer's corner radius in canvas pixels, measured from its alpha (`sampleCornerRadius`): its shadow follows
    /// the window's own shape, not a fixed radius (a squarer shadow box drew a dark inset outline in the corner).
    public var cornerRadius: Float?
    /// Receiver clock of the last write (layer cache eviction).
    public private(set) var lastWriteNanos: UInt64 = 0
    /// Bytes of texture memory this canvas holds (canvas + scratch + incoming).
    public var textureBytes: Int { (canvas == nil ? 0 : width * height * 4) * (1 + (scratch == nil ? 0 : 1) + (incoming == nil ? 0 : 1) + (staging == nil ? 0 : 1)) }

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
        staging = nil; stagedMask = []; commitPending = nil
        fades = []
        clear()
    }
    /// Like `configure`, but a size change keeps the old picture at the top-left (cropped or with cleared margins) until
    /// new pixels replace it: a window resized on either end shows its last content, not a blank canvas, while the host
    /// re-captures it.
    public func configureKeepingPixels(width: Int, height: Int) {
        guard let old = canvas, self.width > 0, width > 0, height > 0, width != self.width || height != self.height else { configure(width: width, height: height); return }
        let ow = self.width, oh = self.height
        configure(width: width, height: height)
        guard let new = canvas, let cb = commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: old, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: min(ow, width), height: min(oh, height), depth: 1),
                  to: new, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.commit()
        bump()
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
    public func trim() { lock.lock(); let busy = !fades.isEmpty; lock.unlock(); if !busy { incoming = nil }; scratch = nil; if !hasStaged { staging = nil; stagedMask = [] } }
    /// Frees everything; the layer is gone.
    public func release() { canvas = nil; scratch = nil; incoming = nil; staging = nil; stagedMask = []; commitPending = nil; videoRGB = nil; videoUp = nil; scaler = nil; width = 0; height = 0; lock.lock(); fades = []; lock.unlock() }

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
    /// The canvas's change counter, for presenters that track what they last drew themselves (Unified mode: one
    /// canvas may be drawn by several native windows, so `needsRender` cannot be shared).
    public var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }
    func markRendered() { lock.lock(); renderedGeneration = generation; lock.unlock() }

    // MARK: Write targets (DESIGN §3.3 presentation levels)
    //
    // `canvas` is what is shown. `incoming` holds what fades in over it (`fades`). `staging` is the layer's next
    // presentation level, assembled off-screen: it starts as a copy of what the canvas will be once its fades end,
    // receives every later write, and holds the staged (refinement) tiles nobody sees until `commitStaged`.
    // A write that is not staged lands on the canvas, on `incoming` where a fade runs over it (so the fade shows the
    // new pixels at once and commits them), and on `staging` (so a commit never puts older pixels back).

    private func ensureStaging(_ cb: MTLCommandBuffer) -> MTLTexture? {
        if let staging { return staging }
        guard width > 0, let canvas else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
        guard let s = device.makeTexture(descriptor: d), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: canvas, to: s)
        lock.lock(); let running = fades; lock.unlock()
        if let incoming { for f in running { copy(incoming, to: s, rect: f.rect, blit: blit) } }
        blit.endEncoding()
        staging = s
        stagedMask = Array(repeating: false, count: tileCols * tileRows)
        return s
    }
    private var tileCols: Int { (width + 63) / 64 }
    private var tileRows: Int { (height + 63) / 64 }
    private func copy(_ src: MTLTexture, to dst: MTLTexture, rect r: PixelRect, blit: MTLBlitCommandEncoder) {
        let c = r.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
        guard !c.isEmpty else { return }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: c.x, y: c.y, z: 0), sourceSize: MTLSize(width: c.width, height: c.height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: c.x, y: c.y, z: 0))
    }
    private func fadeIntersects(_ r: PixelRect) -> Bool { lock.lock(); defer { lock.unlock() }; return fades.contains { $0.rect.intersects(r) } }
    /// Ends the fades over `r` at once (their pixels go to the canvas now): a new crossfade or a copy-rect follows there.
    private func finishFades(intersecting r: PixelRect, _ cb: MTLCommandBuffer) {
        lock.lock(); let hit = fades.filter { $0.rect.intersects(r) }; fades.removeAll { $0.rect.intersects(r) }; lock.unlock()
        guard !hit.isEmpty, let canvas, let incoming, let blit = cb.makeBlitCommandEncoder() else { return }
        for f in hit { copy(incoming, to: canvas, rect: f.rect, blit: blit) }
        blit.endEncoding()
    }
    /// The textures a write of `rect` lands on.
    private func targets(_ rect: PixelRect, staged: Bool, crossfade: Bool, _ cb: MTLCommandBuffer) -> [MTLTexture] {
        guard let canvas else { return [] }
        if staged {
            guard let s = ensureStaging(cb) else { return [] }
            markStaged(rect)
            return [s]
        }
        var out: [MTLTexture] = []
        if crossfade { if let inc = ensureIncoming() { out.append(inc) } else { out.append(canvas) } }
        else {
            out.append(canvas)
            if let incoming, fadeIntersects(rect) { out.append(incoming) }
        }
        if let staging { out.append(staging) }
        return out
    }
    private func markStaged(_ r: PixelRect) {
        let cols = tileCols, rows = tileRows
        guard stagedMask.count == cols * rows, !r.isEmpty else { return }
        let c0 = max(0, r.x / 64), c1 = min(cols - 1, (r.maxX - 1) / 64), r0 = max(0, r.y / 64), r1 = min(rows - 1, (r.maxY - 1) / 64)
        guard c1 >= c0, r1 >= r0 else { return }
        for y in r0...r1 { for x in c0...c1 { stagedMask[y * cols + x] = true } }
    }
    /// Tiles of the next level written off-screen and not yet presented.
    public var stagedTiles: Int { stagedMask.reduce(0) { $0 + ($1 ? 1 : 0) } }
    public var hasStaged: Bool { stagedMask.contains(true) || commitPending != nil }

    /// Presents the staged level: every staged tile crossfades in together over `durationNanos` (one presentation
    /// step for the layer). Waits for running fades to end first, so a level never jumps mid-fade. Returns the
    /// number of tiles committed now (0 if deferred or nothing staged).
    @discardableResult
    public func commitStaged(durationNanos: UInt64 = 220_000_000) -> Int {
        guard stagedMask.contains(true) else { commitPending = nil; return 0 }
        if hasActiveFades { commitPending = durationNanos; return 0 }
        guard let cb = commandQueue.makeCommandBuffer() else { return 0 }
        let n = performCommit(durationNanos: durationNanos, cb)
        cb.commit()
        return n
    }
    /// Commits pending from a deferred `commitStaged` (count of committed levels, for diagnostics).
    public private(set) var commitsPresented = 0
    private var commitPending: UInt64? = nil
    private func performCommit(durationNanos: UInt64, _ cb: MTLCommandBuffer) -> Int {
        commitPending = nil
        guard let staging, let inc = ensureIncoming(), let blit = cb.makeBlitCommandEncoder() else { return 0 }
        let runs = Self.runs(stagedMask, cols: tileCols, rows: tileRows, width: width, height: height)
        let n = stagedTiles
        for r in runs { copy(staging, to: inc, rect: r, blit: blit) }
        blit.endEncoding()
        let start = Clock.nowNanos()
        lock.lock(); for r in runs { fades.append(Fade(rect: r, startNanos: start, durationNanos: durationNanos)) }; lock.unlock()
        stagedMask = Array(repeating: false, count: tileCols * tileRows)
        commitsPresented += 1
        bump()
        return n
    }
    /// Drops the staged level unseen (a fresh stream: nothing staged before it is trusted).
    public func discardStaged() { stagedMask = Array(repeating: false, count: stagedMask.count); commitPending = nil; staging = nil }
    /// Marked tiles as rects: horizontal runs per tile row, merged with the rows below that have the same run.
    static func runs(_ mask: [Bool], cols: Int, rows: Int, width: Int, height: Int) -> [PixelRect] {
        var open: [Int: (x0: Int, x1: Int, y0: Int, y1: Int)] = [:]   // key x0 * 100000 + x1
        var out: [PixelRect] = []
        func emit(_ s: (x0: Int, x1: Int, y0: Int, y1: Int)) {
            out.append(PixelRect(x: s.x0 * 64, y: s.y0 * 64, width: min(width, s.x1 * 64) - s.x0 * 64, height: min(height, s.y1 * 64) - s.y0 * 64))
        }
        for y in 0..<rows {
            var rowRuns: [(Int, Int)] = []
            var x = 0
            while x < cols {
                guard mask[y * cols + x] else { x += 1; continue }
                let x0 = x
                while x < cols, mask[y * cols + x] { x += 1 }
                rowRuns.append((x0, x))
            }
            var next: [Int: (x0: Int, x1: Int, y0: Int, y1: Int)] = [:]
            for (x0, x1) in rowRuns {
                let k = x0 * 100_000 + x1
                if var s = open[k] { s.y1 = y + 1; next[k] = s; open[k] = nil } else { next[k] = (x0, x1, y, y + 1) }
            }
            for s in open.values { emit(s) }
            open = next
        }
        for s in open.values { emit(s) }
        return out
    }

    // MARK: Video

    /// Writes the masked tiles of a decoded NV12 frame into `region` of the canvas (scaling if the
    /// frame is smaller than the region, i.e. the host is on a lower rung).
    public func applyVideo(_ image: CVImageBuffer, region: PixelRect, mask: TileMask?, tile: Int = 64, crossfade: Bool = false) {
        guard canvas != nil, CVPixelBufferGetPlaneCount(image) == 2 else { return }
        let full = region.isEmpty ? PixelRect(x: 0, y: 0, width: width, height: height) : region
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
        if crossfade { finishFades(intersecting: full, cb) }
        let outs = targets(full, staged: false, crossfade: crossfade, cb)
        if crossfade { beginFade(full, durationNanos: 220_000_000) }
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
        // Blit the masked tiles (or the whole region) into every target.
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        let r = full.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
        let grid = TileMask.grid(for: r, tile: tile)
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                if let mask, !mask[col, row] { continue }
                let t = PixelRect(x: r.x + col * tile, y: r.y + row * tile, width: tile, height: tile).intersection(r)
                guard !t.isEmpty, t.maxX <= source.width, t.maxY <= source.height else { continue }
                for dst in outs { copy(source, to: dst, rect: t, blit: blit) }
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
    /// `crossfade`: the tiles fade in together (a whole-layer level). `staged`: they go to the off-screen next
    /// level only, shown on `commitStaged`; the parts of them inside `alsoShow` are written to the canvas too
    /// (the desktop where the viewer shows fill: any clean picture beats the fill). Lossless and solid tiles only.
    @discardableResult
    public func applyTiles(_ tiles: [TileMessage.Tile], crossfade: Bool = false, staged: Bool = false, alsoShow: [PixelRect] = []) -> Int {
        guard canvas != nil, let cb = commandQueue.makeCommandBuffer() else { return 0 }
        let bounds = PixelRect(x: 0, y: 0, width: width, height: height)
        if crossfade && !staged { for t in tiles { finishFades(intersecting: t.rect, cb) } }
        if staged, ensureStaging(cb) == nil { return 0 }   // before any encoder below is open
        var n = 0
        var blit: MTLBlitCommandEncoder? = nil
        var faded: [PixelRect] = []
        var shownNow = false
        for t in tiles {
            let r = t.rect.intersection(bounds)
            guard !r.isEmpty else { continue }
            let w = t.rect.width, h = t.rect.height, stride = w * 4
            if t.format == .lossy {
                // A still at its own size: decode into a shared texture and draw it scaled onto the rect.
                guard let (dw, dh) = TileCodec.size(of: t.data) else { continue }
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: dw, height: dh, mipmapped: false)
                d.usage = [.shaderRead]; d.storageMode = .shared
                guard let tex = device.makeTexture(descriptor: d) else { continue }
                var pixels = [UInt8](repeating: 0, count: dw * dh * 4)
                guard pixels.withUnsafeMutableBytes({ TileCodec.decode(t.data, into: $0.baseAddress!, width: dw, height: dh, stride: dw * 4) }) else { continue }
                if hasAlpha { Self.clampPremultiplied(&pixels) }
                tex.replace(region: MTLRegionMake2D(0, 0, dw, dh), mipmapLevel: 0, withBytes: pixels, bytesPerRow: dw * 4)
                blit?.endEncoding(); blit = nil
                for dst in targets(r, staged: staged, crossfade: crossfade, cb) { drawScaled(tex, into: dst, rect: r, commandBuffer: cb) }
                if crossfade && !staged { faded.append(r) }
                n += 1
                continue
            }
            guard let buf = device.makeBuffer(length: stride * h, options: .storageModeShared) else { continue }
            if t.format == .solid {
                guard TileCodec.fillSolid(t.data, into: buf.contents(), width: w, height: h, stride: stride) else { continue }
            } else {
                guard let (dw, dh) = TileCodec.size(of: t.data), dw == w, dh == h, TileCodec.decode(t.data, into: buf.contents(), width: w, height: h, stride: stride) else { continue }
            }
            let outs = targets(r, staged: staged, crossfade: crossfade, cb)
            if blit == nil { blit = cb.makeBlitCommandEncoder() }
            for dst in outs {
                blit?.copy(from: buf, sourceOffset: 0, sourceBytesPerRow: stride, sourceBytesPerImage: stride * h, sourceSize: MTLSize(width: r.width, height: r.height, depth: 1),
                           to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: r.x, y: r.y, z: 0))
            }
            if staged, let canvasTex = canvas {
                for part in alsoShow {
                    let p = part.intersection(r)
                    guard !p.isEmpty else { continue }
                    let off = (p.y - t.rect.y) * stride + (p.x - t.rect.x) * 4
                    for dst in [canvasTex] + (incoming != nil && fadeIntersects(p) ? [incoming!] : []) {
                        blit?.copy(from: buf, sourceOffset: off, sourceBytesPerRow: stride, sourceBytesPerImage: stride * h, sourceSize: MTLSize(width: p.width, height: p.height, depth: 1),
                                   to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: p.x, y: p.y, z: 0))
                    }
                    shownNow = true
                }
            }
            if crossfade && !staged { faded.append(r) }
            n += 1
        }
        blit?.endEncoding()
        cb.commit()
        // One crossfade for the whole message (a whole-layer level steps in at once, not tile by tile).
        if !faded.isEmpty { let start = Clock.nowNanos(); for r in faded { beginFade(r, durationNanos: crossfadeNanos, start: start) } }
        if n > 0 && (!staged || shownNow) { bump() }
        return n
    }

    /// Window canvases hold premultiplied pixels (the capture's, kept exact by lossless WebP). Lossy WebP does not keep
    /// the colour of transparent pixels: a decoded still or middle level has colour where alpha is 0 (a window's rounded
    /// corners), which premultiplied blending adds on top of the desktop: square, whitish corners whenever a window was
    /// at a lossy level (phrz, Desktop mode, during drags while every move re-sent the window). Each channel is clamped
    /// to its alpha, the premultiplied invariant.
    static func clampPremultiplied(_ p: inout [UInt8]) {
        p.withUnsafeMutableBufferPointer { b in
            var i = 0
            while i + 3 < b.count {
                let a = b[i + 3]
                if b[i] > a { b[i] = a }
                if b[i + 1] > a { b[i + 1] = a }
                if b[i + 2] > a { b[i + 2] = a }
                i += 4
            }
        }
    }

    /// Starts a crossfade for `rect`: the new pixels live in `incoming` until the fade ends, when
    /// they are committed to the canvas (by `settle`, on the writer's queue).
    private func beginFade(_ rect: PixelRect, durationNanos: UInt64, start: UInt64 = Clock.nowNanos()) {
        let r = rect.intersection(PixelRect(x: 0, y: 0, width: width, height: height))
        guard !r.isEmpty else { return }
        lock.lock(); fades.append(Fade(rect: r, startNanos: start, durationNanos: durationNanos)); lock.unlock()
        bump()
    }

    /// The fades to draw now with their progress (a finished one at 1 until `settle` commits it). Render thread.
    func activeFades(now: UInt64) -> [(Fade, Float)] {
        lock.lock(); let list = fades; lock.unlock()
        return list.map { f in (f, min(1, max(0, Float(Clock.elapsed(since: f.startNanos, now: now)) / Float(max(1, f.durationNanos))))) }
    }
    var incomingTexture: MTLTexture? { incoming }
    /// Commits finished crossfades (incoming → canvas), then a deferred level commit once no fade runs. Called every
    /// 20 ms on the writer's queue, so a headless viewer or a hidden window still reaches the final picture (review M1),
    /// and every write and commit happens on one queue in order.
    public func settle(now: UInt64 = Clock.nowNanos()) {
        guard hasActiveFades || commitPending != nil else { return }
        lock.lock(); let done = fades.filter { Clock.elapsed(since: $0.startNanos, now: now) >= $0.durationNanos }; lock.unlock()
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        if !done.isEmpty, let canvas, let incoming, let blit = cb.makeBlitCommandEncoder() {
            for f in done { copy(incoming, to: canvas, rect: f.rect, blit: blit) }
            blit.endEncoding()
            lock.lock(); fades.removeAll { d in done.contains(d) }; lock.unlock()
            bump()
        }
        if let d = commitPending, !hasActiveFades { _ = performCommit(durationNanos: d, cb) }
        cb.commit()
    }
    public var hasActiveFades: Bool { lock.lock(); defer { lock.unlock() }; return !fades.isEmpty }

    /// Ends every fade intersecting `r` at once (tests; review M1 kept for API).
    @discardableResult
    public func dropFades(intersecting r: PixelRect) -> Int {
        lock.lock(); let n = fades.filter { $0.rect.intersects(r) }.count; lock.unlock()
        guard n > 0, let cb = commandQueue.makeCommandBuffer() else { return 0 }
        finishFades(intersecting: r, cb); cb.commit()
        return n
    }

    public func applyCopyRect(_ rect: PixelRect, dx: Int, dy: Int) {
        guard let canvas, let cb = commandQueue.makeCommandBuffer() else { return }
        // A fade under the move ends now (its pixels move with the rest); the staged level moves too.
        finishFades(intersecting: rect.union(rect.offset(dx, dy)), cb)
        guard let scratch = ensureScratch() else { return }
        let bounds = PixelRect(x: 0, y: 0, width: width, height: height)
        let src = rect.intersection(bounds).intersection(bounds.offset(-dx, -dy))
        guard !src.isEmpty else { cb.commit(); return }
        let size = MTLSize(width: src.width, height: src.height, depth: 1)
        for tex in [canvas] + (staging.map { [$0] } ?? []) {
            guard let blit = cb.makeBlitCommandEncoder() else { continue }
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: src.x, y: src.y, z: 0), sourceSize: size,
                      to: scratch, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: src.x, y: src.y, z: 0))
            blit.endEncoding()
            guard let blit2 = cb.makeBlitCommandEncoder() else { continue }
            blit2.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: src.x, y: src.y, z: 0), sourceSize: size,
                       to: tex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: src.x + dx, y: src.y + dy, z: 0))
            blit2.endEncoding()
        }
        // Staged tiles that moved stay staged where they landed (over-marking only re-presents identical pixels).
        if staging != nil, stagedMask.contains(true) {
            let cols = tileCols, rows = tileRows
            var add: [PixelRect] = []
            for i in 0..<stagedMask.count where stagedMask[i] {
                let tr = PixelRect(x: (i % cols) * 64, y: (i / cols) * 64, width: 64, height: 64).intersection(src)
                if !tr.isEmpty { add.append(tr.offset(dx, dy)) }
            }
            _ = rows
            for r in add { markStaged(r) }
        }
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

    /// A window layer's corner radius in pixels, from its alpha along the top-left diagonal (where a rounded corner of
    /// radius r crosses it at ≈0.29 r). Nil while that corner holds nothing opaque yet (no picture).
    public func sampleCornerRadius(completion: @escaping (Double?) -> Void) {
        let n = min(128, width, height)
        guard n >= 8, let canvas, let cb = commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder(),
              let buf = device.makeBuffer(length: n * n * 4, options: .storageModeShared) else { completion(nil); return }
        blit.copy(from: canvas, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: n, height: n, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: n * 4, destinationBytesPerImage: n * n * 4)
        blit.endEncoding()
        cb.addCompletedHandler { _ in
            let p = buf.contents().assumingMemoryBound(to: UInt8.self)
            for i in 0..<n where p[(i * n + i) * 4 + 3] >= 128 { completion(i == 0 ? 0 : Double(i) / 0.2929); return }
            completion(nil)
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
        // Outside the box only: the inside belongs to the window (or, for a clipped cut-out, to the display layer).
        if (d < 0.0) discard_fragment();
        float a = sh.p.z * exp(-d * d / (2.0 * sigma * sigma));
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
        case cutout(PixelRect, shadow: Shadow?, clips: [PixelRect])
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
    /// Desktop rects the viewer holds no clean pixels for (they may still show a window from before it became a
    /// layer): filled with `fillColor` over the display layer, under every window.
    public var displayFill: [PixelRect] = []
    public var fillColor = SIMD4<Float>(0.3, 0.3, 0.32, 1)
    public init(background: Compositor?, items: [Item], displacements: [Displacement], bandColors: [UInt32: SIMD4<Float>], displayFill: [PixelRect] = [], fillColor: SIMD4<Float>? = nil) {
        self.background = background; self.items = items; self.displacements = displacements; self.bandColors = bandColors
        self.displayFill = displayFill; if let fillColor { self.fillColor = fillColor }
    }
}

public enum SceneRenderer {
    /// Draws the scene into `drawable`; `dest` is where the display layer's full rect lands (drawable
    /// pixels); every layer frame is in display-layer pixels and maps through the same transform.
    public static func render(_ scene: LayerScene, context: MetalContext, to drawable: CAMetalDrawable, dest: CGRect) {
        render(scene, context: context, target: drawable.texture, dest: dest, present: drawable)
    }

    /// Unified mode: one canvas's `source` rect (canvas pixels) drawn 1:1 at the drawable's top-left, with its running
    /// crossfades and the displacements given in canvas coordinates. A window being resized locally is larger than its
    /// canvas until the host re-captures it: the rest of the drawable is `clear` (the canvas is never stretched).
    /// `scale`: drawable pixels per canvas pixel (1 where the stream was sized for the screen).
    public static func renderCrop(_ c: Compositor, source: PixelRect, scale: Double = 1, displacements: [Predictor.Displacement], bandColors: [UInt32: SIMD4<Float>],
                                  context: MetalContext, target: MTLTexture, clear: MTLClearColor, present: CAMetalDrawable? = nil) {
        guard c.width > 0 else { return }
        let scene = LayerScene(background: c, items: [], displacements: displacements.map { LayerScene.Displacement(layerID: 0, displacement: $0) }, bandColors: bandColors)
        let s = CGFloat(scale)
        render(scene, context: context, target: target, dest: CGRect(x: -CGFloat(source.x) * s, y: -CGFloat(source.y) * s, width: CGFloat(c.width) * s, height: CGFloat(c.height) * s), present: present, clear: clear)
    }

    /// Draws the scene into `target` (a drawable's texture, or any BGRA render target in tests).
    public static func render(_ scene: LayerScene, context: MetalContext, target: MTLTexture, dest: CGRect, present: CAMetalDrawable? = nil, clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) {
        guard let bg = scene.background, bg.width > 0, let cb = context.commandQueue.makeCommandBuffer() else { return }
        let now = Clock.nowNanos()
        // Every visible canvas's running crossfades (settled on the writer's queue, not here), then one render pass.
        var fades: [ObjectIdentifier: [(Compositor.Fade, Float)]] = [:]
        fades[ObjectIdentifier(bg)] = bg.activeFades(now: now)
        for item in scene.items { if case .layer(let c, _, _, _) = item { fades[ObjectIdentifier(c)] = c.activeFades(now: now) } }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = clear
        guard let re = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        let dw = Float(target.width), dh = Float(target.height)
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
        // 1. The display layer, whole, then the desktop areas it holds no clean pixels for.
        drawCanvas(bg, frame: display, layerID: 0, alpha: nil)
        if !scene.displayFill.isEmpty {
            var color = scene.fillColor
            re.setRenderPipelineState(context.fillPipeline)
            re.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            for r in scene.displayFill {
                var fq = Compositor.Quad(dst: ndc(px(r.intersection(display))), src: SIMD4(repeating: 0))
                re.setVertexBytes(&fq, length: MemoryLayout<Compositor.Quad>.stride, index: 0)
                re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        // 2. Items back to front.
        for item in scene.items.reversed() {
            switch item {
            case .cutout(let rect, let shadow, let clips):
                // Only where the cut-out overlaps a window layer behind it (the display layer shows it elsewhere).
                guard let tex = bg.canvas, !clips.isEmpty else { continue }
                if let s = shadow { drawShadow(s, box: px(rect)) }
                for clip in clips {
                    let r = clip.intersection(display)
                    if !r.isEmpty { drawQuad(tex, dst: px(r), src: uv(r, in: bg), alpha: nil) }
                }
            case .layer(let c, let frame, let shadow, let dim):
                guard c.canvas != nil else { continue }
                if var s = shadow {
                    if let r = c.cornerRadius { s.cornerRadius = r }
                    drawShadow(s, box: px(PixelRect(x: frame.x, y: frame.y, width: c.width, height: c.height)))
                }
                drawCanvas(c, frame: frame, layerID: c.layerID, alpha: c.hasAlpha || dim < 1 ? dim : nil)
            }
        }
        re.endEncoding()
        if let present { cb.present(present) }
        cb.commit()
        bg.markRendered()
        for item in scene.items { if case .layer(let c, _, _, _) = item { c.markRendered() } }
    }
}
