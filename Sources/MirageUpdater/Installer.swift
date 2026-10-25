import Foundation
import CryptoKit
import MirageCore

/// Where an update works (DESIGN §3.10): the installed bundle, and the host's Application Support directory (the Store's
/// root: MIRAGE_TEST_STORE moves all of it for a test).
public struct InstallPaths: Sendable {
    /// The installed bundle the swap replaces (/Applications/Mirage.app).
    public var app: URL
    /// ~/Library/Application Support/Mirage.
    public var support: URL

    public init(app: URL, support: URL) { self.app = app.standardizedFileURL; self.support = support.standardizedFileURL }

    public var updates: URL { support.appendingPathComponent("Updates", isDirectory: true) }
    /// Exactly one previous bundle, outside /Applications so Launch Services and Spotlight list one Mirage.
    public var previous: URL { support.appendingPathComponent("Previous/Mirage.app", isDirectory: true) }
    public var pending: URL { support.appendingPathComponent("pending-update.json") }
    public var result: URL { support.appendingPathComponent("update-result.json") }
    public var settings: URL { support.appendingPathComponent("updates.json") }
    public var lock: URL { updates.appendingPathComponent(".lock") }
    public func staging(_ build: Int) -> URL { updates.appendingPathComponent("\(build)", isDirectory: true) }

    /// The bundle this executable runs from, when it is an installed Mirage.app; else /Applications/Mirage.app (a bare
    /// binary, or the copy in Previous/ that rollback-host.sh runs).
    public static func installedApp(executable: URL = Bundle.main.bundleURL, support: URL) -> URL {
        let b = executable.standardizedFileURL
        if b.pathExtension == "app", !b.path.hasPrefix(support.standardizedFileURL.path + "/") { return b }
        return URL(fileURLWithPath: "/Applications/Mirage.app", isDirectory: true)
    }
}

/// The file operations of an update: download, extract, stage, the atomic swap and its rollback. No policy here: the
/// Updater decides, and `UpdateHealth` says when to roll back.
public struct Installer: Sendable {
    public var paths: InstallPaths
    public init(paths: InstallPaths) { self.paths = paths }

    static let fm = FileManager.default

    // MARK: Download and extract (verification steps 1 and 2)

