#if os(macOS)
import PaneshareCore
import PaneshareDiscovery
import SwiftUI

struct ViewerPanel: View {
    @ObservedObject var viewer: ViewerController
    @ObservedObject var trust: TrustModel
    @State private var pairingTarget: PairTarget?
    @AppStorage(ViewerSession.qualityKey) private var quality: StreamQuality = .native
    @AppStorage(ViewerSession.autoQualityKey) private var autoQuality = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Quality for new windows", selection: $quality) {
                    Text("Native").tag(StreamQuality.native)
                    Text("Balanced (¾ resolution)").tag(StreamQuality.balanced)
                    Text("Economy (½ resolution)").tag(StreamQuality.economy)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Toggle("Lower quality automatically on a slow network", isOn: $autoQuality)
                    .help("The host lowers the bitrate when video frames drop, and raises it again when the network recovers. Applies to windows you open from now on.")
                section("Paired Macs") {
                    if viewer.sessions.isEmpty {
                        Text("No paired Macs yet. Pair with one below.").foregroundStyle(.secondary)
                    }
                    ForEach(viewer.sessions) { s in
                        HostRow(session: s, viewer: viewer)
                    }
                }
                section("On this network") {
                    if viewer.unpaired.isEmpty {
                        Text(viewer.discoveryStatus.isEmpty ? "No other Macs are sharing." : viewer.discoveryStatus)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewer.unpaired) { h in
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(h.name)
                            if let id = h.hostID { Text(id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Pair") { pairingTarget = .discovered(h) }
                        }
                    }
                    Button("Pair by address (Tailscale or IP)…") { pairingTarget = .address }
                }
                if let message = viewer.pairingMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
        .sheet(item: $pairingTarget) { target in
            PairSheet(target: target, viewer: viewer) { pairingTarget = nil }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

enum PairTarget: Identifiable {
    case discovered(DiscoveredHost)
    case address
    var id: String {
        switch self {
        case .discovered(let h): return "d:" + h.id
        case .address: return "address"
        }
    }
}

private struct HostRow: View {
    @State private var colorIndex: Int?
    @ObservedObject var session: ViewerSession
    @ObservedObject var viewer: ViewerController
    @State private var editingAddress = false
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: HostColors.color(index: colorIndex ?? HostColors.index(for: session.host.fingerprint))))
                    .frame(width: 4, height: 14)
                    .help("This Mac's colour")
                Text(session.host.name).font(.body.bold())
                Text(stateText).font(.caption).foregroundStyle(.secondary)
                if let rtt = session.rtt, session.state == .connected {
                    Text(String(format: "%.0f ms", rtt * 1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                switch session.state {
                case .idle:
                    Button("Connect") { session.connect() }
                case .failed:
                    Button("Stop Trying") { session.disconnect() }
                case .connecting, .connected:
                    Button("Disconnect") { session.disconnect() }
                }
                Menu {
                    Picker("Colour", selection: Binding(get: { colorIndex ?? HostColors.index(for: session.host.fingerprint) },
                                                        set: { colorIndex = $0; HostColors.setIndex($0, for: session.host.fingerprint) })) {
                        ForEach(SourceMacColor.names.indices, id: \.self) { i in
                            Text(SourceMacColor.names[i]).tag(i)
                        }
                    }
                    Button("Set address…") { address = session.host.lastAddress ?? ""; editingAddress = true }
                    Button("Unpair", role: .destructive) { viewer.forget(session.host) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            if let status = session.fileStatus {
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    if let file = session.lastReceivedFile, status.hasSuffix(file.lastPathComponent + ".") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                            .font(.caption)
                    }
                }
            }
            if session.state == .connected {
                if session.windows.isEmpty {
                    Text(session.apps.isEmpty ? "This Mac isn't sharing any windows yet." : "No windows are shared yet. You can open an app below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if session.windows.filter({ $0.displayID != nil }).count > 1 {
                    Button("Open every screen") { session.openApp(bundleID: ScreenOffer.bundleID) }
                        .font(.callout)
                }
                ForEach(session.windows, id: \.windowID) { w in
                    HStack {
                        Text(w.appName)
                        Text(w.title).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if session.movedAwayWindows.contains(w.windowID) {
                            Button("Bring Back") { session.setMovedAway(false, windowID: w.windowID) }
                                .help("Put this window back on the other Mac's screen")
                        } else if session.movableWindows.contains(w.windowID) {
                            Button("Move Away") { session.setMovedAway(true, windowID: w.windowID) }
                                .help("Take this window off the other Mac's screen. You keep control of it here.")
                        }
                        if session.openWindowIDs.contains(w.windowID) {
                            Button("Show") { session.focus(w.windowID) }
                        } else {
                            Button("Open") { session.open(w.windowID) }
                        }
                    }
                    .padding(.leading, 16)
                }
                if !session.apps.isEmpty {
                    RemoteAppsSection(session: session)
                }
                if !session.openApps.isEmpty {
                    Text("Sound").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(session.openApps, id: \.bundleID) { app in
                        AppSoundRow(session: session, bundleID: app.bundleID, appName: app.appName)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .alert("Address for \(session.host.name)", isPresented: $editingAddress) {
            TextField("studio.tailnet.ts.net or 100.x.y.z", text: $address)
            Button("Save") { viewer.setAddress(address, for: session.host) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used when the Mac isn't found on the local network, for example over Tailscale.")
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var stateText: String {
        switch session.state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let why): return "Retrying. \(why)"
        }
    }
}

/// Pairing from this Mac: clicking Pair asks the host right away and shows the code its user must
/// type into the prompt that appears there.
private struct PairSheet: View {
    let target: PairTarget
    @ObservedObject var viewer: ViewerController
    let dismiss: () -> Void
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch target {
            case .discovered(let h):
                Text("Pair with “\(h.name)”").font(.title2.bold())
            case .address:
                Text("Pair by address").font(.title2.bold())
                TextField("Host name, Tailscale name or IP (port optional)", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewer.pairingBusy)
                    .onSubmit(start)
            }
            if let code = viewer.pairingCode {
                Text(PairingCode.grouped(code))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            } else {
                Text("The other Mac must have sharing turned on. A prompt will appear there; you'll get a code to type into it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = viewer.pairingMessage {
                HStack(spacing: 8) {
                    if viewer.pairingBusy { ProgressView().controlSize(.small) }
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("This Mac's ID: \(viewer.ownID). The prompt on the other Mac shows the same ID.")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(viewer.pairingBusy ? "Cancel" : "Close") {
                    if viewer.pairingBusy { viewer.cancelPairing() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if !viewer.pairingBusy {
                    Button(viewer.pairingMessage == nil ? "Pair" : "Try again", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isAddress && address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            viewer.pairingMessage = nil
            if !isAddress { start() }
        }
        .onDisappear { if viewer.pairingBusy { viewer.cancelPairing() } }
        .onChange(of: viewer.pairedName) { _, name in
            if name != nil { dismiss() }
        }
    }

    private var isAddress: Bool {
        if case .address = target { return true }
        return false
    }

    private func start() {
        switch target {
        case .discovered(let h): viewer.pair(with: h)
        case .address: viewer.pair(address: address)
        }
    }
}
/// Mute and volume for one remote app, saved per host and app.
private struct AppSoundRow: View {
    @ObservedObject var session: ViewerSession
    let bundleID: String
    let appName: String

    var body: some View {
        let mix = session.audioMix(for: bundleID)
        HStack {
            Button {
                session.setAudioMix(AudioMix(muted: !mix.muted, volume: mix.volume), for: bundleID)
            } label: {
                Image(systemName: mix.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(mix.muted ? Color.secondary : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(mix.muted ? "Unmute \(appName)" : "Mute \(appName)")
            Text(appName).lineLimit(1)
            Slider(value: Binding(get: { mix.volume },
                                  set: { session.setAudioMix(AudioMix(muted: mix.muted, volume: $0), for: bundleID) }),
                   in: 0...1)
                .frame(maxWidth: 140)
                .disabled(mix.muted)
            Text(status(mix)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
    }

    private func status(_ mix: AudioMix) -> String {
        if mix.muted { return "muted" }
        return session.playingAudio[bundleID] != nil ? "playing" : "no sound"
    }
}
#endif
