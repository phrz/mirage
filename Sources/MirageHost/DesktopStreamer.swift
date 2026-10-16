import Foundation
import CoreVideo
import CoreGraphics
import ApplicationServices
import MirageCore

/// macOS desktop streamer: SCK capture → HEVC → datagrams, with ack-driven pacing, cursor
/// metadata and input injection. All mutable state lives on `queue`.
public final class MacDesktopStreamer: DesktopStreamer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "mirage.host.video", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "mirage.host.input", qos: .userInteractive)
    private let log: @Sendable (String) -> Void
    private var output: StreamOutput?
    private var capturer: ScreenCapturer?
    private var encoder: HEVCEncoder?
    private var injector: InputInjector?
    private var cursor: CursorMonitor?
    private var request: ControlMessage.StreamRequest?
    private var target: ScreenCapturer.Target?

    // Pacing state.
    private var seq: UInt32 = 0
    private var tokens: Double = 0                 // bytes available to send
    private var lastRefill = Clock.nowNanos()
    private var lastSendNanos: UInt64 = 0
    private struct InFlight { let sentNanos: UInt64; let bytes: Int; let ltrToken: Int64? }
    private var unacked: [UInt32: InFlight] = [:]
    private var srttNanos: Double = 250_000_000
    private var ackedLTR: [Int64] = []
    private var wantKeyframe = false   // the first encoded frame is an IDR anyway
    private var wantLTRRefresh = false
    private var encoding = false
    private var recoverySeq: UInt32 = 0
    private var keyframeArmed = false

    // Stats (per log interval).
    private var statFrames = 0, statBytes = 0, statDropped = 0, statSkippedBudget = 0, statLost = 0
    private var statEncodeNanos: UInt64 = 0
    private var statDirty = 0.0, statDirtyN = 0, statInput = 0
    private var statTimer: DispatchSourceTimer?

    public init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        hostLog = log
    }

    // MARK: DesktopStreamer

    public func start(_ req: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo {
        let cap = ScreenCapturer(queue: queue)
        let t = try await cap.start(req) { [weak self] pb, nanos, dirty in self?.captured(pb, nanos, dirty: dirty) }
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                do {
                    self.output = output
                    self.capturer = cap
                    self.target = t
                    self.request = req
                    self.encoder = try HEVCEncoder(width: t.pixelWidth, height: t.pixelHeight, bitrateKbps: req.bitrateKbps, expectedFPS: self.plannedFPS(req))
                    self.tokens = self.bucketCapacity(req)
                    self.injector = InputInjector(displayID: t.display.displayID)
                    let cur = CursorMonitor(displayID: t.display.displayID)
                    cur.onShape = { [weak self] s in self?.output?.sendControl(.cursorShape(s)) }
                    cur.onPosition = { [weak self] p in self?.output?.sendControl(.cursorPosition(p)) }
                    cur.start(on: self.queue)
                    self.cursor = cur
                    cap.onStop = { [weak self] err in self?.log("capture stopped: \(err.map { "\($0)" } ?? "ok")") }
                    self.startStats()
                    c.resume(returning: t.info)
                } catch { c.resume(throwing: error) }
            }
        }
    }

    public func update(_ req: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo {
        guard let cap = capturer else { throw MirageError.transport("not streaming") }
        let t = try await cap.update(req)
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                let old = self.target
                if old?.pixelWidth != t.pixelWidth || old?.pixelHeight != t.pixelHeight || self.encoder == nil {
                    do {
                        // Build the new encoder first; on failure the old one (and old size) stay in service.
                        self.encoder = try HEVCEncoder(width: t.pixelWidth, height: t.pixelHeight, bitrateKbps: req.bitrateKbps, expectedFPS: self.plannedFPS(req))
                    } catch {
                        self.log("stream reconfigure to \(t.pixelWidth)x\(t.pixelHeight) failed: \(error)")
                        if let oldReq = self.request { Task { _ = try? await cap.update(oldReq) } }   // put SCK back to the old size
                        c.resume(throwing: error); return
                    }
                    self.wantKeyframe = true
                    self.ackedLTR = []
                    self.log("stream reconfigured to \(t.pixelWidth)x\(t.pixelHeight) @ \(req.bitrateKbps) kbps")
                } else {
                    self.encoder?.setRate(bitrateKbps: req.bitrateKbps, expectedFPS: self.plannedFPS(req))
                    self.log("stream rate set to \(req.bitrateKbps) kbps")
                }
                self.target = t
                self.request = req
                self.injector?.setDisplay(t.display.displayID)
                self.cursor?.setDisplay(t.display.displayID)
                c.resume(returning: t.info)
            }
        }
    }

    public func handle(ack: ControlMessage.FrameAck) {
        queue.async { self.acked(ack) }
    }

    public func handle(input: ControlMessage) {
        inputQueue.async {
            self.injector?.handle(input)
            self.queue.async { self.statInput += 1 }
        }
    }

    public func stop() async {
        let cap = capturer
        await cap?.stop()
        await withCheckedContinuation { c in
            queue.async {
                self.cursor?.stop(); self.cursor = nil
                self.statTimer?.cancel(); self.statTimer = nil
                self.encoder = nil; self.capturer = nil; self.output = nil
                let inj = self.injector; self.injector = nil
                self.inputQueue.async { inj?.releaseAll() }
                c.resume()
            }
        }
    }

    // MARK: Pacing

    /// What the encoder should plan for: the frame rate the bitrate can carry at a sane frame size, capped by the request.
    private func plannedFPS(_ req: ControlMessage.StreamRequest) -> Int {
        // Aim for ~6 KB/frame at the bottom of the ladder, more fps as bitrate grows; never above maxFPS.
        let bytesPerSec = Double(req.bitrateKbps * 1000 / 8)
        let fps = Int(bytesPerSec / 6000)
        return max(5, min(req.maxFPS, fps))
    }
    private func bucketCapacity(_ req: ControlMessage.StreamRequest) -> Double { Double(req.bitrateKbps * 1000 / 8) * 0.35 }

    private func refill() {
        guard let req = request else { return }
        let now = Clock.nowNanos()
        let dt = Double(now - lastRefill) / 1e9
        lastRefill = now
        tokens = min(bucketCapacity(req), tokens + dt * Double(req.bitrateKbps * 1000 / 8))
        tokens = max(tokens, -3 * bucketCapacity(req))   // bound the debt a huge keyframe can create
    }

    private func captured(_ pb: CVPixelBuffer, _ nanos: UInt64, dirty: Double) {
        guard var enc = encoder, let req = request, output != nil else { return }
        refill()
        let now = Clock.nowNanos()
        // Give up on frames whose ack is long overdue; treat as lost.
        let staleAfter = UInt64(max(3 * srttNanos, 1_000_000_000))
        for (s, f) in unacked where now - f.sentNanos > staleAfter {
            unacked[s] = nil; statLost += 1; requestRecovery()
        }
        if encoding { statDropped += 1; return }
        let inflightBytes = unacked.values.reduce(0) { $0 + $1.bytes }
        // Budget: bytes in flight may not exceed what the link drains in one RTT plus slack.
        let inflightBudget = Double(req.bitrateKbps * 1000 / 8) * (srttNanos / 1e9 + 0.15)
        if !unacked.isEmpty && Double(inflightBytes) > inflightBudget { statSkippedBudget += 1; return }
        // Classic token bucket: a frame may go when the bucket is non-negative; it then goes negative
        // by the frame's size and refills at the target bitrate. Big keyframes thus pay their debt over time.
        if tokens < 0 { statSkippedBudget += 1; return }
        // Sparse changes (a caret, a spinner, a clock) do not deserve 30 fps of whole-frame refreshes:
        // low-latency HEVC spends the whole budget re-polishing a static picture otherwise. M2's tile
        // path replaces this; for now cap the rate by how much of the frame moved.
        let fpsCap: Double = dirty < 0.005 ? 5 : dirty < 0.03 ? 10 : dirty < 0.15 ? 20 : Double(req.maxFPS)
        let minInterval = UInt64(1e9 / min(fpsCap, Double(max(1, req.maxFPS))))
        if now - lastSendNanos < minInterval * 9 / 10 { statDropped += 1; return }
        statDirty += dirty; statDirtyN += 1

        var opts = HEVCEncoder.FrameOptions()
        if wantKeyframe {
            // A forced keyframe ignores MinAllowedFrameQP (measured: ~125 KB regardless of when the floor
            // is set), but a fresh session's first IDR honours it (~18 KB). Recovery therefore replaces
            // the session; creation costs a few ms and losses are rare.
            if let fresh = try? HEVCEncoder(width: enc.width, height: enc.height, bitrateKbps: enc.bitrateKbps, expectedFPS: enc.expectedFPS) {
                encoder = fresh; enc = fresh; ackedLTR = []
            } else {
                opts.forceKeyframe = true
            }
            wantKeyframe = false; wantLTRRefresh = false
            keyframeArmed = true   // reused as "this frame is a recovery frame"
        } else if enc.coarse && seq > 0 { enc.setCoarse(false) }
        if !keyframeArmed && wantLTRRefresh { opts.forceLTRRefresh = true }
        opts.acknowledgedLTRTokens = ackedLTR
        let recovery = keyframeArmed || wantLTRRefresh
        if recovery { lastRecoveryWasLTR = wantLTRRefresh && !keyframeArmed }
        keyframeArmed = false; wantLTRRefresh = false
        encoding = true
        lastSendNanos = now
        enc.encode(pb, captureNanos: nanos, options: opts) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.encoding = false
                switch result {
                case .failure(let e):
                    // A rate-limited drop keeps the reference chain intact; only real errors need a keyframe.
                    if case MirageError.transport(let t) = e, t.contains("dropped") { self.statDropped += 1 }
                    else { self.log("encode: \(e)"); self.wantKeyframe = true }
                case .success(let f):
                    self.send(f, recovery: recovery)
                }
            }
        }
    }

    private func send(_ f: HEVCEncoder.Encoded, recovery: Bool) {
        guard let out = output else { return }
        seq &+= 1
        var flags: VideoFragment.Flags = []
        if f.keyframe { flags.insert(.keyframe); flags.insert(.recovery) }
        if recovery { flags.insert(.recovery) }
        if flags.contains(.recovery) { recoverySeq = seq }
        if !f.parameterSets.isEmpty { flags.insert(.parameterSets) }
        let payload = VideoFramePayload.encode(parameterSets: f.parameterSets, sample: f.sample)
        let maxPayload = out.maxDatagramSize - VideoFragment.headerSize
        let frags = VideoFragment.fragments(frameSeq: seq, flags: flags, captureNanos: f.captureNanos, payload: payload, maxPayload: maxPayload)
        for d in frags { out.sendDatagram(d) }
        tokens -= Double(payload.count)
        unacked[seq] = InFlight(sentNanos: Clock.nowNanos(), bytes: payload.count, ltrToken: f.ltrToken)
        statFrames += 1; statBytes += payload.count; statEncodeNanos += f.encodeNanos
        if f.keyframe { log("keyframe \(payload.count) bytes (\(frags.count) datagrams)") }
    }

    private func acked(_ ack: ControlMessage.FrameAck) {
        let now = Clock.nowNanos()
        if let f = unacked.removeValue(forKey: ack.seq) {
            // Loss acks come after the assembler's timeout; they say nothing about the path's RTT.
            if !ack.lost { srttNanos = srttNanos * 0.8 + Double(now - f.sentNanos) * 0.2 }
            if !ack.lost, ack.decodedNanos != 0, ack.seq >= recoverySeq { lastRecoveryWasLTR = false }
            if !ack.lost, ack.decodedNanos != 0, let tok = f.ltrToken {
                ackedLTR.append(tok)
                if ackedLTR.count > 8 { ackedLTR.removeFirst(ackedLTR.count - 8) }
            }
        }
        // Everything older than this ack is either acked already or will never be.
        for s in unacked.keys where s < ack.seq { unacked[s] = nil }
        // A loss before the last recovery frame is already healed by it; only newer losses matter.
        if ack.lost { statLost += 1; if ack.seq >= recoverySeq { requestRecovery() } }
    }

    /// Recovery defaults to a (QP-floored, ~18 KB) keyframe. LTR refresh is opt-in (MIRAGE_LTR=1):
    /// on the Dallas→Japan run the viewer rejected every ForceLTRRefresh frame with
    /// kVTVideoDecoderBadDataErr after it had skipped frames, looping forever; see DESIGN §6.
    private static let ltrEnabled = ProcessInfo.processInfo.environment["MIRAGE_LTR"] != nil
    private var lastRecoveryWasLTR = false
    private func requestRecovery() {
        if Self.ltrEnabled && !ackedLTR.isEmpty && !lastRecoveryWasLTR {
            wantLTRRefresh = true      // one LTR attempt; if that frame is lost too, escalate to a keyframe
        } else {
            wantKeyframe = true
        }
    }

    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let fps = Double(statFrames) / 5
            let kbps = Double(statBytes) * 8 / 5 / 1000
            let enc = statFrames > 0 ? Double(statEncodeNanos) / Double(statFrames) / 1e6 : 0
            let dirty = statDirtyN > 0 ? statDirty / Double(statDirtyN) * 100 : 0
            log(String(format: "video %.1f fps  %.0f kbps  encode %.1f ms  dirty %.1f%%  srtt %.0f ms  inflight %d  skipped(budget) %d dropped(busy/rate) %d lost %d  ltr-acked %d  input %d",
                       fps, kbps, enc, dirty, srttNanos / 1e6, unacked.count, statSkippedBudget, statDropped, statLost, ackedLTR.count, statInput))
            statFrames = 0; statBytes = 0; statDropped = 0; statSkippedBudget = 0; statLost = 0; statEncodeNanos = 0; statDirty = 0; statDirtyN = 0; statInput = 0
        }
        t.resume()
        statTimer = t
    }
}

/// TCC state the host needs; prompting adds `miraged` to the System Settings lists.
public enum HostPermissions {
    public static func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }
    public static func accessibilityGranted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
    }
}
