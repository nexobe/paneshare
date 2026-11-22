#if os(macOS)
import AppKit
import Foundation
import PaneshareAudio
import PaneshareCapture
import PaneshareCore
import PaneshareTransport

/// One paired viewer's session on the host. Streams belong to the connection that opened them:
/// input and resize for any other stream ID are ignored.
@MainActor
final class HostPeer: Identifiable {
    nonisolated let id = UUID()
    let channel: TLSMessageChannel
    let viewer: Fingerprint
    private(set) var viewerName: String
    private weak var host: HostController?
    private var saidHello = false
    private var streams: [UInt16: HostStream] = [:]
    private var nextStreamID: UInt16 = 1
    /// bundleID → that app's audio for this viewer, at most one per app.
    private var audio: [String: HostAudioStream] = [:]
    /// Apps whose audio this viewer asked for and hasn't muted.
    private var audioWanted: Set<String> = []
    private var ended = false
    private var clipboard: ClipboardBridge?
    private var files: FileReceiver?
    private var outgoing: FileSender?
    /// The latest message about files this Mac sends to this viewer.
    private(set) var sendStatus: String?
    /// Progress of a file this viewer is sending here, while it arrives.
    private(set) var receiveStatus: String?
    private var openAppLimiter = OpenAppLimiter()
    var onEnded: ((HostPeer) -> Void)?
    var onChange: (() -> Void)?

    var sharedTitles: [String] { streams.values.map(\.info.displayTitle).sorted() }
    var movedAwayTitles: [String] { streams.values.compactMap(\.movedAwayTitle).sorted() }

    /// The host user's control: every window this viewer moved goes back where it was.
    func bringBackWindows() {
        for stream in streams.values where stream.movedAwayTitle != nil {
            Task { await stream.setPlacement(away: false); onChange?() }
        }
    }

    func refreshStreamInfo() {
        for stream in streams.values { stream.refreshInfo() }
    }

    init(channel: TLSMessageChannel, viewer: Fingerprint, knownName: String, host: HostController) {
        self.channel = channel
        self.viewer = viewer
        self.viewerName = knownName
        self.host = host
    }

