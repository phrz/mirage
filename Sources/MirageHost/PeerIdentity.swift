import Foundation
import Security

/// Who is on the other end of the local control socket, as the host itself finds out (DESIGN §3.13: an agent's unlock
/// request names its requester from this, never from what it says).
/// - The peer by its audit token (LOCAL_PEERTOKEN); each process above it by its own audit token (its task name port), so
///   code is looked up by token (pid and pid version), never by a reusable pid.
/// - `miraged unlock` itself, shells and wrappers are carriers: skipped. Interpreters (python3, node, osascript…) are too,
///   and named: "a script run by python3, under Terminal (Apple)".
/// - The program shown is the first that is neither. Its signature decides the label, against a requirement, not mere
///   integrity: "Apple" only for `anchor apple`; "team ABCDE12345" only for `anchor apple generic` with that team as the
///   leaf certificate's OU; anything else "unsigned".
enum PeerIdentity {
    struct Requester: Equatable, Sendable {
        /// What the person sees.
        var label: String
        /// Who may extend its agent session: the shown program's pid and pid version (from its audit token), and its
        /// verified signer and identifier.
        var anchor: String
    }

    static let carriers: Set<String> = ["miraged", "zsh", "bash", "sh", "dash", "fish", "tcsh", "csh", "ksh", "login", "env", "sudo",
                                        "tmux", "screen", "script", "nohup", "timeout", "xargs", "nice", "caffeinate", "arch", "time"]
    static let interpreters: Set<String> = ["python", "python3", "Python", "perl", "perl5", "ruby", "node", "osascript", "bun", "deno",
                                            "php", "lua", "tclsh", "wish", "swift", "swift-frontend", "java", "pwsh", "Rscript"]

    static func requester(fd: Int32) -> Requester {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return Requester(label: "an unknown process", anchor: "unknown") }
        var current: audit_token_t? = token
        var interpreter: String?
        for _ in 0..<10 {
            guard let t = current else { break }
            let pid = pid_t(bitPattern: t.val.5)
            guard pid > 1 else { break }
            let name = executableName(pid)
            if interpreters.contains(name) { interpreter = interpreter ?? name }
            else if !carriers.contains(name) {
                let signer = signer(of: t)
                let label = "\(name) (\(signer.label))"
                return Requester(label: interpreter.map { "a script run by \($0), under \(label)" } ?? label,
                                 anchor: "\(pid).\(t.val.7):\(signer.anchor):\(signer.identifier ?? name)")
            }
            current = auditToken(of: parent(of: pid))
        }
        return Requester(label: interpreter.map { "a script run by \($0)" } ?? "a shell (no program above it)", anchor: "none")
    }

    static func executableName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? (String(cString: buf) as NSString).lastPathComponent : "pid \(pid)"
    }
    static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? pid_t(info.pbi_ppid) : 0
    }
    /// A process's audit token, through its task name port (allowed for the same user's processes).
    static func auditToken(of pid: pid_t) -> audit_token_t? {
        guard pid > 1 else { return nil }
        var port: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &token) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        return kr == KERN_SUCCESS ? token : nil
    }

    /// Who signed the running code named by `token`, checked against a requirement.
    struct Signer: Equatable { var label: String; var anchor: String; var identifier: String? }
    static func signer(of token: audit_token_t) -> Signer {
        var t = token
        let data = Data(bytes: &t, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code else {
            return Signer(label: "unsigned", anchor: "unsigned", identifier: nil)
        }
        var st: SecStaticCode?
        var info: CFDictionary?
        let d: [String: Any] = (SecCodeCopyStaticCode(code, [], &st) == errSecSuccess && st != nil
            && SecCodeCopySigningInformation(st!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess) ? (info as? [String: Any] ?? [:]) : [:]
        let identifier = d[kSecCodeInfoIdentifier as String] as? String
        if satisfies(code, "anchor apple") { return Signer(label: "Apple", anchor: "apple", identifier: identifier) }
        if let team = d[kSecCodeInfoTeamIdentifier as String] as? String, team.allSatisfy({ $0.isLetter || $0.isNumber }),
           satisfies(code, "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"") {
            return Signer(label: "team \(team)", anchor: "team \(team)", identifier: identifier)
        }
        return Signer(label: "unsigned", anchor: "unsigned", identifier: nil)
    }
    static func satisfies(_ code: SecCode, _ requirement: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
