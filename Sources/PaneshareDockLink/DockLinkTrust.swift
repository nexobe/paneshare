import Foundation

/// How a Dock helper decides the process at the other end of the local link is the real paneshare.
/// Always: the peer's bundle ID (and our parent PID when it launched us). When paneshare is Developer
/// ID signed, its Team ID is written into the helper's Info.plist and the peer's running code must
/// also satisfy `mainAppRequirement`, checked against its audit token.
public enum DockLinkTrust {
    public static let mainTeamIDKey = "PaneshareMainTeamID"

    /// Apple Team IDs are ten characters of A–Z and 0–9.
    public static func isTeamID(_ s: String) -> Bool {
        s.utf8.count == 10 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }

    /// Apple-anchored, our bundle ID, our team. Nil when either value could break out of the quotes.
    public static func mainAppRequirement(mainBundleID: String, teamID: String) -> String? {
        guard isTeamID(teamID), !mainBundleID.isEmpty,
              mainBundleID.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2E || $0 == 0x2D
              }) else { return nil }
        return "anchor apple generic and identifier \"\(mainBundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
