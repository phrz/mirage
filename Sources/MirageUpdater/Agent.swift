import Foundation
import MirageCore

public typealias AgentStatus = HostAgent.Status

/// After a swap or a deploy: whether the new build's agent can be started at all (DESIGN §3.10, the one hole). A build
/// that runs and crashes counts its own attempts and rolls itself back; one launchd refuses to spawn never runs, so the
/// process that swapped it in must notice and act.
public enum AgentWatch {
    public enum Verdict: Equatable, Sendable {
        /// It runs (or ran: it counted an attempt): leave it to its health checks.
        case started
        /// launchd will not spawn it: register again, or, if that was done, roll back.
        case cannotSpawn(String)
        case keepWaiting
    }
    /// How long a swapped-in build may take to start once before it counts as unable to.
    public static let startWindow: TimeInterval = 20

    /// `attempts`: the pending update's count, which the new build raises at its first start.
    public static func verdict(_ s: AgentStatus, attempts: Int, elapsed: TimeInterval, window: TimeInterval = startWindow) -> Verdict {
        if attempts > 0 { return .started }
        switch s {
        case .running: return .started
        case .spawnFailed(let why): return .cannotSpawn(why)
        case .notLoaded: return elapsed >= window ? .cannotSpawn("the agent is not loaded") : .keepWaiting
        case .notRunning(let why): return elapsed >= window ? .cannotSpawn("not started after \(Int(window)) s (\(why))") : .keepWaiting
        }
    }
}

/// launchctl and the app's re-registration, for the updater and `miraged update --ensure-agent`.
public struct AgentControl: Sendable {
    public var app: URL
    public var storeRoot: URL
    public init(app: URL, storeRoot: URL) { self.app = app; self.storeRoot = storeRoot }

    var target: String { "gui/\(getuid())/\(HostAgent.label)" }
    static let launchctl = URL(fileURLWithPath: "/bin/launchctl")

    public func status() -> AgentStatus { HostAgent.currentStatus() }

    /// Whether launchd's job runs its program from inside `app` (the agent belongs to this bundle).
    public func belongsToApp() -> Bool {
        guard let p = AgentStatus.fields(HostAgent.launchctlPrint().0)["program"] else { return false }
        return p.hasPrefix(app.path + "/")
    }

    public func kickstart() { _ = SystemBundleVerifier.run(Self.launchctl, ["kickstart", "-k", target], timeout: 15) }

    /// What a person must do when nothing here can reach the app.
    public static let openOnce = "a person must open Mirage.app once on this Mac (it registers the host again at launch)"

    public enum Reregistration: Equatable, Sendable {
        case done(HostAgent.Registration)
        /// The app could not be launched from here, or did not answer.
        case unreachable(String)
    }

    /// Asks the app to register the agent again and waits for its answer. The app must start in the user's GUI session:
    /// `open -n -g -a Mirage.app --args --reregister-host ID` works there (the agent, a terminal on the Mac), but from SSH
    /// `open` fails ("Could not switch to audit session"), so then a one-shot job in the gui launchd domain runs that
    /// `open` instead (launchctl bootstrap gui/<uid>, the same user). Neither: `.unreachable`.
    public func reregister(timeout: TimeInterval = 30) -> Reregistration {
        let id = UUID().uuidString
        let args = ["-n", "-g", "-a", app.path, "--args", HostAgent.reregisterFlag, id]
        let (out, code, _) = SystemBundleVerifier.run(URL(fileURLWithPath: "/usr/bin/open"), args, timeout: 20)
        var how = "open"
        var cleanup: () -> Void = {}
        defer { cleanup() }
        if code != 0 {
            how = "a one-shot launchd job (open from here: \(out.trimmingCharacters(in: .whitespacesAndNewlines)))"
            let (why, done) = runInGUISession(["/usr/bin/open"] + args, id: id)
            cleanup = done
            if let why { return .unreachable("\(why); \(Self.openOnce)") }
        }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = HostAgent.readRegistration(storeRoot: storeRoot), r.requestID == id { return .done(r) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return .unreachable("Mirage.app did not answer within \(Int(timeout)) s (launched by \(how)); \(Self.openOnce)")
    }

    /// Runs a command once as a job in the user's gui launchd domain (so it is in the GUI session): nil on success, and
    /// what removes the job afterwards.
    func runInGUISession(_ command: [String], id: String) -> (String?, () -> Void) {
        let label = "com.paulherz.mirage.reregister.\(id.prefix(8))"
        let plist = storeRoot.appendingPathComponent("\(label).plist")
        let job: [String: Any] = ["Label": label, "ProgramArguments": command, "RunAtLoad": true, "LaunchOnlyOnce": true]
        do { try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist) }
        catch { return ("cannot write \(plist.path): \(error)", {}) }
        let (out, code, _) = SystemBundleVerifier.run(Self.launchctl, ["bootstrap", "gui/\(getuid())", plist.path], timeout: 15)
        let cleanup = {
            _ = SystemBundleVerifier.run(Self.launchctl, ["bootout", "gui/\(getuid())/\(label)"], timeout: 10)
            try? FileManager.default.removeItem(at: plist)
        }
        return (code == 0 ? nil : "launchctl bootstrap gui/\(getuid()) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))", cleanup)
    }

    /// Polls until the verdict is reached. `attempts` reads the pending update's count (a deploy: always 0).
    public func watch(attempts: () -> Int = { 0 }, window: TimeInterval = AgentWatch.startWindow) -> AgentWatch.Verdict {
        let start = Date()
        while true {
            let v = AgentWatch.verdict(status(), attempts: attempts(), elapsed: Date().timeIntervalSince(start), window: window)
            if v != .keepWaiting { return v }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    public static func describe(_ r: Reregistration) -> String {
        switch r {
        case .done(let r): return "\(r.status)\(r.error.map { ", \($0)" } ?? "")\(r.jobState.map { "; job \($0)" } ?? "")"
        case .unreachable(let why): return "not done: \(why)"
        }
    }

    /// The agent running from this bundle, whatever it takes short of rolling back: (re)start it, and on a spawn failure
    /// register it again once. `restart`: kickstart even a running agent (a deploy replaced its code); else only start one
    /// that is not running. `log` narrates. Returns the last verdict.
    public func ensureRunning(restart: Bool, log: (String) -> Void) -> AgentWatch.Verdict {
        if !restart, case .running = status() { return .started }
        kickstart()
        var v = watch()
        if case .cannotSpawn(let why) = v {
            log("the host agent cannot start (\(why)); registering it again through Mirage.app")
            let r = reregister()
            log("registration: \(Self.describe(r))")
            if case .done(let reg) = r, reg.status == "requiresApproval" {
                log("Login Items must approve Mirage on this Mac (System Settings > General > Login Items) before the host can run")
            }
            if case .unreachable = r { return v }
            v = watch()
        }
        return v
    }
}
