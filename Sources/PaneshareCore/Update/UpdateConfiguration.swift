import Foundation

/// The auto-update settings baked into a build's Info.plist (docs/RELEASING.md). The updater only
/// starts when they're complete and safe: an HTTPS feed, an EdDSA public key, and a signed feed with
/// archives verified before extraction. Local builds have no `SUFeedURL` and simply don't update.
public struct UpdateConfiguration: Equatable, Sendable {
    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"
    public static let requireSignedFeedKey = "SURequireSignedFeed"
    public static let verifyBeforeExtractionKey = "SUVerifyUpdateBeforeExtraction"
    public static let intervalKey = "SUScheduledCheckInterval"
    public static let defaultInterval: TimeInterval = 24 * 3600
    /// Sparkle's own floor for scheduled checks.
    public static let minimumInterval: TimeInterval = 3600

    public enum Problem: Error, Equatable, Sendable {
        /// No feed URL: a local or development build. Not an error to show.
        case notConfigured
        case invalidFeedURL
        case feedNotHTTPS
        case missingPublicKey
        case invalidPublicKey
        case feedNotSigned
        case intervalTooShort

        public var explanation: String {
            switch self {
            case .notConfigured: return "This build has no update feed (it wasn't made by scripts/release.sh)."
            case .invalidFeedURL: return "The update feed URL in this build is malformed."
            case .feedNotHTTPS: return "The update feed must be served over HTTPS."
            case .missingPublicKey: return "This build has no update signing key (SUPublicEDKey)."
            case .invalidPublicKey: return "The update signing key in this build isn't a 32-byte EdDSA key."
            case .feedNotSigned: return "This build doesn't require a signed update feed."
            case .intervalTooShort: return "The update check interval is shorter than one hour."
            }
        }
    }

    public let feedURL: URL
    public let publicEDKey: String
    public let checkInterval: TimeInterval

    public static func from(info: [String: Any]) -> Result<UpdateConfiguration, Problem> {
        guard let raw = (info[feedURLKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .failure(.notConfigured) }
        guard let url = URL(string: raw), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else {
            return .failure(.invalidFeedURL)
        }
        guard components.scheme?.lowercased() == "https" else { return .failure(.feedNotHTTPS) }
        guard let key = (info[publicKeyKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return .failure(.missingPublicKey) }
        guard let decoded = Data(base64Encoded: key), decoded.count == 32 else { return .failure(.invalidPublicKey) }
        guard flag(info[requireSignedFeedKey]), flag(info[verifyBeforeExtractionKey]) else {
            return .failure(.feedNotSigned)
        }
        let interval = number(info[intervalKey]) ?? defaultInterval
        guard interval >= minimumInterval else { return .failure(.intervalTooShort) }
        return .success(UpdateConfiguration(feedURL: url, publicEDKey: key, checkInterval: interval))
    }

    private static func flag(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let s = value as? String { return ["yes", "true", "1"].contains(s.lowercased()) }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return TimeInterval(s) }
        return nil
    }
}

/// Whether to ask the user about automatic update checks. Asked once, on the first launch of a build
/// that can update; the answer is Sparkle's own `SUEnableAutomaticChecks` setting from then on.
public enum UpdateConsent {
    public static let askedKey = "updateConsentAsked"

    public static func shouldAsk(configured: Bool, alreadyAsked: Bool, automaticChecksSetting: Bool?) -> Bool {
        configured && !alreadyAsked && automaticChecksSetting == nil
    }
}
