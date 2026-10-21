import XCTest
@testable import MirageCore

/// Model identifiers to device families (the connect list's and the host menu's icons).
final class DeviceModelTests: XCTestCase {
    func testAppleSiliconModelsFromTheTable() {
        let cases: [(String, DeviceFamily)] = [
            ("Mac15,14", .macStudio), ("Mac14,13", .macStudio), ("Mac13,1", .macStudio), ("Mac16,9", .macStudio),
            ("Mac14,3", .macMini), ("Mac16,10", .macMini), ("Mac16,11", .macMini),
            ("Mac16,6", .macBookPro), ("Mac15,3", .macBookPro), ("Mac14,7", .macBookPro), ("Mac17,2", .macBookPro),
            ("Mac14,2", .macBookAir), ("Mac15,13", .macBookAir), ("Mac16,12", .macBookAir),
            ("Mac15,4", .iMac), ("Mac16,3", .iMac), ("Mac14,8", .macPro), ("Mac17,5", .macBook),
        ]
        for (m, f) in cases { XCTAssertEqual(DeviceModel.knownFamily(of: m), f, m) }
    }

    func testIntelEraAndMobileIdentifiersNameTheirFamily() {
        let cases: [(String, DeviceFamily)] = [
            ("MacBookPro18,3", .macBookPro), ("MacBookAir10,1", .macBookAir), ("MacBook10,1", .macBook), ("Macmini9,1", .macMini),
            ("MacPro7,1", .macPro), ("iMac21,1", .iMac), ("iMacPro1,1", .iMac), ("iPhone17,1", .iPhone), ("iPad16,3", .iPad),
        ]
        for (m, f) in cases { XCTAssertEqual(DeviceModel.knownFamily(of: m), f, m) }
    }

    func testUnknownModels() {
        XCTAssertEqual(DeviceModel.knownFamily(of: "Mac99,9"), .mac, "an Apple silicon Mac newer than the table is still a Mac")
        XCTAssertNil(DeviceModel.knownFamily(of: "arm64"), "the Simulator's machine name without its model")
        XCTAssertNil(DeviceModel.knownFamily(of: "VirtualMac2,1"), "a VM is no family")
        XCTAssertNil(DeviceModel.family(of: nil))
        XCTAssertNil(DeviceModel.family(of: ""))
        XCTAssertNil(DeviceModel.knownFamily(of: "Macintosh"))
    }

    func testTheSystemsTypesAgreeWithTheTable() {
        // On a Mac, CoreTypes names these too (and models newer than the table); its answer must match the table's.
        for (m, f) in DeviceModel.appleSilicon {
            guard let sys = DeviceModel.systemFamily(of: m) else { continue }   // an older macOS may not know it
            XCTAssertEqual(DeviceModel.family(of: m), f, m)
            if sys != .mac { XCTAssertEqual(sys, f, m) }
        }
    }

    func testThisDevice() throws {
        #if os(macOS)
        let m = try XCTUnwrap(DeviceModel.current)
        XCTAssertTrue(m.hasPrefix("Mac") || m.hasPrefix("iMac") || m.hasPrefix("VirtualMac"), m)
        #endif
    }

    func testFamiliesHaveIconsAndSymbols() {
        for f in DeviceFamily.allCases {
            XCTAssertTrue(f.typeIdentifier.hasPrefix("com.apple."))
            XCTAssertFalse(f.symbolName.isEmpty)
        }
        XCTAssertEqual(DeviceFamily.macStudio.symbolName, "macstudio")
        XCTAssertEqual(DeviceFamily.macPro.symbolName, "macpro.gen3")
        XCTAssertEqual(DeviceFamily.macBookAir.symbolName, "macbook")
        XCTAssertFalse(DeviceFamily.iPhone.isMac)
    }

    func testOlderRecordsDecodeWithoutAModel() throws {
        let json = #"{"id":"ab","name":"phone","publicKey":"AAAA","pairedAt":"2026-01-01T00:00:00Z"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let r = try d.decode(DeviceRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.model)
        let hello = ControlMessage.Hello(protocolVersion: 1, deviceID: "x", deviceName: "y", clientNonce: Data(), deviceModel: "iPhone17,1")
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: try Frame.encode(ControlMessage.hello(hello)).dropFirst(4)), .hello(hello))
        let w = ControlMessage.Welcome(hostName: "h", sessionID: "s", hostModel: "Mac15,14", hostFamily: "macStudio")
        XCTAssertEqual(try Frame.decode(ControlMessage.self, from: try Frame.encode(ControlMessage.welcome(w)).dropFirst(4)), .welcome(w))
    }
}
