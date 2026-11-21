import Foundation
import MirageCore
import CMirageDesktop

/// The Linux host's desktop streamer: a desktop source's picture (the kernel's display, or GNOME's screen cast), x265
/// HEVC, whole display only (layer 0, no tiles), input through the source's backend.
///
/// Video: one thread encodes the newest captured frame at up to `fps`; while the screen is still only one sharpening frame
/// at a low quantizer goes a moment after it stops changing, and then a heartbeat ping each second (the viewer warns of a
/// stall after 3 s without a packet; its echo gives the round trip). Every frame of two or more datagrams carries parity
/// (one lost datagram per group rebuilt without a round trip, as Wi-Fi loses them); a lost frame (the viewer's ack) asks for
/// a keyframe; a NACK resends fragments from a ring of recent frames. Every 10 s of streaming the log has the numbers.
final class LinuxStreamer: DesktopStreamer, @unchecked Sendable {
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private let source: DesktopSource
    private var lease: DesktopLease?
    private var output: StreamOutput?
    private var running = false
    private var thread: Thread?
    private var width = 0, height = 0
    private var fps = 30
    private var maxKbps = 20_000
    private var needKeyframe = true
    private var lastKeyframeAsk: UInt64 = 0
    private var frameSeq: UInt32 = 0
    private var ring: [UInt32: [Data]] = [:]
    private var receiver = InputReceiver()
    private var lastInputSeq: UInt64 = 0
    private let input = LinuxInput()
    private var lastSentNanos: UInt64 = 0
    private var heartbeatSeq: UInt64 = 0
    private var stats = Stats()

