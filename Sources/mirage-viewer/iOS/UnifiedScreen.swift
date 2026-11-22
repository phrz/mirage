import SwiftUI
import UIKit
import Metal
import UniformTypeIdentifiers
import MirageCore

/// Unified mode on a phone or tablet (DESIGN §3.11): a strip of the host's windows along the top, one window filling the
/// rest of the screen (two side by side on a large screen, dragged there from the strip and divided like split apps).
/// Only the windows in panes stream; the strip shows stills. Each window in a pane is fitted to it on the host for as long
/// as it is shown (`WindowCommand.temporary`), and put back afterwards.
@MainActor
final class MobileUnified: ObservableObject {
    struct Card: Identifiable, Equatable {
        let id: UInt32
        var title: String
        var app: String
        var image: CGImage?
        static func == (a: Card, b: Card) -> Bool { a.id == b.id && a.title == b.title && a.app == b.app && a.image === b.image }
    }
    let session: ViewerSession
    @Published private(set) var cards: [Card] = []
    /// Windows shown, left to right (one, or two in a split).
    @Published private(set) var panes: [UInt32] = []
    /// The pane last touched: the strip's choice goes there, keys go there.
    @Published var focused = 0
    /// The first pane's share of the width in a split.
    @Published var split: CGFloat = 0.5
    /// Pane sizes in points, as laid out (the host fits each window to its pane).
    private var paneSizes: [CGSize] = []
    private var order: [UInt32] = []
    private var fitted: [UInt32: PixelRect] = [:]
    private var raised: UInt32 = 0
    private var timer: Timer?
    private var lastThumbs: UInt64 = 0
    private var thumbGeneration: [UInt32: Int] = [:]
    private(set) var active = false
    private var splitHookDone = false
    private var lastDebug: UInt64 = 0
    static let debug = UserDefaults.standard.bool(forKey: "unifiedDebug")

    init(session: ViewerSession) { self.session = session }

    func start() {
        guard !active else { return }
        active = true
        session.log("unified (mobile): on")
        // Panes come with the host's windows, which come with a stream: ask for one now (a connect may start here).
        session.requestStream(width: StreamScale.nativeRequest.0, height: StreamScale.nativeRequest.1)
        refresh()
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        for id in fitted.keys { session.sendWindowCommand(.init(id: id, action: .restore, temporary: true)) }
        fitted = [:]
        session.setViewInterest(.init(unified: false))
        session.log("unified (mobile): off")
    }

    /// The host's windows this mode offers: normal, layered, not a sheet or panel of another.
    private func candidates() -> [ControlMessage.WindowInfo] {
        guard let bg = session.compositor, bg.width > 0 else { return [] }
        let arranged = session.hostOrder()
        let layout = UnifiedLayout.plan(arranged, hasCanvas: { _ in true }, display: PixelRect(x: 0, y: 0, width: bg.width, height: bg.height))
        let tops = Set(layout.entries.filter { $0.role == .window && $0.parent == nil && $0.level == 0 }.map(\.id))
        return arranged.filter { tops.contains($0.id) && $0.frame.width >= 64 && $0.frame.height >= 64 }
    }

    func refresh() {
        guard active else { return }
        let list = candidates()
        guard !list.isEmpty || !cards.isEmpty else { session.setViewInterest(.init(unified: true, displayRects: [], hiddenLayers: [], stillLayers: [])); return }
        let ids = Set(list.map(\.id))
        let listed = Set(session.hostOrder().map(\.id))
        // A stable strip: windows keep their place; a new one comes in at the front (where the host just opened it).
        order.removeAll { !ids.contains($0) && !(listed.contains($0) && panes.contains($0)) }
        for w in list.reversed() where !order.contains(w.id) { order.insert(w.id, at: 0) }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next = order.compactMap { id -> Card? in
            guard let w = byID[id] else { return nil }
            return Card(id: id, title: w.title, app: w.app ?? "", image: cards.first { $0.id == id }?.image)
        }
        // Panes: a window that went away leaves its pane; none left shows the host's frontmost window. Gone means not listed
        // at all: while the host resizes a window it may briefly not be a candidate (not layered yet, or mid-change), and
        // dropping it then undid a split for good.
        var p = panes.filter { listed.contains($0) }
        if p.isEmpty, let front = list.first?.id { p = [front] }
        if p != panes { panes = p; focused = min(focused, max(0, p.count - 1)) }
        if Clock.elapsed(since: lastThumbs, now: Clock.nowNanos()) > 1_000_000_000 { lastThumbs = Clock.nowNanos(); updateThumbnails(&next) }
        if next != cards { cards = next }
        if Self.debug, Clock.elapsed(since: lastDebug, now: Clock.nowNanos()) > 2_000_000_000 { lastDebug = Clock.nowNanos(); NSLog("mirage-unified: windows %@ panes %@ sizes %@ hook %@ %@", "\(order)", "\(panes)", "\(paneSizes)", "\(splitHookDone)", "\(UserDefaults.standard.bool(forKey: "unifiedSplit"))") }
        // Test hook: `-unifiedSplit 1` puts the strip's second window beside the first once both are known.
        if !splitHookDone, UserDefaults.standard.bool(forKey: "unifiedSplit"), panes.count == 1, let other = order.first(where: { $0 != panes[0] }) {
            splitHookDone = true; panes = [panes[0], other]; split = 0.5
        }
        // Fit the shown windows to their panes, side by side on the host (so clicks in either land in it); put the others back.
        applyFits(byID)
        for id in fitted.keys where !panes.contains(id) {
            session.sendWindowCommand(.init(id: id, action: .restore, temporary: true)); fitted[id] = nil
        }
        session.setViewInterest(.init(unified: true, displayRects: [], hiddenLayers: [], stillLayers: order.filter { !panes.contains($0) }))
    }

