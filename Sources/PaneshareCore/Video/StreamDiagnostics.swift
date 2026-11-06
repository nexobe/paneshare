#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The viewer's per-stream diagnostics: what the host says it produces (`StreamInfo`), what the
/// viewer decodes and shows, and what actually arrives. Shown in the overlay window and logged when
/// the hidden `debugOverlay` setting is on (docs/TESTING.md §4.2).
public struct StreamDiagnostics: Equatable, Sendable {
    public var info: StreamInfo?
    public var decodedPixels: PixelSize?
    public var viewPoints: CGSize
    public var backingScale: Double
    public var receivedBitsPerSecond: Double
    public var receivedFramesPerSecond: Double
    public var topUps: Int

    public init(info: StreamInfo?, decodedPixels: PixelSize?, viewPoints: CGSize, backingScale: Double,
                receivedBitsPerSecond: Double = 0, receivedFramesPerSecond: Double = 0, topUps: Int = 0) {
        self.info = info; self.decodedPixels = decodedPixels; self.viewPoints = viewPoints
        self.backingScale = backingScale; self.receivedBitsPerSecond = receivedBitsPerSecond
        self.receivedFramesPerSecond = receivedFramesPerSecond; self.topUps = topUps
    }

    public var displayedPixels: PixelSize { DisplayFit.displayedPixels(viewPoints: viewPoints, backingScale: backingScale) }

    /// "1:1", or the factor the picture is scaled by on screen, e.g. "scaled ×0.98".
    public var mapping: String {
        guard let decoded = decodedPixels, decoded.width > 0, decoded.height > 0 else { return "no picture yet" }
        let shown = displayedPixels
        if shown == decoded { return "1:1" }
        let fx = Double(shown.width) / Double(decoded.width), fy = Double(shown.height) / Double(decoded.height)
        return String(format: "scaled ×%.3f", min(fx, fy))
    }

    public var lines: [String] {
        var out: [String] = []
        if let i = info {
            let scale = i.sourceScale.map { Self.scale($0) } ?? "?"
            out.append("host  window \(Self.points(i.sourcePoints)) pt @\(scale) · capture \(Self.px(i.capturePixels)) \(i.captureFormat)")
            out.append("enc   \(i.codec == .hevc ? "HEVC" : "H.264") \(i.chroma.rawValue) \(i.hardware ? "hw" : "sw") · \(Self.px(i.encodedPixels))"
                       + " · \(Self.rate(Double(i.bitrate))) (top-up \(Self.rate(Double(i.topUpBitrate))))")
            out.append("      \(i.profile)")
        } else {
            out.append("host  (no stream info; older host)")
        }
        let decoded = decodedPixels.map(Self.px) ?? "–"
        out.append("view  decoded \(decoded) · shown \(Self.px(displayedPixels)) px = \(Self.points(viewPoints)) pt @\(Self.scale(backingScale)) · \(mapping)")
        out.append(String(format: "rx    %@ · %.0f fps · %d top-ups", Self.rate(receivedBitsPerSecond), receivedFramesPerSecond, topUps))
        return out
    }

    public var text: String { lines.joined(separator: "\n") }

    static func px(_ p: PixelSize) -> String { "\(p.width)×\(p.height)" }
    static func points(_ s: WireSize) -> String { points(CGSize(width: s.width, height: s.height)) }
    static func points(_ s: CGSize) -> String {
        func f(_ v: CGFloat) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", Double(v)) }
        return "\(f(s.width))×\(f(s.height))"
    }
    static func scale(_ s: Double) -> String { s.rounded() == s ? "\(Int(s))x" : String(format: "%.2fx", s) }
    static func rate(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mb/s", bps / 1_000_000) : String(format: "%.0f kb/s", bps / 1000)
    }
}

/// Bytes and frames received for one stream, turned into a rate over a sliding one-second window.
/// The clock is passed in.
public struct RateMeter: Sendable {
    private var samples: [(time: TimeInterval, bytes: Int)] = []
    public let window: TimeInterval

    public init(window: TimeInterval = 1) { self.window = window }

    public mutating func add(bytes: Int, at now: TimeInterval) {
        samples.append((now, bytes))
        trim(now)
    }

    public mutating func rates(at now: TimeInterval) -> (bitsPerSecond: Double, framesPerSecond: Double) {
        trim(now)
        let bytes = samples.reduce(0) { $0 + $1.bytes }
        return (Double(bytes * 8) / window, Double(samples.count) / window)
    }

    private mutating func trim(_ now: TimeInterval) {
        samples.removeAll { now - $0.time > window || $0.time > now }
    }
}