    /// What the log reports every 10 s while streaming.
    struct Stats {
        var since: UInt64 = 0
        var frames = 0, bytes = 0, keyframes = 0, nacks = 0, resent = 0, lostFrames = 0
        var ackMs: [Double] = [], rttMs: [Double] = []
        static func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        static func p95(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.95))] }
    }

    /// The session ended for good (stop, not suspend): Lock When Finished.
    private let ended: @Sendable () -> Void
    init(source: DesktopSource, log: @escaping @Sendable (String) -> Void, ended: @escaping @Sendable () -> Void = {}) {
        self.source = source; self.log = log; self.ended = ended
    }

    // MARK: DesktopStreamer

    func start(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
        guard let l = source.acquire(timeout: 3) else {
            throw MirageError.transport(source.unavailableReason ?? "\(source.name) is not available")
        }
        var w: Int32 = 0, h: Int32 = 0
        md_picture_size(l.picture, &w, &h)
        guard w > 1, h > 1 else { source.release(l); throw MirageError.transport("\(source.name) has shown no picture yet") }
        let envFPS = ProcessInfo.processInfo.environment["MIRAGE_FPS"].flatMap(Int.init)
        lock.lock()
        lease = l
        self.output = output
        width = Int(w) & ~1; height = Int(h) & ~1
        fps = max(5, min(request.maxFPS > 0 ? request.maxFPS : 60, envFPS ?? 60))
        maxKbps = max(2_000, min(request.bitrateKbps > 0 ? request.bitrateKbps : 20_000, 60_000))
        needKeyframe = true
        running = true
        lock.unlock()
        input.backend = l.input
        let t = Thread { [weak self] in self?.encodeLoop() }
        t.name = "mirage-encode"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        log("streaming \(source.name): \(w)x\(h), up to \(fps) fps, HEVC ≤ \(maxKbps) kbit/s")
        return info()
    }

    func update(_ request: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo {
        lock.lock(); needKeyframe = true; lock.unlock()
        return info()
    }

    private func info() -> ControlMessage.StreamInfo {
        lock.lock(); defer { lock.unlock() }
        return .init(width: width, height: height, displayID: 1, displayWidth: width, displayHeight: height, displayScale: 1,
                     displayName: DeviceNames.current())
    }

    func handle(ack: ControlMessage.FrameAck) {
        lock.lock()
        if ack.lost { stats.lostFrames += 1 }
        else { stats.ackMs.append(Double(Clock.elapsed(since: ack.captureNanos, now: Clock.nowNanos())) / 1e6) }   // capture → decoded and acked
        lock.unlock()
        guard ack.lost else { return }
        askKeyframe("frame \(ack.seq) lost")
    }
    func handle(tileAck: ControlMessage.TileAck) {}
    func handle(nack: ControlMessage.Nack) {
        lock.lock()
        let frags = ring[nack.frameSeq]
        let out = output
        lock.unlock()
        guard let frags, let out else { askKeyframe("frame \(nack.frameSeq) no longer held"); return }
        let which = nack.fragments.isEmpty ? Array(frags.indices) : nack.fragments.filter { $0 >= 0 && $0 < frags.count }
        for i in which { out.sendDatagram(frags[i]) }
        lock.lock(); stats.nacks += 1; stats.resent += which.count; lastSentNanos = Clock.nowNanos(); lock.unlock()
    }
    func handle(input message: ControlMessage) { input.apply(message) }
    func handle(inputPacket: InputPacket) -> InputAck? {
        lock.lock()
        let (apply, ack) = receiver.receive(inputPacket)
        lastInputSeq = max(lastInputSeq, ack.eventSeq)
        lock.unlock()
        for m in apply { input.apply(m) }
        return ack
    }
    func handle(probeEcho sentNanos: UInt64, receivedNanos: UInt64) {
        lock.lock(); stats.rttMs.append(Double(Clock.elapsed(since: sentNanos, now: Clock.nowNanos())) / 1e6); lock.unlock()
    }

    /// While the screen is still: a ping each second, so the viewer always hears from the host. Then the 10 s report.
    private func heartbeatAndReport(now: UInt64) {
        lock.lock()
        let out = output
        var ping: Data? = nil
        if Clock.elapsed(since: lastSentNanos, now: now) >= 1_000_000_000 {
            heartbeatSeq &+= 1; lastSentNanos = now
            ping = DatagramPing.encode(seq: heartbeatSeq)
        }
        if stats.since == 0 { stats.since = now }
        var line: String? = nil
        let span = Double(Clock.elapsed(since: stats.since, now: now)) / 1e9
        if span >= 10 {
            let st = stats
            line = String(format: "stream: %.0f fps, %.0f kbit/s, %d keyframes, capture→ack median %.0f ms (p95 %.0f, %d), round trip %.1f ms, %d NACKs (%d datagrams resent), %d frames lost",
                          Double(st.frames) / span, Double(st.bytes) * 8 / 1000 / span, st.keyframes, Stats.median(st.ackMs), Stats.p95(st.ackMs),
                          st.ackMs.count, Stats.median(st.rttMs), st.nacks, st.resent, st.lostFrames)
            stats = Stats(); stats.since = now
        }
        lock.unlock()
        if let ping, let out { out.sendDatagram(ping) }
        if let line { log(line) }
    }

    func suspend() async { await halt() }
    func resume(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
        try await start(request, output: output)
    }
    func stop() async { await halt(); ended() }
    func cachedBytes() async -> Int { 0 }
    func shedCaches() async {}

    private func halt() async {
        lock.lock()
        running = false
        let t = thread; thread = nil
        output = nil
        ring = [:]
        lock.unlock()
        input.backend = nil
        // The encode thread notices within one wait (≤ 100 ms) and stops touching the picture.
        while let t, !t.isFinished { try? await Task.sleep(for: .milliseconds(20)) }
        lock.lock(); let l = lease; lease = nil; lock.unlock()
        if let l { source.release(l) }
    }

    private func askKeyframe(_ why: String) {
        let now = Clock.nowNanos()
        lock.lock()
        let due = Clock.elapsed(since: lastKeyframeAsk, now: now) > 300_000_000
        if due { needKeyframe = true; lastKeyframeAsk = now }
        lock.unlock()
        if due { log("keyframe: \(why)") }
    }

    // MARK: Encoding

    private func encodeLoop() {
        lock.lock()
        guard var l = lease else { lock.unlock(); return }
        let fps = self.fps, kbps = maxKbps
        var w = width, h = height
        lock.unlock()
        var err = [CChar](repeating: 0, count: 256)
        var enc = md_encoder_open(Int32(w), Int32(h), Int32(fps), Int32(kbps), &err, err.count)
        if enc == nil { log("encoder: \(String(cString: err))"); return }
        defer { md_encoder_close(enc) }
        let interval = UInt64(1_000_000_000 / fps)
        var seen: UInt64 = 0
        var lastEncode: UInt64 = 0
        var lastChange: UInt64 = Clock.nowNanos()
        var sharpened = false
        let sharpenAfter: UInt64 = 250_000_000
        let sharpenQP = Int32(ProcessInfo.processInfo.environment["MIRAGE_SHARPEN_QP"].flatMap(Int32.init) ?? 18)

        while true {
            lock.lock(); let go = running; lock.unlock()
            if !go { return }
            if l.ended {
                // GNOME ended the session (the indicator's Stop, a crash): carry on with the next one.
                log("\(source.name) ended; waiting for it again")
                input.backend = nil
                var next: DesktopLease?
                while next == nil {
                    lock.lock(); let go = running; lock.unlock()
                    if !go { return }
                    next = source.acquire(timeout: 1)
                }
                lock.lock(); lease = next; needKeyframe = true; lock.unlock()
                source.release(l)
                l = next!
                input.backend = l.input
                seen = 0
                continue
            }
            let latest = md_picture_wait(l.picture, seen, 100)
            let now = Clock.nowNanos()
            heartbeatAndReport(now: now)
            var qp: Int32 = 0
            if latest != seen {
                seen = latest; lastChange = now; sharpened = false
            } else if !sharpened, Clock.elapsed(since: lastChange, now: now) >= sharpenAfter {
                qp = sharpenQP; sharpened = true   // the screen went still: one frame that makes it crisp
            } else {
                continue
            }
            // Pace to the frame rate: the newest frame when the interval is up.
            let since = Clock.elapsed(since: lastEncode, now: now)
            if since < interval { usleep(useconds_t((interval - since) / 1000)) }

            var cw: Int32 = 0, ch: Int32 = 0
            md_picture_size(l.picture, &cw, &ch)
            if Int(cw) & ~1 != w || Int(ch) & ~1 != h {
                // The screen changed size: a new encoder, a keyframe, and the viewer hears the new size.
                md_encoder_close(enc); enc = nil
                w = Int(cw) & ~1; h = Int(ch) & ~1
                enc = md_encoder_open(Int32(w), Int32(h), Int32(fps), Int32(kbps), &err, err.count)
                if enc == nil { log("encoder: \(String(cString: err))"); return }
                lock.lock(); width = w; height = h; needKeyframe = true; let out = output; lock.unlock()
                out?.sendControl(.streamInfo(info()))
                log("screen is now \(cw)x\(ch)")
            }

            lock.lock(); let idr = needKeyframe; needKeyframe = false; lock.unlock()
            var sample: UnsafePointer<UInt8>?
            var key: Int32 = 0
            let n = md_encoder_encode(enc, l.picture, idr ? 1 : 0, idr ? 0 : qp, &sample, &key)
            lastEncode = Clock.nowNanos()
            if n < 0 { if idr { lock.lock(); needKeyframe = true; lock.unlock() }; continue }
            guard n > 0, let sample else { continue }
            send(sample: Data(bytes: sample, count: Int(n)), keyframe: key != 0, encoder: enc!, captureNanos: now, width: w, height: h)
        }
    }

    private func send(sample: Data, keyframe: Bool, encoder: OpaquePointer, captureNanos: UInt64, width: Int, height: Int) {
        var sets: [Data] = []
        if keyframe {
            for i in 0..<md_encoder_param_set_count(encoder) {
                var len: Int32 = 0
                if let p = md_encoder_param_set(encoder, i, &len) { sets.append(Data(bytes: p, count: Int(len))) }
            }
        }
        let payload = VideoFramePayload.encode(parameterSets: sets, sample: sample)
        lock.lock()
        guard let out = output else { lock.unlock(); return }
        frameSeq &+= 1
        let seq = frameSeq
        let inputSeq = lastInputSeq
        lock.unlock()
        let flags: VideoFragment.Flags = keyframe ? [.keyframe, .parameterSets, .recovery] : []
        let maxPayload = max(256, min(out.maxDatagramSize, VideoFragment.datagramSize) - VideoFragment.headerSize)
        let frags = VideoFragment.fragments(frameSeq: seq, flags: flags, captureNanos: captureNanos, payload: payload, maxPayload: maxPayload,
                                            captureSeq: seq, inputSeq: inputSeq, region: PixelRect(x: 0, y: 0, width: width, height: height), layerID: 0)
        for d in frags { out.sendDatagram(d) }
        // Parity on every frame of two or more datagrams: one lost fragment per group is rebuilt without a round trip.
        var sent = frags.reduce(0) { $0 + $1.count }
        if frags.count > 1 {
            let payloads = frags.map { $0.subdata(in: ($0.startIndex + VideoFragment.headerSize)..<$0.endIndex) }
            for p in ParityFragment.parity(frameSeq: seq, payloads: payloads) { out.sendDatagram(p); sent += p.count }
        }
        lock.lock()
        stats.frames += 1; stats.bytes += sent; if keyframe { stats.keyframes += 1 }
        lastSentNanos = Clock.nowNanos()
        ring[seq] = frags
        if seq > 120 { ring[seq - 120] = nil }
        lock.unlock()
    }
}
