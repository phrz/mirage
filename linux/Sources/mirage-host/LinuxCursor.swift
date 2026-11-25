import Foundation
import MirageCore
import CMirageDesktop

/// The host's pointer for viewers that draw it themselves (as they do a Mac host's): its image when that changes, and its
/// position as it moves, so the pointer under the person's hand never waits for a video frame.
///
/// The kernel's cursor plane has the image and its top-left on the screen, but not the hotspot (the pixel that points).
/// (A virtual GPU says it; others don't.) It is learned from the pointer this host moves itself: a moment after a viewer's move, the pointer sits where the move
/// put it, so the hotspot is that spot less the image's top-left. Each image keeps its own; an image not yet seen borrows
/// the last one learned until the next move.
final class CursorRelay {
    private let source: DesktopSource
    private let picture: OpaquePointer
    private let pointer: UInputBackend?
    private var hotspots: [UInt64: (Int, Int)] = [:]
    private var lastHotspot = (0, 0)
    private var image: (bgra: [UInt8], width: Int, height: Int, serial: UInt64, digest: UInt64)?
    private var imageSince: UInt64 = 0
    private var learned: (move: UInt64, serial: UInt64) = (.max, .max)
    private var sentHotspot: (Int, Int)? = nil
    private var sentPosition: ControlMessage.CursorPosition? = nil

    init(source: DesktopSource, lease: DesktopLease) {
        self.source = source; picture = lease.picture; pointer = lease.input as? UInputBackend
    }

    /// One look: the messages to send now (a shape, a position), if any.
    func poll() -> [ControlMessage] {
        var out: [ControlMessage] = []
        var pw: Int32 = 0, ph: Int32 = 0
        md_picture_size(picture, &pw, &ph)
        guard pw > 1, ph > 1 else { return out }
        let now = Clock.nowNanos()
        guard let c = source.cursor() else {
            if let p = sentPosition, p.visible {
                let hidden = ControlMessage.CursorPosition(x: p.x, y: p.y, visible: false)
                sentPosition = hidden; out.append(.cursorPosition(hidden))
            }
            return out
        }
        var newImage = false
        if c.serial != image?.serial, let img = source.cursorImage() {
            image = (img.bgra, img.width, img.height, img.serial, Self.digest(img.bgra)); imageSince = now; newImage = true
        }
        guard let image else { return out }
        if let mv = pointer?.lastMove, Clock.elapsed(since: mv.nanos, now: now) > 40_000_000, Clock.elapsed(since: mv.nanos, now: now) < 3_000_000_000,
           Clock.elapsed(since: imageSince, now: now) > 40_000_000, learned != (mv.seq, image.serial) {
            learned = (mv.seq, image.serial)
            let hx = Int(mv.x * Double(pw)) - c.x, hy = Int(mv.y * Double(ph)) - c.y
            // Within a pixel of what is known is the desktop's rounding of the move, not a new hotspot.
            if (0..<image.width).contains(hx), (0..<image.height).contains(hy),
               hotspots[image.digest].map({ abs($0.0 - hx) > 1 || abs($0.1 - hy) > 1 }) ?? true {
                hotspots[image.digest] = (hx, hy); lastHotspot = (hx, hy)
            }
        }
        let hot = c.hotspot ?? hotspots[image.digest] ?? lastHotspot
        if newImage || sentHotspot.map({ $0 != hot }) ?? true, let shape = Self.shape(image.bgra, width: image.width, height: image.height, hotspot: hot) {
            out.append(.cursorShape(shape)); sentHotspot = hot
        }
        let pos = ControlMessage.CursorPosition(x: Double(c.x + hot.0) / Double(pw), y: Double(c.y + hot.1) / Double(ph), visible: true)
        if pos != sentPosition { out.append(.cursorPosition(pos)); sentPosition = pos }
        return out
    }

    private static func digest(_ b: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for x in b { h = (h ^ UInt64(x)) &* 0x100_0000_01b3 }
        return h
    }

