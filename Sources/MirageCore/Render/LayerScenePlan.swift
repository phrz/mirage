import Foundation

/// Decides how each window of the (locally arranged) window list is drawn, separately from Metal so it
/// can be tested (DESIGN §3.2, layered desktop):
/// - a window the host captures as its own layer, whose canvas the viewer holds, is drawn from that canvas;
/// - a window the host says is safe to cut out (`WindowInfo.cutout`: menus, popovers, the dock, the menu
///   bar, normal app windows beyond the layer cap) is drawn as a rect of the display layer, but only where
///   it overlaps a window layer behind it: everywhere else the display layer already shows it, and a
///   misjudged window (a transparent full-screen overlay) can then never paint the display layer over the
///   windows (the M3.1 field regression: the bench vanished behind such a cut-out);
/// - anything else is left to the display layer (drawn first, under all layers).
public struct LayerScenePlan: Equatable {
    public enum Kind: String, Codable, Equatable { case layer, cutout, displayOnly = "display", missing }
    public struct Entry: Equatable {
        public var id: UInt32
        public var kind: Kind
        public var frame: PixelRect
        public var level: Int
        /// Cut-outs: the parts of the frame that overlap a window layer behind it.
        public var clips: [PixelRect]
        /// Windows drawn in front of this one that overlap it.
        public var coveredBy: [UInt32]
        /// Whether any part of it is drawn from pixels that contain it.
        public var visible: Bool
        public var why: String?
    }
    public var entries: [Entry]   // front to back

    /// `windows` front to back (index 0 frontmost), frames in display-layer pixels. `shadowMargin`: how far a
    /// layer's shadow reaches beyond its frame (a cut-out in front must cover that too, or the shadow of a
    /// window behind it would darken the part of the menu the display layer draws).
    public static func plan(_ windows: [ControlMessage.WindowInfo], hasCanvas: (UInt32) -> Bool, display: PixelRect, shadowMargin: Int = 0) -> LayerScenePlan {
        var entries: [Entry] = []
        // Kinds first.
        for w in windows {
            let kind: Kind
            if w.isLayered { kind = hasCanvas(w.id) ? .layer : .missing }
            else if w.cutout ?? false, !(w.windowLevel != 0 && w.frame.intersection(display).area * 10 >= display.area * 9) { kind = .cutout }
            else { kind = .displayOnly }
            entries.append(Entry(id: w.id, kind: kind, frame: w.frame, level: w.windowLevel, clips: [], coveredBy: [], visible: false, why: nil))
        }
        // Cut-out clips: overlap with layers behind.
        for i in entries.indices where entries[i].kind == .cutout {
            var clips: [PixelRect] = []
            for j in entries.indices where j > i && entries[j].kind == .layer {
                let f = entries[j].frame, m = shadowMargin
                let reach = PixelRect(x: f.x - m, y: f.y - m, width: f.width + 2 * m, height: f.height + 2 * m + m / 3)
                let c = entries[i].frame.intersection(reach).intersection(display)
                if !c.isEmpty { clips.append(c) }
            }
            entries[i].clips = clips
        }
        // Visibility: what is drawn over each entry (layers and the clipped parts of cut-outs in front).
        for i in entries.indices {
            let e = entries[i]
            let onScreen = e.frame.intersection(display)
            var front: [PixelRect] = []
            var ids: [UInt32] = []
            for j in 0..<i {
                let f = entries[j]
                let rects: [PixelRect] = f.kind == .layer ? [f.frame] : f.kind == .cutout ? f.clips : []
                let hits = rects.map { $0.intersection(onScreen) }.filter { !$0.isEmpty }
                if !hits.isEmpty { front += hits; ids.append(f.id) }
            }
            entries[i].coveredBy = ids
            switch e.kind {
            case .missing: entries[i].why = "host captures it as a layer but the viewer holds no canvas for it"
            case .displayOnly where e.level == 0 && !(windows[i].cutout ?? false): entries[i].why = nil
            default: break
            }
            guard !onScreen.isEmpty else { entries[i].why = entries[i].why ?? "off the display"; continue }
            if e.kind == .missing { continue }
            var uncovered = false
            outer: for gy in 0..<12 { for gx in 0..<12 {
                let px = onScreen.x + onScreen.width * (2 * gx + 1) / 24, py = onScreen.y + onScreen.height * (2 * gy + 1) / 24
                if !front.contains(where: { $0.contains(px, py) }) { uncovered = true; break outer }
            } }
            entries[i].visible = uncovered
            if !uncovered { entries[i].why = "covered by \(ids)" }
        }
        return LayerScenePlan(entries: entries)
    }

    /// Scene items (front to back) for the renderer.
    public func sceneItems(pxPerPoint ppp: Float, canvas: (UInt32) -> Compositor?) -> [LayerScene.Item] {
        var items: [LayerScene.Item] = []
        var keyFound = false
        for e in entries {
            switch e.kind {
            case .layer:
                guard let c = canvas(e.id) else { continue }
                let isKey = e.level == 0 && !keyFound
                if e.level == 0 { keyFound = true }
                items.append(.layer(c, frame: e.frame, shadow: isKey ? .key(pxPerPoint: ppp) : .inactive(pxPerPoint: ppp), dim: 1))
            case .cutout:
                guard !e.clips.isEmpty else { continue }
                // Menus and popovers get a menu shadow, overflow normal windows an inactive one; the dock (20) and menu bar (24, 25) none.
                let shadow: LayerScene.Shadow? = e.level == 0 ? .inactive(pxPerPoint: ppp) : (e.level == 20 || e.level == 24 || e.level == 25) ? nil : .menu(pxPerPoint: ppp)
                items.append(.cutout(e.frame, shadow: shadow, clips: e.clips))
            case .displayOnly, .missing:
                continue
            }
        }
        return items
    }
}
