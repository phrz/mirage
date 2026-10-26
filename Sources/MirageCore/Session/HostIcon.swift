import Foundation
import CryptoKit

/// The host's own picture of itself (phrz, 2026-10-26: "it shows generic iMac icon rather than a green iMac"): the icon
/// Finder and About This Mac show for this Mac, colour included, rendered by the host once per start as PNG at 128 and
/// 256 px. It travels in the Welcome only to a viewer that asks for it (`Feature.hostIcon`) and does not already hold the
/// same one (`Hello.hostIconHash`); the viewer keeps it per host.
public struct HostIcon: Codable, Equatable, Sendable {
    /// SHA-256 of the PNGs, hex (the first 32 characters): what a viewer that has it says in its Hello.
    public var hash: String
    public var png128: Data
    /// Left out when both would not fit the budget.
    public var png256: Data?

    /// At most this many PNG bytes per host.
    public static let budget = 30_000

    /// Both sizes when they fit the budget, else the small one, else nothing.
    public static func make(png128: Data, png256: Data?) -> HostIcon? {
        guard !png128.isEmpty, png128.count <= budget else { return nil }
        let big = png256.flatMap { png128.count + $0.count <= budget ? $0 : nil }
        return HostIcon(hash: digest(png128, big), png128: png128, png256: big)
    }

    public init(hash: String, png128: Data, png256: Data?) { self.hash = hash; self.png128 = png128; self.png256 = png256 }

    static func digest(_ a: Data, _ b: Data?) -> String {
        var h = SHA256()
        h.update(data: a)
        if let b { h.update(data: b) }
        return h.finalize().map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// Sound: within the budget, its hash matches, and both are PNGs. A viewer stores nothing else.
    public var isValid: Bool {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        return png128.count + (png256?.count ?? 0) <= Self.budget && png128.prefix(4) == png && (png256.map { $0.prefix(4) == png } ?? true)
            && hash == Self.digest(png128, png256)
    }

    /// What the Welcome carries for a viewer: only one that asked for it, and only when its copy differs.
    public static func forViewer(features: [String]?, cachedHash: String?, icon: HostIcon?) -> HostIcon? {
        guard let icon, (features ?? []).contains(ControlMessage.Feature.hostIcon), cachedHash != icon.hash else { return nil }
        return icon
    }
}

extension Store {
    private var iconDir: URL { root.appendingPathComponent("host-icons", isDirectory: true) }
    private func iconFile(_ hostID: String) -> URL? {
        guard !hostID.isEmpty, hostID.allSatisfy({ $0.isHexDigit }) else { return nil }
        return iconDir.appendingPathComponent("\(hostID).json")
    }

    /// The icon a host sent last, by its id.
    public func hostIcon(hostID: String) -> HostIcon? {
        guard let u = iconFile(hostID), let d = try? Data(contentsOf: u), let i = try? JSONDecoder().decode(HostIcon.self, from: d), i.isValid else { return nil }
        return i
    }

    public func saveHostIcon(_ icon: HostIcon, hostID: String) throws {
        guard icon.isValid, let u = iconFile(hostID) else { return }
        try FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(icon).write(to: u, options: .atomic)
    }

    public func removeHostIcon(hostID: String) {
        if let u = iconFile(hostID) { try? FileManager.default.removeItem(at: u) }
    }
}
