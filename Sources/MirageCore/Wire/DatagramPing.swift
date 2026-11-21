import Foundation

/// Datagram ping format: magic(1) type(1)=ping seq(8 BE) sentNanos(8 BE) echoNanos(8 BE) padding to `size`.
/// The host echoes it with its own clock written into `echoNanos` (0 from the sender), so one small
/// datagram every 10 s gives the viewer RTT, loss and the clock offset it needs for frame age: that is
/// the session's keepalive (DESIGN §4a: sparse).
public enum DatagramPing {
    public static let minSize = 26
    public static func encode(seq: UInt64, size: Int = 32) -> Data {
        var d = Data([datagramMagic, DatagramType.ping.rawValue])
        var s = seq.bigEndian; var t = Clock.nowNanos().bigEndian; var e = UInt64(0)
        withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &t) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &e) { d.append(contentsOf: $0) }
        if d.count < size { d.append(Data(repeating: 0, count: size - d.count)) }
        return d
    }
    public static func decode(_ d: Data) -> (seq: UInt64, sentNanos: UInt64, echoNanos: UInt64)? {
        guard d.count >= 18, d[d.startIndex] == datagramMagic, d[d.startIndex+1] == DatagramType.ping.rawValue else { return nil }
        let seq = d.subdata(in: d.startIndex+2..<d.startIndex+10).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
        let t = d.subdata(in: d.startIndex+10..<d.startIndex+18).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
        let e = d.count >= minSize ? d.subdata(in: d.startIndex+18..<d.startIndex+26).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian : 0
        return (seq, t, e)
    }
    /// The host's reply: the ping with the responder's clock filled in.
    public static func echo(_ d: Data, now: UInt64 = Clock.nowNanos()) -> Data {
        guard d.count >= minSize else { return d }
        var out = d
        var e = now.bigEndian
        withUnsafeBytes(of: &e) { out.replaceSubrange(out.startIndex+18..<out.startIndex+26, with: $0) }
        return out
    }
}
