import Foundation
import MirageCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// This device's clipboard, for sharing with the host (`Feature.clipboard`): written when the host copies, read only
/// when the person pastes into the host (so the system's paste privacy never asks without a reason).
@MainActor enum LocalClipboard {
    #if os(macOS)
    static var changeCount: Int { NSPasteboard.general.changeCount }

    static func read() -> ControlMessage.Clipboard? {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        // Password managers mark what they copy (nspasteboard.org): it never leaves this Mac.
        if types.contains(.init("org.nspasteboard.ConcealedType")) || types.contains(.init("org.nspasteboard.TransientType")) { return nil }
        let text = pb.string(forType: .string)
        var png = pb.data(forType: .png)
        if png == nil, text == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        let clip = ControlMessage.Clipboard(text: text, png: png)
        return clip.isEmpty ? nil : clip
    }

    /// Returns the change count after writing.
    @discardableResult static func write(_ clip: ControlMessage.Clipboard) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        var types: [NSPasteboard.PasteboardType] = []
        if let t = clip.text, !t.isEmpty { types.append(.string) }
        if let p = clip.png, !p.isEmpty { types.append(.png) }
        pb.declareTypes(types, owner: nil)
        if let t = clip.text, !t.isEmpty { pb.setString(t, forType: .string) }
        if let p = clip.png, !p.isEmpty { pb.setData(p, forType: .png) }
        return pb.changeCount
    }
    #else
    static var changeCount: Int { UIPasteboard.general.changeCount }

    static func read() -> ControlMessage.Clipboard? {
        let pb = UIPasteboard.general
        let text = pb.hasStrings ? pb.string : nil
        let png = text == nil && pb.hasImages ? pb.image?.pngData() : nil
        let clip = ControlMessage.Clipboard(text: text, png: png)
        return clip.isEmpty ? nil : clip
    }

    @discardableResult static func write(_ clip: ControlMessage.Clipboard) -> Int {
        var item: [String: Any] = [:]
        if let t = clip.text, !t.isEmpty { item["public.utf8-plain-text"] = t }
        if let p = clip.png, !p.isEmpty { item["public.png"] = p }
        UIPasteboard.general.setItems([item])
        return UIPasteboard.general.changeCount
    }
    #endif
}
