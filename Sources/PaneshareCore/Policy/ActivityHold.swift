/// Counts the streams that need the Mac awake. Only the first hold and the last release act.
public struct ActivityHold: Equatable, Sendable {
    public private(set) var count = 0

    public init() {}

    /// True when this is the first hold, so the activity must begin.
    public mutating func acquire() -> Bool {
        count += 1
        return count == 1
    }

    /// True when this was the last hold, so the activity must end. Extra releases do nothing.
    public mutating func release() -> Bool {
        guard count > 0 else { return false }
        count -= 1
        return count == 0
    }
}
