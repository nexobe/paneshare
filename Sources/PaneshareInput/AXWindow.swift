#if os(macOS)
// Lookup by PID + frame with per-element messaging timeouts follows Sill (Sources/SillHost/WindowSizer.swift,
// Copyright 2026 Noah Saffer, Apache-2.0). Toggling AXEnhancedUserInterface around a resize follows
// Rectangle (github.com/rxhanson/Rectangle, AccessibilityElement.swift, MIT). Both rewritten; see THIRD_PARTY.md.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The Accessibility element of one shared window: raise, read its frame, move and resize it.
/// Public AX API only: the private `_AXUIElementGetWindow` is not used, so the element is matched by
/// PID, frame and title instead.
public final class AXWindow {
    public let element: AXUIElement
    public let processID: pid_t
    private let app: AXUIElement

    static let frameTolerance: CGFloat = 2

    init(element: AXUIElement, app: AXUIElement, processID: pid_t) {
        self.element = element
        self.app = app
        self.processID = processID
    }

    /// The AX window of `processID` whose frame (global points, top-left origin) matches `frame`.
    /// Title breaks ties between windows stacked at the same frame.
    public static func find(processID: pid_t, frame: CGRect, title: String) -> AXWindow? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let matches = windows.filter { w in
            AXUIElementSetMessagingTimeout(w, 0.5)
            guard let f = frameOf(w) else { return false }
            return abs(f.minX - frame.minX) <= frameTolerance && abs(f.minY - frame.minY) <= frameTolerance
                && abs(f.width - frame.width) <= frameTolerance && abs(f.height - frame.height) <= frameTolerance
        }
        let chosen = matches.first { titleOf($0) == title } ?? matches.first
        return chosen.map { AXWindow(element: $0, app: app, processID: processID) }
    }

    public var frame: CGRect? { Self.frameOf(element) }

    /// Brings the window to the front and its app to the foreground.
    @discardableResult
    public func raise() -> Bool {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        NSRunningApplication(processIdentifier: processID)?.activate()
        return raised
    }

    /// Requests a new size (points), keeping the top-left corner. Returns the size the app accepted.
    public func resize(to size: CGSize) -> CGSize? {
        let enhanced = Self.bool(app, "AXEnhancedUserInterface")
        if enhanced == true { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if enhanced == true { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return nil }
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        return frame?.size
    }

    /// Moves the window's top-left corner to `origin` (global points, top-left origin). Returns the
    /// frame it ended up with.
    @discardableResult
    public func move(to origin: CGPoint) -> CGRect? {
        var p = origin
        guard let value = AXValueCreate(.cgPoint, &p) else { return nil }
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        return frame
    }

    static func frameOf(_ e: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func titleOf(_ e: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func bool(_ e: AXUIElement, _ attribute: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }
}
#endif
