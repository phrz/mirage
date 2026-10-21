import Foundation

/// What build this process is, for About screens and the host's Welcome: the bundle's version and build number when it
/// runs from an app bundle (the host inside Mirage.app, the viewer app), and the executable's build time (its modification
/// date, UTC), which tells two deploys of the same version apart.
public enum BuildInfo {
    public static let current: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        var parts: [String] = []
        if let version { parts.append(build.map { "\(version) (\($0))" } ?? version) }
        if let path = Bundle.main.executablePath ?? CommandLine.arguments.first,
           let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm'Z'"
            parts.append("built \(f.string(from: date))")
        }
        return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")
    }()
}
