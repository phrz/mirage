import AppKit
import Metal
import MetalKit
import IOKit

struct Uniforms {
    var bg = SIMD4<Float>(0, 0, 0, 1)
    var viewTopPt: Float = 0, ptPerPx: Float = 0, drawW: Float = 0, drawH: Float = 0
    var contentW: Float = 0, contentH: Float = 0, baseW: Float = 0, baseH: Float = 0
    var confTop: Float = 0, confBottom: Float = 0, emaK: Float = 1, emaRow0: Float = 0
    var feather: Float = 0, ext: Float = 0, vignette: Float = 0, desat: Float = 0
    var grain: Float = 0, tint: Float = 0, rim: Float = 0, smearRows: Float = 0
    var tileRows: Float = 0, tileShift: Float = 0, srcLod: Float = 0, warpAmp: Float = 0
    var warpSpeed: Float = 0, warpTime: Float = 0, pad0: Float = 0, pad1: Float = 0
    var style: Int32 = 0, showBoundary: Int32 = 0, nDelivered: Int32 = 0, nDisplayed: Int32 = 0
}

/// Rolling GPU timings per named stream, written from command-buffer completion handlers.
final class GPUTimings {
    private let lock = NSLock()
    private var streams: [String: [Double]] = [:]
    func add(_ name: String, _ ms: Double) {
        lock.lock(); defer { lock.unlock() }
        var a = streams[name, default: []]
        a.append(ms); if a.count > 240 { a.removeFirst(a.count - 240) }
        streams[name] = a
    }
    func avg(_ name: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        let a = streams[name, default: []]
        return a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count)
    }
    func reset() { lock.lock(); streams.removeAll(); lock.unlock() }
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

/// Critically damped spring (exact step): no overshoot from rest, continuous velocity under a moving target.
struct Spring {
    var x: Double
    var v: Double = 0
    mutating func step(to target: Double, omega w: Double, dt: Double) {
        guard dt > 0 else { return }
        let y = x - target, c2 = v + w * y, e = exp(-w * dt)
        x = target + (y + c2 * dt) * e
        v = (c2 - w * (y + c2 * dt)) * e
    }
}

/// One boundary edge: two critically damped springs in cascade (4th order). The delivered edge is a staircase
/// (whole chunks, once per host frame); the cascade turns it into motion with continuous velocity and
/// acceleration. Driven by a monotone target from rest, it is itself monotone and never passes the target.
struct Edge {
    var a: Spring, b: Spring
    init(_ x: Double) { a = Spring(x: x); b = Spring(x: x) }
    var x: Double { b.x }
    var v: Double { b.v }
    mutating func step(to target: Double, omega: Double, dt: Double) {
        a.step(to: target, omega: omega, dt: dt)
        b.step(to: a.x, omega: omega, dt: dt)
    }
}

/// A displayed known interval: its edges follow the delivered interval's edges, only ever outward.
struct DisplayedInterval { var top: Edge; var bottom: Edge }

final class Renderer: NSObject, MTKViewDelegate {
    let settings: LabSettings
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let composite: MTLRenderPipelineState
    private let kSource, kDown, kUp, kPull, kPush, kPushTop, kCombine, kEma, kRowAvg: MTLComputePipelineState
    private var truth: [MockTab: MTLTexture] = [:]
    private var rowAvg: [MockTab: MTLBuffer] = [:]
    weak var scrollView: NSScrollView?
    let timings = GPUTimings()
    private let inflight = DispatchSemaphore(value: 3)

    // Content-space fill textures (whole document at 1/divisor of the truth's pixels).
    private var src: MTLTexture?
    private var down: [MTLTexture] = [], up: [MTLTexture] = []
    private var pull: [MTLTexture] = [], push: [MTLTexture] = []
    private var target: MTLTexture?, cache: MTLTexture?
    private var texKey = (div: 0, passes: 0)
    private var cacheValid = false
    private var lastRecomputeKey: [Double] = []
    private var recomputeTimes: [Double] = []

