#if os(macOS)
import Foundation
import PaneshareInput
import ServiceManagement
import SwiftUI

/// Opening paneshare at login, and turning sharing on when it opens. Both are off until the user
/// turns them on. macOS keeps the login item's state, so the app never stores its own copy.
@MainActor
enum LoginItem {
    /// UserDefaults key for the setting.
    static let shareOnOpenKey = "shareOnOpen"

    static var isOn: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns why it failed, or nil.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Without Screen Recording, sharing stays off. A launch nobody is watching must not show a prompt.
    static func shareIfAsked(host: HostController) {
        guard UserDefaults.standard.bool(forKey: shareOnOpenKey) else { return }
        guard Permissions.screenRecording else {
            return NSLog("paneshare: sharing stayed off at launch: no Screen Recording permission")
        }
        host.startHosting()
    }
}

struct StartupSection: View {
    @AppStorage(LoginItem.shareOnOpenKey) private var shareOnOpen = false
    @State private var openAtLogin = LoginItem.isOn
    @State private var needsApproval = LoginItem.needsApproval
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Open paneshare when I log in", isOn: Binding(get: { openAtLogin }, set: { change($0) }))
            Toggle("Turn on sharing when paneshare opens", isOn: $shareOnOpen)
            if needsApproval {
                Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Startup")
        } footer: {
            Text("A user must log in first, because paneshare can't run at the login screen. With sharing on, paired Macs can connect and new Macs can ask to pair. Windows and screens aren't offered again by themselves, so choose them on the Share tab after each launch.")
        }
        .onAppear { refresh() }
    }

    private func change(_ on: Bool) {
        problem = LoginItem.set(on)
        refresh()
    }

    private func refresh() {
        openAtLogin = LoginItem.isOn
        needsApproval = LoginItem.needsApproval
    }
}
#endif
