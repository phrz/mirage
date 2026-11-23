import Foundation
import ArgumentParser
import MirageCore
import CMirageDesktop

/// Dynamic Resolution for a signed-in GNOME desktop: a Mutter virtual monitor the size of the viewer's window, at its
/// pixels per point (scale 2 for a Retina viewer), rendered by GNOME's own GPU and captured from its screen cast; while it
/// exists it is the only monitor on (the real ones go dark, and their windows move onto it), so the viewer sees the whole
/// desktop one to one and GNOME stops drawing for a screen nobody watches. The layout before comes back when the stream
/// ends or the viewer turns it off.
///
/// Why not the monitor's own modes (DisplayFitter): a server's BMC display has a few fixed modes at one pixel per point, and
/// reading it back goes through the CPU. The fitter stays the way for the login and lock screens (GNOME makes no
/// remote-desktop session there) and for desktops other than GNOME.
///
/// A helper process (`mirage-host virtual-display`, run as the desktop's user: the session bus is theirs) owns the GNOME
/// session, so the monitor goes when the helper does: when the stream lets it go, when this host exits or crashes (the
/// helper reads its socket to the end), and when GNOME ends the session itself (the screen locked). It hands over its
/// PipeWire connection, and this process reads the frames.
///
/// One for the process, as DisplayFitter: the first streamer that asks owns it, and every streamer shows it while it exists
/// (it is then the whole desktop).
final class VirtualScreen: @unchecked Sendable {
    static let shared = VirtualScreen()
    /// On unless MIRAGE_VIRTUAL_DISPLAY=0; =force uses this process's own session where loginctl shows no signed-in
    /// desktop on the screen (a headless GNOME Shell, for tests).
    static var enabled: Bool { ProcessInfo.processInfo.environment["MIRAGE_VIRTUAL_DISPLAY"] != "0" }
    static func desktop() -> SessionUser? {
        if let u = SessionUser.desktop() { return u }
        guard ProcessInfo.processInfo.environment["MIRAGE_VIRTUAL_DISPLAY"] == "force", geteuid() != 0 else { return nil }
        return SessionUser(name: NSUserName(), uid: geteuid())
    }

    var log: @Sendable (String) -> Void = { _ in }
    /// Once one is gone and the layout is back, with when it started going (GnomeSession opens its session again: the
    /// one it had may show the virtual monitor).
    var removed: (@Sendable (Date) -> Void)?
    private let lock = NSLock()
    private var current: OpaquePointer?
    private var helper: Process?
    private var currentFit: ControlMessage.FitDisplay?
    /// Stopped ones still read by a streamer, freed once none is.
    private var users: [OpaquePointer: Int] = [:]
    private var retired: Set<OpaquePointer> = []
    private var owner: ObjectIdentifier?
    private var wanted: ControlMessage.FitDisplay?
    private var lastFailure: (reason: String, at: Date)?
    private let queue = DispatchQueue(label: "mirage-virtual-display")
    private var watching = false

    /// Makes the desktop fit `owner`'s window (nil: puts it back), in the order asked, without waiting for GNOME. Falls
    /// back to the monitor's own modes where a virtual monitor cannot be made.
    func request(_ fit: ControlMessage.FitDisplay?, owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        queue.async { self.apply(fit, owner: id) }
        startWatching()
    }

    /// The virtual monitor while there is one (counted as used until `release`).
    func acquire() -> DesktopLease? {
        lock.lock(); defer { lock.unlock() }
        guard let v = current, md_picture_ended(md_virtual_picture(v)) == 0 else { return nil }
        users[v, default: 0] += 1
        // The scale goes with the picture only once the picture has the size GNOME gave it (frames of the size before
        // still come for a moment after a change, and the new size can come before GNOME says the new scale): nil between.
        let pic = md_virtual_picture(v)!
        return DesktopLease(picture: pic, input: VirtualInputBackend(v), token: v, scale: {
            var lw: Int32 = 0, lh: Int32 = 0, s: Double = 1, pw: Int32 = 0, ph: Int32 = 0
            md_virtual_geometry(v, &lw, &lh, &s)
            md_picture_size(pic, &pw, &ph)
            return s > 0 && abs(Double(lw) * s - Double(pw)) < 2 && abs(Double(lh) * s - Double(ph)) < 2 ? s : nil
        })
    }

