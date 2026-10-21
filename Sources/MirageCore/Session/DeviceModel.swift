import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// What kind of Apple device a peer is, for its icon: the host reports its hardware model identifier (`Mac15,14`) in
/// `Welcome`, a viewer in `Hello` and in its pairing record. The viewer keeps the host's per paired host (known-hosts),
/// the host the viewer's per authorized device.
public enum DeviceFamily: String, Codable, CaseIterable, Sendable {
    case macStudio, macMini, macBookPro, macBookAir, macBook, iMac, macPro, mac, iPhone, iPad

    /// The CoreTypes type whose icon is this family's (macOS: `NSWorkspace.icon(for:)`).
    public var typeIdentifier: String {
        switch self {
        case .macStudio: "com.apple.macstudio"
        case .macMini: "com.apple.macmini"
        case .macBookPro: "com.apple.macbookpro"
        case .macBookAir: "com.apple.macbookair"
        case .macBook: "com.apple.macbook"
        case .iMac: "com.apple.imac"
        case .macPro: "com.apple.macpro"
        case .mac: "com.apple.mac"
        case .iPhone: "com.apple.iphone"
        case .iPad: "com.apple.ipad"
        }
    }

    /// The matching SF Symbol (iOS has no CoreTypes device icons).
    public var symbolName: String {
        switch self {
        case .macStudio: "macstudio"
        case .macMini: "macmini"
        case .macBookPro, .macBookAir, .macBook: "macbook"
        case .iMac, .mac: "desktopcomputer"
        case .macPro: "macpro.gen3"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        }
    }

    public var isMac: Bool { self != .iPhone && self != .iPad }
}

public enum DeviceModel {
    /// This device's model identifier: `hw.model` on a Mac ("Mac16,6"), the machine name on iOS ("iPhone17,1"; the
    /// simulated device's in the Simulator). nil if the system does not say.
    public static let current: String? = {
        #if os(macOS)
        return sysctlString("hw.model")
        #else
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { return sim }
        var u = utsname(); uname(&u)
        let s = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return s.isEmpty ? nil : s
        #endif
    }()

    /// This device's family (the system's own device types first, then the table).
    public static let currentFamily: DeviceFamily? = family(of: current)

    /// A model identifier's family: the system's device types (CoreTypes, which knows models newer than this table), then
    /// the table and the identifier's own prefix. nil when neither knows it.
    public static func family(of model: String?) -> DeviceFamily? {
        guard let model, !model.isEmpty else { return nil }
        let system = systemFamily(of: model)
        if let system, system != .mac { return system }
        return knownFamily(of: model) ?? system   // a plain "Mac" from the system: the table may know better
    }

    /// The family from the identifier alone: Intel-era identifiers name it ("MacBookPro18,3", "Macmini9,1"), Apple
    /// silicon ones ("Mac15,14") do not, so those come from this table (CoreTypes' own list as of macOS 27).
    public static func knownFamily(of model: String) -> DeviceFamily? {
        let m = model.trimmingCharacters(in: .whitespaces)
        if let f = appleSilicon[m] { return f }
        // Longest prefixes first ("MacBookPro" before "MacBook", "MacPro" before "Mac").
        let prefixes: [(String, DeviceFamily)] = [
            ("MacBookPro", .macBookPro), ("MacBookAir", .macBookAir), ("MacBook", .macBook), ("Macmini", .macMini),
            ("MacPro", .macPro), ("iMacPro", .iMac), ("iMac", .iMac), ("iPhone", .iPhone), ("iPod", .iPhone), ("iPad", .iPad),
        ]
        for (p, f) in prefixes where m.hasPrefix(p) && m.dropFirst(p.count).first?.isNumber == true { return f }
        if m.hasPrefix("Mac"), m.dropFirst(3).first?.isNumber == true { return .mac }   // an Apple silicon Mac this table predates
        return nil
    }

    static let appleSilicon: [String: DeviceFamily] = {
        var t: [String: DeviceFamily] = [:]
        func add(_ f: DeviceFamily, _ ids: String) { for id in ids.split(separator: " ") { t[String(id)] = f } }
        add(.macStudio, "Mac13,1 Mac13,2 Mac14,13 Mac14,14 Mac15,14 Mac16,9 Mac17,14 Mac17,15")
        add(.macMini, "Mac14,3 Mac14,12 Mac16,10 Mac16,11 Mac17,16 Mac18,5")
        add(.macBookPro, "Mac14,5 Mac14,6 Mac14,7 Mac14,9 Mac14,10 Mac15,3 Mac15,6 Mac15,7 Mac15,8 Mac15,9 Mac15,10 Mac15,11 Mac16,1 Mac16,5 Mac16,6 Mac16,7 Mac16,8 Mac17,2 Mac17,6 Mac17,7 Mac17,8 Mac17,9")
        add(.macBookAir, "Mac14,2 Mac14,15 Mac15,12 Mac15,13 Mac16,12 Mac16,13 Mac17,3 Mac17,4")
        add(.macBook, "Mac17,5")
        add(.iMac, "Mac15,4 Mac15,5 Mac16,2 Mac16,3")
        add(.macPro, "Mac14,8")
        return t
    }()

    /// The system's device type for a model identifier (CoreTypes' `com.apple.device-model-code` tags), nil if it has none.
    public static func systemFamily(of model: String) -> DeviceFamily? {
        #if canImport(UniformTypeIdentifiers)
        guard let t = UTType(tag: model, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil), !t.isDynamic else { return nil }
        // Most specific first: every Mac conforms to com.apple.mac, a MacBook Pro to com.apple.macbook-ish laptops too.
        let order: [DeviceFamily] = [.macStudio, .macMini, .macBookPro, .macBookAir, .iMac, .macPro, .iPhone, .iPad, .macBook]
        for f in order {
            guard let ft = UTType(f.typeIdentifier) else { continue }
            if t == ft || t.conforms(to: ft) { return f }
        }
        if let laptop = UTType("com.apple.mac.laptop"), t.conforms(to: laptop) { return .macBook }
        if let mac = UTType(DeviceFamily.mac.typeIdentifier), t == mac || t.conforms(to: mac) { return .mac }
        return nil
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }
    #endif
}
