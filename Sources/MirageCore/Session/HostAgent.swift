import Foundation
#if os(macOS)
import Security
#endif

/// The host's login-item agent (DESIGN §3.1, §3.10): registered by Mirage.app with SMAppService, run by launchd from the
/// bundle. Shared by the app, which alone can register it, and the updater and deploy scripts, which need it registered
/// again after a signature change.
///
/// launchd keeps a launch constraint (LWCR: signing identifier, team, validation category) that BTM derives from the
/// signature registered. A miraged signed differently (Apple Development ↔ Developer ID) then fails to spawn: "job state =
/// spawn failed", "last exit code = 78: EX_CONFIG", "needs LWCR update" (mac-daddy, 2026-10-26). Only registering the
/// agent again from the app refreshes it.
public enum HostAgent {
    public static let label = "com.paulherz.mirage.host"
    public static let plistName = "com.paulherz.mirage.host.plist"
    /// `Mirage.app --reregister-host ID`: the app unregisters and registers the agent again, writes a `Registration`, and
    /// quits.
    public static let reregisterFlag = "--reregister-host"

    /// The last registration, in host-registration.json: the updater's answer (by `requestID`), and the record the app
    /// compares the bundle's signature with at launch.
    public struct Registration: Codable, Equatable, Sendable {
        public var requestID: String
        public var at: Date
        /// SMAppService's status after registering: enabled, requiresApproval (a person must approve it in Login Items),
        /// notRegistered, notFound.
        public var status: String
        public var error: String?
        /// miraged's designated requirement when it was registered.
        public var requirement: String?
        /// launchd's job state a moment after registering.
        public var jobState: String?
        public init(requestID: String, at: Date, status: String, error: String?, requirement: String? = nil, jobState: String? = nil) {
            self.requestID = requestID; self.at = at; self.status = status; self.error = error
            self.requirement = requirement; self.jobState = jobState
        }
    }

    public static func registrationURL(storeRoot: URL) -> URL { storeRoot.appendingPathComponent("host-registration.json") }

    public static func readRegistration(storeRoot: URL) -> Registration? {
        guard let d = try? Data(contentsOf: registrationURL(storeRoot: storeRoot)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Registration.self, from: d)
    }
    public static func writeRegistration(_ r: Registration, storeRoot: URL) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(r).write(to: registrationURL(storeRoot: storeRoot), options: .atomic)
    }

    /// Why an enabled agent must be registered again, or nil: launchd refuses to spawn it, or miraged's signature is not
    /// the one registered last (no record: registered by a build from before records, so once, to be sure).
    public static func reregistrationReason(status: Status, recorded: Registration?, currentRequirement: String?) -> String? {
        if case .spawnFailed(let why) = status { return "launchd cannot start it (\(why))" }
        guard let now = currentRequirement else { return nil }
        guard let then = recorded?.requirement else { return "no record of the signature it was registered with" }
        return then == now ? nil : "miraged's signature changed since it was registered"
    }

    /// The agent as `launchctl print gui/<uid>/com.paulherz.mirage.host` shows it.
    public enum Status: Equatable, Sendable {
        /// launchd has no such job: never registered, or unregistered.
        case notLoaded
        case running(pid: Int, program: String?)
        /// launchd will not start it at all ("job state = spawn failed", typically EX_CONFIG from a launch constraint).
        /// The binary never runs, so it never counts an update attempt.
        case spawnFailed(String)
        /// Loaded, between runs (exited, waiting for KeepAlive's throttle).
        case notRunning(String)

        public var isRunning: Bool { if case .running = self { return true }; return false }

        /// The top-level `key = value` lines (one tab deep; nested blocks are deeper).
        public static func fields(_ out: String) -> [String: String] {
            var f: [String: String] = [:]
            for raw in out.split(separator: "\n", omittingEmptySubsequences: true) {
                guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t"), let eq = raw.range(of: " = ") else { continue }
                let k = raw[raw.index(after: raw.startIndex)..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
                if f[k] == nil { f[k] = raw[eq.upperBound...].trimmingCharacters(in: .whitespaces) }
            }
            return f
        }

        public static func parse(_ out: String, exitCode: Int32 = 0) -> Status {
            if out.contains("Could not find service") || (exitCode != 0 && !out.contains(" = ")) { return .notLoaded }
            let f = fields(out)
            let exit = f["last exit code"]
            if f["job state"] == "spawn failed" || (exit?.contains("EX_CONFIG") ?? false) && f["state"] != "running" {
                return .spawnFailed([f["job state"].map { "job state \($0)" }, exit.map { "last exit code \($0)" }].compactMap { $0 }.joined(separator: ", "))
            }
            if f["state"] == "running", let pid = f["pid"].flatMap({ Int($0) }) { return .running(pid: pid, program: f["program"]) }
            return .notRunning([f["state"].map { "state \($0)" }, exit.map { "last exit code \($0)" }].compactMap { $0 }.joined(separator: ", "))
        }
    }

    /// Whose the loaded agent job is (mac-daddy, 2026-10-26): an SMAppService agent prints no `program`, only
    /// `program identifier = Contents/MacOS/miraged (mode: 2)` (bundle-relative) and `path = (submitted by smd…)`; a plist
    /// agent prints `program = /abs/path`. So: the running pid's executable decides (it may already sit in the kept
    /// previous bundle, moved there by the swap), else the absolute program, else a bundle-relative identifier naming
    /// miraged, which is ours but cannot say from where.
    public enum Ownership: Equatable, Sendable {
        case notLoaded
        /// Running from one of the given bundles, or launchd's absolute program is inside one.
        case ours(pid: Int?)
        /// Registered from some bundle, which `launchctl print` does not name, and not running now.
        case probablyOurs
        /// Runs (or is configured to run) from elsewhere: another copy of Mirage.
        case elsewhere(String)
    }

    public static func ownership(launchctlOutput out: String, exitCode: Int32 = 0, bundles: [URL], pidPath: (Int) -> String?) -> Ownership {
        if case .notLoaded = Status.parse(out, exitCode: exitCode) { return .notLoaded }
        let f = Status.fields(out)
        func inside(_ path: String) -> Bool {
            let p = URL(fileURLWithPath: path).standardizedFileURL.path
            return bundles.contains { p.hasPrefix($0.standardizedFileURL.path + "/") }
        }
        if f["state"] == "running", let pid = f["pid"].flatMap({ Int($0) }), let exe = pidPath(pid) {
            return inside(exe) ? .ours(pid: pid) : .elsewhere(exe)
        }
        if let program = f["program"], program.hasPrefix("/") { return inside(program) ? .ours(pid: nil) : .elsewhere(program) }
        if let ident = f["program identifier"], ident.hasPrefix("Contents/MacOS/miraged") { return .probablyOurs }
        return .elsewhere(f["program"] ?? f["program identifier"] ?? "unknown program")
    }

    #if os(macOS)
    /// A process's executable path (proc_pidpath), else nil.
    public static func executablePath(pid: Int) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// `launchctl print` of the agent: its output and exit status.
    public static func launchctlPrint() -> (String, Int32) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(label)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return ("\(error)", 1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }
    public static func currentStatus() -> Status { let (o, c) = launchctlPrint(); return .parse(o, exitCode: c) }

    /// The designated requirement a binary is signed with (as text), or nil when it is unsigned.
    public static func designatedRequirement(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &req) == errSecSuccess, let req else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(req, SecCSFlags(), &text) == errSecSuccess else { return nil }
        return text as String?
    }
    #endif
}