    func release(_ lease: DesktopLease) {
        guard let v = lease.token else { return }
        lock.lock()
        let n = (users[v] ?? 1) - 1
        users[v] = n > 0 ? n : nil
        let free = n <= 0 && retired.contains(v)
        if free { retired.remove(v) }
        lock.unlock()
        if free { md_virtual_free(v) }
    }

    /// Whether one is showing now.
    var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return current.map { md_picture_ended(md_virtual_picture($0)) == 0 } ?? false
    }

    /// Ends it now (the service is stopping).
    func stopNow() { queue.sync { teardown() } }

    private func apply(_ fit: ControlMessage.FitDisplay?, owner id: ObjectIdentifier) {
        if let o = owner, o != id { return }   // another viewer's window sets the size
        guard let fit else {
            wanted = nil; owner = nil; lastFailure = nil
            teardown()
            DisplayFitter.shared.apply(nil, ownerID: id)
            return
        }
        owner = id
        wanted = fit
        show(fit, ownerID: id)
    }

    /// The virtual monitor for `fit` (made, or resized), else the monitor's own modes.
    private func show(_ fit: ControlMessage.FitDisplay, ownerID id: ObjectIdentifier) {
        let (w, h, scale) = Self.pixels(fit)
        if let v = live() {
            guard fit != currentFit else { return }
            var err = [CChar](repeating: 0, count: 512)
            let start = Date()
            if md_virtual_resize(v, Int32(w), Int32(h), scale, &err, err.count) == 0 {
                currentFit = fit
                log("display: virtual monitor now \(describe(v, w, h)) for a \(fit.width)x\(fit.height) window (\(ms(since: start)) ms)")
                return
            }
            log("display: virtual monitor not resized: \(String(cString: err))")
            teardown()
        }
        guard Self.enabled, let user = Self.desktop() else { DisplayFitter.shared.apply(fit, ownerID: id); return }
        // A recent failure is not tried again at once (the watch tries again later).
        if let f = lastFailure, Date().timeIntervalSince(f.at) < 20 { DisplayFitter.shared.apply(fit, ownerID: id); return }
        // The real monitor's own mode back first: the virtual one's layout is made from the layout it finds.
        DisplayFitter.shared.apply(nil, ownerID: id)
        let start = Date()
        switch open(user: user, width: w, height: h, scale: scale) {
        case .success(let (v, p)):
            lock.lock(); current = v; helper = p; currentFit = fit; lock.unlock()
            lastFailure = nil
            log("display: virtual monitor \(describe(v, w, h)) for a \(fit.width)x\(fit.height) window (\(ms(since: start)) ms)")
        case .failure(let e):
            let reason = "\(e)"
            if lastFailure?.reason != reason { log("display: no virtual monitor (\(reason)); using the monitor's own modes") }
            lastFailure = (reason, Date())
            DisplayFitter.shared.apply(fit, ownerID: id)
        }
    }

    /// The window's points at the viewer's pixels per point: 2 for a Retina viewer, else 1 (GNOME's fractional scales
    /// blur), in even pixels.
    static func pixels(_ fit: ControlMessage.FitDisplay) -> (Int, Int, Double) {
        let scale: Double = fit.scale >= 1.5 ? 2 : 1
        let w = min(max(Int((Double(fit.width) * scale).rounded()), 640), 8192) & ~1
        let h = min(max(Int((Double(fit.height) * scale).rounded()), 480), 8192) & ~1
        return (w, h, scale)
    }

    private func describe(_ v: OpaquePointer, _ w: Int, _ h: Int) -> String {
        var lw: Int32 = 0, lh: Int32 = 0, s: Double = 1
        md_virtual_geometry(v, &lw, &lh, &s)
        return "\(w)x\(h) pixels, \(lw)x\(lh) at scale \(s == s.rounded() ? String(Int(s)) : String(s))"
    }

    private func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }

    /// The current one unless GNOME ended it (then it is put away).
    private func live() -> OpaquePointer? {
        lock.lock(); let v = current; lock.unlock()
        guard let v else { return nil }
        if md_picture_ended(md_virtual_picture(v)) != 0 { teardown(); return nil }
        return v
    }

    private func teardown() {
        lock.lock()
        let v = current, p = helper
        current = nil; helper = nil; currentFit = nil
        lock.unlock()
        guard let v else { return }
        let start = Date()
        defer { removed?(start) }
        md_virtual_stop(v)   // the helper quits: the monitor goes and the layout comes back
        if let p {
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning, Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate() }
        }
        lock.lock()
        let free = users[v] == nil
        if !free { retired.insert(v) }
        lock.unlock()
        if free { md_virtual_free(v) }
        log("display: virtual monitor removed")
    }

    /// Every 2 s while a viewer asks: a virtual monitor GNOME ended (the screen locked) gives way to the real monitor's
    /// modes, and comes back once the desktop is unlocked.
    private func startWatching() {
        lock.lock(); let start = !watching; watching = true; lock.unlock()
        guard start else { return }
        let t = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 2)
                queue.sync {
                    guard let fit = wanted, let id = owner else { return }
                    lock.lock(); let v = current; lock.unlock()
                    if let v, md_picture_ended(md_virtual_picture(v)) != 0 {
                        log("display: GNOME ended the virtual monitor")
                        teardown()
                        DisplayFitter.shared.apply(fit, ownerID: id)
                    } else if v == nil, Self.desktop() != nil {
                        show(fit, ownerID: id)
                    }
                }
            }
        }
        t.name = "mirage-virtual-display"
        t.start()
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The helper started as the desktop's user (directly when this process is that user), and its monitor opened.
    private func open(user: SessionUser, width: Int, height: Int, scale: Double) -> Result<(OpaquePointer, Process), Failure> {
        Self.open(user: user, width: width, height: height, scale: scale, cursorMetadata: false)
    }

    static func open(user: SessionUser?, width: Int, height: Int, scale: Double, cursorMetadata: Bool) -> Result<(OpaquePointer, Process), Failure> {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &fds) == 0 else {
            return .failure(Failure(description: "socketpair: \(String(cString: strerror(errno)))"))
        }
        let p = Process()
        let args = ["virtual-display"] + (cursorMetadata ? ["--cursor-metadata"] : [])
        if let user, geteuid() != user.uid {
            // setpriv, not runuser: no PAM session (and its journal lines) for each change.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/setpriv")
            p.arguments = ["--reuid=\(user.uid)", "--regid=\(user.gid)", "--init-groups", "--", "/usr/bin/env",
                           "HOME=\(user.home)", "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\(user.uid)/bus",
                           "XDG_RUNTIME_DIR=/run/user/\(user.uid)", helperBinary] + args
        } else {
            p.executableURL = URL(fileURLWithPath: helperBinary)
            p.arguments = args
        }
        let end = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        p.standardInput = end
        p.standardOutput = end
        do { try p.run() } catch {
            close(fds[0]); close(fds[1])
            return .failure(Failure(description: "cannot start the helper: \(error)"))
        }
        close(fds[1])
        var err = [CChar](repeating: 0, count: 512)
        guard let v = md_virtual_open(fds[0], Int32(width), Int32(height), scale, cursorMetadata ? 1 : 0, &err, err.count) else {
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning, Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate() }
            return .failure(Failure(description: String(cString: err)))
        }
        return .success((v, p))
    }

    /// The system service's installed binary (as DisplayFitter runs it: one the desktop's user can run); as a user, this
    /// binary, unless an update replaced it while it runs.
    static var helperBinary: String {
        guard geteuid() != 0 else { return LinuxUpdater.binary }
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? ""
        return path.isEmpty || path.hasSuffix(" (deleted)") ? LinuxUpdater.binary : path
    }
}

