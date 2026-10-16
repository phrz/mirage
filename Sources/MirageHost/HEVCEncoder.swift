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
        set(kVTCompressionPropertyKey_MaxAllowedFrameQP, 51 as CFNumber)
        applyRate()
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { VTCompressionSessionInvalidate(session) }

    func setRate(bitrateKbps: Int, expectedFPS: Int) {
        self.bitrateKbps = bitrateKbps; self.expectedFPS = expectedFPS
        applyRate()
    }

    private func applyRate() {
        let bps = bitrateKbps * 1000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // Hard cap: one second's worth of bytes per second. Low-latency mode has no CBR, so this is the ceiling.
        let limits: [Any] = [bps / 8, 1.0]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: expectedFPS as CFNumber)
    }

    /// Encodes one frame; `completion` runs on VideoToolbox's thread.
    func encode(_ pixelBuffer: CVPixelBuffer, captureNanos: UInt64, options: FrameOptions, completion: @escaping (Result<Encoded, Error>) -> Void) {
        var props: [CFString: Any] = [:]
        if options.forceKeyframe { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue }
        if options.forceLTRRefresh { props[kVTEncodeFrameOptionKey_ForceLTRRefresh] = kCFBooleanTrue }
        if !options.acknowledgedLTRTokens.isEmpty { props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = options.acknowledgedLTRTokens as CFArray }
        let pts = CMTime(value: CMTimeValue(captureNanos), timescale: 1_000_000_000)
        let t0 = Clock.nowNanos()
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: nil) { [weak self] status, flags, sb in
            guard let self else { return }
            if status != noErr { completion(.failure(MirageError.transport("encode failed: \(status)"))); return }
            if flags.contains(.frameDropped) { completion(.failure(MirageError.transport("encoder dropped frame"))); return }
            guard let sb else { completion(.failure(MirageError.transport("encoder produced nothing"))); return }
            do { completion(.success(try self.extract(sb, captureNanos: captureNanos, encodeNanos: Clock.nowNanos() - t0))) }
            catch { completion(.failure(error)) }
        }
        if st != noErr { completion(.failure(MirageError.transport("VTCompressionSessionEncodeFrame: \(st)"))) }
    }

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
                precondition(hdr == 4, "unexpected NAL length size \(hdr)")
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