    // Simulation (content pt rows)
    private let H = Int(ContentGeometry.heightPt)
    private var simTime = 0.0
    private var lastNow: CFTimeInterval = 0
    private var history: [(t: Double, y: Double)] = []
    private var known: [Bool]
    private var delivered: [(Double, Double)] = []
    private var deliveredVersion = 0
    private var displayed: [DisplayedInterval] = []
    private var budget = 0.0
    private var frameAcc = 0.0
    private var lastConf = 0.0, confVel = 0.0
    private var currentTab: MockTab? = nil
    private var lastStyle: FillStyle? = nil
    private var startedAt: CFTimeInterval = 0
    private var didAutoReplay = false
    private var seenReplay = 0, seenReset = 0
    private var replayStart: Double? = nil
    private var lastStatsPublish: CFTimeInterval = 0
    private let cores = gpuCoreCount()

    // Display-link timing and smoothness stats.
    var nextTimestamp: CFTimeInterval? = nil
    var linkDuration: CFTimeInterval = 1.0 / 120
    private var frameIntervals: [Double] = []
    private var lastDrawReal: CFTimeInterval = 0
    private var lastBoundaryV: Double? = nil
    private var dvs: [Double] = []
    private var boundaryV = 0.0
    private var frameLog: FileHandle? = nil
    private var dispatchCount = 0
    private var recorder: FrameRecorder? = nil
    private var recordUntil: Double? = nil
    private var stepDvMax = 0.0
    private var visibleSnaps = 0