    /// Downloads the zip into Updates/<build>/ and checks its size and SHA-256 against the signed manifest.
    public func download(_ m: Manifest, manifestURL: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let url = m.zipURL(relativeTo: manifestURL) else { throw UpdateError.download("bad zip URL \(m.zipURL)") }
        let dir = paths.staging(m.build)
        try? Self.fm.removeItem(at: dir)
        try Self.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Mirage.zip")
        if url.isFileURL {
            try Self.fm.copyItem(at: url, to: dest)
        } else {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 120)
            req.setValue("Mirage-Updater", forHTTPHeaderField: "User-Agent")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw UpdateError.download("HTTP \(h.statusCode) for \(url.lastPathComponent)") }
            try Self.fm.moveItem(at: tmp, to: dest)
        }
        progress(1)
        try Self.checkDigest(dest, size: m.zipSize, sha256: m.zipSHA256)
        return dest
    }

    public static func checkDigest(_ file: URL, size: Int, sha256: String) throws {
        let attrs = try fm.attributesOfItem(atPath: file.path)
        let actual = (attrs[.size] as? NSNumber)?.intValue ?? -1
        guard actual == size else { throw UpdateError.verification("the zip is \(actual) bytes, the manifest says \(size)") }
        let h = FileHandle(forReadingAtPath: file.path)!
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == sha256.lowercased() else { throw UpdateError.verification("the zip's SHA-256 is \(hex.prefix(16))…, the manifest says \(sha256.prefix(16))…") }
    }

    /// `ditto -x -k` beside the zip; the one Mirage.app in it.
    public func extract(_ zip: URL) throws -> URL {
        let dir = zip.deletingLastPathComponent()
        let out = SystemBundleVerifier.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, dir.path], timeout: 120)
        guard out.1 == 0 else { throw UpdateError.install("ditto -x failed: \(out.0)") }
        let app = dir.appendingPathComponent("Mirage.app", isDirectory: true)
        guard Self.fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            throw UpdateError.install("the zip holds no Mirage.app")
        }
        try? Self.fm.removeItem(at: zip)
        return app
    }

    /// The version a bundle's Info.plist states.
    public static func version(of app: URL) -> MirageVersion? {
        guard let d = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return nil }
        return MirageVersion.from(infoDictionary: d)
    }

    // MARK: Swap

    static func device(_ url: URL) -> dev_t? {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_dev : nil
    }

    /// The verified bundle on the installed bundle's volume, so the swap is one rename: the normal case (~/Library and
    /// /Applications share the Data volume); else copied to `<dir>/.Mirage-staged.app` first.
    public func stageOnAppVolume(_ verified: URL) throws -> URL {
        let dir = paths.app.deletingLastPathComponent()
        if let a = Self.device(verified.deletingLastPathComponent()), let b = Self.device(dir), a == b { return verified }
        let staged = dir.appendingPathComponent(".Mirage-staged.app", isDirectory: true)
        try? Self.fm.removeItem(at: staged)
        let out = SystemBundleVerifier.run(URL(fileURLWithPath: "/usr/bin/ditto"), [verified.path, staged.path], timeout: 300)
        guard out.1 == 0 else { throw UpdateError.install("copying to \(dir.path) failed: \(out.0)") }
        return staged
    }

    /// `renamex_np(a, b, RENAME_SWAP)`: one atomic APFS swap, with no instant at which either path is missing.
    public static func swap(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.install("swapping \(a.path) and \(b.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Installs `staged` at the app path: the swap, then the old bundle (now at the staged path) becomes the one kept
    /// previous bundle. Running processes keep their mapped old code.
    public func swapIn(_ staged: URL) throws {
        try Self.swap(staged, paths.app)
        try Self.fm.createDirectory(at: paths.previous.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.fm.removeItem(at: paths.previous)
        do { try Self.fm.moveItem(at: staged, to: paths.previous) }
        catch { try? Self.fm.removeItem(at: staged) }   // the update stands; only the way back is lost
    }

    /// Swaps the previous bundle back in. `keepReplaced`: the replaced build stays as the previous one (a manual rollback);
    /// else it is deleted (a failed build).
    public func rollBack(keepReplaced: Bool) throws {
        guard Self.fm.fileExists(atPath: paths.previous.appendingPathComponent("Contents/Info.plist").path) else {
            throw UpdateError.install("no previous bundle at \(paths.previous.path)")
        }
        try Self.swap(paths.previous, paths.app)
        if !keepReplaced { try? Self.fm.removeItem(at: paths.previous) }
    }

    // MARK: State files

    public func readPending() -> PendingUpdate? { Self.read(PendingUpdate.self, paths.pending) }
    public func writePending(_ p: PendingUpdate) throws { try Self.write(p, paths.pending) }
    public func clearPending() { try? Self.fm.removeItem(at: paths.pending) }
    public func readResult() -> UpdateResult? { Self.read(UpdateResult.self, paths.result) }
    public func writeResult(_ r: UpdateResult) throws { try Self.write(r, paths.result) }

    static func read<T: Decodable>(_ t: T.Type, _ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(t, from: d)
    }
    static func write<T: Encodable>(_ v: T, _ url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(v).write(to: url, options: .atomic)
    }

    /// One update at a time, across processes (`miraged update` over SSH and the host agent): an exclusive lock held for
    /// the life of the returned descriptor.
    public func lock() throws -> Int32 {
        try Self.fm.createDirectory(at: paths.updates, withIntermediateDirectories: true)
        let fd = open(paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw UpdateError.install("cannot open \(paths.lock.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw UpdateError.busy }
        return fd
    }
}
