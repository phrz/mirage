import Foundation
import CoreGraphics
import QuartzCore
import MirageCore

/// One display-link tick of the picture, the same on the Mac (`VideoNSView`) and iOS (`DesktopUIView`): the session's
/// scene (the display layer, every window layer back to front, the overlay layer on top), drawn into the view's
/// CAMetalLayer when anything in it changed, with the display layer at `videoRect` (view points; the views differ only in
/// where they put the picture: the Mac letterboxes it, iOS zooms and pans it).
final class ScenePresenter {
    private var lastDisplacementCount = 0
    private var lastArrangement = -1
    /// Draw at the next tick even if the scene looks unchanged (the session's canvases changed, the view moved the picture).
    var forceRedraw = false
    /// Frames presented (stats and tests).
    private(set) var presented = 0

    /// Draws the scene if it changed since the last tick; returns whether it did.
    @discardableResult
    func tick(_ session: ViewerSession, layer: CAMetalLayer, videoRect r: CGRect) -> Bool {
        guard let comp = session.compositor, comp.width > 0, let context = session.context else { return false }
        let ppp = MainActor.assumeIsolated { session.pixelsPerPoint }
        guard let scene = session.scene(pxPerPoint: ppp) else { return false }
        let arrangement = session.arrangementGeneration
        var layersDirty = false
        for it in scene.items { if case .layer(let c, _, _, _) = it, c.needsRender { layersDirty = true; break } }
        let changed = comp.needsRender || layersDirty || !scene.displacements.isEmpty || lastDisplacementCount != scene.displacements.count
            || arrangement != lastArrangement || session.hasPendingPredictions || forceRedraw
        lastDisplacementCount = scene.displacements.count; lastArrangement = arrangement; forceRedraw = false
        guard changed, let drawable = layer.nextDrawable() else { return false }
        let scale = layer.contentsScale
        let dest = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        session.lastDest = dest
        SceneRenderer.render(scene, context: context, to: drawable, dest: dest)
        presented += 1
        return true
    }
}
