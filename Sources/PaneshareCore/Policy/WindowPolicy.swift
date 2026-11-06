import Foundation

/// Which windows may ever be offered to a viewer. Applied on the host before a window list leaves
/// the machine, and again on the viewer as defense in depth.
public struct WindowPolicy: Sendable {
    /// Password managers and credential stores. Best-effort: bundle IDs drift, so users can extend
    /// the list (`extraDeniedBundleIDs`).
    public static let defaultDeniedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "com.keepersecurity.passwordmanager",
        "com.enpass.Enpass-Desktop",
        "com.nordsec.nordpass",
        "com.proton.pass.electron",
    ]

    /// System authentication UI: admin-password and Touch ID sheets, passkey and keychain prompts,
    /// the login and lock screens. These often sit on a normal layer and must never leave the Mac,
    /// whatever the user adds or removes elsewhere.
    public static let systemAuthBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.coreautha",
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
    ]

    /// Never share ScreenCaptureKit's own system UI or paneshare's proxies.
    public static let deniedBundleIDPrefixes = ["com.apple.screencapture", "dev.paneshare."]

    public static let minimumSide: Double = 64

    public enum Rejection: Equatable, Sendable {
        case ownProcess, systemAuthPrompt, deniedApp, notNormalLayer, hiddenApp, offScreen, tooSmall
    }

    public var ownProcessID: Int32
    public var ownBundleID: String?
    public var extraDeniedBundleIDs: Set<String>

    public init(ownProcessID: Int32, ownBundleID: String?, extraDeniedBundleIDs: Set<String> = []) {
        self.ownProcessID = ownProcessID
        self.ownBundleID = ownBundleID
        self.extraDeniedBundleIDs = extraDeniedBundleIDs
    }

    /// - Parameter appHidden: the owning app is hidden (Cmd-H) on the host right now. Only the host
    ///   knows this; the viewer-side re-check passes false.
    public func rejection(for w: WindowInfo, appHidden: Bool = false) -> Rejection? {
        if let app = appRejection(bundleID: w.bundleID, processID: w.processID) { return app }
        if w.layer != 0 { return .notNormalLayer }
        if appHidden { return .hiddenApp }
        if !w.isOnScreen { return .offScreen }
        if w.frame.width < Self.minimumSide || w.frame.height < Self.minimumSide { return .tooSmall }
        return nil
    }

    /// The rules that apply to a whole app, whatever the window: our own process, system
    /// authentication UI and the deny-list. Audio uses these too (`AudioPolicy`).
    public func appRejection(bundleID id: String, processID: Int32) -> Rejection? {
        if processID == ownProcessID || (ownBundleID != nil && id == ownBundleID) { return .ownProcess }
        if Self.systemAuthBundleIDs.contains(id) { return .systemAuthPrompt }
        if Self.defaultDeniedBundleIDs.contains(id) || extraDeniedBundleIDs.contains(id)
            || Self.deniedBundleIDPrefixes.contains(where: { id.hasPrefix($0) }) {
            return .deniedApp
        }
        return nil
    }

    public func isShareable(_ w: WindowInfo, appHidden: Bool = false) -> Bool { rejection(for: w, appHidden: appHidden) == nil }

    public func filter(_ windows: [WindowInfo]) -> [WindowInfo] { windows.filter { isShareable($0) } }
}
