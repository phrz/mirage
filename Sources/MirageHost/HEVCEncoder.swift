import Foundation
import VideoToolbox
import CoreMedia
import MirageCore

/// Hardware HEVC, low-latency rate control, no reordering, LTR enabled.
final class HEVCEncoder {
    struct Encoded {
        let keyframe: Bool
        let parameterSets: [Data]      // non-empty on keyframes / format change
        let sample: Data               // hvcC-style, 4-byte NAL length prefixes
        let ltrToken: Int64?
        let captureNanos: UInt64
        let encodeNanos: UInt64
    }
    struct FrameOptions {
        var forceKeyframe = false
        var forceLTRRefresh = false
        var acknowledgedLTRTokens: [Int64] = []
    }

    let width: Int, height: Int
    private var session: VTCompressionSession
    private var lastFormat: CMFormatDescription?
    private var firstFrame = true
    private(set) var bitrateKbps: Int
    private(set) var expectedFPS: Int

    init(width: Int, height: Int, bitrateKbps: Int, expectedFPS: Int) throws {
        self.width = width; self.height = height; self.bitrateKbps = bitrateKbps; self.expectedFPS = expectedFPS
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw MirageError.transport("VTCompressionSessionCreate failed: \(st)") }
        session = s
        func set(_ k: CFString, _ v: CFTypeRef) {
            let r = VTSessionSetProperty(s, key: k, value: v)
            if r != noErr { hostLog("encoder: \(k) rejected (\(r))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 1 << 20 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 << 20 as CFNumber)
        set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue)
        applyRate()
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// Session properties change only while no frame is in the hardware encoder: a VTSessionSetProperty during an encode
    /// deadlocked the session (the mini's host on 569, 2026-10-31: the video queue waited in the property call on the encoder
    /// service, which waited on the host for the in-flight frame's format description; every later stream start hung behind
    /// it). Changes queue here and apply when the encoder is idle, at the latest just before the next frame.
    private let idle = NSCondition()
    private var inFlight = 0
    private var pendingKeys: [CFString] = []
    private var pending: [CFString: CFTypeRef] = [:]
    private func set(_ key: CFString, _ value: CFTypeRef) {
        idle.lock()
        if pending[key] == nil { pendingKeys.append(key) }
        pending[key] = value
        if inFlight == 0 { applyPending() }
        idle.unlock()
    }
    /// With `idle` held and nothing in flight.
    private func applyPending() {
        for k in pendingKeys {
            let r = VTSessionSetProperty(session, key: k, value: pending[k]!)
            if r != noErr { hostLog("encoder: \(k) rejected (\(r))") }
        }
        pendingKeys.removeAll(); pending.removeAll()
    }

    func setRate(bitrateKbps: Int, expectedFPS: Int) {
        self.bitrateKbps = bitrateKbps; self.expectedFPS = expectedFPS
        applyRate()
    }

    private func applyRate() {
        let bps = bitrateKbps * 1000
        set(kVTCompressionPropertyKey_AverageBitRate, bps as CFNumber)
        // Hard cap: 1.5 s' worth of bytes per second. Low-latency mode has no CBR, so this is the ceiling;
        // motion frames are bursty against a steady lossless-tile trickle, so leave headroom.
        let limits: [Any] = [bps / 8 * 3 / 2, 1.0]
        set(kVTCompressionPropertyKey_DataRateLimits, limits as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, expectedFPS as CFNumber)
        // Quality the budget pays for: low-latency rate control stayed far under a LAN's budget (the locked mac-daddy on 546:
        // 7-10 Mbps of 45 at 3200x1800, 895 kbps in phrz's viewer: "super lossy way too long for this LAN"), and the lock
        // screen's animated wallpaper never stands still for lossless tiles, so the video is the picture. A QP ceiling from
        // the bits per pixel the budget allows; none on a slow link.
        ceilingQP = Self.maxQP(bitrateKbps: bitrateKbps, width: width, height: height, fps: expectedFPS)
        set(kVTCompressionPropertyKey_MaxAllowedFrameQP, ceilingQP as CFNumber)
        if coarse { applyFloor() }
    }
    /// The QP ceiling in force (MaxAllowedFrameQP): the budget's, or the sharpening pass's.
    private var ceilingQP = 51
    /// The sharpening pass (wholeDisplayOnly): the next frames at a low QP ceiling, the screen standing still; off at the next
    /// change (the budget's ceiling again).
    private(set) var sharpening = false
    func setSharpening(_ on: Bool) {
        guard on != sharpening else { return }
        sharpening = on
        if on {
            ceilingQP = Self.sharpenQP
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, ceilingQP as CFNumber)
            if coarse { applyFloor() }
        } else { applyRate() }
    }
    static let sharpenQP = 20
    /// The highest QP a frame may use for a budget: bits per pixel per frame at the expected rate. Pure, for tests.
    static func maxQP(bitrateKbps: Int, width: Int, height: Int, fps: Int) -> Int {
        let bpp = Double(bitrateKbps) * 1000 / Double(max(1, width * height * max(1, fps)))
        switch bpp {
        case 0.2...: return 30
        case 0.1...: return 33
        case 0.05...: return 36
        default: return 51
        }
    }

    /// Encodes one frame; `completion` runs on VideoToolbox's thread.
    /// Keyframes are bounded by a floor on QP: a 2x desktop keyframe at the encoder's default
    /// quality is ~160 KB (1.3 s at 1 Mbps); at QP ≥ 36 it is a fraction of that and the following
    /// P-frames restore detail within a few hundred ms.
    static let keyframeMinQP = Int(ProcessInfo.processInfo.environment["MIRAGE_KEYFRAME_MINQP"] ?? "") ?? 40
    private(set) var coarse = false
    /// Only a session's first IDR honours the floor; forced keyframes later ignore it (measured),
    /// which is why DesktopStreamer recreates the session for recovery.
    func setCoarse(_ on: Bool) {
        guard on != coarse else { return }
        coarse = on
        applyFloor()
    }
    /// A floor above the ceiling fails every frame with kVTParameterErr (-12902), and keyframe recovery rebuilds the session
    /// into the same floor: on a LAN budget (ceiling 30-36, since 548) video never started and tiles carried the picture.
    static func coarseMinQP(ceiling: Int) -> Int { min(keyframeMinQP, ceiling) }
    private func applyFloor() {
        set(kVTCompressionPropertyKey_MinAllowedFrameQP, (coarse ? Self.coarseMinQP(ceiling: ceilingQP) : 0) as CFNumber)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, captureNanos: UInt64, options: FrameOptions, completion: @escaping (Result<Encoded, Error>) -> Void) {
        var props: [CFString: Any] = [:]
        if firstFrame { setCoarse(true); firstFrame = false }
        if options.forceKeyframe { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue }
        if options.forceLTRRefresh { props[kVTEncodeFrameOptionKey_ForceLTRRefresh] = kCFBooleanTrue }
        if !options.acknowledgedLTRTokens.isEmpty { props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = options.acknowledgedLTRTokens as CFArray }
        let pts = CMTime(value: CMTimeValue(captureNanos), timescale: 1_000_000_000)
        // Queued property changes first (a sharpening frame needs its ceiling): wait briefly for the encoder to be idle.
        idle.lock()
        if !pendingKeys.isEmpty {
            let deadline = Date().addingTimeInterval(0.1)
            while inFlight > 0, idle.wait(until: deadline) {}
            if inFlight == 0 { applyPending() }
        }
        inFlight += 1
        idle.unlock()
        let t0 = Clock.nowNanos()
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: nil) { [weak self] status, flags, sb in
            guard let self else { return }
            self.frameLeft()
            if status != noErr { completion(.failure(MirageError.transport("encode failed: \(status)"))); return }
            if flags.contains(.frameDropped) { completion(.failure(MirageError.transport("encoder dropped frame"))); return }
            guard let sb else { completion(.failure(MirageError.transport("encoder produced nothing"))); return }
            do { completion(.success(try self.extract(sb, captureNanos: captureNanos, encodeNanos: Clock.elapsed(since: t0, now: Clock.nowNanos())))) }
            catch { completion(.failure(error)) }
        }
        if st != noErr { frameLeft(); completion(.failure(MirageError.transport("VTCompressionSessionEncodeFrame: \(st)"))) }
    }
    private func frameLeft() { idle.lock(); inFlight = max(0, inFlight - 1); idle.broadcast(); idle.unlock() }

