import Foundation
import PaneshareDockLink

/// The on-disk plan for one Dock helper: a tiny generated app per remote app, so each remote app
/// gets its own Dock tile and Command-Tab entry (docs/ARCHITECTURE.md §6). The helper only relays
/// activation and its Dock menu to the main app. Computing the plan is pure so naming and plist
/// contents are unit-tested; the macOS factory writes, signs and launches it.
public struct HelperBundlePlan: Equatable, Sendable {
    public static let bundleIDPrefix = "dev.paneshare.dock"
    public static let executableName = "paneshare-dock-helper"
    /// Bumped whenever what a generated helper contains changes (plist keys, icon treatment), so
    /// helpers written by an older paneshare are regenerated instead of reused. 2: source-Mac ring icon.
    /// 3: main-app Team ID and update policy for Developer ID builds.
    public static let revision = 3
    /// Custom Info.plist keys the helper reads at launch.
    public static let hostIDKey = "PaneshareHostID"
    public static let remoteBundleIDKey = "PaneshareRemoteBundleID"
    public static let mainBundleIDKey = "PaneshareMainBundleID"
    /// Present only when the main app is Developer ID signed: the helper then also requires the
    /// link's server to be signed by this team (docs/RELEASING.md, "Dock helpers").
    public static let mainTeamIDKey = DockLinkTrust.mainTeamIDKey

    /// Also the helper's key on the local link and in the ledger.
    public let bundleIdentifier: String
    /// What the Dock and Command-Tab show, e.g. "Xcode on Studio".
    public let bundleName: String
    /// Path relative to the helpers directory (`~/Library/Application Support/paneshare/DockHelpers`):
    /// `<host short ID>/<sanitized remote ID>/<bundle name>.app`, unique per host and remote app.
    public let relativePath: String
    public let host: Fingerprint
    public let remoteBundleID: String
    public let mainBundleID: String
    /// The main app's Apple Team ID, or nil for ad hoc (local) builds. Invalid IDs are dropped.
    public let mainTeamID: String?

    public init(host: Fingerprint, hostName: String, remoteBundleID: String, remoteAppName: String, mainBundleID: String,
                mainTeamID: String? = nil) {
        let hostPart = host.shortID.lowercased()
        let appPart = Self.sanitize(remoteBundleID.isEmpty ? remoteAppName : remoteBundleID)
        bundleIdentifier = "\(Self.bundleIDPrefix).\(hostPart).\(appPart)"
        bundleName = Self.displayName("\(Self.displayName(remoteAppName)) on \(Self.displayName(hostName, fallback: host.shortID))")
        relativePath = "\(hostPart)/\(appPart)/\(bundleName).app"
        self.host = host
        self.remoteBundleID = remoteBundleID
        self.mainBundleID = mainBundleID
        self.mainTeamID = mainTeamID.flatMap { DockLinkTrust.isTeamID($0) ? $0 : nil }
    }

    public var infoPlist: [String: PlistValue] {
        var plist: [String: PlistValue] = [
            "CFBundleIdentifier": .string(bundleIdentifier),
            "CFBundleName": .string(bundleName),
            "CFBundleDisplayName": .string(bundleName),
            "CFBundleExecutable": .string(Self.executableName),
            "CFBundleInfoDictionaryVersion": .string("6.0"),
            "CFBundlePackageType": .string("APPL"),
            "CFBundleIconFile": .string("AppIcon"),
            "CFBundleShortVersionString": .string("\(Self.revision)"),
            "CFBundleVersion": .string("\(Self.revision)"),
            "LSMinimumSystemVersion": .string("14.0"),
            "LSMultipleInstancesProhibited": .bool(true),
            "NSHighResolutionCapable": .bool(true),
            "NSPrincipalClass": .string("NSApplication"),
            Self.hostIDKey: .string(host.hex),
            Self.remoteBundleIDKey: .string(remoteBundleID),
            Self.mainBundleIDKey: .string(mainBundleID),
        ]
        if let mainTeamID {
            plist[Self.mainTeamIDKey] = .string(mainTeamID)
            // macOS 13+ App Management: lets the signed main app (and only it) replace or update this
            // helper without the "paneshare was prevented from modifying apps" prompt.
            plist["NSUpdateSecurityPolicy"] = .dict([
                "AllowProcesses": .dict([mainTeamID: .array([.string(mainBundleID)])]),
            ])
        }
        return plist
    }

    /// Bundle identifiers allow A–Z, a–z, 0–9, hyphen and period. Everything else becomes a
    /// hyphen; periods are flattened so the remote ID is a single component of ours.
    static func sanitize(_ s: String) -> String {
        let mapped = s.unicodeScalars.map { u -> Character in
            let c = Character(u)
            return (c.isASCII && (c.isLetter || c.isNumber)) ? c : "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = String(collapsed.prefix(64)).lowercased()
        return trimmed.isEmpty ? "app" : trimmed
    }

    /// Safe as a file name: no newlines, slashes, colons or leading dots.
    static func displayName(_ s: String, fallback: String = "Remote App") -> String {
        var cleaned = s.filter { !$0.isNewline && $0 != "/" && $0 != ":" }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(96))
    }
}