/// Input to the virtual monitor, through the helper's GNOME session.
final class VirtualInputBackend: InputBackend, @unchecked Sendable {
    let display: OpaquePointer
    init(_ display: OpaquePointer) { self.display = display }
    func move(_ x: Double, _ y: Double) { md_virtual_pointer_move(display, min(max(x, 0), 1), min(max(y, 0), 1)) }
    func button(_ evdev: Int32, _ down: Bool) { md_virtual_pointer_button(display, evdev, down ? 1 : 0) }
    func scroll(dx: Double, dy: Double, precise: Bool) {
        if precise { md_virtual_pointer_axis(display, dx, dy, 1); return }
        let v = Int32(dy.rounded()), hz = Int32(dx.rounded())
        if v != 0 { md_virtual_pointer_axis_discrete(display, 0, v) }
        if hz != 0 { md_virtual_pointer_axis_discrete(display, 1, hz) }
    }
    func key(_ evdev: UInt32, _ down: Bool) { md_virtual_key(display, evdev, down ? 1 : 0) }
    func keysym(_ sym: UInt32, _ down: Bool) { md_virtual_keysym(display, sym, down ? 1 : 0) }
}

struct VirtualDisplayHelper: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "virtual-display",
                                                    abstract: "Keep a GNOME virtual monitor for Dynamic Resolution (run by the host).",
                                                    shouldDisplay: false)
    @Flag(help: "Send the pointer as metadata instead of drawing it in.") var cursorMetadata = false
    func run() throws {
        // Standard input and output are the host's socket: nothing else may write to them. A stop of the service signals
        // the helper too; it goes when the host lets it go or exits (its socket closes), after putting the layout back.
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN)
        throw ExitCode(md_virtual_helper(0, cursorMetadata ? 1 : 0))
    }
}

