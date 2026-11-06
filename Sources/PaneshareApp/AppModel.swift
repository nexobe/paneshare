#if os(macOS)
import AppKit
import Foundation
import PaneshareCore
import PaneshareInput
import PaneshareTransport
import PaneshareViewer

/// Loads this Mac's identity and trust list, and owns both roles. One process does both: a Mac can
/// share windows and view another Mac's windows at the same time.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case loading, ready, failed(String) }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var screenRecording = Permissions.screenRecording
    @Published private(set) var accessibility = Permissions.accessibility
    @Published var showOnboarding = false

    private(set) var host: HostController?
    private(set) var viewer: ViewerController?
    private(set) var trust: TrustModel?
    private(set) var fingerprint: Fingerprint?
    private(set) var strongKeychain = true
    private let keychain = KeychainStore()
    private var permissionTimer: Timer?
    private var dockHelpers: HelperDockPresenter?
    private var terminationObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?

    init() {
        load()
        showOnboarding = !(screenRecording && accessibility) && !UserDefaults.standard.bool(forKey: "onboardingDone")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    private func load() {
        do {
            let device = try keychain.loadOrCreateIdentity()
            let tls = try TLSIdentity(device)
            let trust = try TrustModel(keychain: keychain)
            // Per-app Dock helpers unless turned off (`defaults write dev.paneshare.app dockHelpers -bool false`).
            let (dock, helpers) = HelperDockPresenter.make(
                mainBundleID: Bundle.main.bundleIdentifier,
                enabled: UserDefaults.standard.object(forKey: "dockHelpers") as? Bool ?? true)
            self.trust = trust
            self.fingerprint = device.fingerprint
            self.strongKeychain = keychain.isDataProtection
            let host = HostController(identity: tls, trust: trust)
            self.host = host
            let viewer = ViewerController(identity: tls, trust: trust, dock: dock)
            self.viewer = viewer
            if let helpers {
                self.dockHelpers = helpers
                helpers.onColdStart = { [weak viewer] hostID, bundleID in viewer?.openRemoteApp(hostID: hostID, bundleID: bundleID) }
                helpers.cleanUp(pairedHostIDs: Set(trust.hosts.map(\.fingerprint.hex)))
                terminationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak helpers] _ in
                    MainActor.assumeIsolated { helpers?.shutDown() }
                }
            }
            // Windows on a virtual display go back to a real screen before the display is released.
            quitObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.host?.stopHosting()
                    VirtualDisplayManager.shared.destroyAll()
                }
            }
            viewer.start()
            phase = .ready
            LoginItem.shareIfAsked(host: host)
        } catch {
            phase = .failed("\(error)")
        }
    }

    func refreshPermissions() {
        let sr = Permissions.screenRecording, ax = Permissions.accessibility
        if sr != screenRecording { screenRecording = sr }
        if ax != accessibility { accessibility = ax }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        showOnboarding = false
    }

    /// Forget this Mac's identity and every pairing; takes effect after relaunch.
    func resetIdentity() {
        host?.stopHosting()
        keychain.reset()
        NSApp.terminate(nil)
    }
}
#endif
