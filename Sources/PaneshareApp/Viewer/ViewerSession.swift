#if os(macOS)
import AppKit
import Foundation
import Network
import PaneshareAudio
import PaneshareCore
import PaneshareDecode
import PaneshareTransport
import PaneshareViewer

/// The viewer's session with one paired host: hello, the offered window list, and one
/// `RemoteWindowController` per opened window. Video goes from the network queue straight to each
/// stream's renderer; everything else is handled on the main actor. A dropped connection is
/// re-dialed with backoff and the open windows are re-opened by window ID.
@MainActor
final class ViewerSession: ObservableObject, Identifiable {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    nonisolated let id: Fingerprint
    let host: PairedPeer
    @Published private(set) var state: State = .idle
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var rtt: TimeInterval?

    private let identity: TLSIdentity
    private let dock: DockPresenter
    private let endpoint: () -> NWEndpoint?
    private let queue = DispatchQueue(label: "dev.paneshare.viewer.net", qos: .userInteractive)
    private var channel: TLSMessageChannel?
    private var saidHello = false
    private var wanted = false
    private var backoff = ReconnectBackoff()
    /// When both sides last said hello, on the uptime clock. nil while there's no working session.
    private var connectedAt: TimeInterval?
    private var pingTimer: Timer?
    private var pendingAppOpen: String?
    private var clipboard: ClipboardBridge?
    private var files: FileSender?
    private var incoming: FileReceiver?
    /// The latest file this host sent here.
    @Published private(set) var lastReceivedFile: URL?
    /// The apps this host lets this Mac open. Empty if it offers none, or doesn't know how.
    @Published private(set) var apps: [RemoteApp] = []
    /// The latest message about files sent from this Mac, or apps opened on the host.
    @Published private(set) var fileStatus: String?
    /// The latest message about a file this host sends here.
    @Published private(set) var incomingStatus: String?
    /// UserDefaults key for the `StreamQuality` new windows are opened with.
    nonisolated static let qualityKey = "streamQuality"
    /// UserDefaults key for lowering the bitrate on a slow network. Off unless the user turns it on.
    nonisolated static let autoQualityKey = "autoQuality"
    /// Hidden UserDefaults key capping the chroma format asked for (`ChromaFormat.accepted(setting:)`).
    nonisolated static let chromaKey = "chroma"
    /// Set after a 4:2:2 or 4:4:4 stream from this host failed to decode here; until relaunch,
    /// windows from this host are opened in 4:2:0.
    private var chroma420Only = false
    /// windowID → the quality it was opened with.
    private var openedQuality: [UInt32: StreamQuality] = [:]

    /// streamID → controller, main actor.
    private var controllers: [UInt16: RemoteWindowController] = [:]
    /// windowID → controller, kept across reconnects.
    private var byWindow: [UInt32: RemoteWindowController] = [:] {
        didSet { openWindowIDs = Set(byWindow.keys) }
    }
    @Published private(set) var openWindowIDs: Set<UInt32> = []
    /// Windows the host lets this Mac move off its screens, and those moved now.
    @Published private(set) var movableWindows: Set<UInt32> = []
    @Published private(set) var movedAwayWindows: Set<UInt32> = []
    /// streamID → renderer, read by the network queue.
    private let renderers = Locked<[UInt16: StreamRenderer]>([:])
    /// streamID → remote app audio, read by the network queue.
    private let audioStreams = Locked<[UInt16: RemoteAudioStream]>([:])
    /// Remote apps with sound playing here, bundleID → stream ID.
    @Published private(set) var playingAudio: [String: UInt16] = [:]
    private var mixStore: AudioMixStore { .shared }

    struct OpenApp: Hashable { let bundleID: String; let appName: String }

    /// Apps with a window open here, for the per-app sound controls.
    var openApps: [OpenApp] {
        Set(byWindow.values.map { OpenApp(bundleID: $0.remote.bundleID, appName: $0.remote.appName) })
            .sorted { ($0.appName, $0.bundleID) < ($1.appName, $1.bundleID) }
    }

    init(host: PairedPeer, identity: TLSIdentity, dock: DockPresenter, endpoint: @escaping () -> NWEndpoint?) {
        self.id = host.fingerprint
        self.host = host
        self.identity = identity
        self.dock = dock
        self.endpoint = endpoint
    }

    // MARK: Connection

