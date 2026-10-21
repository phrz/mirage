import AppKit
import Metal
import MetalKit
import IOKit

struct Uniforms {
    var bg = SIMD4<Float>(0, 0, 0, 1)
    var viewTopPt: Float = 0, ptPerPx: Float = 0, drawW: Float = 0, drawH: Float = 0
    var contentW: Float = 0, contentH: Float = 0, sTop: Float = 0, sBottom: Float = 0
    var kTop: Float = 0, kBottom: Float = 0, confTop: Float = 0, confBottom: Float = 0
    var now: Float = 0, crossfade: Float = 0, feather: Float = 0, innerFeather: Float = 0
    var ext: Float = 0, vignette: Float = 0, desat: Float = 0, grain: Float = 0
    var tint: Float = 0, rim: Float = 0, smearRows: Float = 0, tileRows: Float = 0
    var tileShift: Float = 0, regTop: Float = 0, regH: Float = 0, srcLod: Float = 0
    var warpAmp: Float = 0, warpSpeed: Float = 0, warpTime: Float = 0, blendK: Float = 1
    var prevRegTop: Float = 0, prevRegH: Float = 1, pad2: Float = 0, pad3: Float = 0
    var style: Int32 = 0, showBoundary: Int32 = 0, hasKnown: Int32 = 0, pad1: Int32 = 0
}

/// Rolling GPU timings, written from command-buffer completion handlers.
final class GPUTimings {
    private let lock = NSLock()
    private var fill: [Double] = []
    private var comp: [Double] = []
    func add(fill f: Double? = nil, composite c: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let f { fill.append(f); if fill.count > 240 { fill.removeFirst(fill.count - 240) } }
        if let c { comp.append(c); if comp.count > 240 { comp.removeFirst(comp.count - 240) } }
    }
    func summary() -> (fill: Double, fillP95: Double, comp: Double) {
        lock.lock(); defer { lock.unlock() }
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let s = fill.sorted()
        let p95 = s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.95))]
        return (avg(fill), p95, avg(comp))
    }
    func reset() { lock.lock(); fill.removeAll(); comp.removeAll(); lock.unlock() }
}

func gpuCoreCount() -> Int {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &it) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(it) }
    var s = IOIteratorNext(it)
    while s != 0 {
        defer { IOObjectRelease(s) }
        if let v = IORegistryEntryCreateCFProperty(s, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int { return v }
        s = IOIteratorNext(it)
    }
    return 0
}

final class Renderer: NSObject, MTKViewDelegate {
    let settings: LabSettings
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let composite: MTLRenderPipelineState
    private let kSource, kDown, kUp, kPull, kPush, kPushTop, kEdge, kTemporal: MTLComputePipelineState
    private var truth: [MockTab: MTLTexture] = [:]
    weak var scrollView: NSScrollView?
    let timings = GPUTimings()
    private let inflight = DispatchSemaphore(value: 3)
    private var arrivalBufs: [MTLBuffer] = []
    private let edgeBuf: MTLBuffer
    private var frame = 0

    // Fill textures
    private var src: MTLTexture?
    private var down: [MTLTexture] = [], up: [MTLTexture] = []
    private var pull: [MTLTexture] = [], push: [MTLTexture] = []
    private var texKey = (w: 0, h: 0, passes: 0)

    // Simulation (content pt rows)
    private let H = Int(ContentGeometry.heightPt)
    private var simTime = 0.0
    private var lastReal: CFTimeInterval = 0
    private var history: [(t: Double, y: Double)] = []
    private var arrival: [Float]
    private var K: (top: Int, bottom: Int)? = nil
    private var budget = 0.0
    private var frameAcc = 0.0
    // Temporal fill smoothing (ping-pong) and the region it was computed over.
    private var smooth: [MTLTexture] = []
    private var smoothIdx = 0
    private var prevReg: (top: Double, h: Double)? = nil
    private var S: (top: Double, bottom: Double)? = nil
    private var lastS: (top: Double, bottom: Double)? = nil
    private var lastConf = 0.0, confVel = 0.0
    private var currentTab: MockTab? = nil
    private var lastStyle: FillStyle? = nil
    private var startedAt: CFTimeInterval = 0
    private var didAutoReplay = false
    private var seenReplay = 0, seenReset = 0
    private var replayStart: Double? = nil
    private var lastStatsPublish: CFTimeInterval = 0
    private var unknownFrac = 0.0
    private let cores = gpuCoreCount()

