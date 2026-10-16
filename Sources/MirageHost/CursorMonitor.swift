import Foundation
import AppKit
import CryptoKit
import MirageCore

/// Polls the system cursor; reports shape changes (as PNG + hotspot) and position changes.
final class CursorMonitor {
    private var timer: DispatchSourceTimer?
    private var lastShapeHash: Data?
    private var lastCursor: NSCursor?
    private var lastPos: CGPoint = .zero
    private var displayBounds: CGRect
    var onShape: ((ControlMessage.CursorShape) -> Void)?
    var onPosition: ((ControlMessage.CursorPosition) -> Void)?

    init(displayID: CGDirectDisplayID) { displayBounds = CGDisplayBounds(displayID) }
    func setDisplay(_ id: CGDirectDisplayID) { displayBounds = CGDisplayBounds(id) }

    func start(on queue: DispatchQueue, hz: Int = 20) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / hz))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }
    func stop() { timer?.cancel(); timer = nil }

    /// Re-sends the current shape (new viewer).
    func resend() { lastShapeHash = nil; lastCursor = nil; poll() }

    private func poll() {
        // AppKit hands back the same NSCursor object while the shape is unchanged; only encode on a new one.
        if let cursor = NSCursor.currentSystem, cursor !== lastCursor {
            lastCursor = cursor
            let image = cursor.image
            if let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
               let cg = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let bitmap = NSBitmapImageRep(cgImage: cg)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let hash = Data(SHA256.hash(data: png))
                    if hash != lastShapeHash {
                        lastShapeHash = hash
                        onShape?(.init(png: png, width: image.size.width, height: image.size.height, hotspotX: cursor.hotSpot.x, hotspotY: cursor.hotSpot.y))
                    }
                }
            }
        }
        if let loc = CGEvent(source: nil)?.location, loc != lastPos {
            lastPos = loc
            let x = (loc.x - displayBounds.origin.x) / displayBounds.width
            let y = (loc.y - displayBounds.origin.y) / displayBounds.height
            onPosition?(.init(x: x, y: y, visible: (0...1).contains(x) && (0...1).contains(y)))
        }
    }
}
