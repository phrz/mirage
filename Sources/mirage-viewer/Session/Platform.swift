import Foundation
import MirageCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The session layer's platform edges: the few AppKit/UIKit types and system events it needs, and where the
// viewer's credentials live. Everything else in Session/ is the same code on macOS and iOS.

#if os(macOS)
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
/// Modifier keys of a local key event (typeahead decides on them).
typealias KeyModifiers = NSEvent.ModifierFlags
#else
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
struct KeyModifiers: OptionSet, Sendable {
    let rawValue: UInt
    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
}
#endif

enum PlatformEvents {
    /// Calls `handler` with a reason when the connection is likely dead and worth redialing at once: the Mac woke from
    /// sleep, or the iOS app came back to the foreground (its sockets were frozen or torn down meanwhile).
    static func observeWake(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        #if os(macOS)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in handler("woke from sleep") }
        #else
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in handler("back in the foreground") }
        #endif
    }

    /// Calls `handler` when the app is about to be suspended (iOS: it may be ended without another word); nil on macOS.
    static func observeSuspend(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol? {
        #if os(macOS)
        return nil
        #else
        return NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in handler() }
        #endif
    }
}

/// The viewer's long-term identity and its resume token. macOS keeps both as before (identity file in the Mirage
/// store, resume token in memory only); iOS keeps both in the keychain, so a relaunched app (iOS ends suspended apps
/// whenever it likes) is the same paired device and can resume the host's session within its window.
enum ViewerCredentials {
    static func clientIdentity(store: Store) throws -> DeviceIdentity {
        #if os(macOS)
        return try store.identity(role: "client", name: DeviceNames.current())
        #else
        let name = DeviceNames.current()
        if let seed = Keychain.read("client-identity"), let id = try? DeviceIdentity(seed: seed, name: name) { return id }
        let id = DeviceIdentity(name: name)
        guard Keychain.write("client-identity", id.signingKey.rawRepresentation) else { throw MirageError.storage("could not save the identity in the keychain") }
        return id
        #endif
    }

    /// A resume token with the last input sequence number sent under it (a resumed session continues the numbering).
    struct SavedResume: Codable { var token: Data; var inputSeq: UInt64; var savedAt: Date }

    /// A resume token saved for this host that the host may still honour.
    static func savedResume(host: String, port: UInt16) -> SavedResume? {
        #if os(macOS)
        return nil
        #else
        guard let d = Keychain.read("resume-\(host):\(port)"), let t = try? JSONDecoder().decode(SavedResume.self, from: d),
              Date().timeIntervalSince(t.savedAt) < Double(Mirage.resumeWindowSeconds) else { return nil }
        return t
        #endif
    }

    static func saveResume(_ token: Data, inputSeq: UInt64, host: String, port: UInt16) {
        #if !os(macOS)
        if let d = try? JSONEncoder().encode(SavedResume(token: token, inputSeq: inputSeq, savedAt: Date())) { _ = Keychain.write("resume-\(host):\(port)", d) }
        #endif
    }
}
