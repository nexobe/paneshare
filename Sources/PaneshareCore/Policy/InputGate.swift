import Foundation

/// Decides whether the host may inject one viewer event (docs/ARCHITECTURE.md §4.3, "paired but
/// malicious viewer"). Pure; the host supplies the live facts.
public enum InputGate {
    public enum Decision: Equatable, Sendable {
        case inject
        /// Raise the target window first, then inject.
        case raiseThenInject
        case drop(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case malformed, streamNotOwned, noAccessibility, secureInput, targetNotFrontmost
    }

    /// - Parameters:
    ///   - streamOwned: the stream was opened by this connection.
    ///   - secureInputActive: secure keyboard entry is on somewhere on the host.
    ///   - frontmostPID: the frontmost application's process ID right now.
    ///   - targetPID: the shared window's owning process.
    public static func decide(_ event: InputEvent, streamOwned: Bool, accessibilityTrusted: Bool,
                              secureInputActive: Bool = false, frontmostPID: Int32?, targetPID: Int32) -> Decision {
        guard event.isWellFormed else { return .drop(.malformed) }
        guard streamOwned else { return .drop(.streamNotOwned) }
        guard accessibilityTrusted else { return .drop(.noAccessibility) }
        // Key releases and modifier changes still pass, so a key held when secure input began
        // doesn't stick; neither can type anything.
        if secureInputActive, event.kind == .keyDown { return .drop(.secureInput) }
        let isFront = frontmostPID == targetPID
        switch event.kind {
        case .mouseDown:
            return isFront ? .inject : .raiseThenInject
        case .mouseMove, .mouseDrag, .mouseUp, .scroll:
            // Hover and scroll reach background windows on macOS too; no raise needed.
            return .inject
        case .keyDown, .keyUp, .flagsChanged:
            // Keys go to whatever is focused, so never post them unless the target is frontmost.
            return isFront ? .inject : .drop(.targetNotFrontmost)
        }
    }

    /// What the viewer should be told about the stream's input right now.
    public static func pause(accessibilityTrusted: Bool, secureInputActive: Bool) -> InputState.Pause? {
        if !accessibilityTrusted { return .noAccessibility }
        return secureInputActive ? .secureInput : nil
    }
}
