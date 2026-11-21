import Foundation
import CMirageDesktop

/// The one GNOME remote-desktop session the host keeps open, from start until GNOME ends it, then opened again.
///
/// GNOME ends remote-desktop sessions when the screen locks and refuses new ones until it is unlocked ("Session creation
/// inhibited"); the host keeps the screen from idle-locking (md_inhibit_idle) and opens a session as soon as it can, so a
/// viewer gets a picture at once. While it is open GNOME shows its screen-sharing indicator in the top bar.
final class GnomeSession: DesktopSource, @unchecked Sendable {
    let name = "GNOME's screen"

    private let lock = NSLock()
    private var current: OpaquePointer?
    /// Streamers using each session; an ended session is closed once none does.
    private var users: [OpaquePointer: Int] = [:]
    private var lastError: String?
    private var log: (@Sendable (String) -> Void)?

    func start(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        let t = Thread { [self] in
            while true {
                tick()
                Thread.sleep(forTimeInterval: 2)
            }
        }
        t.name = "mirage-gnome-session"
        t.start()
    }

    /// Why there is no session right now (for the viewer), or nil.
    var unavailableReason: String? {
        lock.lock(); defer { lock.unlock() }
        guard current == nil else { return nil }
        guard let e = lastError else { return "GNOME's screen is not shared yet" }
        if e.contains("inhibited") {
            return "the screen is locked, and GNOME shares only an unlocked screen: unlock it at the computer"
        }
        return e
    }

    /// The open session (counted as used until `release`), waiting up to `timeout` for one.
    func acquire(timeout: TimeInterval) -> DesktopLease? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if let s = current, md_picture_ended(md_session_picture(s)) == 0 {
                users[s, default: 0] += 1
                lock.unlock()
                return DesktopLease(picture: md_session_picture(s), input: MutterBackend(s), token: s)
            }
            lock.unlock()
            if Date() >= deadline { return nil }
            tick()
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    func release(_ lease: DesktopLease) {
        guard let s = lease.token else { return }
        lock.lock()
        let n = (users[s] ?? 1) - 1
        users[s] = n > 0 ? n : nil
        let close = n <= 0 && s != current
        lock.unlock()
        if close { md_session_close(s) }
    }

    private let opening = NSLock()   // one tick at a time (the thread's and an acquire's)

    private func tick() {
        opening.lock(); defer { opening.unlock() }
        lock.lock()
        if let s = current, md_picture_ended(md_session_picture(s)) != 0 {
            current = nil
            let unused = users[s] == nil
            lock.unlock()
            log?("GNOME ended the screen-sharing session; opening a new one")
            if unused { md_session_close(s) }
            lock.lock()
        }
        let need = current == nil
        lock.unlock()
        guard need else { return }
        var err = [CChar](repeating: 0, count: 512)
        if let s = md_session_open(&err, err.count) {
            var w: Int32 = 0, h: Int32 = 0
            _ = md_picture_wait(md_session_picture(s), 0, 2000)
            md_picture_size(md_session_picture(s), &w, &h)
            lock.lock(); current = s; lastError = nil; lock.unlock()
            log?("sharing GNOME's screen (\(w)x\(h))")
        } else {
            let e = String(cString: err)
            lock.lock(); let changed = e != lastError; lastError = e; lock.unlock()
            if changed { log?("cannot share GNOME's screen yet: \(e)\(e.contains("inhibited") ? " (the screen is locked; retrying until it is unlocked)" : "")") }
        }
    }
}
