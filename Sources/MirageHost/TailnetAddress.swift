import Foundation

/// This Mac's tailnet address and name, for the pairing link. The address from the interfaces (the first 100.64.0.0/10
/// IPv4: Tailscale's range), at once; the name by a reverse lookup of it (Tailscale's resolver answers with the MagicDNS
/// name), else a standalone `tailscale` CLI if one is installed, off the caller's queue, at most 2 s each. Never the
/// Tailscale app's own binary: run as a CLI from the login-item host it blocked ~15 s and raised Tailscale's network-extension
/// prompt on the host at every "Pair a Device…" (2026-10-25, 10:31 and 11:36Z).
public enum TailnetAddress {
    /// The tailnet IPv4 address now (no process, no lookup), nil off the tailnet.
    public static func address() -> String? { cgnatAddress() }

    /// The MagicDNS name of `address` (no trailing dot), or nil, on `completion` (any queue).
    public static func name(of address: String, completion: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            if let n = reverseName(address) { completion(n); return }
            for path in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"] where FileManager.default.isExecutableFile(atPath: path) {
                if let n = cliName(path) { completion(n); return }
            }
            completion(nil)
        }
    }

    /// getnameinfo with a name required (a fully qualified one), bounded at 2 s.
    static func reverseName(_ address: String) -> String? {
        var sa = sockaddr_in(); sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sa.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &sa.sin_addr) == 1 else { return nil }
        let box = ResultBox()
        let t = Thread {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = withUnsafePointer(to: &sa) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) } }
            if r == 0 { box.set(String(cString: host)) }
            box.done.signal()
        }
        t.start()
        guard box.done.wait(timeout: .now() + 2) == .success, var n = box.get() else { return nil }
        if n.hasSuffix(".") { n.removeLast() }
        return n.contains(".") ? n : nil   // a bare local name is not the tailnet's
    }
    /// A standalone CLI's `status --self --json` DNSName, killed after 2 s.
    static func cliName(_ path: String) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = ["status", "--self", "--json"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); killer.cancel()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let me = j["Self"] as? [String: Any], var dns = me["DNSName"] as? String, !dns.isEmpty else { return nil }
        if dns.hasSuffix(".") { dns.removeLast() }
        return dns
    }
    final class ResultBox: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock(); private var value: String?
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func cgnatAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if a & 0xFFC0_0000 == 0x6440_0000 {   // 100.64.0.0/10
                return "\(a >> 24).\((a >> 16) & 255).\((a >> 8) & 255).\(a & 255)"
            }
        }
        return nil
    }
}
