import Foundation
import MirageCore

/// Host load is cheap, wire bytes are not (decision from phrz, 2026-10-17): hosts are Apple silicon
/// desktops on mains power, so the codec spends CPU freely for wire efficiency unless the host is
/// genuinely busy. One signal combines load average relative to core count, thermal pressure and
/// the streamer's own per-capture latency; it maps to an effort level the codec paths read.
public enum HostEffort: String, Sendable {
    case full, reduced, minimal

    /// WebP lossless effort (0 fastest … 9 smallest).
    var webpEffort: Int { switch self { case .full: return 4; case .reduced: return 2; case .minimal: return 0 } }
    /// Copy-rect search range and drag refinement radius (px).
    var shiftSearch: (maxShift: Int, refineRadius: Int) { switch self { case .full: return (900, 24); case .reduced: return (600, 16); case .minimal: return (200, 8) } }
    /// Whether to compute the exact changed box inside a dirty tile (else send the whole tile).
    var tightBoxes: Bool { self != .minimal }

    public struct Pressure: Sendable {
        public var loadPerCore: Double
        public var thermal: ProcessInfo.ThermalState
        public var captureMs: Double
        public var level: HostEffort {
            if thermal == .critical || thermal == .serious || loadPerCore > 1.5 || captureMs > 25 { return .minimal }
            if thermal == .fair || loadPerCore > 0.8 || captureMs > 15 { return .reduced }
            return .full
        }
    }

    /// Samples the machine; `captureMs` is the streamer's own mean per-capture time over the last period.
    public static func measure(captureMs: Double) -> Pressure {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return Pressure(loadPerCore: loads[0] / Double(cores), thermal: ProcessInfo.processInfo.thermalState, captureMs: captureMs)
    }
}