    init(settings: LabSettings) {
        self.settings = settings
        let dev = MTLCreateSystemDefaultDevice()!
        device = dev
        queue = dev.makeCommandQueue()!
        let lib = try! dev.makeLibrary(source: shaderSource, options: nil)
        func k(_ n: String) -> MTLComputePipelineState { try! dev.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
        kSource = k("buildSource"); kDown = k("kawaseDown"); kUp = k("kawaseUp")
        kPull = k("pullDown"); kPush = k("pushUp"); kPushTop = k("pushTop"); kEdge = k("edgeAverage"); kTemporal = k("temporalBlend")
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "fullscreenVS")
        d.fragmentFunction = lib.makeFunction(name: "compositeFS")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        composite = try! device.makeRenderPipelineState(descriptor: d)
        arrival = Array(repeating: 1e30, count: Int(ContentGeometry.heightPt))
        for _ in 0..<3 { arrivalBufs.append(device.makeBuffer(length: arrival.count * 4, options: .storageModeShared)!) }
        edgeBuf = device.makeBuffer(length: 32, options: .storageModePrivate)!
        super.init()
        startedAt = CACurrentMediaTime()
    }

    // MARK: Truth

    private func truthTexture(_ tab: MockTab) -> MTLTexture {
        if let t = truth[tab] { return t }
        let t0 = CACurrentMediaTime()
        let (data, bpr) = MockRenderer.render(tab)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: ContentGeometry.widthPx, height: ContentGeometry.heightPx, mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let tex = device.makeTexture(descriptor: d)!
        data.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, ContentGeometry.widthPx, ContentGeometry.heightPx), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bpr) }
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: tex)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        truth[tab] = tex
        NSLog("Reveal Lab: rendered %@ truth in %.0f ms", tab.title, (CACurrentMediaTime() - t0) * 1000)
        return tex
    }

    // MARK: Fill textures

    private func makeTex(_ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func ensureFillTextures(w: Int, h: Int, passes: Int) {
        if texKey == (w, h, passes), src != nil { return }
        texKey = (w, h, passes)
        let s = makeTex(w, h)
        src = s
        down = [s]; up = []
        var cw = w, ch = h
        for _ in 0..<passes { cw = max(1, (cw + 1) / 2); ch = max(1, (ch + 1) / 2); down.append(makeTex(cw, ch)) }
        for i in 0..<passes { up.append(makeTex(down[i].width, down[i].height)) }
        pull = [s]; push = []
        cw = w; ch = h
        while cw > 1 || ch > 1 { cw = max(1, (cw + 1) / 2); ch = max(1, (ch + 1) / 2); pull.append(makeTex(cw, ch)) }
        for p in pull { push.append(makeTex(p.width, p.height)) }
        smooth = [makeTex(w, h), makeTex(w, h)]
        prevReg = nil
    }

    // MARK: Simulated host

    private func offset(at t: Double) -> Double {
        guard let first = history.first else { return 0 }
        if t <= first.t { return first.y }
        for i in stride(from: history.count - 1, through: 0, by: -1) where history[i].t <= t {
            if i + 1 < history.count {
                let a = history[i], b = history[i + 1]
                let f = (t - a.t) / max(b.t - a.t, 1e-6)
                return a.y + (b.y - a.y) * f
            }
            return history[i].y
        }
        return first.y
    }

    private func targetBand(conf: Double, viewH: Double) -> (Int, Int) {
        let top = max(0, Int(floor(conf - settings.marginPt)))
        let bot = min(H, Int(ceil(conf + viewH + settings.marginPt)))
        return (top, max(top + 1, bot))
    }

    private func deliverInstantly(at y: Double, viewH: Double) {
        for i in 0..<H { arrival[i] = 1e30 }
        let (t, b) = targetBand(conf: y, viewH: viewH)
        for i in t..<b { arrival[i] = Float(simTime - 100) }
        K = (t, b); budget = 0; frameAcc = 0
        prevReg = nil
        history = [(simTime, y)]
        lastConf = y; confVel = 0
    }

    private func evict(_ range: Range<Int>) { for i in range where i >= 0 && i < H { arrival[i] = 1e30 } }

    private func hostUpdate(dt: Double, viewH: Double) {
        let conf = offset(at: simTime - settings.latencyMs / 1000)
        if dt > 0 { confVel = 0.8 * confVel + 0.2 * (conf - lastConf) / dt }
        lastConf = conf
        let (tTop, tBot) = targetBand(conf: conf, viewH: viewH)
        let keepTop = max(0, tTop - Int(viewH)), keepBot = min(H, tBot + Int(viewH))
        if var k = K {
            if k.bottom <= tTop || k.top >= tBot {
                evict(k.top..<k.bottom); K = nil
            } else {
                if k.top < keepTop { evict(k.top..<keepTop); k.top = keepTop }
                if k.bottom > keepBot { evict(keepBot..<k.bottom); k.bottom = keepBot }
                K = k
            }
        }
        if K == nil {
            // Fresh band: the host starts at the confirmed viewport edge on the side we came from.
            let seed = confVel >= 0 ? max(tTop, min(tBot - 1, Int(conf))) : max(tTop, min(tBot - 1, Int(conf + viewH) - 1))
            K = (seed, seed)
        }
        guard var k = K else { return }
        budget += settings.bandwidthRows * dt
        // The host sends whole frames: rows arrive together, once per frame interval.
        frameAcc += dt
        if settings.hostFrameMs > 0 && frameAcc < settings.hostFrameMs / 1000 { return }
        frameAcc = 0
        let vpTop = Int(conf), vpBot = Int(conf + viewH)
        var guardCount = 0
        while budget >= 1, guardCount < 10000 {
            guardCount += 1
            let needAbove = k.top - tTop, needBelow = tBot - k.bottom
            if needAbove <= 0 && needBelow <= 0 { budget = 0; break }
            let aboveInView = needAbove > 0 && k.top > vpTop
            let belowInView = needBelow > 0 && k.bottom < vpBot
            var below: Bool
            if aboveInView != belowInView { below = belowInView }
            else if needAbove <= 0 { below = true }
            else if needBelow <= 0 { below = false }
            else { below = confVel >= 0 }
            let n = min(Int(budget), below ? needBelow : needAbove, 8)
            if n <= 0 { break }
            let now = Float(simTime)
            if below { for i in k.bottom..<(k.bottom + n) { arrival[i] = now }; k.bottom += n }
            else { for i in (k.top - n)..<k.top { arrival[i] = now }; k.top -= n }
            budget -= Double(n)
        }
        K = k
    }

    /// The fill extrapolates from everything delivered (the viewer has those pixels even while they crossfade in).
    /// While a fresh band is still empty, it keeps extrapolating from the last band it had.
    private func computeKnown() {
        if let k = K, k.bottom > k.top { S = (Double(k.top), Double(k.bottom)); lastS = S } else { S = nil }
    }

    // MARK: Replay (scripted fling, in simulated time)

    private static let decel = 0.998   // per ms, like UIScrollView's normal rate
    private func flingOffset(_ v0: Double, _ ms: Double) -> Double { v0 * (pow(Renderer.decel, ms) - 1) / log(Renderer.decel) }

    /// Returns the scripted offset at replay time `t`, or nil when the script is over.
    private func replayOffset(_ t: Double) -> Double? {
        let hold0 = 0.6, f1 = 3.0, hold1 = 1.0, f2 = 3.0
        let v1 = 3.0, v2 = -2.4   // pt per ms
        if t < hold0 { return 0 }
        if t < hold0 + f1 { return flingOffset(v1, (t - hold0) * 1000) }
        let y1 = flingOffset(v1, f1 * 1000)
        if t < hold0 + f1 + hold1 { return y1 }
        if t < hold0 + f1 + hold1 + f2 { return max(0, y1 + flingOffset(v2, (t - hold0 - f1 - hold1) * 1000)) }
        if t < hold0 + f1 + hold1 + f2 + 1.0 { return max(0, y1 + flingOffset(v2, f2 * 1000)) }
        return nil
    }

    private func setScroll(_ sv: NSScrollView, pt: Double, scale: Double) {
        sv.contentView.scroll(to: NSPoint(x: 0, y: pt * scale))
        sv.reflectScrolledClipView(sv.contentView)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let realNow = CACurrentMediaTime()
        var dt = lastReal == 0 ? 0 : min(0.1, realNow - lastReal)
        lastReal = realNow
        if settings.frozen { dt = 0 }
        simTime += dt

        let viewWidthPt = Double(sv.contentView.bounds.width)
        guard viewWidthPt > 10 else { return }
        let scale = viewWidthPt / Double(ContentGeometry.widthPt)
        let docH = CGFloat(Double(ContentGeometry.heightPt) * scale)
        if abs(doc.frame.height - docH) > 0.5 || abs(doc.frame.width - sv.contentView.bounds.width) > 0.5 {
            doc.frame = NSRect(x: 0, y: 0, width: sv.contentView.bounds.width, height: docH)
        }
        let viewH = Double(sv.contentView.bounds.height) / scale

        let tab = settings.tab
        let truthTex = truthTexture(tab)
        if currentTab != tab {
            currentTab = tab
            setScroll(sv, pt: 0, scale: scale)
            deliverInstantly(at: 0, viewH: viewH)
            lastS = nil
        }
        if settings.style != lastStyle { lastStyle = settings.style; timings.reset(); prevReg = nil }

        // Replay / reset requests.
        if settings.autoReplay && !didAutoReplay && realNow - startedAt > 1.2 { didAutoReplay = true; settings.replayRequest += 1 }
        if settings.replayRequest != seenReplay {
            seenReplay = settings.replayRequest
            replayStart = simTime
            setScroll(sv, pt: 0, scale: scale)
            deliverInstantly(at: 0, viewH: viewH)
        }
        if settings.resetRequest != seenReset {
            seenReset = settings.resetRequest
            replayStart = nil
            setScroll(sv, pt: 0, scale: scale)
            deliverInstantly(at: 0, viewH: viewH)
        }
        if let rs = replayStart {
            let t = simTime - rs
            if let fa = settings.freezeAt, !settings.frozen, t >= 0.6 + fa {
                DispatchQueue.main.async { self.settings.frozen = true; self.settings.freezeAt = nil }
            }
            if let y = replayOffset(t) { setScroll(sv, pt: y, scale: scale) } else { replayStart = nil }
        }

        let viewTop = Double(sv.contentView.bounds.origin.y) / scale
        if dt > 0 {
            history.append((simTime, viewTop))
            let cutoff = simTime - 2.5
            if let idx = history.firstIndex(where: { $0.t >= cutoff }), idx > 1 { history.removeFirst(idx - 1) }
            hostUpdate(dt: dt, viewH: viewH)
        }
        let p = settings.current
        let style = settings.style
        computeKnown()

        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        inflight.wait()

        let drawW = Double(view.drawableSize.width), drawH = Double(view.drawableSize.height)
        let div = max(1, p.divisor)
        let passes = max(1, Int(p.passes.rounded()))
        let srcW = max(8, Int(drawW / div)), srcH = max(8, Int(2 * drawH / div))
        ensureFillTextures(w: srcW, h: srcH, passes: passes)

        // Fill region: viewport plus half a view of padding each side; pull-push reaches to the known band.
        let fillS = S ?? lastS
        var regTop = viewTop - viewH * 0.5, regBot = viewTop + viewH * 1.5
        if style == .pullPush, let s = fillS {
            if s.bottom <= regTop + 8 { regTop = s.bottom - 48 }
            if s.top >= regBot - 8 { regBot = s.top + 48 }
        }
        let regH = regBot - regTop
        let lod = max(0, log2(max(2 * Double(ContentGeometry.widthPt) / Double(srcW), 2 * regH / Double(srcH))))

        var u = Uniforms()
        let bg = tab.background.usingColorSpace(.sRGB)!
        u.bg = SIMD4(Float(bg.redComponent), Float(bg.greenComponent), Float(bg.blueComponent), 1)
        u.viewTopPt = Float(viewTop); u.ptPerPx = Float(Double(ContentGeometry.widthPt) / drawW)
        u.drawW = Float(drawW); u.drawH = Float(drawH)
        u.contentW = Float(ContentGeometry.widthPt); u.contentH = Float(ContentGeometry.heightPt)
        if let s = fillS { u.sTop = Float(s.top); u.sBottom = Float(s.bottom); u.hasKnown = 1 }
        if let k = K { u.kTop = Float(k.top); u.kBottom = Float(k.bottom) }
        u.confTop = Float(lastConf); u.confBottom = Float(lastConf + viewH)
        u.now = Float(simTime); u.crossfade = Float(max(p.crossfadeMs, 0.001) / 1000)
        u.feather = Float(p.feather); u.innerFeather = style.knobs.contains(\FillParams.innerFeather) ? Float(p.innerFeather) : 0
        u.ext = Float(p.ext); u.vignette = Float(p.vignette); u.desat = Float(p.desat); u.grain = Float(p.grain)
        u.tint = Float(p.tint); u.rim = Float(p.rim); u.smearRows = Float(p.smearRows); u.tileRows = Float(p.tileRows)
        u.tileShift = Float(p.tileShift); u.regTop = Float(regTop); u.regH = Float(regH); u.srcLod = Float(lod)
        u.warpAmp = Float(p.warpAmp); u.warpSpeed = Float(p.warpSpeed); u.warpTime = Float(simTime)
        u.style = Int32(style.rawValue); u.showBoundary = settings.showBoundary ? 1 : 0
        // Fill smoothing time constant: a third of the crossfade, so a replaced fill has settled when rows are sharp.
        let tau = max(p.crossfadeMs, 1) / 1000 / 3
        if let pr = prevReg { u.blendK = Float(1 - exp(-dt / tau)); u.prevRegTop = Float(pr.top); u.prevRegH = Float(pr.h) }
        else { u.blendK = 1; u.prevRegTop = Float(regTop); u.prevRegH = Float(regH) }

        let ab = arrivalBufs[frame % 3]; frame += 1
        arrival.withUnsafeBytes { ab.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        // ---- Fill pass (timed on its own command buffer) ----
        dispatchCount = 1
        let fillCB = queue.makeCommandBuffer()!
        fillCB.label = "fill"
        let enc = fillCB.makeComputeCommandEncoder()!
        enc.setComputePipelineState(kEdge)
        enc.setTexture(truthTex, index: 0)
        enc.setBuffer(edgeBuf, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        var blurred: MTLTexture = src!
        if style != .flat {
            enc.setComputePipelineState(kSource)
            enc.setTexture(truthTex, index: 0); enc.setTexture(src!, index: 1)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            dispatch(enc, srcW, srcH)
            if style == .pullPush {
                for i in 1..<pull.count {
                    enc.setComputePipelineState(kPull)
                    enc.setTexture(pull[i - 1], index: 0); enc.setTexture(pull[i], index: 1)
                    dispatch(enc, pull[i].width, pull[i].height)
                }
                let top = pull.count - 1
                enc.setComputePipelineState(kPushTop)
                enc.setTexture(pull[top], index: 0); enc.setTexture(push[top], index: 1)
                dispatch(enc, push[top].width, push[top].height)
                for i in stride(from: top - 1, through: 0, by: -1) {
                    enc.setComputePipelineState(kPush)
                    enc.setTexture(pull[i], index: 0); enc.setTexture(push[i + 1], index: 1); enc.setTexture(push[i], index: 2)
                    dispatch(enc, push[i].width, push[i].height)
                }
                blurred = push[0]
            } else {
                var off = Float(p.blurOffset)
                for i in 1...passes {
                    enc.setComputePipelineState(kDown)
                    enc.setTexture(down[i - 1], index: 0); enc.setTexture(down[i], index: 1)
                    enc.setBytes(&off, length: 4, index: 0)
                    dispatch(enc, down[i].width, down[i].height)
                }
                for i in stride(from: passes - 1, through: 0, by: -1) {
                    enc.setComputePipelineState(kUp)
                    enc.setTexture(i == passes - 1 ? down[passes] : up[i + 1], index: 0); enc.setTexture(up[i], index: 1)
                    enc.setBytes(&off, length: 4, index: 0)
                    dispatch(enc, up[i].width, up[i].height)
                }
                blurred = up[0]
            }
            let prev = smooth[smoothIdx], next = smooth[1 - smoothIdx]
            enc.setComputePipelineState(kTemporal)
            enc.setTexture(blurred, index: 0); enc.setTexture(prev, index: 1); enc.setTexture(next, index: 2)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            dispatch(enc, srcW, srcH)
            smoothIdx = 1 - smoothIdx
            prevReg = (regTop, regH)
            blurred = next
        }
        enc.endEncoding()
        let t = timings
        fillCB.addCompletedHandler { cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0 { t.add(fill: ms) }
        }
        fillCB.commit()

        // ---- Composite ----
        let cb = queue.makeCommandBuffer()!
        cb.label = "composite"
        let re = cb.makeRenderCommandEncoder(descriptor: rpd)!
        re.setRenderPipelineState(composite)
        re.setFragmentTexture(truthTex, index: 0)
        re.setFragmentTexture(src!, index: 1)
        re.setFragmentTexture(blurred, index: 2)
        re.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        re.setFragmentBuffer(ab, offset: 0, index: 1)
        re.setFragmentBuffer(edgeBuf, offset: 0, index: 2)
        re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        re.endEncoding()
        cb.present(drawable)
        let sem = inflight
        cb.addCompletedHandler { cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0 { t.add(composite: ms) }
            sem.signal()
        }
        cb.commit()

        // Unknown fraction of the visible rows (not settled and not yet arriving).
        var unknown = 0
        let r0 = max(0, Int(viewTop)), r1 = min(H, Int(viewTop + viewH))
        if r1 > r0 { for r in r0..<r1 where arrival[r] > Float(simTime) { unknown += 1 }; unknownFrac = Double(unknown) / Double(r1 - r0) }

        if realNow - lastStatsPublish > 0.25 {
            lastStatsPublish = realNow
            let sm = timings.summary()
            let iphonePx = 1179.0 * 2556.0
            let est = cores > 0 ? sm.fill * Double(cores) / 5.0 * iphonePx / (drawW * drawH) : 0
            let uf = unknownFrac
            if settings.logTimings {
                print(String(format: "TIMING style=%@ fill=%.3f p95=%.3f composite=%.3f dispatches=%d frozen=%d", style.title, sm.fill, sm.fillP95, sm.comp, dispatchCount, settings.frozen ? 1 : 0))
                fflush(stdout)
            }
            DispatchQueue.main.async { [settings] in
                settings.fillMs = sm.fill; settings.fillP95 = sm.fillP95; settings.compositeMs = sm.comp
                settings.iphoneEstimate = est; settings.gpuCores = self.cores
                settings.drawablePx = "\(Int(drawW))×\(Int(drawH)) px, base \(srcW)×\(srcH)"
                settings.unknownFraction = uf; settings.dispatches = self.dispatchCount
            }
        }
    }

    private var dispatchCount = 0
    private func dispatch(_ enc: MTLComputeCommandEncoder, _ w: Int, _ h: Int) {
        dispatchCount += 1
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }
}
