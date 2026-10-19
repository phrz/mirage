import Foundation
// Copied from Sources/MirageCore/Wire/Tiles.swift (the rest of that file is wire format this harness does not need).
/// A rect in native stream pixels (the size in `StreamInfo`), top-left origin.
public struct PixelRect: Equatable, Hashable, Sendable, Codable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public func contains(_ px: Int, _ py: Int) -> Bool { px >= x && py >= y && px < maxX && py < maxY }
    public func intersection(_ o: PixelRect) -> PixelRect {
        let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .zero
    }
    public func union(_ o: PixelRect) -> PixelRect {
        if isEmpty { return o }; if o.isEmpty { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y), x1 = max(maxX, o.maxX), y1 = max(maxY, o.maxY)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    public func intersects(_ o: PixelRect) -> Bool { !intersection(o).isEmpty }
    public func offset(_ dx: Int, _ dy: Int) -> PixelRect { PixelRect(x: x + dx, y: y + dy, width: width, height: height) }
    public var area: Int { max(0, width) * max(0, height) }
    /// This rect minus `o`: up to four disjoint rects (top band, bottom band, left and right of the overlap).
    public func subtracting(_ o: PixelRect) -> [PixelRect] {
        let i = intersection(o)
        guard !i.isEmpty else { return isEmpty ? [] : [self] }
        var out: [PixelRect] = []
        if i.y > y { out.append(PixelRect(x: x, y: y, width: width, height: i.y - y)) }
        if i.maxY < maxY { out.append(PixelRect(x: x, y: i.maxY, width: width, height: maxY - i.maxY)) }
        if i.x > x { out.append(PixelRect(x: x, y: i.y, width: i.x - x, height: i.height)) }
        if i.maxX < maxX { out.append(PixelRect(x: i.maxX, y: i.y, width: maxX - i.maxX, height: i.height)) }
        return out
    }
    /// This rect minus every rect in `others`.
    public func subtracting(_ others: [PixelRect]) -> [PixelRect] {
        others.reduce([self]) { pieces, o in pieces.flatMap { $0.subtracting(o) } }
    }
}
