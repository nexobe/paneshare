import Foundation

/// Chooses a bitrate level from dropped video frames. The send queue is short, so drops are the
/// first sign the network can't keep up. It steps down quickly and comes back slowly, so a passing
/// stall costs little and the picture doesn't keep changing.
public struct AdaptiveBitrate: Equatable, Sendable {
    public static let levels: [Double] = [1, 0.75, 0.5, 0.35, 0.25]
    /// This many drops within `window` seconds steps down one level.
    public static let dropsToStepDown = 3
    public static let window: TimeInterval = 2
    /// With no drop for this many seconds, it steps up one level.
    public static let quietToStepUp: TimeInterval = 15

    private var level = 0
    private var windowStart: TimeInterval?
    private var windowDrops = 0
    private var quietSince: TimeInterval?

    public init() {}

    public var factor: Double { Self.levels[level] }

    /// Call regularly with the drops since the last call. Returns the new factor if it changed.
    public mutating func update(dropped: Int, now: TimeInterval) -> Double? {
        if windowStart == nil { windowStart = now }
        if quietSince == nil { quietSince = now }
        if dropped > 0 { quietSince = now }
        if let start = windowStart, now - start >= Self.window {
            windowStart = now
            windowDrops = 0
        }
        windowDrops += max(0, dropped)
        if windowDrops >= Self.dropsToStepDown {
            windowStart = now
            windowDrops = 0
            guard level < Self.levels.count - 1 else { return nil }
            level += 1
            return factor
        }
        if let quiet = quietSince, now - quiet >= Self.quietToStepUp, level > 0 {
            quietSince = now
            level -= 1
            return factor
        }
        return nil
    }

    /// The rate for one level, never below what still works.
    public static func scaled(_ bitrate: Int, factor: Double) -> Int {
        guard factor < 1 else { return bitrate }
        return min(bitrate, max(StreamTuning.minBitrate, Int(Double(bitrate) * factor)))
    }
}
