import Foundation

/// The System Settings panes a host Mac's grants live in, named as that Mac's System Settings shows them. macOS 27 renamed
/// Privacy & Security → Accessibility to "Device Control and Data Access" (its SecurityPrivacyExtension's "ACCESSIBILITY"
/// string, checked on 27.0.1); Screen & System Audio Recording kept its name (since macOS 15).
public enum PrivacyPane {
    public static let screenRecording = "Screen & System Audio Recording"
    public static func accessibility(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        osMajor >= 27 ? "Device Control and Data Access" : "Accessibility"
    }
    /// "System Settings → Privacy & Security → <pane>".
    public static func path(_ pane: String) -> String { "System Settings → Privacy & Security → \(pane)" }
}