    func connect() {
        wanted = true
        guard channel == nil else { return }
        guard let endpoint = endpoint() else {
            state = .failed("Not found. Sharing may be off on that Mac. If it's on another network, add its address.")
            return scheduleRetry()
        }
        // While retrying, keep showing why the last try failed, so the status doesn't flicker.
        if !isFailed { state = .connecting }
        saidHello = false
        let pinned = host.fingerprint
        let channel = Dialer.connect(to: endpoint, identity: identity, alpn: PinnedTLS.sessionALPN, queue: queue) { $0 == pinned }
        self.channel = channel
        let renderers = self.renderers
        let audioStreams = self.audioStreams
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            onMain { if self.channel === channel { self.ready() } }
        }
        channel.onMessage = { [weak self, weak channel] frame in
            // Video skips the main thread.
            switch frame.kind {
            case .videoFrame:
                guard let r = renderers.withLock({ $0[frame.streamID] }),
                      let payload = try? VideoFramePayload(decoding: frame.payload) else { return }
                r.frame(payload, isKeyframe: frame.flags.contains(.keyframe), isTopUp: frame.flags.contains(.topUp))
            case .parameterSets:
                guard let r = renderers.withLock({ $0[frame.streamID] }),
                      let sets = try? ParameterSets(decoding: frame.payload) else { return }
                r.parameterSets(sets)
            case .audioFrame:
                guard let a = audioStreams.withLock({ $0[frame.streamID] }),
                      let payload = try? AudioFramePayload(decoding: frame.payload) else { return }
                a.receive(payload)
            default:
                guard let self, let channel else { return }
                onMain { if self.channel === channel { self.handle(frame) } }
            }
        }
        // A late callback from a channel this session already replaced is ignored.
        channel.onClose = { [weak self, weak channel] error in
            guard let self, let channel else { return }
            let text = error.map { "\($0)" }
            onMain { if self.channel === channel { self.closed(text) } }
        }
        channel.start()
    }

    private func startClipboard() {
        clipboard?.stop()
        let bridge = ClipboardBridge(
            isViewer: true,
            localFocus: { [weak self] in
                guard let self, NSApp.isActive else { return false }
                return self.byWindow.values.contains { $0.window?.isKeyWindow == true }
            },
            sendState: { [weak self] in self?.send(.clipboardState, $0) },
            sendText: { [weak self] in self?.channel?.send(Frame(kind: .clipboardText, payload: $0)) })
        clipboard = bridge
        bridge.start()
        files?.stop()
        files = FileSender(send: { [weak self] in self?.channel?.send($0) },
                           status: { [weak self] in self?.fileStatus = $0 })
        incoming?.discard()
        incoming = FileReceiver(
            settingKey: FileReceiver.fromHostsKey,
            hasOpenStream: { [weak self] in self.map { !$0.byWindow.isEmpty } ?? false },
            reply: { [weak self] in self?.send(.fileReply, $0) },
            progress: { [weak self] name, percent in
                guard let self else { return }
                self.lastReceivedFile = nil
                self.incomingStatus = "Receiving \(name) from \(self.host.name): \(percent)%"
            },
            finished: { [weak self] url, _ in
                guard let self else { return }
                self.lastReceivedFile = url
                self.incomingStatus = "\(self.host.name) sent \(url.lastPathComponent)."
            })
    }

    func disconnect() {
        apps = []
        movableWindows = []
        movedAwayWindows = []
        clipboard?.stop()
        clipboard = nil
        files?.stop()
        files = nil
        incoming?.discard()
        incoming = nil
        wanted = false
        backoff.reset()
        connectedAt = nil
        for c in Array(byWindow.values) { c.closeFromHost() }
        byWindow.removeAll()
        controllers.removeAll()
        renderers.withLock { $0.removeAll() }
        stopAllAudio()
        channel?.close()
        channel = nil
        state = .idle
    }

    private func ready() {
        send(.hello, Hello(appVersion: AppInfo.version, deviceName: AppInfo.deviceName, role: .viewer))
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ping() }
        }
    }

    private func closed(_ error: String?) {
        apps = []
        movableWindows = []
        movedAwayWindows = []
        clipboard?.stop()
        clipboard = nil
        files?.stop()
        files = nil
        incoming?.discard()
        incoming = nil
        channel = nil
        backoff.sessionEnded(lasted: connectedAt.map { ProcessInfo.processInfo.systemUptime - $0 })
        connectedAt = nil
        pingTimer?.invalidate()
        renderers.withLock { $0.removeAll() }
        stopAllAudio()
        controllers.removeAll()
        for c in byWindow.values { c.renderer.reset() }
        guard wanted else { state = .idle; return }
        // Keep a more specific reason set just before this side closed the channel.
        if error != nil || !isFailed { state = .failed(error ?? "Disconnected.") }
        scheduleRetry()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func scheduleRetry() {
        guard wanted else { return }
        let delay = backoff.nextDelay()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wanted, self.channel == nil else { return }
                self.connect()
            }
        }
    }

    // MARK: Messages

    private func handle(_ frame: Frame) {
        guard saidHello else {
            switch SessionRules.checkHello(frame, expecting: .host) {
            case .success:
                saidHello = true
                connectedAt = ProcessInfo.processInfo.systemUptime
                state = .connected
                // Re-open what was open before a reconnect.
                for windowID in byWindow.keys { open(windowID) }
                startClipboard()
                refreshApps()
            case .failure(let problem):
                if frame.kind == .error, let e = try? MessageCodec.decode(ProtocolErrorMessage.self, from: frame) {
                    state = .failed(e.message)
                } else {
                    state = .failed("The host doesn't speak this protocol (\(problem)).")
                }
                channel?.close()
            }
            return
        }
        guard let kind = frame.kind else { return }
        switch kind {
        case .clipboardState:
            if let state = try? MessageCodec.decode(ClipboardState.self, from: frame) { clipboard?.peerState(state) }
        case .clipboardText:
            clipboard?.received(frame.payload)
        case .appList:
            apps = (try? MessageCodec.decode([RemoteApp].self, from: frame)) ?? []
        case .openAppResult:
            if let result = try? MessageCodec.decode(OpenAppResult.self, from: frame) { appOpened(result) }
        case .fileReply:
            if let reply = try? MessageCodec.decode(FileReply.self, from: frame) { files?.reply(reply) }
        case .fileOffer:
            if let offer = try? MessageCodec.decode(FileOffer.self, from: frame) { incoming?.offer(offer) }
        case .fileChunk:
            incoming?.chunk(frame.payload)
        case .fileEnd:
            if let end = try? MessageCodec.decode(FileEnd.self, from: frame) { incoming?.end(end) }
        case .windowList:
            windows = (try? MessageCodec.decode([WindowInfo].self, from: frame)) ?? []
            // A window the host stopped offering closes here too.
            let offered = Set(windows.map(\.windowID))
            for (id, c) in byWindow where !offered.contains(id) {
                byWindow[id] = nil
                c.closeFromHost()
            }
            if let bundleID = pendingAppOpen {
                pendingAppOpen = nil
                openWindows(of: bundleID)
            }
        case .streamStarted:
            guard let started = try? MessageCodec.decode(StreamStarted.self, from: frame) else { return }
            streamStarted(started)
        case .resized:
            // Replies to mid-drag requests can land after the drag ended; only the final size counts.
            guard let r = try? MessageCodec.decode(Resized.self, from: frame), r.final != false else { return }
            controllers[frame.streamID]?.hostResized(to: r.pointSize.cgSize, pixelSize: r.pixelSize)
        case .streamInfo:
            guard let info = try? MessageCodec.decode(StreamInfo.self, from: frame) else { return }
            guard let controller = controllers[frame.streamID] else { return }
            controller.streamInfo = info
            let id = controller.remote.windowID
            if info.movable == true { movableWindows.insert(id) } else { movableWindows.remove(id) }
            if info.movedAway == true { movedAwayWindows.insert(id) } else { movedAwayWindows.remove(id) }
        case .inputState:
            guard let s = try? MessageCodec.decode(InputState.self, from: frame) else { return }
            controllers[frame.streamID]?.inputPause = s.paused
        case .closeStream:
            guard let c = controllers.removeValue(forKey: frame.streamID) else { return }
            renderers.withLock { $0[frame.streamID] = nil }
            byWindow[c.remote.windowID] = nil
            c.closeFromHost()
        case .audioStarted:
            guard let started = try? MessageCodec.decode(AudioStarted.self, from: frame) else { return }
            audioStarted(started, streamID: frame.streamID)
        case .audioStopped:
            stopAudio(streamID: frame.streamID)
        case .pong:
            if let sent = PingPayload.decode(frame.payload) {
                rtt = max(0, Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1e9)
            }
        case .ping:
            channel?.send(Frame(kind: .pong, payload: frame.payload.prefix(8)))
        case .error:
            if let e = try? MessageCodec.decode(ProtocolErrorMessage.self, from: frame) {
                NSLog("paneshare: host error %@: %@", e.code, e.message)
            }
        default:
            break
        }
    }

    // MARK: Windows

    func open(_ windowID: UInt32) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let quality = openedQuality[windowID]
            ?? UserDefaults.standard.string(forKey: ViewerSession.qualityKey).flatMap(StreamQuality.init) ?? .native
        openedQuality[windowID] = quality
        let chroma: [ChromaFormat] = chroma420Only ? [.yuv420] : ChromaFormat.accepted(setting: UserDefaults.standard.string(forKey: ViewerSession.chromaKey))
        let wantsAudio = windows.first { $0.windowID == windowID }.map { !mixStore.mix(host: host.fingerprint, bundleID: $0.bundleID).muted } ?? true
        send(.openWindow, OpenWindow(windowID: windowID, viewerBackingScale: Double(scale), quality: quality, chroma: chroma,
                                     audio: wantsAudio, viewerDisplay: NSScreen.main.map { WireSize($0.visibleFrame.size) },
                                     adaptiveQuality: UserDefaults.standard.bool(forKey: ViewerSession.autoQualityKey)))
    }

    // MARK: Audio

    private func audioStarted(_ started: AudioStarted, streamID: UInt16) {
        if let existing = audioStreams.withLock({ $0[streamID] }) {
            do { try existing.restart(started) } catch { stopAudio(streamID: streamID) }
            return
        }
        // One stream per app; a second one for the same app replaces the first.
        if let old = playingAudio[started.bundleID] { stopAudio(streamID: old) }
        do {
            let stream = try RemoteAudioStream(streamID: streamID, started: started)
            stream.output.volume = mixStore.mix(host: host.fingerprint, bundleID: started.bundleID).effectiveGain
            audioStreams.withLock { $0[streamID] = stream }
            playingAudio[started.bundleID] = streamID
        } catch {
            NSLog("paneshare viewer: can't play %@'s audio: %@", started.appName, "\(error)")
            send(.audioControl, AudioControl(bundleID: started.bundleID, enabled: false))
        }
    }

    private func stopAudio(streamID: UInt16) {
        guard let stream = audioStreams.withLock({ $0.removeValue(forKey: streamID) }) else { return }
        stream.stop()
        if playingAudio[stream.started.bundleID] == streamID { playingAudio[stream.started.bundleID] = nil }
    }

    private func stopAllAudio() {
        let all = audioStreams.withLock { streams -> [RemoteAudioStream] in
            defer { streams.removeAll() }
            return Array(streams.values)
        }
        for stream in all { stream.stop() }
        playingAudio.removeAll()
    }

    func audioMix(for bundleID: String) -> AudioMix { mixStore.mix(host: host.fingerprint, bundleID: bundleID) }

    /// The viewer's mute and volume for one remote app. Muting also stops the audio at the host,
    /// so a muted app costs no bandwidth; unmuting asks for it again.
    func setAudioMix(_ mix: AudioMix, for bundleID: String) {
        let wasMuted = audioMix(for: bundleID).muted
        mixStore.set(mix, host: host.fingerprint, bundleID: bundleID)
        objectWillChange.send()
        if let id = playingAudio[bundleID], let stream = audioStreams.withLock({ $0[id] }) {
            stream.output.volume = mix.effectiveGain
        }
        guard mix.muted != wasMuted, state == .connected else { return }
        send(.audioControl, AudioControl(bundleID: bundleID, enabled: !mix.muted))
    }

    /// Buffer health of one app's audio, for diagnostics.
    func audioStats(for bundleID: String) -> RemoteAudioOutput.Stats? {
        guard let id = playingAudio[bundleID] else { return nil }
        return audioStreams.withLock { $0[id] }?.output.stats
    }

    /// This Mac couldn't decode a 4:2:2 or 4:4:4 stream: re-open the window as 4:2:0, keeping the
    /// local window, and stay on 4:2:0 for this host until relaunch.
    private func fallBackTo420(_ controller: RemoteWindowController) {
        guard controllers[controller.streamID] === controller, let chroma = controller.streamInfo?.chroma,
              chroma != .yuv420 else { return }
        NSLog("paneshare viewer: %@ stream from %@ failed to decode here; re-opening in 4:2:0", chroma.rawValue, host.name)
        chroma420Only = true
        let old = controller.streamID
        send(.closeStream, CloseStream(reason: .viewerClosed), streamID: old)
        controllers[old] = nil
        renderers.withLock { $0[old] = nil }
        controller.renderer.reset()
        open(controller.remote.windowID)
    }

    func setMovedAway(_ away: Bool, windowID: UInt32) {
        guard let streamID = controllers.first(where: { $0.value.remote.windowID == windowID })?.key else { return }
        send(.windowPlacement, WindowPlacement(away: away), streamID: streamID)
    }

    func focus(_ windowID: UInt32) {
        byWindow[windowID]?.show()
    }

    /// Opens every offered window of `bundleID`, now or as soon as the window list arrives.
    func openApp(bundleID: String) {
        if saidHello, !windows.isEmpty {
            openWindows(of: bundleID)
        } else {
            pendingAppOpen = bundleID
            connect()
        }
    }

    func refreshApps() {
        if saidHello { channel?.send(Frame(kind: .requestAppList)) }
    }

    /// Asks the host to open an app. Its windows open here when the host answers.
    func requestApp(_ app: RemoteApp) {
        fileStatus = "Opening \(app.name)…"
        send(.openApp, OpenAppRequest(bundleID: app.bundleID))
    }

    private func appOpened(_ result: OpenAppResult) {
        let name = apps.first { $0.bundleID == result.bundleID }?.name ?? result.bundleID
        switch result.outcome {
        case .opened:
            fileStatus = nil
            openApp(bundleID: result.bundleID)
            refreshApps()
        case .noWindows: fileStatus = "\(name) opened, but it has no window to share."
        case .refused: fileStatus = "\(host.name) didn't allow opening \(name)."
        case .notFound: fileStatus = "\(name) isn't on \(host.name) any more."
        case .failed: fileStatus = "\(name) couldn't open on \(host.name)."
        }
    }

    private func openWindows(of bundleID: String) {
        for w in windows where w.bundleID == bundleID && byWindow[w.windowID] == nil { open(w.windowID) }
    }

    private func streamStarted(_ started: StreamStarted) {
        let streamID = started.streamID
        let controller: RemoteWindowController
        if let existing = byWindow[started.window.windowID] {
            // Same window after a reconnect: keep the local window, bind it to the new stream.
            controllers = controllers.filter { $0.value !== existing }
            existing.rebind(streamID: streamID)
            existing.isViewOnly = started.inputEnabled == false
            controller = existing
        } else {
            let remote = RemoteWindowIdentity(host: host.fingerprint, hostName: host.name, windowID: started.window.windowID,
                                              appName: started.window.appName, bundleID: started.window.bundleID)
            controller = RemoteWindowController(remote: remote, started: started,
                                                quality: openedQuality[started.window.windowID] ?? .native, dock: dock)
            controller.videoView.setBorder(HostColors.borderColor(for: host.fingerprint))
            byWindow[started.window.windowID] = controller
        }
        controllers[streamID] = controller
        controller.renderer.onNeedsKeyframe = { [weak self, weak controller] in
            guard let self, let controller else { return }
            onMain { self.requestKeyframe(for: controller) }
        }
        controller.renderer.onDecodeFailure = { [weak self, weak controller] in
            guard let self, let controller else { return }
            onMain { self.fallBackTo420(controller) }
        }
        renderers.withLock { $0[streamID] = controller.renderer }
        controller.onInput = { [weak self, weak controller] event in
            guard let self, let id = controller?.streamID,
                  let f = try? MessageCodec.frame(.input, event, streamID: id) else { return }
            self.channel?.send(f)
        }
        controller.onResizeRequest = { [weak self, weak controller] size, final in
            guard let self, let id = controller?.streamID else { return }
            self.send(.resize, ResizeRequest(pointSize: WireSize(size), final: final), streamID: id)
        }
        controller.onFilesDropped = { [weak self] urls in self?.files?.enqueue(urls) }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let id = controller.streamID
            self.send(.closeStream, CloseStream(reason: .viewerClosed), streamID: id)
            self.controllers[id] = nil
            self.byWindow[controller.remote.windowID] = nil
            self.openedQuality[controller.remote.windowID] = nil
            self.renderers.withLock { $0[id] = nil }
        }
        controller.show()
        NSApp.activate()
    }

    private func requestKeyframe(for controller: RemoteWindowController) {
        guard controllers[controller.streamID] === controller else { return }
        channel?.send(Frame(kind: .requestKeyframe, streamID: controller.streamID))
    }

    private func ping() {
        channel?.send(Frame(kind: .ping, payload: PingPayload.encode(DispatchTime.now().uptimeNanoseconds)))
    }

    private func send<T: Encodable>(_ kind: MessageKind, _ value: T, streamID: UInt16 = 0) {
        if let f = try? MessageCodec.frame(kind, value, streamID: streamID) { channel?.send(f) }
    }
}
#endif