/// A stream as a viewer would ask for it, with Dynamic Resolution, through the streamer (no viewer, no pairing): what
/// reaches the viewer (stream info, frames) as the window is made, resized and the option turned off.
struct StreamTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stream-test",
                                                    abstract: "As the desktop's user: stream with Dynamic Resolution to nowhere and report.",
                                                    shouldDisplay: false)
    @Option(help: "Seconds per step.") var seconds = 6.0

    final class Output: StreamOutput, @unchecked Sendable {
        let lock = NSLock()
        var datagrams = 0, bytes = 0
        var infos: [(Date, ControlMessage.StreamInfo)] = []
        func sendDatagram(_ data: Data) { lock.lock(); datagrams += 1; bytes += data.count; lock.unlock() }
        func sendControl(_ message: ControlMessage) {
            if case .streamInfo(let i) = message {
                lock.lock(); infos.append((Date(), i)); lock.unlock()
                print("  → stream info: \(i.width)x\(i.height) pixels, display \(i.displayWidth)x\(i.displayHeight) points at scale \(i.displayScale)")
            }
        }
        func sendTiles(_ data: Data, fast: Bool) {}
        var maxDatagramSize: Int { 1200 }
    }

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let gnome = GnomeSession()
        gnome.start(log: { print("host: \($0)") })
        VirtualScreen.shared.removed = { gnome.renew(openedBefore: $0) }
        let streamer = LinuxStreamer(source: gnome, log: { print("host: \($0)") })
        let out = Output()
        var req = ControlMessage.StreamRequest(width: 2560, height: 2716, maxFPS: 60)
        req.fitDisplay = .init(width: 1280, height: 1358, scale: 2)
        let info = try await streamer.start(req, output: out)
        print("start: \(info.width)x\(info.height) at scale \(info.displayScale)")
        await step(streamer, out, "window 1280x1358 points at 2x")
        req.fitDisplay = .init(width: 1440, height: 900, scale: 2)
        _ = try await streamer.update(req)
        await step(streamer, out, "resized to 1440x900 points at 2x")
        req.fitDisplay = .init(width: 1600, height: 1000, scale: 1)
        _ = try await streamer.update(req)
        await step(streamer, out, "1600x1000 points at 1x")
        req.fitDisplay = nil
        _ = try await streamer.update(req)
        await step(streamer, out, "Dynamic Resolution off")
        await streamer.stop()
        try await Task.sleep(for: .seconds(1))
        var err = [CChar](repeating: 0, count: 512), now = [CChar](repeating: 0, count: 2048)
        _ = md_display_save(&now, now.count, &err, err.count)
        print("layout at the end: \(String(cString: now))")
    }

    /// The pointer circling (through the viewer's input path) for a while; frames and bytes sent meanwhile.
    private func step(_ streamer: LinuxStreamer, _ out: Output, _ label: String) async {
        print(label)
        out.lock.lock(); let d0 = out.datagrams, b0 = out.bytes; out.lock.unlock()
        let start = Date()
        var a = 0.0
        while Date().timeIntervalSince(start) < seconds {
            streamer.handle(input: .mouseMove(.init(x: 0.5 + 0.3 * cos(a), y: 0.5 + 0.3 * sin(a))))
            a += 0.05
            try? await Task.sleep(for: .milliseconds(8))
        }
        out.lock.lock(); let d = out.datagrams - d0, b = out.bytes - b0; out.lock.unlock()
        let span = Date().timeIntervalSince(start)
        print(String(format: "  %.0f datagrams/s, %.0f kbit/s over %.1f s", Double(d) / span, Double(b) * 8 / 1000 / span, span))
    }
}