    init(settings: LabSettings) {
        self.settings = settings
        let dev = MTLCreateSystemDefaultDevice()!
        device = dev
        queue = dev.makeCommandQueue()!
        let lib = try! dev.makeLibrary(source: shaderSource, options: nil)
        func k(_ n: String) -> MTLComputePipelineState { try! dev.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
        kSource = k("buildSource"); kDown = k("kawaseDown"); kUp = k("kawaseUp")
        kPull = k("pullDown"); kPush = k("pushUp"); kPushTop = k("pushTop")
        kCombine = k("combineFill"); kEma = k("emaBlend"); kRowAvg = k("rowAverage")
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "fullscreenVS")
        d.fragmentFunction = lib.makeFunction(name: "compositeFS")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        composite = try! dev.makeRenderPipelineState(descriptor: d)
        known = Array(repeating: false, count: Int(ContentGeometry.heightPt))
        super.init()
        startedAt = CACurrentMediaTime()
        if let path = settings.frameLog {
            FileManager.default.createFile(atPath: path, contents: nil)
            frameLog = FileHandle(forWritingAtPath: path)
            frameLog?.write("sim_t,real_interval_ms,view_top_pt,edge_pt,edge_screen_pt,edge_v_pt_s,delivered_edge_pt,unknown_frac,step_dv_max,visible_snaps\n".data(using: .utf8)!)
        }
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
        let buf = device.makeBuffer(length: H * 16, options: .storageModePrivate)!
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(kRowAvg)
        enc.setTexture(tex, index: 0); enc.setBuffer(buf, offset: 0, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: H, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        truth[tab] = tex
        rowAvg[tab] = buf
        NSLog("Reveal Lab: rendered %@ truth in %.0f ms", tab.title, (CACurrentMediaTime() - t0) * 1000)
        return tex
    }

    // MARK: Fill textures

    private func makeTex(_ w: Int, _ h: Int, rw: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func ensureFillTextures(div: Int, passes: Int) {
        if texKey == (div, passes), src != nil { return }
        let divChanged = texKey.div != div
        texKey = (div, passes)
        let w = ContentGeometry.widthPx / div, h = ContentGeometry.heightPx / div
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
        target = makeTex(w, h)
        if divChanged || cache == nil { cache = makeTex(w, h, rw: true); cacheValid = false }
        lastRecomputeKey = []
    }

    // MARK: Simulated host

    private func offset(at t: Double) -> Double {
        guard let first = history.first else { return 0 }
        if t <= first.t { return first.y }
        for i in stride(from: history.count - 1, through: 0, by: -1) where history[i].t <= t {
            if i + 1 < history.count {
                let a = history[i], b = history[i + 1]
                return a.y + (b.y - a.y) * (t - a.t) / max(b.t - a.t, 1e-6)
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

    private var chunk: Int { max(4, Int(settings.chunkPt)) }

    private func recomputeIntervals() {
        var iv: [(Double, Double)] = []
        var i = 0
        while i < H {
            if known[i] {
                let s = i
                while i < H && known[i] { i += 1 }
                iv.append((Double(s), Double(i)))
            } else { i += 1 }
        }
        delivered = iv
        deliveredVersion += 1
    }

    private func deliverInstantly(at y: Double, viewH: Double) {
        let ch = chunk
        for i in 0..<H { known[i] = false }
        let (t, b) = targetBand(conf: y, viewH: viewH)
        for i in ((t / ch) * ch)..<min(H, ((b + ch - 1) / ch) * ch) { known[i] = true }
        recomputeIntervals()
        displayed = delivered.map { DisplayedInterval(top: Edge($0.0), bottom: Edge($0.1)) }
        budget = 0; frameAcc = 0
        history = [(simTime, y)]
        lastConf = y; confVel = 0
        cacheValid = false
    }

    private func hostUpdate(dt: Double, viewH: Double) {
        let conf = offset(at: simTime - settings.latencyMs / 1000)
        if dt > 0 { confVel = 0.8 * confVel + 0.2 * (conf - lastConf) / dt }
        lastConf = conf
        let ch = chunk
        budget = min(budget + settings.bandwidthRows * dt, settings.bandwidthRows * 0.25 + Double(ch))
        // The host sends whole frames, once per frame interval.
        frameAcc += dt
        if settings.hostFrameMs > 0 && frameAcc < settings.hostFrameMs / 1000 { return }
        frameAcc = 0
        let (tTop, tBot) = targetBand(conf: conf, viewH: viewH)
        var changed = false
        // Forget chunks far from the band.
        let keepTop = (max(0, tTop - Int(viewH * 1.5)) / ch) * ch
        let keepBot = min(H, ((min(H, tBot + Int(viewH * 1.5)) + ch - 1) / ch) * ch)
        for i in 0..<keepTop where known[i] { known[i] = false; changed = true }
        for i in keepBot..<H where known[i] { known[i] = false; changed = true }
        // Undelivered chunks of the band, sent whole: confirmed viewport first, then growing from what is known
        // (so delivery sweeps contiguously); with nothing near, from the side the content came from.
        let nChunks = (H + ch - 1) / ch
        var cands = Array((tTop / ch)..<min(nChunks, (tBot + ch - 1) / ch)).filter { !known[$0 * ch] }
        let seed = confVel >= 0 ? conf : conf + viewH
        func key(_ c: Int) -> Double {
            let lo = c * ch, hi = min(H, lo + ch)
            let inView = Double(hi) > conf && Double(lo) < conf + viewH
            var dist = 1000 + abs(Double(lo + ch / 2) - seed) / Double(ch)
            for k in 1...200 {
                if (c - k >= 0 && known[(c - k) * ch]) || (c + k < nChunks && known[(c + k) * ch]) { dist = Double(k); break }
            }
            return (inView ? 0 : 1e6) + dist
        }
        if cands.isEmpty { budget = min(budget, Double(ch)) }
        while budget >= Double(ch), !cands.isEmpty {
            var best = 0, bestKey = Double.infinity
            for (i, c) in cands.enumerated() { let kk = key(c); if kk < bestKey { bestKey = kk; best = i } }
            let c = cands.remove(at: best)
            for i in (c * ch)..<min(H, c * ch + ch) { known[i] = true }
            budget -= Double(ch)
            changed = true
        }
        if changed { recomputeIntervals() }
    }

    /// Displayed intervals follow the delivered ones on springs. They only advance (never back and forth); a fresh
    /// delivered interval starts collapsed on the side the motion comes from and sweeps open; displayed intervals
    /// inside one delivered interval sweep toward each other and merge.
    private func updateDisplayed(dt: Double, viewTop: Double, viewH: Double) {
        let D = delivered
        // An edge snapping (losing its spring state) inside the view would be a visible jump: count them.
        func visible(_ x: Double) -> Bool { x > 0 && x < Double(H) && x >= viewTop - 20 && x <= viewTop + viewH + 20 }
        func snap(_ e: inout Edge, to x: Double) { if visible(e.x) || visible(x) { visibleSnaps += 1 }; e = Edge(x) }
        var items: [(DisplayedInterval, Int)] = []
        var claimed = Array(repeating: false, count: D.count)
        for var di in displayed {
            let mid = (di.top.x + di.bottom.x) / 2
            guard let j = D.firstIndex(where: { $0.0 <= mid && mid <= $0.1 }) ?? D.firstIndex(where: { $0.0 < di.bottom.x && $0.1 > di.top.x }) else {
                if visible(di.top.x) || visible(di.bottom.x) { visibleSnaps += 1 }
                continue
            }
            // Eviction trimmed the delivered interval (far from the view in practice).
            if di.top.x < D[j].0 { snap(&di.top, to: D[j].0) }
            if di.bottom.x > D[j].1 { snap(&di.bottom, to: D[j].1) }
            if di.bottom.x < di.top.x { snap(&di.bottom, to: di.top.x) }
            claimed[j] = true
            items.append((di, j))
        }
        for j in D.indices where !claimed[j] {
            // A fresh interval opens from the side the motion comes from, at rest: the cascade starts it gently.
            let s = confVel >= 0 ? D[j].0 : D[j].1
            items.append((DisplayedInterval(top: Edge(s), bottom: Edge(s)), j))
        }
        let w = 7.0 / max(settings.current.crossfadeMs / 1000, 0.005)
        for i in items.indices {
            let j = items[i].1
            var di = items[i].0
            let pt = di.top.x, pb = di.bottom.x, vt = di.top.v, vb = di.bottom.v
            di.top.step(to: D[j].0, omega: w, dt: dt)
            di.bottom.step(to: D[j].1, omega: w, dt: dt)
            if dt > 0 { stepDvMax = max(stepDvMax, abs(di.top.v - vt), abs(di.bottom.v - vb)) }
            // Only outward, never past what is delivered (a monotone target makes these no-ops).
            if di.top.x > pt + 1e-9 { snap(&di.top, to: pt) }
            if di.bottom.x < pb - 1e-9 { snap(&di.bottom, to: pb) }
            if di.top.x < D[j].0 - 1e-9 { snap(&di.top, to: D[j].0) }
            if di.bottom.x > D[j].1 + 1e-9 { snap(&di.bottom, to: D[j].1) }
            items[i].0 = di
        }
        // Displayed intervals in one delivered interval sweep into each other and overlap; the composite takes the
        // max of their ramps, so they merge only once the overlap is wide enough (2 feathers) that the union has
        // no dip: the merge itself changes no pixel.
        let mergeOverlap = 2 * settings.current.innerFeather + 1
        items.sort { $0.0.top.x < $1.0.top.x }
        var merged: [(DisplayedInterval, Int)] = []
        for it in items {
            if var last = merged.last, last.1 == it.1, last.0.bottom.x - it.0.top.x >= mergeOverlap || it.0.bottom.x <= last.0.bottom.x {
                if it.0.bottom.x > last.0.bottom.x { last.0.bottom = it.0.bottom }
                merged[merged.count - 1] = last
            } else { merged.append(it) }
        }
        displayed = merged.map { $0.0 }
    }

    // MARK: Replay (scripted fling, in simulated time)

    private static let decel = 0.998   // per ms, like UIScrollView's normal rate
    private func flingOffset(_ v0: Double, _ ms: Double) -> Double { v0 * (pow(Renderer.decel, ms) - 1) / log(Renderer.decel) }

    private func replayOffset(_ t: Double) -> Double? {
        let hold0 = 0.6, f1 = 3.0, hold1 = 1.0, f2 = 3.0
        let v1 = 3.0 * settings.flingScale, v2 = -2.4 * settings.flingScale   // pt per ms
        let maxY = Double(ContentGeometry.heightPt) - 900
        if t < hold0 { return 0 }
        if t < hold0 + f1 { return min(maxY, flingOffset(v1, (t - hold0) * 1000)) }
        let y1 = min(maxY, flingOffset(v1, f1 * 1000))
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
        let real = CACurrentMediaTime()
        if lastDrawReal > 0 { frameIntervals.append((real - lastDrawReal) * 1000); if frameIntervals.count > 240 { frameIntervals.removeFirst() } }
        let realInterval = lastDrawReal > 0 ? (real - lastDrawReal) * 1000 : 0
        lastDrawReal = real
        // Time is the display link's target presentation time, so motion is sampled at an even cadence.
        let now = nextTimestamp ?? real
        nextTimestamp = nil
        var dt = lastNow == 0 ? 0 : min(0.1, max(0, now - lastNow))
        lastNow = now
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
        }
        if settings.style != lastStyle { lastStyle = settings.style; timings.reset(); recomputeTimes.removeAll() }

        if settings.autoReplay && !didAutoReplay && real - startedAt > 1.2 { didAutoReplay = true; settings.replayRequest += 1 }
        if settings.replayRequest != seenReplay {
            seenReplay = settings.replayRequest
            if let path = settings.recordPath, recorder == nil {
                recorder = FrameRecorder(url: URL(fileURLWithPath: path), width: Int(view.drawableSize.width), height: Int(view.drawableSize.height), device: device)
                recordUntil = simTime + settings.recordSeconds
                print(String(format: "RECORD_START sim_t=%.5f", simTime)); fflush(stdout)
            }
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
        stepDvMax = 0
        let snapsBefore = visibleSnaps
        updateDisplayed(dt: dt, viewTop: Double(sv.contentView.bounds.origin.y) / scale, viewH: viewH)
        let frameSnaps = visibleSnaps - snapsBefore
        let p = settings.current
        let style = settings.style

        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else { return }
        inflight.wait()

        let drawW = Double(view.drawableSize.width), drawH = Double(view.drawableSize.height)
        let div = max(2, Int(p.divisor.rounded()))
        let passes = max(1, Int(p.passes.rounded()))
        ensureFillTextures(div: div, passes: passes)
        let baseW = src!.width, baseH = src!.height

        // Intervals for the shaders (at most 16 each, nearest the view first).
        func pack(_ iv: [(Double, Double)]) -> [SIMD2<Float>] {
            var a = iv
            if a.count > 16 { a.sort { abs(($0.0 + $0.1) / 2 - viewTop) < abs(($1.0 + $1.1) / 2 - viewTop) }; a = Array(a.prefix(16)) }
            return a.map { SIMD2(Float($0.0), Float($0.1)) }
        }
        var dIv = pack(delivered)
        var sIv = pack(displayed.map { ($0.top.x, $0.bottom.x) })
        let nD = dIv.count, nS = sIv.count
        if dIv.isEmpty { dIv = [SIMD2(0, 0)] }
        if sIv.isEmpty { sIv = [SIMD2(0, 0)] }

        var u = Uniforms()
        let bg = tab.background.usingColorSpace(.sRGB)!
        u.bg = SIMD4(Float(bg.redComponent), Float(bg.greenComponent), Float(bg.blueComponent), 1)
        u.viewTopPt = Float(viewTop); u.ptPerPx = Float(Double(ContentGeometry.widthPt) / drawW)
        u.drawW = Float(drawW); u.drawH = Float(drawH)
        u.contentW = Float(ContentGeometry.widthPt); u.contentH = Float(ContentGeometry.heightPt)
        u.baseW = Float(baseW); u.baseH = Float(baseH)
        u.confTop = Float(lastConf); u.confBottom = Float(lastConf + viewH)
        u.feather = Float(p.innerFeather); u.ext = Float(p.ext); u.vignette = Float(p.vignette); u.desat = Float(p.desat)
        u.grain = Float(p.grain); u.tint = Float(p.tint); u.rim = Float(p.rim); u.smearRows = Float(p.smearRows)
        u.tileRows = Float(p.tileRows); u.tileShift = Float(p.tileShift); u.srcLod = Float(log2(Double(div)))
        u.warpAmp = Float(p.warpAmp); u.warpSpeed = Float(p.warpSpeed); u.warpTime = Float(simTime)
        u.style = Int32(style.rawValue); u.showBoundary = settings.showBoundary ? 1 : 0
        u.nDelivered = Int32(nD); u.nDisplayed = Int32(nS)
        let ub = MemoryLayout<Uniforms>.stride
        let rowAvgBuf = rowAvg[tab]!
        let t = timings

        // ---- Fill recompute: only when delivered content, the style or its fill parameters change ----
        let rkey = [Double(deliveredVersion), Double(style.rawValue), Double(MockTab.allCases.firstIndex(of: tab)!)] + p.recomputeKey
        if rkey != lastRecomputeKey {
            lastRecomputeKey = rkey
            recomputeTimes.append(simTime); recomputeTimes.removeAll { $0 < simTime - 1 }
            dispatchCount = 0
            let cb = queue.makeCommandBuffer()!
            cb.label = "fill recompute"
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(kSource)
            enc.setTexture(truthTex, index: 0); enc.setTexture(src!, index: 1)
            enc.setBytes(&u, length: ub, index: 0)
            enc.setBytes(dIv, length: dIv.count * 8, index: 1)
            enc.setBuffer(rowAvgBuf, offset: 0, index: 2)
            dispatch(enc, baseW, baseH)
            var blurInput: MTLTexture = src!
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
                blurInput = push[0]
            }
            var blurred: MTLTexture = blurInput
            if style != .flat {
                // Dual Kawase (for pull-push: a softening of the filled pyramid, so known content under the
                // feather is blurred like the fill beyond it).
                var off = Float(p.blurOffset)
                for i in 1...passes {
                    enc.setComputePipelineState(kDown)
                    enc.setTexture(i == 1 ? blurInput : down[i - 1], index: 0); enc.setTexture(down[i], index: 1)
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
            enc.setComputePipelineState(kCombine)
            enc.setTexture(src!, index: 0); enc.setTexture(blurred, index: 1); enc.setTexture(target!, index: 2)
            enc.setBytes(&u, length: ub, index: 0)
            enc.setBytes(dIv, length: dIv.count * 8, index: 1)
            enc.setBuffer(rowAvgBuf, offset: 0, index: 2)
            dispatch(enc, baseW, baseH)
            enc.endEncoding()
            cb.addCompletedHandler { cb in let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000; if ms > 0 { t.add("recompute", ms) } }
            cb.commit()
        }

        // ---- Every frame: EMA of the cache toward the recomputed fill, over a window of rows around the view ----
        do {
            let tau = max(settings.fillSmoothMs, 1) / 1000
            var row0 = 0, rows = baseH
            if cacheValid {
                u.emaK = Float(1 - exp(-dt / tau))
                let r0 = max(0, viewTop - viewH), r1 = min(Double(ContentGeometry.heightPt), viewTop + 2 * viewH)
                row0 = Int(r0 / Double(ContentGeometry.heightPt) * Double(baseH))
                rows = max(1, Int(ceil(r1 / Double(ContentGeometry.heightPt) * Double(baseH))) - row0)
            } else { u.emaK = 1; cacheValid = true }
            u.emaRow0 = Float(row0)
            if u.emaK > 0 {
                let cb = queue.makeCommandBuffer()!
                cb.label = "fill EMA"
                let enc = cb.makeComputeCommandEncoder()!
                enc.setComputePipelineState(kEma)
                enc.setTexture(target!, index: 0); enc.setTexture(cache!, index: 1)
                enc.setBytes(&u, length: ub, index: 0)
                enc.dispatchThreadgroups(MTLSize(width: (baseW + 15) / 16, height: (rows + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
                cb.addCompletedHandler { cb in let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000; if ms > 0 { t.add("ema", ms) } }
                cb.commit()
            }
        }

        // ---- Composite ----
        let cb = queue.makeCommandBuffer()!
        cb.label = "composite"
        let re = cb.makeRenderCommandEncoder(descriptor: rpd)!
        re.setRenderPipelineState(composite)
        re.setFragmentTexture(truthTex, index: 0)
        re.setFragmentTexture(cache!, index: 1)
        re.setFragmentBytes(&u, length: ub, index: 0)
        re.setFragmentBytes(sIv, length: sIv.count * 8, index: 1)
        re.setFragmentBytes(dIv, length: dIv.count * 8, index: 2)
        re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        re.endEncoding()
        if let rec = recorder, let until = recordUntil {
            if simTime <= until {
                rec.capture(drawable.texture, at: now, in: cb)
            } else {
                recordUntil = nil
                rec.finish { frames, dropped in
                    print("RECORD_DONE frames=\(frames) dropped=\(dropped)"); fflush(stdout)
                }
            }
        }
        cb.present(drawable)
        let sem = inflight
        cb.addCompletedHandler { cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0 { t.add("composite", ms) }
            sem.signal()
        }
        cb.commit()

        // ---- Smoothness stats: the displayed edge nearest the view centre ----
        let centre = viewTop + viewH / 2
        var best: (x: Double, v: Double)? = nil
        for di in displayed {
            for e in [di.top, di.bottom] where e.x > 0 && e.x < Double(ContentGeometry.heightPt) {
                if best == nil || abs(e.x - centre) < abs(best!.x - centre) { best = (e.x, e.v) }
            }
        }
        boundaryV = best?.v ?? 0
        if dt > 0 {
            if let lv = lastBoundaryV { dvs.append(abs(boundaryV - lv)); if dvs.count > 120 { dvs.removeFirst() } }
            lastBoundaryV = boundaryV
        }
        var unknownRows = 0
        let r0 = max(0, Int(viewTop)), r1 = min(H, Int(viewTop + viewH))
        for r in stride(from: r0, to: r1, by: 1) {
            if !displayed.contains(where: { Double(r) >= $0.top.x && Double(r) < $0.bottom.x }) { unknownRows += 1 }
        }
        let unknownFrac = r1 > r0 ? Double(unknownRows) / Double(r1 - r0) : 0
        if let fl = frameLog, dt > 0 {
            var dEdge = Double.nan
            for iv in delivered { for e in [iv.0, iv.1] where e > 0 && e < Double(H) { if dEdge.isNaN || abs(e - centre) < abs(dEdge - centre) { dEdge = e } } }
            let line = String(format: "%.5f,%.3f,%.3f,%.3f,%.3f,%.2f,%.1f,%.4f,%.2f,%d\n", simTime, realInterval, viewTop, best?.x ?? .nan, (best?.x ?? .nan) - viewTop, boundaryV, dEdge, unknownFrac, stepDvMax, frameSnaps)
            fl.write(line.data(using: .utf8)!)
        }

        if real - lastStatsPublish > 0.5 {
            lastStatsPublish = real
            let rec = t.avg("recompute"), ema = t.avg("ema"), comp = t.avg("composite")
            let fi = frameIntervals
            let favg = fi.isEmpty ? 0 : fi.reduce(0, +) / Double(fi.count)
            let fmax = fi.max() ?? 0
            let hitch = fi.filter { $0 > linkDuration * 1000 * 1.5 }.count
            let dvMax = dvs.max() ?? 0
            let rHz = Double(recomputeTimes.count)
            let bv = boundaryV
            let dc = dispatchCount
            if settings.logTimings {
                print(String(format: "TIMING style=%@ recompute=%.3f recomputeHz=%.0f ema=%.3f composite=%.3f dispatches=%d frameAvg=%.2f frameMax=%.2f hitches=%d dvMax=%.1f", style.title, rec, rHz, ema, comp, dc, favg, fmax, hitch, dvMax))
                fflush(stdout)
            }
            var snap = StatsSnapshot()
            snap.recomputeMs = rec; snap.recomputeHz = rHz; snap.emaMs = ema; snap.compositeMs = comp
            snap.frameAvgMs = favg; snap.frameMaxMs = fmax; snap.hitches = hitch
            snap.boundaryVel = bv; snap.boundaryDvMax = dvMax
            snap.gpuCores = cores
            snap.drawablePx = "\(Int(drawW))×\(Int(drawH)) px view, fill \(baseW)×\(baseH) (whole document)"
            snap.unknownFraction = unknownFrac
            snap.dispatches = dc
            // Published after this frame's work, outside the display-link callback.
            DispatchQueue.main.async { [st = settings.stats] in if st.s != snap { st.s = snap } }
        }
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ w: Int, _ h: Int) {
        dispatchCount += 1
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }
}