    /// The layout's pane sizes changed (rotation, a split, the divider let go).
    func setPaneSizes(_ sizes: [CGSize]) {
        guard sizes != paneSizes else { return }
        paneSizes = sizes
        refresh()
    }

    private func applyFits(_ byID: [UInt32: ControlMessage.WindowInfo]) {
        guard paneSizes.count == panes.count else { return }
        let ppp = session.pixelsPerPoint
        var x = 0
        for (i, id) in panes.enumerated() {
            let s = paneSizes[i]
            guard s.width >= 100, s.height >= 100, let w = byID[id] else { continue }
            let want = PixelRect(x: x, y: w.frame.y, width: Int((s.width * ppp).rounded()), height: Int((s.height * ppp).rounded()))
            x += want.width
            if let last = fitted[id], abs(last.width - want.width) <= 2, abs(last.height - want.height) <= 2, last.x == want.x { continue }
            fitted[id] = want
            // In a split, side by side from the left; alone, wherever the host keeps it on its display.
            session.sendWindowCommand(.init(id: id, action: .resize, x: panes.count > 1 ? want.x : nil, y: panes.count > 1 ? want.y : nil,
                                            width: want.width, height: want.height, temporary: true))
            session.log("unified (mobile): window \(id) fitted to pane \(i), \(Int(s.width))x\(Int(s.height)) pt")
        }
    }

    /// A card chosen: its window goes in the focused pane (if it is already in the other pane, the two swap).
    func show(_ id: UInt32, in pane: Int? = nil) {
        var p = panes
        let i = min(pane ?? focused, max(0, p.count - 1))
        if p.isEmpty { p = [id] }
        else if let j = p.firstIndex(of: id) { if j != i { p.swapAt(i, j) } }
        else { p[i] = id }
        panes = p; focused = i
        raise(id)
        refresh()
    }

    /// A card dropped beside the window shown: two panes (the dropped window on the side it was dropped on).
    func showBeside(_ id: UInt32, leading: Bool) {
        guard let current = panes.first(where: { $0 != id }) ?? panes.first else { show(id); return }
        if current == id { return }
        panes = leading ? [id, current] : [current, id]
        focused = leading ? 0 : 1
        split = 0.5
        raise(id)
        refresh()
    }

    /// The divider let go at an edge: that pane closes.
    func closePane(_ i: Int) {
        guard panes.count > 1, panes.indices.contains(i) else { return }
        panes.remove(at: i); focused = 0; split = 0.5
        refresh()
    }

    /// A touch in a pane: its window to the front on the host first, so the touch lands in it.
    func touched(pane i: Int) {
        focused = i
        guard panes.indices.contains(i) else { return }
        raise(panes[i])
    }

    private func raise(_ id: UInt32) {
        guard id != raised || session.hostOrder().first(where: { $0.windowLevel == 0 })?.id != id else { return }
        raised = id
        session.sendWindowCommand(.init(id: id, action: .raise))
    }

    // MARK: Stills

    private func updateThumbnails(_ cards: inout [Card]) {
        guard let ctx = session.context else { return }
        for i in cards.indices {
            guard let c = session.layerCanvas(cards[i].id), c.width > 0, c.height > 0 else { continue }
            let g = c.currentGeneration
            if thumbGeneration[cards[i].id] == g, cards[i].image != nil { continue }
            thumbGeneration[cards[i].id] = g
            if let img = Self.thumbnail(c, context: ctx, maxWidth: 360) { cards[i].image = img }
        }
    }

