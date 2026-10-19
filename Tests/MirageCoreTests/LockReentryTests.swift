import XCTest

/// Deadlock regression (fc43def: the viewer's video queue hung because `apply` called `displayRect`, which takes
/// `predictorLock`, while holding `predictorLock`). This test reads the viewer's and the host's sources and fails if any
/// region that holds one of their locks calls a member that takes the same lock. A region is from `X.lock()` to the
/// matching `X.unlock()`, or to the end of the function for `defer { X.unlock() }`.
final class LockReentryTests: XCTestCase {
    private func sources(_ dir: String) -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/\(dir)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return files.filter { $0.hasSuffix(".swift") }.compactMap { f in (try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)).map { (f, $0) } }
    }

    struct Member { var name: String; var body: String; var file: String; var isFunc: Bool }

    /// Top-level-ish members (func / computed var with a body), brace-matched, string literals ignored for braces.
    private func members(_ src: String, file: String) -> [Member] {
        var out: [Member] = []
        let chars = Array(src)
        let header = try! NSRegularExpression(pattern: #"(?:func\s+([A-Za-z_]\w*)[^{]*|var\s+([A-Za-z_]\w*)\s*:[^={]*)\{"#)
        let ns = src as NSString
        for m in header.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
            let nameRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let name = ns.substring(with: nameRange)
            var i = m.range.location + m.range.length   // just after "{"
            var depth = 1, inString = false
            let start = i
            while i < chars.count, depth > 0 {
                let c = chars[i]
                if c == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
                if !inString { if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } }
                i += 1
            }
            out.append(Member(name: name, body: String(chars[start..<max(start, i - 1)]), file: file, isFunc: m.range(at: 1).location != NSNotFound))
        }
        return out
    }

    private func violations(in dir: String, locks: [String]) -> [String] {
        let all = sources(dir).flatMap { members($0.1, file: $0.0) }
        var found: [String] = []
        for lock in locks {
            let takers = all.filter { $0.body.contains("\(lock).lock()") }
            let stored = storedNames(dir)
            for m in all where m.body.contains("\(lock).lock()") {
                let body = m.body
                var regions: [Substring] = []
                var rest = Substring(body)
                while let r = rest.range(of: "\(lock).lock()") {
                    let after = rest[r.upperBound...]
                    if after.prefix(40).contains("defer { \(lock).unlock() }") { regions.append(after); break }
                    if let u = after.range(of: "\(lock).unlock()") { regions.append(after[..<u.lowerBound]); rest = after[u.upperBound...] } else { regions.append(after); break }
                }
                for region in regions {
                    for t in takers where t.name != m.name && isUse(region, t, stored: stored) {
                        found.append("\(m.file): \(m.name) holds \(lock) and uses \(t.name), which takes it again")
                    }
                }
            }
        }
        return found
    }
    /// Stored properties (a stored `localRaise` next to a `func localRaise` is not a call).
    private func storedNames(_ dir: String) -> Set<String> {
        let re = try! NSRegularExpression(pattern: #"(?:var|let)\s+(?:\(?)([A-Za-z_]\w*)\s*(?::[^{=\n]*)?(?:=|\n|$)"#, options: [.anchorsMatchLines])
        var out = Set<String>()
        for (_, src) in sources(dir) { let ns = src as NSString; for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) { out.insert(ns.substring(with: m.range(at: 1))) } }
        return out
    }
    /// A call of a function member (unqualified or through `self.`), or a read of a computed property.
    private func isUse(_ region: Substring, _ t: Member, stored: Set<String> = []) -> Bool {
        if t.isFunc { return region.range(of: #"(?<![\w.])(?:self\.)?"# + t.name + #"\s*\("#, options: .regularExpression) != nil
            || region.range(of: #"self\."# + t.name + #"\s*\("#, options: .regularExpression) != nil }
        guard !stored.contains(t.name) else { return false }
        return region.range(of: #"(?<![\w.])(?:self\.)?"# + t.name + #"(?![\w(:])(?!\s*=[^=])"#, options: .regularExpression) != nil
    }

    func testNoLockIsTakenAgainWhileHeldInTheViewer() {
        let v = violations(in: "mirage-viewer", locks: ["predictorLock", "statsLock", "desktopLock"])
        XCTAssertEqual(v, [], v.joined(separator: "\n"))
    }

    func testNoLockIsTakenAgainWhileHeldInTheHostAndCore() {
        let h = violations(in: "MirageHost", locks: ["scrollLock", "inputReceiverLock", "seqLock", "locusLock", "cacheLock", "liveLock", "filterLock", "fingerprintLock", "frameSeqLock"])
        XCTAssertEqual(h, [], h.joined(separator: "\n"))
    }

    func testTheCheckCatchesTheFc43defDeadlock() {
        // The exact shape of the bug: a region holding the lock calls a member that takes it.
        let src = """
        func displayRect(_ r: Int) -> Int { predictorLock.lock(); defer { predictorLock.unlock() }; return r }
        func apply() {
            predictorLock.lock()
            for t in tiles { landed(displayRect(t)) }
            predictorLock.unlock()
        }
        """
        let all = members(src, file: "x")
        XCTAssertEqual(all.map(\.name).sorted(), ["apply", "displayRect"])
        let taker = all.first { $0.name == "displayRect" }!
        let apply = all.first { $0.name == "apply" }!
        let region = apply.body[apply.body.range(of: "predictorLock.lock()")!.upperBound...]
        XCTAssertTrue(taker.body.contains("predictorLock.lock()") && isUse(region, taker))
        XCTAssertFalse(isUse("list.displayRect(1)", taker), "a method of another value is not this member")
    }
}
