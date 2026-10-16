import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation

// Capture the main display at 1x for ~12 s; for each delivered frame compare SCK's dirtyRects
// area with the actual changed-pixel bounding box (CPU diff vs previous frame).
final class Out: NSObject, SCStreamOutput {
    var prev: [UInt8]? ; var w = 0, h = 0
    var frames = 0, dirtyArea = 0, actualArea = 0, zeroDirty = 0, missed = 0, tilesDirty = 0, tilesActual = 0
    let t0 = Date()
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let info = atts?.first, let statusRaw = info[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw), status == .complete else { return }
        let dirty = (info[.dirtyRects] as? [[String: CGFloat]])?.compactMap { d -> CGRect? in
            guard let x = d["X"], let y = d["Y"], let w = d["Width"], let h = d["Height"] else { return nil }; return CGRect(x: x, y: y, width: w, height: h) } ?? []
        let scale = (info[.scaleFactor] as? CGFloat) ?? 1
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var cur = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { memcpy(&cur[y * w * 4], p + y * stride, w * 4) }
        if let prev {
            frames += 1
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            var dirtyTiles = Set<Int>(), actualTiles = Set<Int>()
            cur.withUnsafeBufferPointer { c in prev.withUnsafeBufferPointer { q in
                for y in 0..<h { for x in 0..<w { let i = (y * w + x) * 4
                    if c[i] != q[i] || c[i+1] != q[i+1] || c[i+2] != q[i+2] { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); actualTiles.insert((y / 64) * 1000 + x / 64) } } } } }
            let actual = maxX >= 0 ? (maxX - minX + 1) * (maxY - minY + 1) : 0
            var dArea = 0
            for r in dirty { let rr = r; dArea += Int(rr.width * rr.height)
                var ty = Int(rr.minY) / 64; while ty <= Int(rr.maxY - 1) / 64 { var tx = Int(rr.minX) / 64; while tx <= Int(rr.maxX - 1) / 64 { dirtyTiles.insert(ty * 1000 + tx); tx += 1 }; ty += 1 } }
            dirtyArea += dArea; actualArea += actual
            tilesDirty += dirtyTiles.count; tilesActual += actualTiles.count
            if dirty.isEmpty && actual > 0 { zeroDirty += 1 }
            if !actualTiles.isSubset(of: dirtyTiles) { missed += 1 }
            if frames < 0 { print("   raw dirtyRects (points?):", dirty.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }.joined(separator: "  "), " scale=\(scale)  actual bbox x:\(minX)-\(maxX) y:\(minY)-\(maxY)") }
            if frames < 0 { print(String(format: "frame %3d  dirtyRects=%d area=%7d px (%d tiles)   actual bbox=%7d px (%d tiles)   subset=%@", frames, dirty.count, dArea, dirtyTiles.count, actual, actualTiles.count, actualTiles.isSubset(of: dirtyTiles) ? "yes" : "NO")) }
        }
        prev = cur
    }
}
let sem = DispatchSemaphore(value: 0)
var content: SCShareableContent?
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in content = c; sem.signal() }
sem.wait()
let display = content!.displays[0]
let filter = SCContentFilter(display: display, excludingWindows: [])
let cfg = SCStreamConfiguration()
cfg.width = display.width; cfg.height = display.height   // 1x
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
cfg.showsCursor = false
cfg.pixelFormat = kCVPixelFormatType_32BGRA
cfg.queueDepth = 5
let out = Out()
let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
try! stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
stream.startCapture { e in if let e { print("start error", e) } }
Thread.sleep(forTimeInterval: 12)
stream.stopCapture { _ in }
print("\nframes with a predecessor: \(out.frames) in 12 s (\(out.w)x\(out.h)); frames where SCK said nothing dirty but pixels changed: \(out.zeroDirty); frames where changed tiles were NOT covered by dirtyRects: \(out.missed)")
print("tiles flagged dirty by SCK: \(out.tilesDirty)   tiles actually changed: \(out.tilesActual)   → SCK over-reports by \(out.tilesActual > 0 ? String(format: "%.1fx", Double(out.tilesDirty) / Double(out.tilesActual)) : "n/a")")
