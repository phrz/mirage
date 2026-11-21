import Foundation
import MirageCore
import Crypto

/// Automatic updates of the system service (root): the Mac's signed-manifest scheme (ManifestVerifier) with the Linux
/// host's own key (LinuxTrustedKeys).
///
/// Every 6 hours (first 5 minutes after start) it fetches `linux-<arch>.manifest.json` and its signatures from the
/// `linux-host` release. A manifest signed by a trusted key, for a newer build that was not rolled back before, names the
/// binary: downloaded beside the installed one, checked against the manifest's SHA-256 and size, and run once
/// (`version` must name the build). Once no viewer is streaming, it replaces /usr/local/bin/mirage-host (the old one kept
/// as mirage-host.previous) and the service exits for systemd to start the new build.
///
/// The new build is on trial: a build that starts more than 3 times without running 2 minutes puts the previous binary
/// back, is never offered again, and exits for systemd to start the previous one.
///
/// `/var/lib/mirage/no-auto-update` turns it off; `sudo mirage-host update` checks now.
final class LinuxUpdater: @unchecked Sendable {
    static let release = URL(string: "https://github.com/phrz/mirage/releases/download/linux-host/")!
    /// Tests: another feed (http allowed), from the service's environment, which only root sets.
    static let testFeed = ProcessInfo.processInfo.environment["MIRAGE_LINUX_FEED"].flatMap { URL(string: $0.hasSuffix("/") ? $0 : $0 + "/") }
    static var feed: URL { testFeed ?? release }
    static let binary = "/usr/local/bin/mirage-host"
    static var previous: String { binary + ".previous" }
    static var staged: String { (binary as NSString).deletingLastPathComponent + "/.mirage-host.new" }
    static var arch: String {
        #if arch(x86_64)
        return "x86_64"
        #else
        return "aarch64"
        #endif
    }

    struct State: Codable {
        struct Trial: Codable { var build: Int; var previous: Int; var starts: Int }
        var trial: Trial?
        /// Builds that failed their trial: never installed again.
        var refused: [Int] = []
    }

    let store: Store
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var checking = false

    init(store: Store, log: @escaping @Sendable (String) -> Void) { self.store = store; self.log = log }

