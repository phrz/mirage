import Foundation
import ArgumentParser
import MirageCore

@main
struct MirageCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirage",
        abstract: "Mirage client.",
        subcommands: [Connect.self, Hosts.self],
        defaultSubcommand: Connect.self)
}

struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Connect to a host; with --pair, pair first.")
    @Argument(help: "Host name or address (tailnet MagicDNS name works).") var host: String
    @Option(name: .shortAndLong) var port: UInt16 = Mirage.defaultPort
    @Option(help: "6-digit code shown by `miraged pair` on the host.") var pair: String?
    @Option(help: "Name this device presents to hosts (default: this device's computer name).") var name: String?
    @Option(help: "Ping interval in milliseconds.") var interval: Int = 250
    @Option(help: "Datagram ping payload size in bytes.") var datagramSize: Int = 64
    @Flag(help: "Exit after the handshake instead of streaming pings.") var once = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = try Store()
        let identity = try store.identity(role: "client", name: name ?? DeviceNames.current())
        let client = QUICClient(host: host, port: port)
        let t0 = Clock.nowNanos()
        try await client.connect()
        guard let fp = client.tlsFingerprint else { throw MirageError.transport("no TLS fingerprint captured") }
        let control = try await client.openStream()
        let connectMs = Double(Clock.nowNanos() - t0) / 1e6
        print(String(format: "connected to %@ (QUIC handshake %.0f ms, tls %@…)", host, connectMs, fp.prefix(6).map { String(format: "%02x", $0) }.joined()))

        let session = ClientSession(identity: identity, store: store, alias: host, tlsFingerprint: fp, stream: control)
        if let pair {
            guard let code = PairingCode.normalize(pair) else { throw ValidationError("--pair needs 6 digits") }
            let hostRecord = try await session.pair(code: code)
            print("✓ paired with \(hostRecord.name) (\(hostRecord.id.prefix(12))); this device is \(identity.name) (\(identity.id.prefix(12)))")
        }
        let t1 = Clock.nowNanos()
        let welcome = try await session.authenticate()
        print(String(format: "✓ authenticated to %@ (session %@, auth round trips %.0f ms)", welcome.hostName, String(welcome.sessionID.prefix(8)), Double(Clock.nowNanos() - t1) / 1e6))
        if once { client.close(); return }

        // Datagram flow: unreliable echo for loss + RTT without retransmission effects.
        let flow = try? await client.openDatagramFlow()
        if flow == nil { print("(datagram flow unavailable; stream pings only)") }

        let statsBox = StatsBox()
        if let flow {
            Task.detached {
                while true {
                    guard let d = try? await flow.receiveSome(), let (seq, sent, _) = DatagramPing.decode(d) else { break }
                    _ = seq
                    await statsBox.recordDatagram(rtt: Double(Clock.nowNanos() - sent) / 1e6)
                }
            }
        }
        var seq: UInt64 = 0
        print("streaming pings every \(interval) ms; ctrl-c to stop\n")
        while true {
            seq += 1
            if let flow {
                await statsBox.datagramSent()
                try? await flow.sendRaw(DatagramPing.encode(seq: seq, size: datagramSize))
            }
            await statsBox.streamSent()
            let rtt = try await session.ping(seq: seq)
            await statsBox.recordStream(rtt: rtt)
            let (s, d) = await statsBox.snapshot()
            var out = "\u{1B}[2A\u{1B}[2K  stream   \(s.sparkline()) \(s.summaryLine())\n"
            out += "\u{1B}[2K  datagram \(d.sparkline()) \(d.summaryLine())\n"
            FileHandle.standardOutput.write(Data(out.utf8))
            try await Task.sleep(for: .milliseconds(interval))
        }
    }
}

actor StatsBox {
    var stream = RTTStats(), datagram = RTTStats()
    func streamSent() { stream.recordSent() }
    func datagramSent() { datagram.recordSent() }
    func recordStream(rtt: Double) { stream.record(rttMillis: rtt) }
    func recordDatagram(rtt: Double) { datagram.record(rttMillis: rtt) }
    func snapshot() -> (RTTStats, RTTStats) { (stream, datagram) }
}

struct Hosts: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List paired hosts.")
    func run() throws {
        let hosts = try Store().knownHosts()
        if hosts.isEmpty { print("no paired hosts"); return }
        for (alias, h) in hosts.sorted(by: { $0.key < $1.key }) { print("\(alias)  \(h.hostID.prefix(12))  \(h.hostName)") }
    }
}
