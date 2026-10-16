import Foundation
import CoreMedia
import VideoToolbox

/// Synchronous HEVC decoder around VTDecompressionSession. Platform-neutral (macOS + iOS).
/// Not thread-safe; call from one queue.
public final class HEVCDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var lastParameterSets: [Data] = []
    public private(set) var width = 0, height = 0

    public init() {}
    deinit { if let s = session { VTDecompressionSessionInvalidate(s) } }

    public enum DecodeError: Error, CustomStringConvertible {
        case noFormat, status(OSStatus, String)
        public var description: String {
            switch self {
            case .noFormat: return "no parameter sets seen yet"
            case .status(let s, let what): return "\(what) failed: \(s)"
            }
        }
    }

    /// Decodes one frame; returns the image buffer. Throws if the decoder has no format yet
    /// (i.e. no keyframe with parameter sets has arrived) or decoding failed.
    public func decode(_ frame: VideoFrame) throws -> CVImageBuffer {
        if !frame.parameterSets.isEmpty, frame.parameterSets != lastParameterSets {
            try updateFormat(frame.parameterSets)
        }
        guard let format, let session else { throw DecodeError.noFormat }

        var blockBuffer: CMBlockBuffer?
        let sample = frame.sample
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count, blockAllocator: kCFAllocatorDefault,
                                                    customBlockSource: nil, offsetToData: 0, dataLength: sample.count, flags: 0, blockBufferOut: &blockBuffer)
        guard st == noErr, let bb = blockBuffer else { throw DecodeError.status(st, "CMBlockBufferCreate") }
        st = sample.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: sample.count) }
        guard st == noErr else { throw DecodeError.status(st, "CMBlockBufferReplaceDataBytes") }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(frame.captureNanos), timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sampleSize = sample.count
        var sbuf: CMSampleBuffer?
        st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format, sampleCount: 1,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sbuf)
        guard st == noErr, let sb = sbuf else { throw DecodeError.status(st, "CMSampleBufferCreateReady") }

        var out: CVImageBuffer?
        var outStatus: OSStatus = noErr
        st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            outStatus = status; out = image
        }
        guard st == noErr else { throw DecodeError.status(st, "VTDecompressionSessionDecodeFrame") }
        guard outStatus == noErr, let image = out else { throw DecodeError.status(outStatus, "decode callback") }
        return image
    }

    private func updateFormat(_ sets: [Data]) throws {
        var fd: CMVideoFormatDescription?
        let st: OSStatus = withParameterSetPointers(sets) { ptrs, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                                                                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        }
        guard st == noErr, let fd else { throw DecodeError.status(st, "CMVideoFormatDescriptionCreateFromHEVCParameterSets") }
        lastParameterSets = sets
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        width = Int(dims.width); height = Int(dims.height)
        if let s = session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fd) {
            format = fd; return
        }
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        var s: VTDecompressionSession?
        let cst = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
                                               imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard cst == noErr, let s else { throw DecodeError.status(cst, "VTDecompressionSessionCreate") }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s; format = fd
    }
}

/// Calls `body` with C arrays of pointers/sizes for the given parameter sets.
func withParameterSetPointers<R>(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
    // Copy into one contiguous buffer so pointers stay valid for the call.
    let total = sets.reduce(0) { $0 + $1.count }
    var storage = [UInt8](repeating: 0, count: max(total, 1))
    var offsets: [Int] = []
    var o = 0
    for s in sets { offsets.append(o); storage.replaceSubrange(o..<o + s.count, with: s); o += s.count }
    let sizes = sets.map { $0.count }
    return storage.withUnsafeBufferPointer { buf in
        let base = buf.baseAddress!
        let ptrs = offsets.map { UnsafePointer<UInt8>(base + $0) }
        return ptrs.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) }
        }
    }
}
