#if canImport(CoreGraphics)
// Since the macOS 15 SDK, CoreFoundation declares CGPoint/CGSize/CGRect, so Foundation alone exposes
// the types without CoreGraphics' Swift overlay (minX, width on CGRect, CGRect(x:y:width:height:),
// .zero, Equatable). On Linux, swift-corelibs-foundation defines them all.
import CoreGraphics
#endif
import Foundation

/// Coordinate conversions between the viewer's view, the wire's normalized space and the host's
/// global display space (docs/ARCHITECTURE.md §3.4).
public enum InputMapping {
    /// Host-side inset so an injected event never lands exactly on the window's edge, where it
    /// could hit a neighbouring window or a resize handle of the frame.
    public static let edgeInset: Double = 0.5

    /// Viewer: a point in a top-left-origin (flipped) view of `viewSize` → normalized, clamped.
    public static func normalize(flippedPoint p: CGPoint, viewSize: CGSize) -> NormalizedPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        return NormalizedPoint(x: clamp01(Double(p.x / viewSize.width)), y: clamp01(Double(p.y / viewSize.height)))
    }

    /// Viewer: a point in AppKit's default bottom-left-origin view coordinates → normalized.
    public static func normalize(bottomLeftPoint p: CGPoint, viewSize: CGSize) -> NormalizedPoint {
        normalize(flippedPoint: CGPoint(x: p.x, y: viewSize.height - p.y), viewSize: viewSize)
    }

    /// Host: normalized → global display point (top-left origin, the CGEvent location space)
    /// inside `windowFrame`, clamped to the frame minus `edgeInset`.
    public static func globalPoint(_ n: NormalizedPoint, windowFrame f: CGRect) -> CGPoint {
        let x = Double(f.minX) + clamp01(n.x) * Double(f.width)
        let y = Double(f.minY) + clamp01(n.y) * Double(f.height)
        let insetX = min(edgeInset, Double(f.width) / 2)
        let insetY = min(edgeInset, Double(f.height) / 2)
        return CGPoint(x: min(max(x, Double(f.minX) + insetX), Double(f.maxX) - insetX),
                       y: min(max(y, Double(f.minY) + insetY), Double(f.maxY) - insetY))
    }

    /// Host: the inverse of `globalPoint`, for tests and for reporting the host cursor.
    public static func normalize(globalPoint p: CGPoint, windowFrame f: CGRect) -> NormalizedPoint {
        guard f.width > 0, f.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        return NormalizedPoint(x: clamp01(Double((p.x - f.minX) / f.width)),
                               y: clamp01(Double((p.y - f.minY) / f.height)))
    }

    static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }
}

extension WireRect {
    public init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.width), height: Double(r.height))
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension WireSize {
    public init(_ s: CGSize) { self.init(width: Double(s.width), height: Double(s.height)) }
    public var cgSize: CGSize { CGSize(width: width, height: height) }
}
