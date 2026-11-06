#if os(macOS)
import AppKit
import Combine
import PaneshareCore
import Sparkle
import SwiftUI

/// Sparkle 2 behind paneshare's own rules (docs/RELEASING.md): it only starts in a build whose
/// Info.plist has a complete, HTTPS, signed-feed configuration (`UpdateConfiguration`), and it never
/// checks on its own until the user has said yes, which is asked once on first launch. Checks are
/// then daily (`SUScheduledCheckInterval`); installing always asks first.
@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    let status: Result<UpdateConfiguration, UpdateConfiguration.Problem>

    private let controller: SPUStandardUpdaterController?
    private let defaults: UserDefaults
    private var started = false

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        status = UpdateConfiguration.from(info: bundle.infoDictionary ?? [:])
        guard case .success = status else {
            controller = nil
            if case .failure(let problem) = status, problem != .notConfigured {
                NSLog("paneshare: updates disabled: %@", problem.explanation)
            }
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
    }

    var isConfigured: Bool { controller != nil }

    /// Call once the app has finished launching.
    func startAfterConsent() {
        guard let controller, !started else { return }
        let decided = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool
        if UpdateConsent.shouldAsk(configured: true, alreadyAsked: defaults.bool(forKey: UpdateConsent.askedKey),
                                   automaticChecksSetting: decided) {
            controller.updater.automaticallyChecksForUpdates = askForConsent()
            defaults.set(true, forKey: UpdateConsent.askedKey)
        }
        controller.startUpdater()
        started = true
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    private func askForConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Check for paneshare updates automatically?"
        var host = "the update server"
        if case .success(let config) = status, let h = config.feedURL.host { host = h }
        alert.informativeText = """
            paneshare can look for a new version once a day at \(host). Only the update feed is \
            requested (with paneshare's and macOS's version numbers); nothing is installed without asking you. \
            You can change this any time in the paneshare menu.
            """
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The app menu items: "Check for Updates…" and the automatic-check switch.
struct UpdateCommands: Commands {
    @ObservedObject var updater: UpdaterController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            if updater.isConfigured {
                Toggle("Check for Updates Automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.setAutomaticallyChecks($0) }
                ))
            }
        }
    }
}
#endif
