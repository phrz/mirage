import Foundation

/// This Mac's tailnet name and address, for the pairing link: Tailscale's own status when its CLI is installed, else the
/// first 100.64.0.0/10 IPv4 address (Tailscale's range) and this Mac's local host name.
public enum TailnetAddress {
    public static func current() -> (name: String?, address: String?) {
        for path in ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = ["status", "--self", "--json"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let me = j["Self"] as? [String: Any] {
                let dns = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
                let ip = (me["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
                if ip != nil { return (dns.flatMap { $0.isEmpty ? nil : $0 }, ip) }
            }
        }
        return (Host.current().localizedName, cgnatAddress())
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
