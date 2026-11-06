import Foundation

/// Wire encodings for scroll phases and modifiers. On the wire, `InputEvent.scrollPhase` is a
/// `CGScrollPhase` raw value and `momentumPhase` a `CGMomentumScrollPhase` raw value, so the host
/// posts them unchanged. The viewer converts from `NSEvent.Phase`, which uses different bits.
public enum EventCodes {
    // NSEvent.Phase raw values.
    static let nsBegan: UInt = 1, nsStationary: UInt = 2, nsChanged: UInt = 4, nsEnded: UInt = 8
    static let nsCancelled: UInt = 16, nsMayBegin: UInt = 32

    /// `NSEvent.phase` → `CGScrollPhase` (began 1, changed 2, ended 4, cancelled 8, mayBegin 128); 0 = none.
    public static func scrollPhase(fromNSPhase raw: UInt) -> UInt32 {
        if raw & nsMayBegin != 0 { return 128 }
        if raw & nsBegan != 0 { return 1 }
        if raw & (nsChanged | nsStationary) != 0 { return 2 }
        if raw & nsEnded != 0 { return 4 }
        if raw & nsCancelled != 0 { return 8 }
        return 0
    }

    /// `NSEvent.momentumPhase` → `CGMomentumScrollPhase` (none 0, begin 1, continue 2, end 3).
    public static func momentumPhase(fromNSPhase raw: UInt) -> UInt32 {
        if raw & nsBegan != 0 { return 1 }
        if raw & (nsChanged | nsStationary) != 0 { return 2 }
        if raw & (nsEnded | nsCancelled) != 0 { return 3 }
        return 0
    }

    /// Device-independent modifier bits, identical in `NSEvent.ModifierFlags` and `CGEventFlags`:
    /// caps lock, shift, control, option, command, numeric pad, help, function. Anything else is
    /// stripped on both ends.
    public static let modifierMask: UInt64 = 0x00FF_0000
}
