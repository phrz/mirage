import XCTest
import CoreVideo
@testable import MirageHost

/// The mini's host, nightly 569 (2026-10-31): wholeDisplayOnly toggled the sharpening ceiling at every caret blink, and a
/// property set while a frame was in the hardware encoder deadlocked the session (the video queue in VTSessionSetProperty,
/// the encoder service waiting on the host for the frame's format description); every later stream start hung behind it.
final class EncoderPropertyTests: XCTestCase {
    func testSharpeningTogglesBetweenFramesNeverHangTheEncoder() throws {
        let w = 3200, h = 1800
        let enc = try HEVCEncoder(width: w, height: h, bitrateKbps: 45_000, expectedFPS: 30)
        var pbOut: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pbOut)
        let pb = try XCTUnwrap(pbOut)
        let q = DispatchQueue(label: "test.video")
        let done = expectation(description: "frames encoded")
        let frames = 600
        final class Count: @unchecked Sendable { let lock = NSLock(); var ok = 0, failed = 0 }
        let count = Count()
        q.async {
            var seed: UInt32 = 1
            for i in 0..<frames {
                // A changing square of noise, as a caret blink or a scroll changes part of the screen.
                CVPixelBufferLockBaseAddress(pb, [])
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self), row = CVPixelBufferGetBytesPerRow(pb) / 4
                let x0 = (i * 37) % (w - 256), y0 = (i * 23) % (h - 256)
                for y in y0..<(y0 + 256) { for x in x0..<(x0 + 256) { seed = seed &* 1_664_525 &+ 1_013_904_223; base[y * row + x] = seed | 0xFF00_0000 } }
                CVPixelBufferUnlockBaseAddress(pb, [])
                enc.encode(pb, captureNanos: UInt64(i + 1) * 33_000_000, options: .init()) { r in
                    count.lock.lock(); if case .success = r { count.ok += 1 } else { count.failed += 1 }; count.lock.unlock()
                }
                enc.setSharpening(i % 2 == 0)
                if i % 15 == 0 { enc.setRate(bitrateKbps: 30_000 + (i % 4) * 5_000, expectedFPS: 30) }
            }
            done.fulfill()
        }
        let result = XCTWaiter().wait(for: [done], timeout: 60)
        count.lock.lock(); defer { count.lock.unlock() }
        XCTAssertEqual(result, .completed, "the encoder hung after \(count.ok) of \(frames) frames")
        XCTAssertEqual(count.failed, 0)
    }
}
