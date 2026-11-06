#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// How the viewer sizes a window so the stream lands pixel for pixel on its screen
/// (docs/ARCHITECTURE.md §7.1). Pure, so it is unit-tested.
public enum DisplayFit {
    /// The content size (points) for a stream of `pixels` on a screen of `backingScale`.
    ///
    /// At native quality the stream is the host window's points × the viewer's scale, rounded to even
    /// pixels, so `pixels / backingScale` is within a point of the host's size: use it exactly, so each
    /// stream pixel is one screen pixel. Otherwise (reduced quality, a capture clamped by the size
    /// limits, a scale that changed since the window was opened) follow the host's point size.
    public static func contentSize(pixels: PixelSize, backingScale: Double, quality: StreamQuality,
                                   hostPoints: CGSize) -> CGSize {
        guard quality == .native, backingScale.isFinite, backingScale > 0, pixels.width > 0, pixels.height > 0 else {
            return hostPoints
        }
        let exact = CGSize(width: Double(pixels.width) / backingScale, height: Double(pixels.height) / backingScale)
        let close = abs(exact.width - hostPoints.width) <= 2 && abs(exact.height - hostPoints.height) <= 2
        return close ? exact : hostPoints
    }

    /// Whether a layer of `viewPoints` at `backingScale` shows `pixels` without resampling.
    public static func isOneToOne(pixels: PixelSize, viewPoints: CGSize, backingScale: Double) -> Bool {
        let shown = displayedPixels(viewPoints: viewPoints, backingScale: backingScale)
        return shown == pixels
    }

    public static func displayedPixels(viewPoints: CGSize, backingScale: Double) -> PixelSize {
        PixelSize(width: Int((Double(viewPoints.width) * backingScale).rounded()),
                  height: Int((Double(viewPoints.height) * backingScale).rounded()))
    }
}
