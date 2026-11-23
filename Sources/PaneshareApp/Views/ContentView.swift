#if os(macOS)
import PaneshareCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var tab: Tab = .connect

    enum Tab: Hashable { case connect, share, about }

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading this Mac's identity…")
        case .failed(let why):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("paneshare couldn't load its identity from the Keychain.").font(.headline)
                Text(why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Nothing was created or overwritten. Check Keychain Access, or reset below.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Reset identity and quit", role: .destructive) { model.resetIdentity() }
            }
            .padding(40)
        case .ready:
            if model.showOnboarding {
                OnboardingView(model: model)
            } else if let host = model.host, let viewer = model.viewer, let trust = model.trust {
                VStack(spacing: 12) {
                LocalNetworkBanner(viewer: viewer)
                TabView(selection: $tab) {
                    ViewerPanel(viewer: viewer, trust: trust)
                        .tabItem { Label("Connect", systemImage: "macwindow.on.rectangle") }
                        .tag(Tab.connect)
                    HostPanel(host: host, trust: trust, model: model)
                        .tabItem { Label("Share", systemImage: "rectangle.portrait.and.arrow.right") }
                        .tag(Tab.share)
                    AboutPanel(model: model)
                        .tabItem { Label("This Mac", systemImage: "info.circle") }
                        .tag(Tab.about)
                }
                }
                .padding()
            }
        }
    }
}

struct AboutPanel: View {
    @ObservedObject var model: AppModel
    @AppStorage(ClipboardBridge.enabledKey) private var clipboardSync = false
    @AppStorage(FileReceiver.enabledKey) private var receiveFiles = false
    @AppStorage(FileReceiver.fromHostsKey) private var receiveFromHosts = false
    @State private var reportCopied = false
    @AppStorage(HostColors.borderKey) private var windowBorder = false

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Mac ID", value: model.fingerprint?.shortID ?? "—")
                LabeledContent("Fingerprint") {
                    Text(model.fingerprint?.hex ?? "—").font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Key storage",
                               value: model.strongKeychain ? "Data-protection keychain"
                                                           : "Login keychain (development build without a provisioning profile)")
            }
            Section {
                Toggle("Sync the clipboard with paired Macs", isOn: $clipboardSync)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Plain text, up to 1 MB. Both Macs must turn this on. Text moves only while a window from the other Mac is in front, and items that apps mark as private stay here. macOS may ask you to allow clipboard access.")
            }
            Section {
                Toggle("Accept files dropped on my shared windows", isOn: $receiveFiles)
                Toggle("Accept files from Macs I connect to", isOn: $receiveFromHosts)
            } header: {
                Text("Files")
            } footer: {
                Text("Single files up to 2 GB go to Downloads/paneshare on this Mac and never replace a file there. They are marked as downloaded, so macOS checks apps and scripts before they run. A Mac you share with can start sending files only while one of your windows is open on it. A Mac you connect to can start sending them only while one of its windows is open here.")
            }
            StartupSection()
            Section {
                Toggle("Outline remote windows in their Mac's colour", isOn: $windowBorder)
            } header: {
                Text("Remote windows")
            } footer: {
                Text("Applies to windows you open from now on. Choose a Mac's colour from the … menu on its row. A Dock icon that already exists keeps its ring colour.")
            }
            Section("Permissions") {
                PermissionRow(title: "Screen Recording", granted: model.screenRecording, pane: .screenRecording)
                PermissionRow(title: "Accessibility", granted: model.accessibility, pane: .accessibility)
                if let viewer = model.viewer { LocalNetworkRow(viewer: viewer) }
                Button("Show setup again") { model.showOnboarding = true }
            }
            Section {
                Button("Copy Problem Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DoctorRunner.report(model: model), forType: .string)
                    reportCopied = true
                }
                if reportCopied { Text("Copied.").font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Problems")
            } footer: {
                Text("Stays on this Mac until you paste it somewhere. It has versions, settings and counts, and no names, addresses, IDs or window titles.")
            }
            Section {
                Button("Reset identity and all pairings…", role: .destructive) { model.resetIdentity() }
            } footer: {
                Text("Every paired Mac will have to pair again. paneshare quits so the new identity takes effect.")
            }
        }
        .formStyle(.grouped)
    }
}
#endif
