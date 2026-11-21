import Foundation
import MirageCore
import CMirageDesktop

/// Where the picture comes from and where input goes.
protocol DesktopSource: AnyObject, Sendable {
    /// The current desktop (counted as used until `release`), waiting up to `timeout` for one.
    func acquire(timeout: TimeInterval) -> DesktopLease?
    func release(_ lease: DesktopLease)
    /// Why there is no desktop right now (said to the viewer).
    var unavailableReason: String? { get }
    /// What the log calls it ("the screen", "GNOME's screen").
    var name: String { get }
    /// The pointer apart from the picture: its image's top-left on the screen (pixels) and the image's serial; nil while
    /// it does not show, and always for a source that draws it into the picture.
    func cursor() -> (x: Int, y: Int, hotspot: (Int, Int)?, serial: UInt64)?
    /// The pointer's image (premultiplied B, G, R, A).
    func cursorImage() -> (bgra: [UInt8], width: Int, height: Int, serial: UInt64)?
}

extension DesktopSource {
    func cursor() -> (x: Int, y: Int, hotspot: (Int, Int)?, serial: UInt64)? { nil }
    func cursorImage() -> (bgra: [UInt8], width: Int, height: Int, serial: UInt64)? { nil }
}

/// One use of a source's desktop: its picture (CMirageDesktop's md_picture) and its input.
final class DesktopLease: @unchecked Sendable {
    let picture: OpaquePointer
    let input: InputBackend
    /// The source's own handle (GNOME's session), for its release.
    let token: OpaquePointer?
    init(picture: OpaquePointer, input: InputBackend, token: OpaquePointer?) { self.picture = picture; self.input = input; self.token = token }
    var ended: Bool { md_picture_ended(picture) != 0 }
}

/// The kernel's display and virtual input devices: the host runs as root from boot (the system service), and the viewer
/// sees and drives whatever is on the screen: GDM's login screen, the lock screen, any desktop, a text console.
final class KMSDesktop: DesktopSource, @unchecked Sendable {
    let name = "the screen"
    private let capture: OpaquePointer
    private let lease: DesktopLease

    /// Starts reading the display and creates the input devices; throws when either is impossible (not root, no uinput).
    init(log: @escaping @Sendable (String) -> Void) throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let c = mk_capture_open(&err, err.count) else { throw MirageError.transport(String(cString: err)) }
        guard let u = mu_input_open(&err, err.count) else { throw MirageError.transport(String(cString: err)) }
        capture = c
        lease = DesktopLease(picture: mk_capture_picture(c), input: UInputBackend(u), token: nil)
        // Say once when the display is first seen, and what is wrong while it is not.
        Thread.detachNewThread { [capture, lease] in
            var said = ""
            while true {
                var w: Int32 = 0, h: Int32 = 0
                md_picture_size(lease.picture, &w, &h)
                var buf = [CChar](repeating: 0, count: 256)
                mk_capture_status(capture, &buf, buf.count)
                let status = String(cString: buf)
                let line = !status.isEmpty ? "display: \(status)" : w > 0 ? "display: \(w)x\(h)" : ""
                if !line.isEmpty, line != said { log(line); said = line }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    func acquire(timeout: TimeInterval) -> DesktopLease? {
        let start = Date(), deadline = start.addingTimeInterval(timeout)
        var lastTap: Date? = nil
        while true {
            var w: Int32 = 0, h: Int32 = 0
            md_picture_size(lease.picture, &w, &h)
            var buf = [CChar](repeating: 0, count: 256)
            mk_capture_status(capture, &buf, buf.count)
            if w > 1, h > 1, buf[0] == 0 { return lease }
            if Date() >= deadline { return nil }
            // A blanked screen has nothing to read: a Shift tap wakes it (and types nothing, at the lock screen too). Again
            // every 1.5 s: a virtual keyboard created a moment ago is not yet one the compositor listens to.
            if Date().timeIntervalSince(start) >= 0.3, lastTap.map({ Date().timeIntervalSince($0) >= 1.5 }) ?? true {
                lastTap = Date(); lease.input.key(42, true); lease.input.key(42, false)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func release(_ lease: DesktopLease) {}

    func cursor() -> (x: Int, y: Int, hotspot: (Int, Int)?, serial: UInt64)? {
        var x: Int32 = 0, y: Int32 = 0, hx: Int32 = -1, hy: Int32 = -1, serial: UInt64 = 0
        guard mk_cursor_state(capture, &x, &y, &hx, &hy, &serial) != 0 else { return nil }
        return (Int(x), Int(y), hx >= 0 && hy >= 0 ? (Int(hx), Int(hy)) : nil, serial)
    }

    func cursorImage() -> (bgra: [UInt8], width: Int, height: Int, serial: UInt64)? {
        var buf = [UInt8](repeating: 0, count: 256 * 256 * 4)
        var w: Int32 = 0, h: Int32 = 0, serial: UInt64 = 0
        guard mk_cursor_image(capture, &buf, buf.count, &w, &h, &serial) == 0 else { return nil }
        return (Array(buf[0..<Int(w * h * 4)]), Int(w), Int(h), serial)
    }

    var unavailableReason: String? {
        var buf = [CChar](repeating: 0, count: 256)
        mk_capture_status(capture, &buf, buf.count)
        let s = String(cString: buf)
        return s.isEmpty ? "the display has shown no picture yet" : s
    }
}
