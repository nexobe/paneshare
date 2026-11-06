#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The two permissions the host needs, and the settings panes that grant them.
public enum Permissions {
    /// Screen Recording, for ScreenCaptureKit. Never prompts.
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once per launch; the user grants it in System Settings.
    @discardableResult
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// Accessibility, for CGEvent injection, raising and AX resizing. Never prompts.
    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that offers to open System Settings.
    public static func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt. Spelled out because SDKs disagree on whether the
        // constant imports as Unmanaged<CFString> or CFString.
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case localNetwork = "Privacy_LocalNetwork"
    }

    /// Opens a settings pane. For Screen Recording, it also asks macOS to list the app. On macOS 27.2
    /// the request didn't add the app to the list, so the UI also tells the user to add it with +.
    public static func open(_ pane: Pane) {
        if pane == .screenRecording, !screenRecording { requestScreenRecording() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
