#if os(macOS)
import AppKit
import Foundation
import PaneshareCore
import PaneshareInput
import ServiceManagement

/// `paneshare --doctor` prints what might be wrong on this Mac and exits, 1 if it found a problem.
/// It opens no window or listener, and doesn't read the Keychain. The app's own problem report adds
/// what only the running app knows.
@MainActor
enum DoctorRunner {
    static let flag = "--doctor"

    static func requested(_ arguments: [String] = CommandLine.arguments) -> Bool { arguments.contains(flag) }

    static func run() -> Never {
        var facts = baseFacts()
        facts.fromCommandLine = true
        print(Doctor.text(facts), terminator: "")
        exit(Doctor.hasProblem(facts) ? 1 : 0)
    }

    static func report(model: AppModel) -> String {
        var facts = baseFacts()
        facts.screenRecording = Permissions.screenRecording
        facts.accessibility = Permissions.accessibility
        if let host = model.host {
            facts.sharing = host.isHosting
            facts.listenerStatus = host.status
            facts.connectedViewers = host.peers.count
            facts.virtualDisplayProblem = host.virtualDisplayProblem != nil
        }
        if let trust = model.trust {
            facts.pairedHosts = trust.hosts.count
            facts.pairedViewers = trust.viewers.count
        }
        if let viewer = model.viewer {
            facts.connectedHosts = viewer.sessions.filter { $0.state == .connected }.count
            facts.localNetworkBlocked = viewer.localNetworkBlocked
        }
        return Doctor.text(facts)
    }

    private static func baseFacts() -> DoctorFacts {
        var facts = DoctorFacts()
        let bundle = Bundle.main
        facts.version = AppInfo.version
        facts.build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        facts.systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        facts.inApplications = bundle.bundleURL.path.hasPrefix("/Applications/")
        facts.quarantined = DockHelperFactory.hasQuarantine(bundle.bundleURL)
        facts.updatesConfigured = bundle.object(forInfoDictionaryKey: UpdateConfiguration.feedURLKey) != nil
        let status = SMAppService.mainApp.status
        facts.openAtLogin = status == .enabled
        facts.loginItemNeedsApproval = status == .requiresApproval
        facts.shareOnOpen = UserDefaults.standard.bool(forKey: LoginItem.shareOnOpenKey)
        let addresses = LocalAddresses.ipv4()
        facts.tailscaleAddress = addresses.contains(where: Doctor.isTailscale)
        facts.localNetworkAddress = addresses.contains { !Doctor.isTailscale($0) }
        return facts
    }
}
#endif
