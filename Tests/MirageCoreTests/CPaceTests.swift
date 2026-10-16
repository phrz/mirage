import XCTest
import CryptoKit
@testable import MirageCore

final class CPaceTests: XCTestCase {
    func run(clientCode: String, hostCode: String) throws -> Bool {
        let sid = CPace.newSessionID()
        let ci = Data("channel".utf8)
        let host = try CPace(password: hostCode, channelID: ci, sid: sid)
        let client = try CPace(password: clientCode, channelID: ci, sid: sid)
        let yb = try host.makeShare()
        let ya = try client.makeShare()
        let iskA = try client.sessionKey(own: ya, peer: yb.publicShare, initiatorShare: ya.publicShare, responderShare: yb.publicShare)
        let iskB = try host.sessionKey(own: yb, peer: ya.publicShare, initiatorShare: ya.publicShare, responderShare: yb.publicShare)
        let tagA = CPace.confirmationTag(isk: iskA, role: "A", initiatorShare: ya.publicShare, responderShare: yb.publicShare)
        return CPace.verifyTag(tagA, isk: iskB, role: "A", initiatorShare: ya.publicShare, responderShare: yb.publicShare)
    }

    func testSameCodeAgrees() throws { XCTAssertTrue(try run(clientCode: "123456", hostCode: "123456")) }
    func testDifferentCodeFails() throws { XCTAssertFalse(try run(clientCode: "123456", hostCode: "123457")) }

    func testChannelBindingMatters() throws {
        let sid = CPace.newSessionID()
        let host = try CPace(password: "000000", channelID: Data("real".utf8), sid: sid)
        let client = try CPace(password: "000000", channelID: Data("mitm".utf8), sid: sid)
        let yb = try host.makeShare(), ya = try client.makeShare()
        let iskA = try client.sessionKey(own: ya, peer: yb.publicShare, initiatorShare: ya.publicShare, responderShare: yb.publicShare)
        let iskB = try host.sessionKey(own: yb, peer: ya.publicShare, initiatorShare: ya.publicShare, responderShare: yb.publicShare)
        XCTAssertNotEqual(iskA.withUnsafeBytes { Data($0) }, iskB.withUnsafeBytes { Data($0) })
    }

    func testLowOrderShareRejected() throws {
        let c = try CPace(password: "1", channelID: Data(), sid: Data(repeating: 1, count: 16))
        let mine = try c.makeShare()
        XCTAssertThrowsError(try c.sessionKey(own: mine, peer: Data(repeating: 0, count: 32), initiatorShare: Data(), responderShare: Data()))
    }

    func testFrameRoundTrip() throws {
        let m = ControlMessage.ping(.init(seq: 7, sentNanos: 42))
        let enc = try Frame.encode(m)
        XCTAssertEqual(Frame.length(from: enc.prefix(4)), enc.count - 4)
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: enc.dropFirst(4)), m)
    }

    func testAuthSignatures() throws {
        let host = DeviceIdentity(name: "h"), client = DeviceIdentity(name: "c")
        let t = DeviceIdentity.hostAuthTranscript(tlsFingerprint: Data([1]), clientNonce: Data([2]), hostNonce: Data([3]), clientID: client.id)
        let sig = try host.sign(t)
        XCTAssertTrue(DeviceIdentity.verify(signature: sig, message: t, publicKey: host.publicKey))
        let t2 = DeviceIdentity.hostAuthTranscript(tlsFingerprint: Data([9]), clientNonce: Data([2]), hostNonce: Data([3]), clientID: client.id)
        XCTAssertFalse(DeviceIdentity.verify(signature: sig, message: t2, publicKey: host.publicKey))
    }
}
