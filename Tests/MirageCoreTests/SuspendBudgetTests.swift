import XCTest
@testable import MirageCore

/// Sleep durability (DESIGN §4a): suspended sessions wait a day; memory is bounded by shedding the oldest sessions'
/// pixel caches first, and only past the session cap is a session stopped.
final class SuspendBudgetTests: XCTestCase {
    final class FakeStreamer: DesktopStreamer, @unchecked Sendable {
        let bytes: Int
        var shed = false, stopped = false
        init(bytes: Int) { self.bytes = bytes }
        func start(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo { fatalError() }
        func update(_ request: ControlMessage.StreamRequest) async throws -> ControlMessage.StreamInfo { fatalError() }
        func handle(ack: ControlMessage.FrameAck) {}
        func handle(tileAck: ControlMessage.TileAck) {}
        func handle(nack: ControlMessage.Nack) {}
        func handle(input: ControlMessage) {}
        func handle(inputPacket: InputPacket) -> InputAck? { nil }
        func handle(probeEcho sentNanos: UInt64, receivedNanos: UInt64) {}
        func suspend() async {}
        func resume(_ request: ControlMessage.StreamRequest, output: StreamOutput) async throws -> ControlMessage.StreamInfo { fatalError() }
        func stop() async { stopped = true }
        func cachedBytes() async -> Int { shed ? 0 : bytes }
        func shedCaches() async { shed = true }
    }

    func testOldestShedFirstThenStoppedPastTheCap() async throws {
        XCTAssertEqual(Mirage.resumeWindowSeconds, 86_400)
        let reg = HostConnections()
        await reg.setBudget(bytes: 1500, maxSessions: 3)
        var fakes: [FakeStreamer] = []
        for i in 0..<3 {
            let f = FakeStreamer(bytes: 1000); fakes.append(f)
            await reg.suspend(token: Data([UInt8(i)]), deviceID: "d", streamer: f, request: nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        await reg.enforceBudget()
        // 3000 bytes against 1500: the two oldest shed, the newest keeps its caches; nobody stopped.
        XCTAssertEqual(fakes.map(\.shed), [true, true, false])
        XCTAssertEqual(fakes.map(\.stopped), [false, false, false])
        let n = await reg.suspendedCount
        XCTAssertEqual(n, 3)
        // A fourth session: past the cap of 3, the oldest is stopped.
        let f4 = FakeStreamer(bytes: 10)
        await reg.suspend(token: Data([9]), deviceID: "d", streamer: f4, request: nil)
        await reg.enforceBudget()
        XCTAssertTrue(fakes[0].stopped)
        let m = await reg.suspendedCount
        XCTAssertEqual(m, 3)
    }
}
