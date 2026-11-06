import Foundation

/// The macOS icon body shape: a superellipse |x|ⁿ + |y|ⁿ = 1, the same curve the app icon's SVG
/// sources use (`scripts/icon/squircle.py`, n = 4.6).
public enum Squircle {
    public static let exponent = 4.6

    /// Outline points, counter-clockwise from the right-hand extreme, in a y-up coordinate space.
    public static func points(centerX: Double, centerY: Double, halfSide: Double,
                              exponent: Double = Squircle.exponent, count: Int = 96) -> [(x: Double, y: Double)] {
        (0..<max(8, count)).map { i in
            let t = 2 * Double.pi * Double(i) / Double(max(8, count))
            let c = cos(t), s = sin(t)
            return (centerX + halfSide * copysign(pow(abs(c), 2 / exponent), c),
                    centerY + halfSide * copysign(pow(abs(s), 2 / exponent), s))
        }
    }
}

/// The colour that marks one source Mac on its helpers' rings, chosen from a fixed palette by the
/// host's fingerprint, so every helper from that Mac matches and two Macs usually differ.
public enum SourceMacColor {
    /// sRGB, 0–255: blue, purple, pink, orange, teal, green, indigo, red (the system accent hues).
    public static let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (0, 122, 255), (175, 82, 222), (255, 45, 85), (255, 149, 0),
        (48, 176, 199), (52, 199, 89), (88, 86, 214), (255, 59, 48),
    ]

    /// Names for `palette`, in the same order.
    public static let names = ["Blue", "Purple", "Pink", "Orange", "Teal", "Green", "Indigo", "Red"]

    public static func index(for host: Fingerprint) -> Int {
        Int(host.bytes.first ?? 0) % palette.count
    }

    /// The user's choice if it's a real palette entry, and the host's own colour if not.
    public static func index(for host: Fingerprint, choice: Int?) -> Int {
        if let choice, palette.indices.contains(choice) { return choice }
        return index(for: host)
    }
}

/// Where each part of a Dock helper's icon goes at one pixel size (docs/ARCHITECTURE.md §6.2):
/// a ring in the source Mac's colour on the app icon grid's body, the remote app's icon inside it,
/// and (from 64 px) a small paneshare badge so the tile reads as remote. Small sizes get a ring that's
/// relatively thicker, so it's still at least 1.5 px at 16 px. y-up, origin bottom left, in pixels.
public struct HelperIconLayout: Equatable, Sendable {
    public struct Rect: Equatable, Sendable {
        public let x: Double, y: Double, width: Double, height: Double
        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
    }

    public let pixels: Int
    /// The icon grid's body: 824/1024 of the canvas, centred.
    public let body: Rect
    public let ringWidth: Double
    /// The square the remote app's whole icon image (with its own grid margins) is drawn into, so
    /// its body lands just inside the ring.
    public let remoteIcon: Rect
    public let badge: Rect?

    public static let bodyFraction = 824.0 / 1024.0
    public static let minimumBadgePixels = 64

    public init(pixels: Int) {
        let p = Double(max(1, pixels))
        self.pixels = max(1, pixels)
        let side = p * Self.bodyFraction
        let origin = (p - side) / 2
        body = Rect(x: origin, y: origin, width: side, height: side)
        ringWidth = max(1.5, p * (pixels <= 32 ? 0.09 : 0.055))
        let gap = max(0.5, p * 0.012)
        let innerBody = side - 2 * (ringWidth + gap)
        let imageSide = innerBody / Self.bodyFraction
        remoteIcon = Rect(x: (p - imageSide) / 2, y: (p - imageSide) / 2, width: imageSide, height: imageSide)
        if pixels >= Self.minimumBadgePixels {
            let d = p * 0.36
            badge = Rect(x: origin + side - d * 0.82, y: origin - d * 0.18, width: d, height: d)
        } else {
            badge = nil
        }
    }

    /// The ring's outer and inner outlines (fill with the even-odd rule).
    public func ringOutlines(count: Int = 96) -> (outer: [(x: Double, y: Double)], inner: [(x: Double, y: Double)]) {
        let half = body.width / 2
        return (Squircle.points(centerX: body.midX, centerY: body.midY, halfSide: half, count: count),
                Squircle.points(centerX: body.midX, centerY: body.midY, halfSide: half - ringWidth, count: count))
    }
}
