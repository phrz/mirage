import Foundation
import MirageCore

/// The signing identity of a Mirage bundle: the designated requirements of the app and of its miraged. TCC's Screen
/// Recording and Accessibility grants and launchd's launch constraint for the agent both follow them, so a change (Apple
/// Development → Developer ID) needs a person at the Mac (mac-daddy, 2026-10-26: grants removed and added by hand).
public struct SigningIdentity: Codable, Equatable, Sendable {
    public var app: String?
    public var host: String?
    /// The build these were read from (a record is reused only for the build that wrote it).
    public var build: Int?

    public init(app: String?, host: String?, build: Int? = nil) { self.app = app; self.host = host; self.build = build }

    /// Read from a bundle's signatures.
    public static func of(bundle: URL) -> SigningIdentity {
        SigningIdentity(app: HostAgent.designatedRequirement(of: bundle),
                        host: HostAgent.designatedRequirement(of: bundle.appendingPathComponent("Contents/MacOS/miraged")),
                        build: Installer.version(of: bundle)?.build)
    }

    /// What changes from `running` to `staged`, in words, or nil when the identity is the same. A requirement this side
    /// cannot read (unsigned test bundles on both sides) compares as equal only to another unreadable one.
    public static func change(from running: SigningIdentity, to staged: SigningIdentity) -> String? {
        var parts: [String] = []
        if running.app != staged.app { parts.append("the app's (\(running.app ?? "unsigned") → \(staged.app ?? "unsigned"))") }
        if running.host != staged.host { parts.append("miraged's (\(running.host ?? "unsigned") → \(staged.host ?? "unsigned"))") }
        return parts.isEmpty ? nil : "signing identity change: \(parts.joined(separator: " and ")) designated requirement differs"
    }

    /// The refusal, and what `--allow-identity-change` costs.
    public static func refusal(_ change: String) -> String {
        "\(change). The Screen Recording and Accessibility grants and the host agent's registration will need a person at the Mac; to go ahead anyway: miraged update --now --allow-identity-change"
    }

    /// What a person must do at the Mac after an identity change.
    public static let tccSteps = """
        On this Mac, once (the grants follow the old signature):
          System Settings > Privacy & Security > Screen & System Audio Recording, and then Accessibility:
          select the old Mirage / miraged rows and remove them (−), add /Applications/Mirage.app/Contents/MacOS/miraged (+)
          and switch it on; then restart the host: launchctl kickstart -k gui/$(id -u)/com.paulherz.mirage.host
        If the host agent does not start, open Mirage.app once (it registers the agent again).
        """
}