    /// A canvas drawn small (an area filter through the scene renderer), read back as an image.
    static func thumbnail(_ c: Compositor, context: MetalContext, maxWidth: Int) -> CGImage? {
        let k = min(1, Double(maxWidth) / Double(c.width))
        let w = max(1, Int(Double(c.width) * k)), h = max(1, Int(Double(c.height) * k))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        guard let tex = context.device.makeTexture(descriptor: d) else { return nil }
        SceneRenderer.renderCrop(c, source: PixelRect(x: 0, y: 0, width: c.width, height: c.height), scale: k, displacements: [], bandColors: [:],
                                 context: context, target: tex, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        let stride = w * 4
        guard let buf = context.device.makeBuffer(length: stride * h, options: .storageModeShared), let cb = context.commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * h)
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        let data = Data(bytes: buf.contents(), count: stride * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The strip and the panes.
struct UnifiedArea: View {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    @ObservedObject var unified: MobileUnified
    @Binding var keyboard: Bool
    let touchMode: TouchMode
    let accessoryRow: Bool
    let safeInsets: UIEdgeInsets
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// While a card is dragged over the panes: which side it would land on (nil: replace the window shown).
    @State private var dropSide: DropSide?
    @State private var dividerDrag: CGFloat?
    enum DropSide { case leading, trailing, replace }

    static let stripHeight: CGFloat = 104
    /// Where a divider snaps (as split apps): a third, a half, two thirds; past the ends, that pane closes.
    static let snaps: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3]

    var body: some View {
        VStack(spacing: 0) {
            strip
                .frame(height: Self.stripHeight)
                .padding(.top, safeInsets.top)
            GeometryReader { geo in
                panes(in: geo.size)
                    .onChange(of: paneSizes(in: geo.size), initial: true) { _, s in unified.setPaneSizes(s) }
            }
            .padding(.bottom, max(0, safeInsets.bottom - 8))
            .padding(.leading, safeInsets.left).padding(.trailing, safeInsets.right)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { unified.start() }
    }

    private var canSplit: Bool { sizeClass == .regular }

    // MARK: Strip

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(unified.cards) { card in
                        WindowCard(card: card, shown: unified.panes.contains(card.id), current: unified.panes.indices.contains(unified.focused) && unified.panes[unified.focused] == card.id)
                            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { unified.show(card.id) } }
                            .draggable(String(card.id)) { WindowCard(card: card, shown: false, current: false).frame(width: 140) }
                            .id(card.id)
                    }
                }
                .padding(.horizontal, max(12, safeInsets.left))
                .padding(.vertical, 6)
            }
            .onChange(of: unified.panes) { _, p in
                if let id = p.indices.contains(unified.focused) ? p[unified.focused] : p.first { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    // MARK: Panes

    private func widths(_ total: CGFloat) -> [CGFloat] {
        guard unified.panes.count > 1 else { return [total] }
        let f = dividerDrag ?? unified.split
        let first = (total - Self.dividerWidth) * min(0.85, max(0.15, f))
        return [first, total - Self.dividerWidth - first]
    }
    static let dividerWidth: CGFloat = 12

    private func paneSizes(in size: CGSize) -> [CGSize] {
        // The divider's live position is not sent: the host refits when it is let go.
        let f = unified.split
        guard unified.panes.count > 1 else { return [size] }
        let first = ((size.width - Self.dividerWidth) * f).rounded()
        return [CGSize(width: first, height: size.height), CGSize(width: size.width - Self.dividerWidth - first, height: size.height)]
    }

    @ViewBuilder private func panes(in size: CGSize) -> some View {
        let w = widths(size.width)
        HStack(spacing: 0) {
            ForEach(Array(unified.panes.enumerated()), id: \.element) { i, id in
                if i > 0 { divider(total: size.width) }
                pane(i, id: id)
                    .frame(width: w[min(i, w.count - 1)])
            }
        }
        .overlay { dropOverlay(size: size) }
        .onDrop(of: [UTType.plainText], delegate: CardDrop(side: { side(at: $0, width: size.width) }, current: $dropSide) { id, loc in
            withAnimation(.snappy(duration: 0.3)) {
                switch side(at: loc, width: size.width) {
                case .leading: unified.showBeside(id, leading: true)
                case .trailing: unified.showBeside(id, leading: false)
                case .replace: unified.show(id, in: unified.panes.count > 1 ? (loc.x < size.width * unified.split ? 0 : 1) : 0)
                }
            }
        })
    }

    /// Dropped within the outer quarter of a single pane on a large screen: beside it; else in place of the window there.
    private func side(at p: CGPoint, width: CGFloat) -> DropSide {
        guard canSplit, unified.panes.count == 1 else { return .replace }
        if p.x < width * 0.25 { return .leading }
        if p.x > width * 0.75 { return .trailing }
        return .replace
    }

    @ViewBuilder private func dropOverlay(size: CGSize) -> some View {
        if let s = dropSide, s != .replace {
            HStack(spacing: 0) {
                if s == .trailing { Color.clear }
                RoundedRectangle(cornerRadius: 22).fill(.tint.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.tint, lineWidth: 2))
                    .padding(6)
                    .frame(width: size.width / 2)
                if s == .leading { Color.clear }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func pane(_ i: Int, id: UInt32) -> some View {
        FocusDesktopView(session: session, model: model, focus: id, keyboard: $keyboard, touchMode: touchMode, accessoryRow: accessoryRow,
                         focused: unified.focused == i, onTouch: { unified.touched(pane: i) })
            .clipShape(RoundedRectangle(cornerRadius: unified.panes.count > 1 ? 14 : 0))
    }

    /// The handle between two panes: dragged, it snaps to a third, half or two thirds; past the ends, that side closes.
    private func divider(total: CGFloat) -> some View {
        ZStack {
            Color.black
            Capsule().fill(.white.opacity(dividerDrag == nil ? 0.45 : 0.85)).frame(width: 4, height: 44)
        }
        .frame(width: Self.dividerWidth)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global)
            .onChanged { g in
                let usable = total - Self.dividerWidth
                dividerDrag = min(0.95, max(0.05, unified.split + g.translation.width / usable))
            }
            .onEnded { _ in
                let f = dividerDrag ?? unified.split
                withAnimation(.snappy(duration: 0.3)) {
                    dividerDrag = nil
                    if f < 0.2 { unified.closePane(0) }
                    else if f > 0.8 { unified.closePane(1) }
                    else { unified.split = Self.snaps.min { abs($0 - f) < abs($1 - f) } ?? 0.5; unified.refresh() }
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            })
        .accessibilityLabel("Divider")
    }
}

/// A card dragged over the panes: which side it would land on while it moves, and where it goes when dropped.
private struct CardDrop: DropDelegate {
    let side: (CGPoint) -> UnifiedArea.DropSide
    @Binding var current: UnifiedArea.DropSide?
    let drop: (UInt32, CGPoint) -> Void
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let s = side(info.location)
        if s != current { withAnimation(.easeOut(duration: 0.15)) { current = s } }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { withAnimation(.easeOut(duration: 0.15)) { current = nil } }
    func performDrop(info: DropInfo) -> Bool {
        current = nil
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        let loc = info.location
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? NSString, let id = UInt32(s as String) else { return }
            DispatchQueue.main.async { drop(id, loc) }
        }
        return true
    }
}

/// One window in the strip: its still and its title.
struct WindowCard: View {
    let card: MobileUnified.Card
    let shown: Bool
    let current: Bool
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
                if let img = card.image {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                } else {
                    Image(systemName: "macwindow").font(.system(size: 22)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 112, height: 70)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(current ? Color.accentColor : shown ? Color.white.opacity(0.5) : .clear, lineWidth: 2))
            Text(card.title.isEmpty ? card.app : card.title)
                .font(.caption2).lineLimit(1)
                .foregroundStyle(current ? Color.white : Color.white.opacity(0.75))
                .frame(width: 112)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.title.isEmpty ? card.app : "\(card.app), \(card.title)")
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}

/// A pane: the Desktop view showing one window alone.
struct FocusDesktopView: UIViewRepresentable {
    let session: ViewerSession
    @ObservedObject var model: ViewerModel
    let focus: UInt32
    @Binding var keyboard: Bool
    let touchMode: TouchMode
    let accessoryRow: Bool
    let focused: Bool
    let onTouch: () -> Void

    func makeUIView(context: Context) -> DesktopUIView {
        let v = DesktopUIView(frame: .zero)
        v.model = model
        v.focus = focus
        v.onKeyboardRequest = { on in keyboard = on }
        v.attach(session)
        return v
    }
    func updateUIView(_ v: DesktopUIView, context: Context) {
        v.focus = focus
        v.onTouchDown = onTouch
        v.touchMode = touchMode
        v.accessoryRow = accessoryRow
        // The keyboard belongs to the focused pane.
        v.setSoftKeyboard(keyboard && focused)
        if focused, !v.isFirstResponder { DispatchQueue.main.async { _ = v.becomeFirstResponder() } }
        v.updateCursorLayer()
        v.scheduleStreamRequest()
    }
}