    /// The image cut to its visible pixels, as PNG (straight alpha), with the hotspot from the cut's top-left.
    static func shape(_ bgra: [UInt8], width: Int, height: Int, hotspot: (Int, Int), scale: Double = 1) -> ControlMessage.CursorShape? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where bgra[(y * width + x) * 4 + 3] != 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let s = ((y + minY) * width + x + minX) * 4, d = (y * w + x) * 4
            let a = Int(bgra[s + 3])
            guard a > 0 else { continue }
            // Premultiplied to straight.
            rgba[d] = UInt8(min(255, Int(bgra[s + 2]) * 255 / a)); rgba[d + 1] = UInt8(min(255, Int(bgra[s + 1]) * 255 / a))
            rgba[d + 2] = UInt8(min(255, Int(bgra[s]) * 255 / a)); rgba[d + 3] = UInt8(a)
        } }
        return .init(png: PNG.encode(rgba: rgba, width: w, height: h), width: Double(w) / scale, height: Double(h) / scale,
                     hotspotX: Double(hotspot.0 - minX) / scale, hotspotY: Double(hotspot.1 - minY) / scale)
    }
}

/// The pointer of the virtual monitor, which comes with the frames apart from
/// the picture: image, hotspot and position, in the picture's pixels.
final class CastCursorRelay {
    private let lease: DesktopLease
    private var sent: (serial: UInt64, scale: Double)?
    private var sentPosition: ControlMessage.CursorPosition?

    init(lease: DesktopLease) { self.lease = lease }

    func poll() -> [ControlMessage] {
        var out: [ControlMessage] = []
        var x: Int32 = 0, y: Int32 = 0, serial: UInt64 = 0, pw: Int32 = 0, ph: Int32 = 0
        let state = md_picture_cursor(lease.picture, &x, &y, &serial)
        md_picture_size(lease.picture, &pw, &ph)
        guard state != 0, pw > 1, ph > 1, let scale = lease.scale else { return out }
        if serial != 0, sent.map({ $0 != (serial, scale) }) ?? true {
            var buf = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
            var w: Int32 = 0, h: Int32 = 0, hx: Int32 = 0, hy: Int32 = 0
            if md_picture_cursor_image(lease.picture, &buf, buf.count, &w, &h, &hx, &hy, &serial) == 0 {
                out.append(.cursorShape(CursorRelay.shape(buf, width: Int(w), height: Int(h), hotspot: (Int(hx), Int(hy)), scale: scale) ?? Self.invisible))
                sent = (serial, scale)
            }
        }
        let pos = ControlMessage.CursorPosition(x: Double(x) / Double(pw), y: Double(y) / Double(ph), visible: state == 1)
        if pos != sentPosition { out.append(.cursorPosition(pos)); sentPosition = pos }
        return out
    }

    /// An application hid the pointer, or the picture has it: viewers draw the last image sent, so one with nothing in it.
    static let invisible = ControlMessage.CursorShape(png: PNG.encode(rgba: [0, 0, 0, 0], width: 1, height: 1), width: 1, height: 1,
                                                              hotspotX: 0, hotspotY: 0)
}

/// A minimal PNG writer (8-bit RGBA, stored deflate blocks): cursor images are a few kilobytes.
enum PNG {
    static func encode(rgba: [UInt8], width: Int, height: Int) -> Data {
        var raw = [UInt8](); raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height { raw.append(0); raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)]) }
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, raw.count - i)
            let last: UInt8 = i + n == raw.count ? 1 : 0
            z += [last, UInt8(n & 0xff), UInt8(n >> 8), UInt8(~n & 0xff), UInt8((~n >> 8) & 0xff)]
            z += raw[i..<(i + n)]
            i += n
        } while i < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for x in raw { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        z += be(b << 16 | a)
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", be(UInt32(width)) + be(UInt32(height)) + [8, 6, 0, 0, 0])
        png += chunk("IDAT", z)
        png += chunk("IEND", [])
        return Data(png)
    }

    private static func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let tb = Array(type.utf8) + body
        return be(UInt32(body.count)) + tb + be(crc(tb))
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in b { c = table[Int((c ^ UInt32(x)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