struct VirtualDisplayTest: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "virtual-test",
                                                    abstract: "As the desktop's user: make a virtual monitor, measure it, and remove it.",
                                                    shouldDisplay: false)
    @Option(help: "The viewer's window, in points.") var size = "1280x1358"
    @Option(help: "The viewer's pixels per point.") var scale = 2.0
    @Option(help: "A second window size to resize to.") var resize = "1440x900"
    @Option(help: "Seconds of pointer motion to measure the frame rate over.") var seconds = 4.0

    func run() throws {
        func fit(_ s: String) throws -> ControlMessage.FitDisplay {
            let p = s.split(separator: "x").compactMap { Int($0) }
            guard p.count == 2 else { throw ValidationError("expected WxH") }
            return .init(width: p[0], height: p[1], scale: scale)
        }
        var err = [CChar](repeating: 0, count: 2048)
        var before = [CChar](repeating: 0, count: 2048)
        guard md_display_save(&before, before.count, &err, err.count) == 0 else { throw ValidationError(String(cString: err)) }
        print("layout before: \(String(cString: before))")

        // 1. Pointer mapping, with the pointer as metadata.
        let f1 = try fit(size)
        let (w, h, sc) = VirtualScreen.pixels(f1)
        var t0 = Date()
        let m: OpaquePointer, mp: Process
        switch VirtualScreen.open(user: nil, width: w, height: h, scale: sc, cursorMetadata: true) {
        case .success(let r): (m, mp) = r
        case .failure(let e): print("✗ \(e)"); throw ExitCode(1)
        }
        print("virtual monitor (pointer as metadata) up in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        _ = md_picture_wait(md_virtual_picture(m), 0, 2000)
        report(m, label: "made")
        for (x, y) in [(0.25, 0.5), (0.75, 0.25), (0.5, 0.9), (0.02, 0.02)] {
            md_virtual_pointer_move(m, x, y)
            usleep(250_000)
            var cx: Int32 = 0, cy: Int32 = 0
            let known = md_virtual_cursor(m, &cx, &cy) != 0
            var pw: Int32 = 0, ph: Int32 = 0
            md_picture_size(md_virtual_picture(m), &pw, &ph)
            print(String(format: "pointer to (%.2f, %.2f): expected (%d, %d) pixels, stream says %@", x, y, Int(x * Double(pw)), Int(y * Double(ph)),
                         known ? "(\(cx), \(cy))" : "nothing"))
        }
        md_virtual_stop(m); md_virtual_free(m)
        while mp.isRunning { usleep(20_000) }
        print("layout after the first: \(layoutNow())")

        // 2. Frame rate and encode time while the pointer moves (drawn in), then a resize, then the end.
        t0 = Date()
        let v: OpaquePointer, vp: Process
        switch VirtualScreen.open(user: nil, width: w, height: h, scale: sc, cursorMetadata: false) {
        case .success(let r): (v, vp) = r
        case .failure(let e): print("✗ \(e)"); throw ExitCode(1)
        }
        print("virtual monitor up in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        _ = md_picture_wait(md_virtual_picture(v), 0, 2000)
        report(v, label: "made")
        for (x, y) in [(0.25, 0.3), (0.75, 0.3), (0.3, 0.75), (0.7, 0.7)] { locate(v, x, y) }
        measure(v, seconds: seconds)

        let f2 = try fit(resize)
        let (w2, h2, sc2) = VirtualScreen.pixels(f2)
        t0 = Date()
        if md_virtual_resize(v, Int32(w2), Int32(h2), sc2, &err, err.count) != 0 { print("✗ resize: \(String(cString: err))") }
        var pw: Int32 = 0, ph: Int32 = 0
        var seq: UInt64 = 0
        while Date().timeIntervalSince(t0) < 3 {
            seq = md_picture_wait(md_virtual_picture(v), seq, 100)
            md_picture_size(md_virtual_picture(v), &pw, &ph)
            if pw == w2, ph == h2 { break }
            md_virtual_pointer_move(v, Double.random(in: 0...1), Double.random(in: 0...1))
        }
        print("resized to \(w2)x\(h2): frames at \(pw)x\(ph) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        report(v, label: "resized")
        measure(v, seconds: min(seconds, 2))

        t0 = Date()
        md_virtual_stop(v); md_virtual_free(v)
        while vp.isRunning { usleep(20_000) }
        let after = layoutNow()
        print("removed in \(Int(Date().timeIntervalSince(t0) * 1000)) ms; layout after: \(after)")
        print(after == String(cString: before) ? "✓ layout restored" : "✗ layout differs from before")
    }

    private func layoutNow() -> String {
        var err = [CChar](repeating: 0, count: 512), now = [CChar](repeating: 0, count: 2048)
        return md_display_save(&now, now.count, &err, err.count) == 0 ? String(cString: now) : "? \(String(cString: err))"
    }

    private func report(_ v: OpaquePointer, label: String) {
        var pw: Int32 = 0, ph: Int32 = 0, lw: Int32 = 0, lh: Int32 = 0, s: Double = 0
        md_picture_size(md_virtual_picture(v), &pw, &ph)
        md_virtual_geometry(v, &lw, &lh, &s)
        print("\(label): picture \(pw)x\(ph) pixels, monitor \(lw)x\(lh) logical at scale \(s); layout \(layoutNow())")
    }

    /// Where the pointer drawn into the picture lands for a move to (x, y): the pixels that change when it comes from the
    /// opposite corner (only their extent is printed).
    private func locate(_ v: OpaquePointer, _ x: Double, _ y: Double) {
        let pic = md_virtual_picture(v)
        var pw: Int32 = 0, ph: Int32 = 0
        md_picture_size(pic, &pw, &ph)
        let cap = (Int(pw) + 256) * 4 * Int(ph)
        let park = (x < 0.5 ? 0.98 : 0.02, y < 0.5 ? 0.98 : 0.02)
        var a = [UInt8](repeating: 0, count: cap), b = [UInt8](repeating: 0, count: cap)
        var w: Int32 = 0, h: Int32 = 0
        md_virtual_pointer_move(v, park.0, park.1); usleep(400_000)
        let sa = md_picture_copy(pic, &a, cap, &w, &h)
        md_virtual_pointer_move(v, x, y); usleep(400_000)
        let sb = md_picture_copy(pic, &b, cap, &w, &h)
        guard sa > 0, sa == sb else { print("  pointer to (\(x), \(y)): no frames"); return }
        let px = Int(park.0 * Double(w)), py = Int(park.1 * Double(h))
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0..<Int(h) {
            let o = row * Int(sa)
            for col in 0..<Int(w) where abs(col - px) > 300 || abs(row - py) > 300 {
                let i = o + col * 4
                if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
                    minX = min(minX, col); maxX = max(maxX, col); minY = min(minY, row); maxY = max(maxY, row)
                }
            }
        }
        let want = "(\(Int(x * Double(w))), \(Int(y * Double(h))))"
        print(maxX < 0 ? "  pointer to (\(x), \(y)): expected near \(want) pixels, nothing changed"
                       : "  pointer to (\(x), \(y)): expected near \(want) pixels, changed \(minX)...\(maxX) x \(minY)...\(maxY)")
    }

    /// Frames delivered while the pointer circles at 120 Hz, and x265's time per frame at this size.
    private func measure(_ v: OpaquePointer, seconds: Double) {
        let pic = md_virtual_picture(v)
        var pw: Int32 = 0, ph: Int32 = 0
        md_picture_size(pic, &pw, &ph)
        var err = [CChar](repeating: 0, count: 256)
        let enc = md_encoder_open(pw & ~1, ph & ~1, 60, 20_000, &err, err.count)
        defer { md_encoder_close(enc) }
        let stop = Date().addingTimeInterval(seconds)
        let mover = Thread {
            var a = 0.0
            while Date() < stop { md_virtual_pointer_move(v, 0.5 + 0.3 * cos(a), 0.5 + 0.3 * sin(a)); a += 0.05; usleep(8_333) }
        }
        mover.start()
        let first = md_picture_wait(pic, 0, 0)
        var seq = first, frames = 0
        var encodeMs: [Double] = []
        let start = Date()
        while Date() < stop {
            let n = md_picture_wait(pic, seq, 100)
            guard n != seq else { continue }
            seq = n; frames += 1
            if let enc {
                let t = Date()
                var sample: UnsafePointer<UInt8>?; var key: Int32 = 0
                _ = md_encoder_encode(enc, pic, frames == 1 ? 1 : 0, 0, &sample, &key)
                encodeMs.append(Date().timeIntervalSince(t) * 1000)
            }
        }
        let span = Date().timeIntervalSince(start)
        let sorted = encodeMs.sorted()
        print(String(format: "  captured %.1f frames/s, encoded %.1f/s over %.1f s with the pointer moving; x265 %.1f ms per frame (median), %.1f (p95)",
                     Double(seq - first) / span, Double(frames) / span, span, sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                     sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]))
    }
}
