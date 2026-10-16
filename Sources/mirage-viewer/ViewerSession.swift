import Foundation
import AppKit
import CoreVideo
import MirageCore

/// Everything the viewer knows about one host connection, published for SwiftUI.
@MainActor
final class ViewerModel: ObservableObject {
    @Published var status = "connecting…"
    @Published var error: String?
    @Published var stats = Stats()
    @Published var showStats = true
    @Published var cursor: CursorImage?
    @Published var remoteCursor: CGPoint? = nil      // normalized, host-reported
    @Published var streamInfo: ControlMessage.StreamInfo?
    @Published var bitrateKbps: Int
    @Published var pixelFactor: Double

    struct Stats {
        var rttMs = 0.0, fps = 0.0, kbps = 0.0, frameAgeMs = 0.0, decodeMs = 0.0
        var lost = 0, frames = 0, dropped = 0
        var width = 0, height = 0
    }
    struct CursorImage {
        let image: NSImage
        let hotspot: CGPoint
        let size: CGSize
    }

    init(bitrateKbps: Int, pixelFactor: Double) { self.bitrateKbps = bitrateKbps; self.pixelFactor = pixelFactor }
}

/// Owns the connection; feeds decoded frames to a presenter and forwards input.
final class ViewerSession: @unchecked Sendable {
    let host: String
    let port: UInt16
    let pairCode: String?
    let model: ViewerModel
    private var client: QUICClient?
    private var control: MessageStream?
    private var sender: ControlSender?
    private var flow: MessageStream?
    private let videoQueue = DispatchQueue(label: "mirage.viewer.video", qos: .userInteractive)
    private var assembler = FrameAssembler()
    private let decoder = HEVCDecoder()
    private var awaitingRecovery = false
    var present: ((CVImageBuffer, VideoFrame) -> Void)?

    // Clock sync: hostNanos ≈ localNanos + offset.
    private var clockOffset: Double = 0
    private var bestRTT: Double = .infinity
    private var pingSeq: UInt64 = 0
    private var pingsOut: [UInt64: UInt64] = [:]
    private let statsLock = NSLock()
    private var sFrames = 0, sBytes = 0, sLost = 0, sDecodeNanos: UInt64 = 0, sAge: Double = 0, sRTT = 0.0, sDropped = 0
    private var lastRequest: ControlMessage.StreamRequest?
    private var lastMoveSent: UInt64 = 0
    private var pendingMove: ControlMessage.MouseMove?

    init(host: String, port: UInt16, pairCode: String?, model: ViewerModel) {
        self.host = host; self.port = port; self.pairCode = pairCode; self.model = model
    }

    func log(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }

    func start() {
        Task { await run() }
    }

    private func setStatus(_ s: String) { Task { @MainActor in model.status = s } }

    private func run() async {
        do {
            let store = try Store()
            let identity = try store.identity(role: "client", name: DeviceNames.current())
            let client = QUICClient(host: host, port: port)
            self.client = client
            try await client.connect()
            guard let fp = client.tlsFingerprint else { throw MirageError.transport("no TLS fingerprint") }
            let control = try await client.openStream()
            self.control = control
            let session = ClientSession(identity: identity, store: store, alias: host, tlsFingerprint: fp, stream: control)
            if let pairCode {
                guard let code = PairingCode.normalize(pairCode) else { throw MirageError.pairingFailed("--pair needs 6 digits") }
                let h = try await session.pair(code: code)
                log("paired with \(h.name)")
            }
            let welcome = try await session.authenticate()
            setStatus("authenticated to \(welcome.hostName)")
            sender = ControlSender(stream: control, log: { [weak self] in self?.log($0) })
            if let p = pendingRequest { pendingRequest = nil; requestStream(width: p.width, height: p.height) }
            let flow = try await client.openDatagramFlow()
            self.flow = flow
            try await flow.sendRaw(DatagramPing.encode(seq: 0))   // opens the flow on the host side
            Task.detached { [weak self] in await self?.receiveDatagrams(flow) }
            Task.detached { [weak self] in await self?.pingLoop() }
            Task.detached { [weak self] in await self?.statsLoop() }
            try await receiveControl(control)
        } catch {
            log("viewer: \(error)")
            Task { @MainActor in model.error = "\(error)"; model.status = "disconnected" }
        }
    }

    // MARK: Stream control

    func requestStream(width: Int, height: Int) {
        Task { @MainActor in
            let req = ControlMessage.StreamRequest(width: width, height: height, bitrateKbps: model.bitrateKbps, maxFPS: 30)
            if req == lastRequest { return }
            guard let sender else { pendingRequest = req; return }   // not connected yet; sent once the control stream is up
            lastRequest = req
            sender.send(.streamRequest(req))
        }
    }
    private var pendingRequest: ControlMessage.StreamRequest?

    @MainActor func adjustBitrate(by delta: Int) {
        model.bitrateKbps = max(100, min(20_000, model.bitrateKbps + delta))
        if let r = lastRequest { lastRequest = nil; requestStream(width: r.width, height: r.height) }
    }

    // MARK: Receive loops

