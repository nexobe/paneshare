#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Capture and window size rules (docs/ARCHITECTURE.md §7).
public enum Sizing {
    /// Largest per-side pixel dimension we ask ScreenCaptureKit / VideoToolbox for.
    public static let maxPixelDimension = 16_384
    /// Largest pixel area (≈ 8K × 5K); bigger windows are captured at a reduced scale.
    public static let maxPixelArea = 40_000_000
    /// Smallest window size (points) the viewer will request.
    public static let minPointSize = CGSize(width: 160, height: 100)
    /// Largest window size (points) the viewer will request.
    public static let maxPointSize = CGSize(width: 8_192, height: 8_192)

    /// Pixel size for capturing `points` at `scale` (the viewer's backing scale factor): rounded,
    /// even in both dimensions (4:2:0 chroma), at least 2×2, and scaled down uniformly when it
    /// would exceed the per-side or area limits.
    public static func pixelSize(points: CGSize, scale: Double) -> PixelSize {
        let s = (scale.isFinite && scale > 0) ? min(scale, 4) : 1
        var w = max(Double(points.width), 1) * s
        var h = max(Double(points.height), 1) * s
        let sideFactor = min(1, Double(maxPixelDimension) / max(w, h))
        w *= sideFactor; h *= sideFactor
        if w * h > Double(maxPixelArea) {
            let f = (Double(maxPixelArea) / (w * h)).squareRoot()
            w *= f; h *= f
        }
        return PixelSize(width: even(w), height: even(h))
    }

    /// Capture size for a viewer's backing scale and chosen quality (points × scale × quality).
    public static func pixelSize(points: CGSize, scale: Double, quality: StreamQuality) -> PixelSize {
        let s = (scale.isFinite && scale > 0) ? min(scale, 4) : 1
        return pixelSize(points: points, scale: s * quality.factor)
    }

    /// Whether a resize request should rebuild the capture and encoder. During a live resize the
    /// stream keeps its size (the window content is scaled into it) so the encoder isn't torn down
    /// on every step; it is rebuilt once, for the final size.
    public static func shouldReconfigure(final: Bool, current: PixelSize, next: PixelSize) -> Bool {
        final && next != current
    }

    /// A viewer-requested point size clamped to the allowed range.
    public static func clampRequested(_ size: CGSize) -> CGSize {
        func c(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { v.isFinite ? min(max(v, lo), hi) : lo }
        return CGSize(width: c(size.width, minPointSize.width, maxPointSize.width),
                      height: c(size.height, minPointSize.height, maxPointSize.height))
    }

    /// Whether two sizes differ by more than `tolerance` points in either dimension.
    public static func differs(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }

    private static func even(_ v: Double) -> Int {
        max(2, Int((v / 2).rounded()) * 2)
    }
}

/// Coalesces a stream of live-resize sizes into at most one request per `interval`, plus the
/// final size when the drag ends. Pure (time is passed in) so it is unit-testable.
public struct ResizeCoalescer: Sendable {
    public let interval: TimeInterval
    private var lastSent: CGSize?
    private var lastSentAt: TimeInterval = -.infinity
    private var pending: CGSize?

    public init(interval: TimeInterval = 0.1) { self.interval = interval }

    /// Offer a new size at time `now`; returns a size to send now, or nil to wait.
    public mutating func offer(_ size: CGSize, now: TimeInterval) -> CGSize? {
        if let lastSent, !Sizing.differs(lastSent, size, tolerance: 0.5) {
            pending = nil
            return nil
        }
        if now - lastSentAt >= interval {
            return send(size, now)
        }
        pending = size
        return nil
    }

    /// The deferred size if its interval has elapsed (call from a timer), else nil.
    public mutating func poll(now: TimeInterval) -> CGSize? {
        guard let p = pending, now - lastSentAt >= interval else { return nil }
        return send(p, now)
    }

    /// End of a live resize: whatever is pending goes out immediately.
    public mutating func finish(now: TimeInterval) -> CGSize? {
        guard let p = pending else { return nil }
        return send(p, now)
    }

    private mutating func send(_ size: CGSize, _ now: TimeInterval) -> CGSize {
        lastSent = size
        lastSentAt = now
        pending = nil
        return size
    }
}
