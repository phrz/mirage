import AppKit
import MirageCore

/// This Mac's clipboard, shared with the viewers that ask for it (`Feature.clipboard`): a copy here goes to each of them,
/// and a viewer's clipboard is put here before its paste. Plain text and images (PNG); a clipboard larger than one control
/// frame stays here. Contents marked concealed or transient (password managers, nspasteboard.org) never leave this Mac.
///
/// The clipboard is read only while a viewer listens (macOS may ask whether this app can read it): its change count is
/// polled, which reads nothing.
public final class ClipboardBridge: @unchecked Sendable {
    public static let shared = ClipboardBridge()

    private var listeners: ClipboardListeners?
    private var log: (String) -> Void = { _ in }
    /// The change count last seen or written here (main thread): a change of ours is not sent back.
    private var seen = -1
    private var timer: Timer?

    @MainActor public func start(listeners: ClipboardListeners, log: @escaping (String) -> Void) {
        guard timer == nil else { return }
        self.listeners = listeners; self.log = log
        seen = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
    }

    @MainActor private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != seen, let listeners else { return }
        seen = count
        Task { @MainActor in
            guard await listeners.count > 0, NSPasteboard.general.changeCount == count else { return }
            guard let clip = Self.read(NSPasteboard.general) else { return }
            guard clip.fitsOneFrame else { log("clipboard: too large to share (\(clip))"); return }
            let n = await listeners.count
            await listeners.send(clip)
            log("clipboard: a copy here, to \(n) viewer\(n == 1 ? "" : "s") (\(clip))")
        }
    }

    /// Puts a viewer's clipboard here; returns once it is on the clipboard.
    public func set(_ clip: ControlMessage.Clipboard) async {
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            var items: [NSPasteboard.PasteboardType] = []
            if let t = clip.text, !t.isEmpty { items.append(.string) }
            if let p = clip.png, !p.isEmpty { items.append(.png) }
            pb.declareTypes(items, owner: nil)
            if let t = clip.text, !t.isEmpty { pb.setString(t, forType: .string) }
            if let p = clip.png, !p.isEmpty { pb.setData(p, forType: .png) }
            seen = pb.changeCount
        }
        log("clipboard: from a viewer (\(clip))")
    }

    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Text and an image from `pb`, nil when there is neither or the contents are private.
    @MainActor static func read(_ pb: NSPasteboard) -> ControlMessage.Clipboard? {
        let types = pb.types ?? []
        if types.contains(concealed) || types.contains(transient) { return nil }
        let text = pb.string(forType: .string)
        var png = pb.data(forType: .png)
        // TIFF only when it is the content (a copied image), not a file's icon beside its name.
        if png == nil, text == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        let clip = ControlMessage.Clipboard(text: text, png: png)
        return clip.isEmpty ? nil : clip
    }
}
