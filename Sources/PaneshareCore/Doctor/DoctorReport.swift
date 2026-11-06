import Foundation

/// What `--doctor` and the problem report look at. It holds no names, IDs, addresses or window
/// titles, so a report is safe to send to someone else.
public struct DoctorFacts: Equatable, Sendable {
    public var version = ""
    public var build = ""
    public var systemVersion = ""
    public var inApplications = false
    public var quarantined = false
    public var updatesConfigured = false
    public var screenRecording = false
    public var accessibility = false
    public var openAtLogin = false
    public var loginItemNeedsApproval = false
    public var shareOnOpen = false
    public var localNetworkAddress = false
    public var tailscaleAddress = false
    public var virtualDisplayProblem = false
    /// Run from a shell, macOS checks permissions for the shell's app, and the running app's state
    /// (the fields below) is unknown.
    public var fromCommandLine = false
    public var sharing: Bool?
    public var listenerStatus: String?
    public var pairedHosts: Int?
    public var pairedViewers: Int?
    public var connectedViewers: Int?
    public var connectedHosts: Int?

    public init() {}
}

public struct DoctorCheck: Equatable, Sendable {
    public enum Status: String, Sendable { case ok, note, problem }

    public var status: Status
    public var title: String
    public var fix: String?

    public init(_ status: Status, _ title: String, fix: String? = nil) {
        self.status = status
        self.title = title
        self.fix = fix
    }
}

public enum Doctor {
    public static func checks(_ f: DoctorFacts) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        if f.fromCommandLine {
            out.append(DoctorCheck(.note, "Permissions weren't checked, because macOS checks them for the app that ran this command",
                                   fix: "Use This Mac > Copy Problem Report in paneshare."))
        } else {
            out.append(f.screenRecording ? DoctorCheck(.ok, "Screen Recording is on")
                : DoctorCheck(.problem, "Screen Recording is off", fix: "Add paneshare in System Settings > Privacy & Security > Screen Recording. This Mac can't share without it."))
            out.append(f.accessibility ? DoctorCheck(.ok, "Accessibility is on")
                : DoctorCheck(.problem, "Accessibility is off", fix: "Add paneshare in System Settings > Privacy & Security > Accessibility. Viewers can only watch without it."))
        }
        out.append(f.inApplications ? DoctorCheck(.ok, "The app is in Applications")
            : DoctorCheck(.note, "The app isn't in Applications", fix: "Move it to Applications. Open at login and updates work best from there."))
        if f.quarantined {
            out.append(DoctorCheck(.problem, "The app is quarantined", fix: "Open it once from Applications and confirm the macOS prompt."))
        }
        if !f.localNetworkAddress && !f.tailscaleAddress {
            out.append(DoctorCheck(.problem, "This Mac has no network address", fix: "Connect to a network or start Tailscale."))
        } else {
            out.append(DoctorCheck(.ok, "Network: local \(f.localNetworkAddress ? "yes" : "no"), Tailscale \(f.tailscaleAddress ? "yes" : "no")"))
        }
        if f.virtualDisplayProblem {
            out.append(DoctorCheck(.note, "Virtual displays aren't available on this Mac", fix: "Shared windows stay on this Mac's screens."))
        }
        if f.loginItemNeedsApproval {
            out.append(DoctorCheck(.problem, "Open at login needs approval", fix: "Allow paneshare in System Settings > General > Login Items."))
        } else {
            out.append(DoctorCheck(.note, "Open at login: \(f.openAtLogin ? "on" : "off"); sharing when opened: \(f.shareOnOpen ? "on" : "off")"))
        }
        if f.shareOnOpen && !f.openAtLogin {
            out.append(DoctorCheck(.note, "Sharing turns on only after someone opens paneshare", fix: "Turn on Open paneshare when I log in for a Mac with no screen."))
        }
        if !f.updatesConfigured {
            out.append(DoctorCheck(.note, "This build doesn't check for updates"))
        }
        if let sharing = f.sharing {
            out.append(DoctorCheck(.note, "Sharing: \(sharing ? "on" : "off")\(f.listenerStatus.map { " (\($0))" } ?? "")"))
        }
        if let hosts = f.pairedHosts, let viewers = f.pairedViewers {
            out.append(DoctorCheck(.note, "Paired: \(hosts) to view, \(viewers) that can view this Mac"))
            if hosts + viewers == 0 {
                out.append(DoctorCheck(.note, "No Macs are paired", fix: "Turn on sharing on one Mac, then pair from the other."))
            }
        }
        if let connectedHosts = f.connectedHosts, let connectedViewers = f.connectedViewers {
            out.append(DoctorCheck(.note, "Connected now: \(connectedHosts) to view, \(connectedViewers) viewing this Mac"))
        }
        return out
    }

    public static func text(_ f: DoctorFacts) -> String {
        var lines = ["paneshare \(f.version) (\(f.build)), macOS \(f.systemVersion)"]
        for c in checks(f) {
            lines.append("[\(c.status.rawValue)] \(c.title)")
            if let fix = c.fix { lines.append("    \(fix)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func hasProblem(_ f: DoctorFacts) -> Bool { checks(f).contains { $0.status == .problem } }

    /// CGNAT, the range Tailscale gives out: 100.64.0.0/10.
    public static func isTailscale(_ ipv4: String) -> Bool {
        let parts = ipv4.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && parts[1] >= 64 && parts[1] < 128
    }
}
