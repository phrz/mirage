import XCTest
import Metal

extension MTLCommandBuffer {
    /// Commits and waits for completion, at most `seconds`: an unbounded waitUntilCompleted stalled a scene test for 250 s on
    /// a busy machine. A GPU that does not finish in time fails the test (never a skip: the deploy gate counts failures, and a
    /// skip would let a broken compositor through).
    func commitAndWaitBounded(seconds: Double = 10) throws {
        let done = DispatchSemaphore(value: 0)
        addCompletedHandler { _ in done.signal() }
        commit()
        if done.wait(timeout: .now() + seconds) == .timedOut { throw GPUTimeout(seconds: seconds) }
    }
}

/// A GPU wait that did not finish in time (a failing test, with this description).
struct GPUTimeout: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "the GPU did not finish within \(Int(seconds)) s" }
}