    private func extract(_ sb: CMSampleBuffer, captureNanos: UInt64, encodeNanos: UInt64) throws -> Encoded {
        var keyframe = true
        var ltr: Int64?
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = arr.first {
            if let notSync = a[kCMSampleAttachmentKey_NotSync] as? Bool { keyframe = !notSync }
            if let tok = a[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber { ltr = tok.int64Value }
        }
        var sets: [Data] = []
        if let fd = CMSampleBufferGetFormatDescription(sb) {
            let changed = lastFormat.map { !CMFormatDescriptionEqual($0, otherFormatDescription: fd) } ?? true
            if keyframe || changed {
                var count = 0
                var hdr: Int32 = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &hdr)
                guard hdr == 4 else { throw MirageError.transport("unexpected NAL length size \(hdr)") }
                for i in 0..<count {
                    var p: UnsafePointer<UInt8>? = nil; var n = 0
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if let p { sets.append(Data(bytes: p, count: n)) }
                }
                lastFormat = fd
            }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { throw MirageError.transport("no data buffer") }
        let len = CMBlockBufferGetDataLength(bb)
        var sample = Data(count: len)
        let st = sample.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        guard st == noErr else { throw MirageError.transport("CMBlockBufferCopyDataBytes: \(st)") }
        return Encoded(keyframe: keyframe, parameterSets: sets, sample: sample, ltrToken: ltr, captureNanos: captureNanos, encodeNanos: encodeNanos)
    }
}

nonisolated(unsafe) var hostLog: @Sendable (String) -> Void = { print($0) }
