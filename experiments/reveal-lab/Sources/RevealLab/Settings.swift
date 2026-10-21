import SwiftUI

enum FillStyle: Int, CaseIterable, Identifiable {
    case flat, kawase, mirror, smear, frosted, aware, pullPush
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .flat: return "Flat"
        case .kawase: return "Kawase"
        case .mirror: return "Mirror"
        case .smear: return "Smear"
        case .frosted: return "Frosted"
        case .aware: return "Aware"
        case .pullPush: return "Pull-push"
        }
    }
    var subtitle: String {
        switch self {
        case .flat: return "1 · flat edge colour (today)"
        case .kawase: return "2 · clamp + dual Kawase at ¼ res + vignette (spec)"
        case .mirror: return "3 · mirror-extend + blur"
        case .smear: return "4 · smear the last N rows, blur growing, to average"
        case .frosted: return "5 · spec + frosted glass tint, rim and grain"
        case .aware: return "6 · repeat nearest tile rows with offset, blurred"
        case .pullPush: return "7 · mask-aware pull-push pyramid fill (Photos-like)"
        }
    }
    /// Which sliders this style uses.
    var knobs: Set<PartialKeyPath<FillParams>> {
        let blur: Set<PartialKeyPath<FillParams>> = [\.blurOffset, \.passes, \.divisor]
        let look: Set<PartialKeyPath<FillParams>> = [\.ext, \.vignette, \.desat, \.grain, \.warpAmp, \.warpSpeed]
        switch self {
        case .flat: return [\.crossfadeMs]
        case .kawase, .mirror: return blur.union(look).union([\.feather, \.innerFeather, \.crossfadeMs])
        case .smear: return blur.union(look).union([\.smearRows, \.crossfadeMs])
        case .frosted: return blur.union(look).union([\.feather, \.innerFeather, \.tint, \.rim, \.crossfadeMs])
        case .aware: return blur.union(look).union([\.feather, \.innerFeather, \.tileRows, \.tileShift, \.crossfadeMs])
        case .pullPush: return [\.divisor, \.innerFeather, \.ext, \.vignette, \.desat, \.grain, \.warpAmp, \.warpSpeed, \.crossfadeMs]
        }
    }
}

struct FillParams: Equatable {
    var blurOffset = 1.5      // Kawase sample offset multiplier ("radius")
    var passes = 4.0          // Kawase down/up passes
    var divisor = 4.0         // base resolution divisor (4 = quarter)
    var feather = 16.0        // pt beyond the edge where sharp extension blends into blur
    var innerFeather = 0.0    // pt inside the known edge where truth fades into the fill
    var ext = 260.0           // extension length, pt
    var vignette = 0.4
    var desat = 0.25
    var grain = 0.0
    var crossfadeMs = 180.0
    var tint = 0.0
    var rim = 0.0
    var smearRows = 48.0
    var tileRows = 120.0
    var tileShift = 14.0
    var warpAmp = 0.0         // pt; 0 = off
    var warpSpeed = 0.25
}

final class LabSettings: ObservableObject {
    @Published var tab: MockTab = .finder
    @Published var style: FillStyle = .pullPush
    @Published var latencyMs = 250.0
    @Published var bandwidthRows = 4000.0   // content rows (pt) per second
    @Published var marginPt = 120.0          // host sends this much beyond the confirmed viewport
    @Published var hostFrameMs = 50.0        // host frame interval; rows of one frame arrive together
    @Published var showBoundary = false
    @Published var frozen = false
    @Published var params: [Int: FillParams]

    // Stats, published a few times a second.
    @Published var fillMs = 0.0
    @Published var fillP95 = 0.0
    @Published var compositeMs = 0.0
    @Published var iphoneEstimate = 0.0
    @Published var gpuCores = 0
    @Published var drawablePx = ""
    @Published var unknownFraction = 0.0
    @Published var dispatches = 0

    // Automation (command line).
    var autoReplay = false
    var freezeAt: Double? = nil
    var replayRequest = 0
    var resetRequest = 0
    var winIdFile: String? = nil
    var logTimings = false

    init() {
        var p: [Int: FillParams] = [:]
        p[FillStyle.flat.rawValue] = FillParams(crossfadeMs: 120)
        p[FillStyle.kawase.rawValue] = FillParams()
        p[FillStyle.mirror.rawValue] = FillParams()
        p[FillStyle.smear.rawValue] = FillParams(blurOffset: 1.5, passes: 4, ext: 240, vignette: 0.3, desat: 0.2, smearRows: 48)
        p[FillStyle.frosted.rawValue] = FillParams(blurOffset: 2, passes: 4, feather: 20, ext: 320, vignette: 0.15, desat: 0.1, grain: 0.35, crossfadeMs: 220, tint: 0.35, rim: 0.5)
        p[FillStyle.aware.rawValue] = FillParams(blurOffset: 1.0, passes: 2, feather: 12, ext: 420, vignette: 0.25, desat: 0.2, tileRows: 118, tileShift: 14)
        p[FillStyle.pullPush.rawValue] = FillParams(divisor: 4, innerFeather: 20, ext: 360, vignette: 0.2, desat: 0.15, grain: 0.0, crossfadeMs: 220, warpAmp: 10, warpSpeed: 0.25)
        params = p
        parseArguments()
    }

    var current: FillParams { params[style.rawValue] ?? FillParams() }

    func binding(_ kp: WritableKeyPath<FillParams, Double>) -> Binding<Double> {
        Binding(get: { self.params[self.style.rawValue]?[keyPath: kp] ?? 0 },
                set: { self.params[self.style.rawValue]?[keyPath: kp] = $0 })
    }

    func replay() { frozen = false; replayRequest += 1 }
    func resetToTop() { frozen = false; resetRequest += 1 }

    private func parseArguments() {
        let a = ProcessInfo.processInfo.arguments
        func value(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        if let t = value("--tab"), let tab = MockTab(rawValue: t) { self.tab = tab }
        if let s = value("--style"), let n = Int(s), let st = FillStyle(rawValue: n - 1) { style = st }
        if let v = value("--latency"), let d = Double(v) { latencyMs = d }
        if let v = value("--bandwidth"), let d = Double(v) { bandwidthRows = d }
        if let v = value("--freeze-at"), let d = Double(v) { freezeAt = d }
        if let v = value("--winid-file") { winIdFile = v }
        if a.contains("--replay") { autoReplay = true }
        if a.contains("--log-timings") { logTimings = true }
        if a.contains("--boundary") { showBoundary = true }
    }
}