    private var stateURL: URL { store.url("linux-update.json") }
    private func loadState() -> State {
        guard let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: d) else { return State() }
        return s
    }
    private func save(_ s: State) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
    }
    var disabled: Bool { FileManager.default.fileExists(atPath: store.url("no-auto-update").path) }

    // MARK: Trial (at the service's start, before anything else)

    /// Counts this start of a build on trial; rolls back (and exits) after too many. Ends the trial after 2 minutes up.
    func beginStart() {
        var s = loadState()
        guard var t = s.trial else { return }
        guard t.build == LinuxBuild.number else { s.trial = nil; save(s); return }   // put back by hand: no trial
        t.starts += 1
        s.trial = t
        save(s)
        if t.starts > 3 {
            log("update: build \(t.build) failed to stay up \(t.starts - 1) times; going back to build \(t.previous)")
            let fm = FileManager.default
            if fm.fileExists(atPath: Self.previous) {
                _ = rename(Self.previous, Self.binary)
                s.trial = nil
                if !s.refused.contains(t.build) { s.refused.append(t.build) }
                save(s)
                exit(1)   // systemd starts the previous build
            }
            log("update: no previous build to go back to; staying")
            s.trial = nil; save(s)
            return
        }
        log("update: build \(t.build) on trial (start \(t.starts) of 3)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [self] in
            var s = loadState()
            if s.trial?.build == LinuxBuild.number { s.trial = nil; save(s); log("update: build \(LinuxBuild.number) stays") }
        }
    }

    // MARK: Checking

    /// Checks every 6 hours, the first 5 minutes after start; installs once nobody is streaming.
    func start(ctx: HostContext) {
        Task.detached { [self] in
            try? await Task.sleep(for: .seconds(300))
            while true {
                if !disabled {
                    do {
                        if let staged = try await stage() {
                            while await !ctx.connections.streamingDeviceIDs().isEmpty { try? await Task.sleep(for: .seconds(60)) }
                            install(staged, restart: false)
                        }
                    } catch { log("update: \(error)") }
                }
                try? await Task.sleep(for: .seconds(6 * 3600 + Int.random(in: 0..<900)))
            }
        }
    }

    /// The newer build, downloaded and checked beside the installed binary, or nil when there is none.
    func stage() async throws -> Int? {
        lock.lock(); if checking { lock.unlock(); return nil }; checking = true; lock.unlock()
        defer { lock.lock(); checking = false; lock.unlock() }
        let name = "linux-\(Self.arch).manifest"
        let manifestURL = Self.feed.appendingPathComponent("\(name).json")
        let data = try fetch(manifestURL, maxBytes: 64 << 10)
        let sigs = try fetch(Self.feed.appendingPathComponent("\(name).sigs.json"), maxBytes: 64 << 10)
        let verified = try ManifestVerifier.verify(manifest: data, signatures: sigs,
                                                   trust: ManifestTrust(compiled: LinuxTrustedKeys.compiled, learned: [], revoked: []),
                                                   channel: nil)
        let m = verified.manifest
        guard m.build > LinuxBuild.number else { return nil }
        guard !loadState().refused.contains(m.build) else { return nil }
        guard let url = m.zipURL(relativeTo: manifestURL), url.scheme == "https" || Self.testFeed != nil else { throw MirageError.storage("manifest names no https binary") }
        log("update: build \(m.build) (\(m.commit)) is out; downloading")
        try? FileManager.default.removeItem(atPath: Self.staged)
        let bin = try fetch(url, maxBytes: 512 << 20)
        guard bin.count == m.zipSize else { throw MirageError.storage("downloaded \(bin.count) bytes, the manifest says \(m.zipSize)") }
        let sha = SHA256.hash(data: bin).map { String(format: "%02x", $0) }.joined()
        guard sha == m.zipSHA256.lowercased() else { throw MirageError.storage("the download's SHA-256 does not match the signed manifest") }
        guard FileManager.default.createFile(atPath: Self.staged, contents: bin, attributes: [.posixPermissions: 0o755]) else {
            throw MirageError.storage("cannot write \(Self.staged)")
        }
        let says = try run(Self.staged, ["version"], timeout: 20)
        guard says.contains("build \(m.build) ") else {
            try? FileManager.default.removeItem(atPath: Self.staged)
            throw MirageError.storage("the new binary does not run here (it said: \(says.prefix(200)))")
        }
        log("update: build \(m.build) downloaded and checked")
        return m.build
    }

    /// Puts the staged binary in place (the installed one kept as .previous) and starts it: the service exits for systemd
    /// (`restart` false), or `systemctl restart` (the `update` command, run beside the service).
    func install(_ build: Int, restart: Bool) {
        var s = loadState()
        s.trial = .init(build: build, previous: LinuxBuild.number, starts: 0)
        _ = unlink(Self.previous)
        guard link(Self.binary, Self.previous) == 0 || !FileManager.default.fileExists(atPath: Self.binary) else {
            log("update: cannot keep the installed binary as \(Self.previous); not updating"); return
        }
        save(s)
        guard rename(Self.staged, Self.binary) == 0 else { log("update: cannot replace \(Self.binary)"); s.trial = nil; save(s); return }
        log("update: installed build \(build); restarting into it")
        if restart { _ = try? run("/usr/bin/systemctl", ["restart", "mirage-host.service"], timeout: 30) }
        else { exit(0) }
    }

    // MARK: Helpers

    private func fetch(_ url: URL, maxBytes: Int) throws -> Data {
        let out = try run("/usr/bin/env", ["curl", "-fsSL", "--proto", Self.testFeed == nil ? "=https" : "=https,http", "--max-time", "600", "--max-filesize", "\(maxBytes)", url.absoluteString],
                          timeout: 660, binary: true)
        return out
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String], timeout: TimeInterval) throws -> String {
        String(decoding: try run(tool, args, timeout: timeout, binary: true), as: UTF8.self)
    }

    private func run(_ tool: String, _ args: [String], timeout: TimeInterval, binary: Bool) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw MirageError.transport("\((args.first == "curl" ? args.last : nil) ?? tool) failed: \(e.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }
}
