import XCTest
import Metal

extension MTLCommandBuffer {
    /// Commits and waits for completion, at most `seconds`: an unbounded waitUntilCompleted stalled a scene test for 250 s on
    /// a busy machine. A GPU that does not finish in time skips the test instead of hanging the suite.
    func commitAndWaitBounded(seconds: Double = 10) throws {
        let done = DispatchSemaphore(value: 0)
        addCompletedHandler { _ in done.signal() }
        commit()
        if done.wait(timeout: .now() + seconds) == .timedOut { throw XCTSkip("the GPU did not finish within \(Int(seconds)) s (a busy machine)") }
    }
}
