#if os(macOS)
import PaneshareCore
import PaneshareInput
import SwiftUI

struct HostPanel: View {
    @ObservedObject var host: HostController
    @ObservedObject var trust: TrustModel
    @ObservedObject var model: AppModel
    @State private var linkTarget: ShareLinkTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Share windows from this Mac", isOn: Binding(
                    get: { host.isHosting },
                    set: { $0 ? host.startHosting() : host.stopHosting() }))
                    .toggleStyle(.switch)
                    .font(.headline)
                Spacer()
                Text(host.status).font(.caption).foregroundStyle(.secondary)
            }
            if !model.screenRecording {
                Banner(text: "Screen Recording isn't granted. Sharing can't start. If paneshare isn't in the list, click + and add it.", pane: .screenRecording)
            } else if !model.accessibility {
                Banner(text: "Accessibility isn't granted. Viewers can watch, but can't click, type or resize.",
                       pane: .accessibility)
            }
            if let file = host.lastReceivedFile {
                HStack {
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
                    Text("\(file.from) sent \(file.url.lastPathComponent).")
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                }
                .font(.callout)
            }
            if let opened = host.lastOpenedApp {
                HStack {
                    Image(systemName: "app.badge").foregroundStyle(.secondary)
                    Text("\(opened.by) opened \(opened.name). Its windows are now shared.")
                }
                .font(.callout)
            }
            if let error = host.lastError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            if host.isHosting {
                windowPicker
                Divider()
                viewers
                ShareLinksSection(links: host.shareLinks)
            } else {
                Spacer()
                Text("Turn sharing on, then pick the windows a paired viewer may open. Nothing is reachable while sharing is off.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Windows to share").font(.headline)
                Spacer()
                Button { Task { await host.refreshCandidates() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            Text("Password managers, paneshare's own windows and system overlays are never listed. Sharing a whole screen shows everything else on it, and a paired viewer can click anywhere on it. New password manager windows can take up to 2 seconds to be hidden.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Share the sound of shared apps", isOn: Binding(get: { host.shareAudio }, set: { host.setShareAudio($0) }))
                .font(.callout)
            Toggle("Let paired Macs open apps on this Mac", isOn: Binding(get: { host.offerApps }, set: { host.setOfferApps($0) }))
                .font(.callout)
            Toggle("Remember the apps I share", isOn: Binding(get: { host.rememberApps }, set: { host.setRememberApps($0) }))
                .font(.callout)
            Text("After a restart, windows of apps you ticked are shared again. New windows in those apps are shared too, within about 5 seconds, including private ones. Unticking a window stops the whole app.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Share my whole screen when sharing starts", isOn: Binding(get: { host.offerScreensAtStart }, set: { host.setOfferScreensAtStart($0) }))
                .font(.callout)
            Text("Every paired Mac can see and control everything on this Mac's screens as soon as sharing starts, with nobody here to notice. Password managers stay hidden.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Let paired Macs move shared windows off this screen", isOn: Binding(get: { host.allowMoveAway }, set: { host.setAllowMoveAway($0) }))
                .font(.callout)
            Text("The window goes to a virtual display and stays usable from the other Mac. It comes back when you click Bring Back under Viewers, or when that Mac disconnects.")
                .font(.caption).foregroundStyle(.secondary)
            Text("A paired Mac sees your apps, can open and control any of them, including Terminal, and all that app's windows become shared with every paired Mac. Opening one brings it to the front here. Password managers are left out.")
                .font(.caption).foregroundStyle(.secondary)
            virtualDisplayPicker
            List(host.candidates, id: \.windowID) { w in
                HStack {
                    Toggle(isOn: Binding(get: { host.isOffered(w.windowID) }, set: { host.userSetOffered(w, $0) })) {
                        VStack(alignment: .leading) {
                            Text(w.appName).font(.body)
                            Text(w.title.isEmpty ? "Untitled" : w.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if host.isOffered(w.windowID), w.displayID == nil {
                        Button { linkTarget = ShareLinkTarget(window: w) } label: { Image(systemName: "link.badge.plus") }
                            .buttonStyle(.borderless)
                            .help("Make a link a browser can open")
                    }
                    if host.shareAudio && host.audioPossible(for: w) {
                        let muted = host.audioMutedApps.contains(w.bundleID)
                        Button { host.setAudioMuted(w.bundleID, !muted) } label: {
                            Image(systemName: muted ? "speaker.slash" : "speaker.wave.2")
                        }
                        .buttonStyle(.borderless)
                        .help(muted ? "\(w.appName)'s sound stays on this Mac" : "\(w.appName)'s sound goes to viewers")
                    }
                }
            }
            .frame(minHeight: 160)
            .sheet(item: $linkTarget) { target in
                ShareLinkSheet(window: target.window, links: host.shareLinks)
            }
        }
    }

    private var virtualDisplayPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("Virtual display", selection: Binding(get: { host.virtualDisplayMode }, set: { host.setVirtualDisplayMode($0) })) {
                Text("Off").tag(VirtualDisplayMode.off)
                Text("When needed").tag(VirtualDisplayMode.auto)
                Text("Always").tag(VirtualDisplayMode.always)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .font(.callout)
            if host.virtualDisplayMode != .off, let problem = host.virtualDisplayProblem {
                Text("Not available on this Mac (\(problem)). Windows stay on the real screen.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("For a Mac with no screen, or windows bigger than this Mac's screen: shared windows move to an invisible HiDPI display sized to the viewer's screen, and come back when the viewer closes them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var viewers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Viewers").font(.headline)
                Spacer()
            }
            Text("To pair, click Pair on the other Mac. A prompt appears here; type the code it shows to accept.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = host.pairingMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            ForEach(host.peers) { peer in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                        Text(peer.viewerName)
                        if !peer.movedAwayTitles.isEmpty {
                            Button("Bring Back") { peer.bringBackWindows() }
                                .help("Moved off this screen: " + peer.movedAwayTitles.joined(separator: ", "))
                        }
                        Text(peer.sharedTitles.isEmpty ? "connected" : "viewing " + peer.sharedTitles.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if peer.canSendFiles {
                            Button("Send Files…") { chooseFiles(for: peer) }
                                .help("Send files to \(peer.viewerName). That Mac must accept files and have one of your windows open.")
                        }
                    }
                    if let status = peer.sendStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    if let status = peer.receiveStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard peer.canSendFiles, !files.isEmpty else { return false }
                    peer.sendFiles(files)
                    return true
                }
            }
            ForEach(trust.viewers) { v in
                HStack {
                    Text(v.name)
                    Text(v.fingerprint.shortID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Unpair", role: .destructive) { trust.remove(v.fingerprint, role: .viewer) }
                }
            }
            if trust.viewers.isEmpty { Text("No paired viewers yet.").foregroundStyle(.secondary) }
        }
    }
}

/// Files the host user picks for one viewer. Only regular files; folders are refused by the sender.
@MainActor
private func chooseFiles(for peer: HostPeer) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Send"
    panel.message = "Files go to Downloads/paneshare on \(peer.viewerName)."
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    peer.sendFiles(panel.urls)
}

struct Banner: View {
    let text: String
    let pane: Permissions.Pane
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
            Spacer()
            Button("Open System Settings") { Permissions.open(pane) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
    }
}
#endif