    private func receiveControl(_ control: MessageStream) async throws {
        while true {
            let msg = try await control.receive()
            switch msg {
            case .pong(let p):
                let now = Clock.nowNanos()
                let rtt = Double(now - p.sentNanos)
                pingsOut[p.seq] = nil
                if let echo = p.echoNanos, rtt < bestRTT {
                    bestRTT = rtt
                    clockOffset = Double(echo) - (Double(p.sentNanos) + rtt / 2)
                }
                statsLock.lock(); sRTT = rtt / 1e6; statsLock.unlock()
            case .streamInfo(let info):
                Task { @MainActor in model.streamInfo = info; model.status = "streaming \(info.width)x\(info.height) from \(host)" }
            case .cursorShape(let c):
                if let img = NSImage(data: c.png) {
                    Task { @MainActor in model.cursor = .init(image: img, hotspot: CGPoint(x: c.hotspotX, y: c.hotspotY), size: CGSize(width: c.width, height: c.height)) }
                }
            case .cursorPosition(let p):
                Task { @MainActor in model.remoteCursor = p.visible ? CGPoint(x: p.x, y: p.y) : nil }
            case .reject(let r):
                log("host: \(r.reason)")
                Task { @MainActor in model.error = r.reason; model.status = "host refused" }
                lastRequest = nil   // a later resize/bitrate change retries
            default:
                log("unexpected control message: \(msg)")
            }
        }
    }

    private func receiveDatagrams(_ flow: MessageStream) async {
        while true {
            guard let d = try? await flow.receiveSome() else { log("datagram flow closed"); return }
            if let frag = VideoFragment.decode(d) {
                videoQueue.async { self.ingest(frag) }
            }
        }
    }

    private func ingest(_ frag: VideoFragment) {
        let now = Clock.nowNanos()
        for ev in assembler.ingest(frag, now: now) {
            switch ev {
            case .lost(let seq):
                awaitingRecovery = true
                statsLock.lock(); sLost += 1; statsLock.unlock()
                sender?.send(.frameAck(.init(seq: seq, captureNanos: 0, receivedNanos: now, decodedNanos: 0, bytes: 0, lost: true)))
            case .completed(let frame):
                statsLock.lock(); sBytes += frame.bytes; statsLock.unlock()
                if awaitingRecovery && !frame.flags.contains(.recovery) {
                    statsLock.lock(); sDropped += 1; statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: 0, bytes: frame.bytes, lost: false)))
                    continue
                }
                let t0 = Clock.nowNanos()
                do {
                    let image = try decoder.decode(frame)
                    let t1 = Clock.nowNanos()
                    awaitingRecovery = false
                    present?(image, frame)
                    let ageNanos = (Double(t1) + clockOffset) - Double(frame.captureNanos)
                    statsLock.lock()
                    sFrames += 1; sDecodeNanos += t1 - t0; sAge = sAge == 0 ? ageNanos : sAge * 0.7 + ageNanos * 0.3
                    statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: t1, bytes: frame.bytes, lost: false)))
                } catch {
                    log("decode seq \(frame.seq): \(error)")
                    awaitingRecovery = true
                    statsLock.lock(); sLost += 1; statsLock.unlock()
                    sender?.send(.frameAck(.init(seq: frame.seq, captureNanos: frame.captureNanos, receivedNanos: frame.lastFragmentNanos, decodedNanos: 0, bytes: frame.bytes, lost: true)))
                }
            }
        }
    }

    private func pingLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(1))
            pingSeq += 1
            let t = Clock.nowNanos()
            pingsOut[pingSeq] = t
            sender?.send(.ping(.init(seq: pingSeq, sentNanos: t)))
        }
    }

    private func statsLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(1))
            statsLock.lock()
            let frames = sFrames, bytes = sBytes, lost = sLost, dec = sDecodeNanos, age = sAge, rtt = sRTT, dropped = sDropped
            sFrames = 0; sBytes = 0; sLost = 0; sDecodeNanos = 0; sDropped = 0
            statsLock.unlock()
            let w = decoder.width, h = decoder.height
            await MainActor.run {
                var s = model.stats
                s.fps = Double(frames); s.kbps = Double(bytes) * 8 / 1000; s.lost += lost; s.frames += frames; s.dropped += dropped
                s.decodeMs = frames > 0 ? Double(dec) / Double(frames) / 1e6 : s.decodeMs
                s.frameAgeMs = age / 1e6; s.rttMs = rtt; s.width = w; s.height = h
                model.stats = s
            }
        }
    }

    // MARK: Input

    func sendMouseMove(x: Double, y: Double) {
        // Coalesce to ~60 Hz; the control stream is ordered so later moves supersede earlier ones anyway.
        let now = Clock.nowNanos()
        if now - lastMoveSent < 15_000_000 { pendingMove = .init(x: x, y: y); scheduleMoveFlush(); return }
        lastMoveSent = now; pendingMove = nil
        sender?.send(.mouseMove(.init(x: x, y: y)))
    }
    private var flushScheduled = false
    private func scheduleMoveFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [self] in
            flushScheduled = false
            if let m = pendingMove { pendingMove = nil; lastMoveSent = Clock.nowNanos(); sender?.send(.mouseMove(m)) }
        }
    }
    func send(_ m: ControlMessage) { sender?.send(m) }

    func stop() {
        sender?.send(.streamStop)
        client?.close()
    }
}
