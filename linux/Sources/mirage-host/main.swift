import Foundation
import ArgumentParser
import MirageCore

@main
struct MirageHost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirage-host",
        abstract: "Mirage host for Linux: shares this GNOME desktop with paired Mirage viewers over QUIC.",
        subcommands: [Serve.self, Pair.self, Devices.self, Revoke.self],
        defaultSubcommand: Serve.self)
}

func log(_ s: String) {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    FileHandle.standardError.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the host (foreground; the installer runs it as a systemd user service).")
    @Option(name: .shortAndLong, help: "UDP port to listen on.") var port: UInt16 = Mirage.defaultPort
    @Option(help: "Host name shown to viewers (default: this computer's host name).") var name: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try Store()
        let identity = try store.identity(role: "host", name: name ?? DeviceNames.current())
        let tls = try TLSIdentity.loadOrCreate(store: store)
        let ctx = HostContext(identity: identity, store: store, tlsFingerprint: tls.fingerprint, log: { log($0) },
                              makeStreamer: { LinuxStreamer(log: { log($0) }) })
        GnomeSession.shared.start(log: { log($0) })
        let host = QUICHost(port: port, tls: tls)
        host.log = { log($0) }
        try host.start(onStream: { stream, id, remote in
            Task { await HostSession.handle(stream: stream, connectionID: id, remote: remote, ctx: ctx) }
        })
        log("mirage host \(identity.name) (Linux) id=\(identity.id.prefix(12)) devices=\(try store.authorizedDevices().count), listening on udp/\(port)")
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a one-time 6-digit code and wait for a device to pair.")
    @Option(help: "Seconds the code stays valid.") var timeout: Int = 300

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try Store()
        let code = PairingCode.generate()
        let pending = Store.PendingPairing(code: code, expiresAt: Date().addingTimeInterval(TimeInterval(timeout)))
        try store.setPendingPairing(pending)
        let addresses = localAddresses()
        print("""

            Pairing code:  \(code.prefix(3)) \(code.suffix(3))

            On your Mac, in Mirage: click +, enter \(addresses.first ?? DeviceNames.current()) and this code.
            \(addresses.count > 1 ? "Other addresses of this computer: \(addresses.dropFirst().joined(separator: ", "))\n" : "")\
            Valid for \(timeout / 60) minutes, one attempt. Waiting…
            """)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout) + 65)
        while Date() < deadline {
            if let q = try store.takePairingConfirmRequest(attemptID: pending.attemptID) {
                print("\n\(q.deviceName) wants to pair with this computer (key \(q.deviceID.prefix(16))…). Allow? [y/N] ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
                try store.setPairingDecision(attemptID: pending.attemptID, allow: answer == "y" || answer == "yes")
            }
            if let r = try store.takePairingResult(attemptID: pending.attemptID) {
                print(r.ok ? "✓ \(r.message)" : "✗ \(r.message)")
                throw ExitCode(r.ok ? 0 : 1)
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        store.remove("pending-pair.json")
        print("✗ timed out, code expired")
        throw ExitCode(1)
    }

    /// IPv4 addresses of this computer's up, non-loopback interfaces, LAN first.
    func localAddresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt16(AF_INET), i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  i.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let name = String(cString: i.pointee.ifa_name)
                let addr = String(cString: host)
                if name.hasPrefix("docker") || name.hasPrefix("br-") || name.hasPrefix("virbr") || name.hasPrefix("veth") { continue }
                if name.hasPrefix("tailscale") { out.append(addr) } else { out.insert(addr, at: 0) }
            }
        }
        return out
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List paired devices.")
    func run() throws {
        let list = try Store().authorizedDevices()
        if list.isEmpty { print("no paired devices"); return }
        let f = ISO8601DateFormatter()
        for d in list { print("\(d.id.prefix(12))  \(f.string(from: d.pairedAt))  \(d.name)") }
    }
}

struct Revoke: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a paired device by id prefix.")
    @Argument var idPrefix: String
    func run() throws {
        let removed = try Store().revoke(idPrefix: idPrefix)
        if removed.isEmpty { print("no device matches \(idPrefix)"); throw ExitCode(1) }
        for d in removed { print("revoked \(d.id.prefix(12)) \(d.name)") }
    }
}
