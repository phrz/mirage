import Foundation

/// One ScreenCaptureKit operation at a time, first come first served: window captures' starts and the display captures'
/// filter updates. ScreenCaptureKit serialises them itself, so running them at once only makes each one wait (mac-daddy on
/// 537 after an unlock: three window starts at 2.1, 2.9 and 3.9 s, the curtain's filter updates timing out behind them at
/// 3 s without ever being tried); in turn, the frontmost window's start comes first, and a filter update's bound counts its
/// own run only. Filter updates are `urgent`: they go ahead of waiting window starts (539: the whole display, wanted at an
/// unlock, waited behind three window starts for 4.6 s).
actor SCKGate {
    static let shared = SCKGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var urgentWaiters: [CheckedContinuation<Void, Never>] = []
    /// How many are waiting or running (for the log).
    private(set) var queued = 0

    /// `op` in turn. The gate is held for `holdAtMost` seconds at most: a start that never returns (it happened once) must
    /// not hold every later one back; it goes on outside the gate.
    func run<T: Sendable>(urgent: Bool = false, holdAtMost: Double = 4, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        await enter(urgent: urgent)
        let released = ScreenCapturer.StartOnce()
        let timer = Task { try? await Task.sleep(for: .milliseconds(Int(holdAtMost * 1000))); if released.claim() { self.leave() } }
        defer { timer.cancel(); if released.claim() { leave() } }
        return try await op()
    }
    private func enter(urgent: Bool) async {
        queued += 1
        if !busy { busy = true; return }
        await withCheckedContinuation { c in if urgent { urgentWaiters.append(c) } else { waiters.append(c) } }
    }
    private func leave() {
        queued -= 1
        if !urgentWaiters.isEmpty { urgentWaiters.removeFirst().resume() }
        else if !waiters.isEmpty { waiters.removeFirst().resume() }
        else { busy = false }
    }
}