    func start() {
        channel.onMessage = { [weak self] frame in
            guard let self else { return }
            onMain { self.handle(frame) }
        }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            onMain { self.closed() }
        }
        channel.startReceiving()
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionRules.helloTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.saidHello else { return }
                self.channel.sendError(code: "helloTimeout", message: "No hello in time.")
                self.channel.close()
            }
        }
    }

    private func handle(_ frame: Frame) {
        guard !ended else { return }
        guard saidHello else {
            switch SessionRules.checkHello(frame, expecting: .viewer) {
            case .success(let hello):
                saidHello = true
                viewerName = String(hello.deviceName.prefix(64))
                send(.hello, Hello(appVersion: AppInfo.version, deviceName: AppInfo.deviceName, role: .host))
                sendWindowList()
                startClipboard()
                files = FileReceiver(
                    settingKey: FileReceiver.enabledKey,
                    hasOpenStream: { [weak self] in self.map { !$0.streams.isEmpty } ?? false },
                    reply: { [weak self] in self?.send(.fileReply, $0) },
                    progress: { [weak self] name, percent in
                        guard let self else { return }
                        self.receiveStatus = "Receiving \(name): \(percent)%"
                        self.onChange?()
                    },
                    finished: { [weak self] url, _ in
                        guard let self else { return }
                        self.receiveStatus = nil
                        self.onChange?()
                        self.host?.fileReceived(url, from: self.viewerName)
                    })
                outgoing = FileSender(
                    send: { [weak self] in self?.channel.send($0) },
                    status: { [weak self] in self?.sendStatus = $0; self?.onChange?() })
                onChange?()
            case .failure(let problem):
                channel.sendError(code: "hello", message: "\(problem)")
                channel.close()
            }
            return
        }
        guard let kind = frame.kind else { return }   // unknown kinds are skipped
        do {
            switch kind {
            case .requestWindowList:
                sendWindowList()
            case .requestAppList:
                sendAppList()
            case .openApp:
                openApp(try MessageCodec.decode(OpenAppRequest.self, from: frame).bundleID)
            case .openWindow:
                let req = try MessageCodec.decode(OpenWindow.self, from: frame)
                open(req)
            case .input:
                guard let stream = streams[frame.streamID] else { return }
                let event = try MessageCodec.decode(InputEvent.self, from: frame)
                guard event.isWellFormed else { return }
                stream.handle(event)
            case .resize:
                guard let stream = streams[frame.streamID] else { return }
                let req = try MessageCodec.decode(ResizeRequest.self, from: frame)
                guard req.pointSize.width.isFinite, req.pointSize.height.isFinite else { return }
                Task { await stream.resize(to: req.pointSize, final: req.final ?? true) }
            case .requestKeyframe:
                streams[frame.streamID]?.requestKeyframe()
            case .windowPlacement:
                guard let stream = streams[frame.streamID] else { return }
                let placement = try MessageCodec.decode(WindowPlacement.self, from: frame)
                Task {
                    await stream.setPlacement(away: placement.away)
                    onChange?()
                }
            case .closeStream:
                streams[frame.streamID]?.end(.viewerClosed, notify: false)
            case .audioControl:
                let control = try MessageCodec.decode(AudioControl.self, from: frame)
                guard control.bundleID.utf8.count <= 255 else { return }
                if control.enabled { audioWanted.insert(control.bundleID) } else { audioWanted.remove(control.bundleID) }
                updateAudio(for: control.bundleID, reason: .viewerMuted)
            case .clipboardState:
                clipboard?.peerState(try MessageCodec.decode(ClipboardState.self, from: frame))
            case .clipboardText:
                clipboard?.received(frame.payload)
            case .fileOffer:
                files?.offer(try MessageCodec.decode(FileOffer.self, from: frame))
            case .fileChunk:
                files?.chunk(frame.payload)
            case .fileEnd:
                files?.end(try MessageCodec.decode(FileEnd.self, from: frame))
            case .fileReply:
                outgoing?.reply(try MessageCodec.decode(FileReply.self, from: frame))
            case .ping:
                channel.send(Frame(kind: .pong, payload: frame.payload.prefix(8)))
            case .pong, .error:
                break
            case .hello, .windowList, .streamStarted, .parameterSets, .videoFrame, .resized, .inputState, .streamInfo,
                 .audioStarted, .audioFrame, .audioStopped, .appList, .openAppResult,
                 .pairBegin, .pairChallenge, .pairResponse, .pairResult, .pairStatus:
                channel.sendError(code: "unexpected", message: "Unexpected message \(kind).")
                channel.close()
            }
        } catch {
            channel.sendError(code: "malformed", message: "\(error)")
            channel.close()
        }
    }

    func sendWindowList() {
        send(.windowList, host?.offeredWindows ?? [])
    }

    func sendAppList() {
        Task {
            guard let apps = await host?.appList(), !ended else { return }
            send(.appList, apps)
        }
    }

    private func openApp(_ bundleID: String) {
        guard saidHello, openAppLimiter.allow(now: ProcessInfo.processInfo.systemUptime) else {
            return send(.openAppResult, OpenAppResult(bundleID: String(bundleID.prefix(RemoteAppRules.maxBundleIDBytes)), outcome: .refused))
        }
        let name = viewerName
        Task {
            guard let outcome = await host?.openApp(bundleID: bundleID, for: name), !ended else { return }
            send(.openAppResult, OpenAppResult(bundleID: bundleID, outcome: outcome))
        }
    }

    private func open(_ req: OpenWindow) {
        guard let host, host.isOffered(req.windowID) else {
            return channel.sendError(code: "notOffered", message: "That window isn't shared.")
        }
        guard streams.count < 16 else { return channel.sendError(code: "tooMany", message: "Too many windows open.") }
        let scale = req.viewerBackingScale.isFinite ? min(4, max(1, req.viewerBackingScale)) : 2
        let streamID = allocateStreamID()
        let channel = self.channel
        Task {
            do {
                guard let entry = try await ShareableWindows.find(req.windowID, policy: host.policy) else {
                    return channel.sendError(code: "gone", message: "That window is no longer available.")
                }
                let stream = HostStream(streamID: streamID, entry: entry, viewerScale: scale, quality: req.quality ?? .native,
                                        chroma: req.chroma ?? [.yuv420], channel: channel, viewer: viewer,
                                        viewerDisplay: req.viewerDisplay, policy: host.policy,
                                        adaptiveQuality: req.adaptiveQuality == true)
                stream.moveAwayAllowed = { [weak host] in host?.allowMoveAway ?? false }
                let bundleID = entry.info.bundleID
                stream.onEnded = { [weak self] _ in
                    self?.streams[streamID] = nil
                    self?.updateAudio(for: bundleID, reason: .windowsClosed)
                    self?.onChange?()
                }
                streams[streamID] = stream
                try await stream.start()
                if req.audio == true { audioWanted.insert(bundleID) } else { audioWanted.remove(bundleID) }
                updateAudio(for: bundleID, reason: .viewerMuted)
                onChange?()
            } catch {
                streams[streamID]?.end(.error)
                channel.sendError(code: "capture", message: "\(error)")
            }
        }
    }

    /// The host user stopped sharing this window.
    func unshare(_ windowID: UInt32) {
        for s in streams.values where s.info.windowID == windowID { s.end(.hostStopped) }
        sendWindowList()
    }

    /// The host user chose files for this viewer. They go one at a time; the viewer must accept them.
    func sendFiles(_ urls: [URL]) {
        guard saidHello, !ended, let outgoing else { return }
        outgoing.enqueue(urls)
    }

    /// The viewer can only accept files while it has one of this Mac's windows open.
    var canSendFiles: Bool { saidHello && !ended && outgoing != nil && !streams.isEmpty }

    private func startClipboard() {
        let bridge = ClipboardBridge(
            isViewer: false,
            localFocus: { [weak self] in self.map { !$0.streams.isEmpty } ?? false },
            sendState: { [weak self] in self?.send(.clipboardState, $0) },
            sendText: { [weak self] in self?.channel.send(Frame(kind: .clipboardText, payload: $0)) })
        clipboard = bridge
        bridge.start()
    }

    func stop() {
        clipboard?.stop()
        clipboard = nil
        files?.discard()
        receiveStatus = nil
        files = nil
        outgoing?.stop()
        outgoing = nil
        audioWanted.removeAll()
        for a in audio.values { a.stop(.turnedOffOnHost) }
        audio.removeAll()
        for s in streams.values { s.end(.hostStopped) }
        channel.close()
    }

    private func allocateStreamID() -> UInt16 {
        let id = nextStreamID
        nextStreamID = nextStreamID == .max ? 1 : nextStreamID + 1
        return id
    }

    // MARK: Audio

    /// The host user changed an audio switch.
    func audioPolicyChanged() {
        for bundleID in Set(audio.keys).union(audioWanted) { updateAudio(for: bundleID, reason: .turnedOffOnHost) }
    }

    /// Starts or stops one app's audio so it flows exactly while the viewer has one of its windows
    /// open, wants its audio, and `AudioPolicy` allows it.
    private func updateAudio(for bundleID: String, reason: AudioStopped.Reason) {
        guard !ended, let host else { return }
        let window = streams.values.first { $0.info.bundleID == bundleID }?.info
        let wanted = window.map { audioWanted.contains(bundleID) && host.audioPolicy.allows(bundleID: bundleID, processID: $0.processID) } ?? false
        if wanted, audio[bundleID] == nil, let window {
            let stream = HostAudioStream(streamID: allocateStreamID(), bundleID: bundleID, appName: window.appName,
                                         processID: window.processID, channel: channel)
            audio[bundleID] = stream
            Task {
                do {
                    try await stream.start()
                } catch {
                    NSLog("paneshare audio: couldn't capture %@: %@", bundleID, "\(error)")
                    stream.stop(.captureFailed)
                    if audio[bundleID] === stream { audio[bundleID] = nil }
                }
            }
        } else if !wanted, let stream = audio.removeValue(forKey: bundleID) {
            stream.stop(window == nil ? .windowsClosed : reason)
        }
    }

    private func closed() {
        files?.discard()
        receiveStatus = nil
        files = nil
        outgoing?.stop()
        outgoing = nil
        clipboard?.stop()
        clipboard = nil
        guard !ended else { return }
        ended = true
        for a in audio.values { a.stop(.windowsClosed, notify: false) }
        audio.removeAll()
        for s in streams.values { s.end(.viewerClosed, notify: false) }
        streams.removeAll()
        onEnded?(self)
    }

    private func send<T: Encodable>(_ kind: MessageKind, _ value: T, streamID: UInt16 = 0) {
        if let f = try? MessageCodec.frame(kind, value, streamID: streamID) { channel.send(f) }
    }
}
#endif
