import Foundation

/// A point normalized to the shared window's content rect: x, y in [0, 1], top-left origin, y down.
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum MouseButton: String, Codable, Sendable { case left, right, other }

public enum ScrollUnit: String, Codable, Sendable { case pixel, line }

/// Viewer → host input. Key codes are macOS virtual key codes and `modifierFlags` carries the
/// CGEventFlags / NSEvent.ModifierFlags device-independent bits, which are the same values on both.
public struct InputEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mouseMove, mouseDown, mouseUp, mouseDrag, scroll, keyDown, keyUp, flagsChanged
    }

    public var kind: Kind
    public var position: NormalizedPoint?
    public var button: MouseButton?
    public var clickCount: Int?
    public var scrollDeltaX: Double?
    public var scrollDeltaY: Double?
    public var scrollUnit: ScrollUnit?
    public var scrollPhase: UInt32?
    public var momentumPhase: UInt32?
    public var keyCode: UInt16?
    public var modifierFlags: UInt64
    public var isRepeat: Bool?

    public init(kind: Kind, position: NormalizedPoint? = nil, button: MouseButton? = nil, clickCount: Int? = nil,
                scrollDeltaX: Double? = nil, scrollDeltaY: Double? = nil, scrollUnit: ScrollUnit? = nil,
                scrollPhase: UInt32? = nil, momentumPhase: UInt32? = nil, keyCode: UInt16? = nil,
                modifierFlags: UInt64 = 0, isRepeat: Bool? = nil) {
        self.kind = kind; self.position = position; self.button = button; self.clickCount = clickCount
        self.scrollDeltaX = scrollDeltaX; self.scrollDeltaY = scrollDeltaY; self.scrollUnit = scrollUnit
        self.scrollPhase = scrollPhase; self.momentumPhase = momentumPhase; self.keyCode = keyCode
        self.modifierFlags = modifierFlags; self.isRepeat = isRepeat
    }

    public var isPointer: Bool {
        switch kind {
        case .mouseMove, .mouseDown, .mouseUp, .mouseDrag, .scroll: return true
        case .keyDown, .keyUp, .flagsChanged: return false
        }
    }

    /// Structural validation the host applies before acting on an event from the network.
    public var isWellFormed: Bool {
        switch kind {
        case .mouseMove, .mouseDrag:
            return position.map(Self.inRange) ?? false
        case .mouseDown, .mouseUp:
            guard let p = position, Self.inRange(p), button != nil else { return false }
            return (clickCount ?? 1) >= 1 && (clickCount ?? 1) <= 3
        case .scroll:
            guard let p = position, Self.inRange(p) else { return false }
            let dx = scrollDeltaX ?? 0, dy = scrollDeltaY ?? 0
            return dx.isFinite && dy.isFinite && abs(dx) <= 10_000 && abs(dy) <= 10_000
        case .keyDown, .keyUp:
            return (keyCode ?? 0x200) < 0x80
        case .flagsChanged:
            return true
        }
    }

    private static func inRange(_ p: NormalizedPoint) -> Bool {
        p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y)
    }
}
