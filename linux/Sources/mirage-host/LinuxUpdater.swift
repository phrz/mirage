import Foundation
import MirageCore
import Crypto

/// Automatic updates of the system service (root): the Mac's signed-manifest scheme (ManifestVerifier) with the Linux
/// host's own key (LinuxTrustedKeys).
///
/// Every 6 hours (first a minute after start) it fetches `linux-<arch>.manifest.json` and its signatures from the
/// `linux-host` release. A manifest signed by a trusted key, for a newer build that was not rolled back before, names the
/// binary: downloaded beside the installed one, checked against the manifest's SHA-256 and size, and run once
/// (`version` must name the build and this processor). Once no viewer is streaming, it replaces /usr/local/bin/mirage-host (the old one kept
/// as mirage-host.previous) and the service exits for systemd to start the new build.
///
/// The new build is on trial until a viewer has streamed from it for a minute (or it has run a day): one that starts more
/// than 3 times before that puts the previous binary back, is never offered again, and exits for systemd to start the
/// previous one. A build that crashes as a viewer connects is so rolled back after the viewer's reconnects.
///
/// The state (`linux-update.json`) is read at a fixed path before anything else at start, so a build that fails early is
/// counted too; a lock file keeps the service and `mirage-host update` from installing at once.
///
/// A paired Mac's update arrow works too: the Welcome reports this build and the newest verified one (refreshed when a
/// viewer checks in, at most every 10 minutes), and an update or rollback request runs the same verified path at once.
///
/// `/var/lib/mirage/no-auto-update` turns the automatic install off; `sudo mirage-host update` checks now.
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

    let dir: URL
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var checking = false
    private var lockFD: Int32 = -1
    private var latest: MirageVersion?
    private var latestAt: Date?

    /// How builds show in the viewer: "Linux (602)".
    static func version(_ build: Int, _ commit: String) -> MirageVersion {
        MirageVersion(version: "Linux", build: build, commit: commit, channel: .stable)
    }
    static var current: MirageVersion { version(LinuxBuild.number, LinuxBuild.commit) }

    /// The newest build a verified manifest named, for the Welcome (nil: none newer known).
    var latestAvailable: MirageVersion? {
        lock.lock(); defer { lock.unlock() }
        guard let l = latest, l.build > LinuxBuild.number else { return nil }
        return l
    }

    init(dir: URL, log: @escaping @Sendable (String) -> Void) { self.dir = dir; self.log = log }

    private var stateURL: URL { dir.appendingPathComponent("linux-update.json") }
    private func loadState() -> State {
        guard let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: d) else { return State() }
        return s
    }
    private func save(_ s: State) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
    }
    var disabledPath: String { dir.appendingPathComponent("no-auto-update").path }
    var disabled: Bool { FileManager.default.fileExists(atPath: disabledPath) }

    /// One updater at a time across processes (the service, `mirage-host update`). False when another holds it.
    private func takeLock() -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(dir.appendingPathComponent("update.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        lock.lock(); lockFD = fd; lock.unlock()
        return true
    }
    private func dropLock() {
        lock.lock(); let fd = lockFD; lockFD = -1; lock.unlock()
        if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
    }

    // MARK: Trial (at the service's start, before anything else)

    /// Counts this start of a build on trial; rolls back (and exits) after too many.
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
                guard rename(Self.previous, Self.binary) == 0 else {
                    // The trial stays: the next start tries again.
                    log("update: cannot put \(Self.previous) back (\(String(cString: strerror(errno)))); still on build \(t.build)")
                    return
                }
                syncDirectory(Self.binary)
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
    }

    /// Ends this build's trial once a viewer has streamed for a minute without a break, or after a day up.
    func watchTrial(ctx: HostContext) {
        guard loadState().trial?.build == LinuxBuild.number else { return }
        Task.detached { [self] in
            let start = Date()
            var streamed = 0
            while loadState().trial?.build == LinuxBuild.number {
                try? await Task.sleep(for: .seconds(10))
                streamed = await ctx.connections.streamingDeviceIDs().isEmpty ? 0 : streamed + 10
                if streamed >= 60 || Date().timeIntervalSince(start) >= 86_400 {
                    var s = loadState(); s.trial = nil; save(s)
                    log("update: build \(LinuxBuild.number) stays")
                    return
                }
            }
        }
    }

    // MARK: Checking

    /// Checks every 6 hours, the first a minute after start; installs once nobody is streaming.
    func start(ctx: HostContext) {
        Task.detached { [self] in
            try? await Task.sleep(for: .seconds(60))
            while true {
                if !disabled {
                    do {
                        // Not while this build is still on trial: it is judged first.
                        if loadState().trial == nil, let staged = try await stage() {
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
        guard takeLock() else { log("update: another update is running"); return nil }
        var keepLock = false
        defer { if !keepLock { dropLock() } }
        let (m, manifestURL) = try verifiedManifest()
        guard m.build > LinuxBuild.number else { return nil }
        guard !loadState().refused.contains(m.build) else { return nil }
        guard let url = m.zipURL(relativeTo: manifestURL), url.scheme == "https" || Self.testFeed != nil else { throw MirageError.storage("manifest names no https binary") }
        log("update: build \(m.build) (\(m.commit)) is out; downloading")
        try? FileManager.default.removeItem(atPath: Self.staged)
        let bin = try fetch(url, maxBytes: 512 << 20)
        guard bin.count == m.zipSize else { throw MirageError.storage("downloaded \(bin.count) bytes, the manifest says \(m.zipSize)") }
        let sha = SHA256.hash(data: bin).map { String(format: "%02x", $0) }.joined()
        guard sha == m.zipSHA256.lowercased() else { throw MirageError.storage("the download's SHA-256 does not match the signed manifest") }
        try writeDurably(bin, to: Self.staged)
        let says = try run(Self.staged, ["version"], timeout: 20).trimmingCharacters(in: .whitespacesAndNewlines)
        guard says.contains("build \(m.build) "), says.hasSuffix(" \(Self.arch)") else {
            try? FileManager.default.removeItem(atPath: Self.staged)
            throw MirageError.storage("the new binary does not run here (it said: \(says.prefix(200)))")
        }
        log("update: build \(m.build) downloaded and checked")
        keepLock = true   // held until install
        return m.build
    }

    /// The feed's manifest for this processor, its signature verified; remembered as the newest build seen.
    private func verifiedManifest() throws -> (Manifest, URL) {
        let name = "linux-\(Self.arch).manifest"
        let manifestURL = Self.feed.appendingPathComponent("\(name).json")
        let data = try fetch(manifestURL, maxBytes: 64 << 10)
        let sigs = try fetch(Self.feed.appendingPathComponent("\(name).sigs.json"), maxBytes: 64 << 10)
        let verified = try ManifestVerifier.verify(manifest: data, signatures: sigs,
                                                   trust: ManifestTrust(compiled: LinuxTrustedKeys.compiled, learned: [], revoked: []),
                                                   channel: nil)
        let m = verified.manifest
        let refused = loadState().refused.contains(m.build)
        lock.lock(); latest = refused ? nil : Self.version(m.build, m.commit); latestAt = Date(); lock.unlock()
        return (m, manifestURL)
    }

    /// A viewer checked in: read the manifest again when the last read is over 10 minutes old (no download).
    func refreshSoon() {
        lock.lock()
        let due = latestAt.map { Date().timeIntervalSince($0) > 600 } ?? true
        if due { latestAt = Date() }
        lock.unlock()
        guard due else { return }
        Task.detached { [self] in
            do { _ = try verifiedManifest() } catch { log("update: \(error)") }
        }
    }

    /// An update or rollback a paired viewer asked for: progress to it, then the restart (the process exits).
    func handle(_ cmd: UpdateCommand, reply: @escaping @Sendable (ControlMessage.UpdateStatus) -> Void) async {
        let from = Self.current
        switch cmd {
        case .update(let target):
            reply(.init(phase: .checking, message: "Checking for a newer build…", from: from, yours: true))
            do {
                guard let build = try await stage() else {
                    let asked = target.map { $0 > LinuxBuild.number } ?? false
                    reply(.init(phase: .failed, message: asked ? "That build is not published yet" : "Already up to date (\(from.display))",
                                from: from, yours: true, notPublished: asked ? true : nil))
                    return
                }
                let to = Self.version(build, latestAvailable?.commit ?? "")
                reply(.init(phase: .installing, message: "Installing \(to.display)…", from: from, to: to, yours: true))
                reply(.init(phase: .restarting, message: "Restarting into \(to.display)…", from: from, to: to, yours: true))
                try? await Task.sleep(for: .milliseconds(500))   // the replies leave first
                install(build, restart: false)
            } catch {
                reply(.init(phase: .failed, message: "\(error)", from: from, yours: true))
            }
        case .rollback:
            guard FileManager.default.fileExists(atPath: Self.previous), takeLock() else {
                reply(.init(phase: .failed, message: "No earlier build to go back to", from: from, yours: true)); return
            }
            reply(.init(phase: .restarting, message: "Going back to the previous build…", from: from, yours: true))
            try? await Task.sleep(for: .milliseconds(500))
            guard rename(Self.previous, Self.binary) == 0 else {
                dropLock(); reply(.init(phase: .failed, message: "Cannot put the previous build back", from: from, yours: true)); return
            }
            syncDirectory(Self.binary)
            var s = loadState()
            s.trial = nil
            if !s.refused.contains(LinuxBuild.number) { s.refused.append(LinuxBuild.number) }
            save(s)
            log("update: rolled back from build \(LinuxBuild.number) at a viewer's request")
            exit(0)
        }
    }

    /// Puts the staged binary in place (the installed one kept as .previous) and starts it: the service exits for systemd
    /// (`restart` false), or `systemctl restart` (the `update` command, run beside the service).
    func install(_ build: Int, restart: Bool) {
        defer { dropLock() }
        var s = loadState()
        s.trial = .init(build: build, previous: LinuxBuild.number, starts: 0)
        _ = unlink(Self.previous)
        guard link(Self.binary, Self.previous) == 0 || !FileManager.default.fileExists(atPath: Self.binary) else {
            log("update: cannot keep the installed binary as \(Self.previous); not updating"); return
        }
        save(s)
        guard rename(Self.staged, Self.binary) == 0 else { log("update: cannot replace \(Self.binary)"); s.trial = nil; save(s); return }
        syncDirectory(Self.binary)
        log("update: installed build \(build); restarting into it")
        if restart { _ = try? run("/usr/bin/systemctl", ["restart", "mirage-host.service"], timeout: 30) }
        else { exit(0) }
    }

    // MARK: Helpers

    /// Written and flushed to disk before it is renamed into place (a power cut leaves the old binary, not an empty one).
    private func writeDurably(_ data: Data, to path: String) throws {
        _ = unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o755)
        guard fd >= 0 else { throw MirageError.storage("cannot write \(path)") }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard ok, fsync(fd) == 0 else { throw MirageError.storage("cannot write \(path)") }
    }

    private func syncDirectory(_ file: String) {
        let fd = open((file as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { fsync(fd); close(fd) }
    }

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
