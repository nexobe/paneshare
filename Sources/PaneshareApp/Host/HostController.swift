#if os(macOS)
import AppKit
import Foundation
import PaneshareCapture
import PaneshareCore
import PaneshareInput
import PaneshareTransport

/// The host role: the listener, the windows the user chose to offer, pairing requests, and the
/// connected viewers. The listener, and so the Bonjour advert and any pairing request, exists only
/// while hosting is on.
@MainActor
final class HostController: ObservableObject {
    @Published private(set) var isHosting = false
    @Published private(set) var status = "Off"
    @Published private(set) var candidates: [WindowInfo] = []
    @Published private(set) var offered: [UInt32: WindowInfo] = [:]
    @Published private(set) var peers: [HostPeer] = []
    /// The latest file another Mac sent here.
    @Published private(set) var lastReceivedFile: (url: URL, from: String)?
    /// The latest app another Mac opened here.
    @Published private(set) var lastOpenedApp: (name: String, by: String)?
    /// Off until the user turns it on. Paired viewers then see the apps here and can open them.
    @Published private(set) var offerApps = UserDefaults.standard.bool(forKey: HostController.offerAppsKey)
    nonisolated static let offerAppsKey = "offerApps"
    /// Off until the user turns it on. Viewers may then move shared windows off this Mac's screens.
    @Published private(set) var allowMoveAway = UserDefaults.standard.bool(forKey: HostController.allowMoveAwayKey)
    nonisolated static let allowMoveAwayKey = "allowMoveAway"
    /// Off until the user turns it on. The apps of ticked windows are then offered after each restart.
    @Published private(set) var rememberApps = UserDefaults.standard.bool(forKey: HostController.rememberAppsKey)
    /// Off until the user turns it on. Every screen is then offered when sharing starts.
    @Published private(set) var offerScreensAtStart = UserDefaults.standard.bool(forKey: HostController.offerScreensKey)
    nonisolated static let rememberAppsKey = "rememberOfferedApps"
    nonisolated static let offerScreensKey = "offerScreensAtStart"
    nonisolated static let savedAppsKey = "savedOfferedApps"
    private var savedOffers = SavedOffers(saved: UserDefaults.standard.stringArray(forKey: HostController.savedAppsKey))
    private var offerTimer: Timer?
    private var catalogScan: Task<[AppCatalog.Entry], Never>?
    private var catalogScannedAt: TimeInterval = 0
    @Published private(set) var pairingMessage: String?
    @Published var lastError: String?

    private let identity: TLSIdentity
    private let trust: TrustModel
    private var listener: HostListener?
    private let admission = AdmissionSnapshot()
    private var limiter = PairRequestLimiter()
    private var request: PairingRequest?
    private var prompt: PairPrompt?
    let policy: WindowPolicy

    /// Host-side audio switches (`AudioPolicy`): all apps, and apps muted at the source.
    @Published private(set) var shareAudio = UserDefaults.standard.object(forKey: HostController.shareAudioKey) as? Bool ?? true
    @Published private(set) var audioMutedApps = AudioPolicy.mutedList(
        from: UserDefaults.standard.stringArray(forKey: HostController.audioMutedAppsKey))
    nonisolated static let shareAudioKey = "shareAudio"
    nonisolated static let audioMutedAppsKey = "audioMutedApps"

    var audioPolicy: AudioPolicy { AudioPolicy(windowPolicy: policy, enabled: shareAudio, mutedBundleIDs: audioMutedApps) }

    init(identity: TLSIdentity, trust: TrustModel) {
        self.identity = identity
        self.trust = trust
        self.policy = WindowPolicy(ownProcessID: ProcessInfo.processInfo.processIdentifier, ownBundleID: AppInfo.bundleID)
        trust.onChange = { [weak self] in self?.refreshAdmission() }
    }

    /// Browser guests (§7.4). Links exist only while hosting is on.
    private(set) lazy var shareLinks = ShareLinkController(host: self)

    var offeredWindows: [WindowInfo] { offered.values.sorted { $0.displayTitle < $1.displayTitle } }
    func isOffered(_ id: UInt32) -> Bool { offered[id] != nil }

    // MARK: Hosting

    func startHosting() {
        guard !isHosting else { return }
        guard Permissions.screenRecording else {
            Permissions.requestScreenRecording()
            lastError = "paneshare needs Screen Recording permission to share windows."
            return
        }
        // Only the host user can turn sharing on, so it may clear the spam limits.
        limiter = PairRequestLimiter()
        let admission = self.admission
        let listener = HostListener(identity: identity, serviceName: AppInfo.deviceName) { peer, alpn in
            admission.admits(peer, alpn: alpn)
        }
        listener.onState = { [weak self] text in
            guard let self else { return }
            onMain { self.status = text }
        }
        listener.onChannel = { [weak self] channel in
            guard let self else { return }
            onMain { self.accept(channel) }
        }
        // A handshake can arrive as soon as the listener starts, so pairing must already be open.
        refreshAdmission(pairingOpen: true)
        do {
            try listener.start()
            self.listener = listener
            isHosting = true
            updateOfferTimer()
            Task {
                await refreshCandidates()
                await offerSavedApps()
                await offerScreens()
            }
        } catch {
            refreshAdmission()
            lastError = "Couldn't start listening: \(error)"
        }
    }

    func fileReceived(_ url: URL, from viewer: String) {
        lastReceivedFile = (url, viewer)
    }

    func stopHosting() {
        request?.cancel()
        endPrompt()
        shareLinks.stopAll()
        for p in peers { p.stop() }
        peers.removeAll()
        listener?.stop()
        listener = nil
        isHosting = false
        updateOfferTimer()
        status = "Off"
        refreshAdmission()
    }

    private func accept(_ channel: TLSMessageChannel) {
        guard let peer = channel.peerFingerprint, let alpn = channel.alpn else { return channel.close() }
        switch alpn {
        case PinnedTLS.sessionALPN:
            guard trust.store.isTrusted(peer, as: .viewer) else { return channel.close() }
            let p = HostPeer(channel: channel, viewer: peer, knownName: trust.store.peer(peer)?.name ?? peer.shortID, host: self)
            p.onEnded = { [weak self] ended in
                self?.peers.removeAll { $0 === ended }
                self?.listener?.forget(ended.channel)
            }
            p.onChange = { [weak self] in self?.objectWillChange.send() }
            peers.append(p)
            trust.updateAddress(peer, address: channel.remoteDescription)
            p.start()
        case PinnedTLS.pairingALPN:
            beginPairing(channel, viewer: peer)
        default:
            channel.close()
        }
    }

    // MARK: Offering windows

    func refreshCandidates() async {
        do {
            let windows = try await ShareableWindows.list(policy: policy).map(\.info)
            candidates = try await ShareableWindows.listScreens() + windows
            // Drop offers for windows that disappeared.
            let live = Set(candidates.map(\.windowID))
            for id in offered.keys where !live.contains(id) {
                offered[id] = nil
                shareLinks.windowUnshared(id)
            }
        } catch {
            lastError = "Couldn't list windows: \(error.localizedDescription)"
        }
    }

    func setOffered(_ window: WindowInfo, _ on: Bool) {
        if on {
            offered[window.windowID] = window
            for p in peers { p.sendWindowList() }
        } else {
            offered[window.windowID] = nil
            for p in peers { p.unshare(window.windowID) }
            shareLinks.windowUnshared(window.windowID)
        }
    }

    // MARK: Saved offers

    /// A tick or untick by the host user. Windows offered any other way don't change what's saved.
    func userSetOffered(_ window: WindowInfo, _ on: Bool) {
        setOffered(window, on)
        guard rememberApps else { return }
        savedOffers.userChanged(window, offered: on, policy: policy)
        saveOffers()
    }

    func setRememberApps(_ on: Bool) {
        rememberApps = on
        UserDefaults.standard.set(on, forKey: Self.rememberAppsKey)
        savedOffers = SavedOffers()
        if on {
            for w in offered.values { savedOffers.userChanged(w, offered: true, policy: policy) }
        }
        saveOffers()
        updateOfferTimer()
    }

    func setOfferScreensAtStart(_ on: Bool) {
        offerScreensAtStart = on
        UserDefaults.standard.set(on, forKey: Self.offerScreensKey)
    }

    private func saveOffers() {
        UserDefaults.standard.set(savedOffers.encoded, forKey: Self.savedAppsKey)
    }

    /// New windows of saved apps can open at any time, so this checks every few seconds.
    private func updateOfferTimer() {
        offerTimer?.invalidate()
        offerTimer = nil
        guard isHosting, rememberApps else { return }
        offerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.offerSavedApps() }
            }
        }
    }

    private func offerSavedApps() async {
        guard isHosting, rememberApps else { return }
        guard let all = try? await ShareableWindows.list(policy: policy).map(\.info), isHosting, rememberApps else { return }
        let found = savedOffers.windowsToOffer(from: all, alreadyOffered: Set(offered.keys), policy: policy)
        offerFound(found)
    }

    private func offerScreens() async {
        guard offerScreensAtStart, let screens = try? await ShareableWindows.listScreens(), isHosting, offerScreensAtStart else { return }
        offerFound(SavedOffers.screens(in: screens, alreadyOffered: Set(offered.keys)))
    }

    /// Only adds rows: a full refresh would also drop offers for minimized windows.
    private func offerFound(_ found: [WindowInfo]) {
        candidates += found.filter { w in !candidates.contains { $0.windowID == w.windowID } }
        for w in found { setOffered(w, true) }
    }

    // MARK: Moving windows

    func setAllowMoveAway(_ on: Bool) {
        allowMoveAway = on
        UserDefaults.standard.set(on, forKey: Self.allowMoveAwayKey)
        for p in peers { p.refreshStreamInfo() }
    }

    // MARK: Apps

    func setOfferApps(_ on: Bool) {
        offerApps = on
        UserDefaults.standard.set(on, forKey: Self.offerAppsKey)
        for p in peers { p.sendAppList() }
    }

    /// Installed apps change rarely, and a viewer's request mustn't start a disk scan each time.
    private func installedApps() async -> [AppCatalog.Entry] {
        let now = ProcessInfo.processInfo.systemUptime
        if catalogScan == nil || now - catalogScannedAt > 30 {
            catalogScan = Task.detached(priority: .utility) { AppCatalog.installed() }
            catalogScannedAt = now
        }
        return await catalogScan?.value ?? []
    }

    /// What a viewer may see. Empty while the setting is off.
    func appList() async -> [RemoteApp] {
        guard offerApps else { return [] }
        let installed = await installedApps()
        guard offerApps else { return [] }
        return RemoteAppRules.list((installed + AppCatalog.running()).map(\.app), policy: policy)
    }

    /// Opens an app for a paired viewer and offers its windows. Every check runs again here, because
    /// the viewer can ask for anything.
    func openApp(bundleID: String, for viewerName: String) async -> OpenAppResult.Outcome {
        guard isHosting, offerApps, RemoteAppRules.isAllowed(bundleID: bundleID, policy: policy) else { return .refused }
        let installed = await installedApps()
        guard let entry = (AppCatalog.running() + installed).first(where: { $0.app.bundleID == bundleID }) else { return .notFound }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration)
        } catch {
            NSLog("paneshare: couldn't open %@: %@", bundleID, error.localizedDescription)
            return .failed
        }
        guard isHosting, offerApps else { return .refused }
        lastOpenedApp = (entry.app.name, viewerName)
        return await offerWindows(of: bundleID) ? .opened : .noWindows
    }

    /// Waits up to 15 s for the app's windows, then gives slower windows one more second.
    private func offerWindows(of bundleID: String) async -> Bool {
        for _ in 0..<30 {
            guard isHosting else { return false }
            if !(await windows(of: bundleID)).isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard isHosting, offerApps else { return false }
                let found = await windows(of: bundleID)
                // Only adds rows: a full refresh would also drop offers for minimized windows.
                candidates += found.filter { w in !candidates.contains { $0.windowID == w.windowID } }
                for w in found where !isOffered(w.windowID) { setOffered(w, true) }
                return !found.isEmpty
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func windows(of bundleID: String) async -> [WindowInfo] {
        let all = (try? await ShareableWindows.list(policy: policy)) ?? []
        return all.map(\.info).filter { $0.bundleID == bundleID }
    }

    // MARK: Virtual display

    @Published private(set) var virtualDisplayMode = VirtualDisplayMode(setting: UserDefaults.standard.string(forKey: VirtualDisplayMode.key))

    /// Why virtual displays can't be used on this Mac, or nil.
    var virtualDisplayProblem: String? { VirtualDisplayManager.shared.apiProblem }

    /// Applies to windows opened (or resized past the screen) from now on.
    func setVirtualDisplayMode(_ mode: VirtualDisplayMode) {
        virtualDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: VirtualDisplayMode.key)
    }

    // MARK: Audio

    func setShareAudio(_ on: Bool) {
        shareAudio = on
        UserDefaults.standard.set(on, forKey: Self.shareAudioKey)
        for p in peers { p.audioPolicyChanged() }
    }

    func setAudioMuted(_ bundleID: String, _ muted: Bool) {
        if muted { audioMutedApps.insert(bundleID) } else { audioMutedApps.remove(bundleID) }
        UserDefaults.standard.set(audioMutedApps.sorted(), forKey: Self.audioMutedAppsKey)
        for p in peers { p.audioPolicyChanged() }
    }

    /// Whether this app's audio could ever be shared (false for excluded apps, whatever the switches).
    func audioPossible(for w: WindowInfo) -> Bool {
        if case .excludedApp = audioPolicy.decision(bundleID: w.bundleID, processID: w.processID) { return false }
        return true
    }

    // MARK: Pairing

    /// A viewer asked to pair. At most one prompt is up at a time; a stranger repeating requests
    /// is ignored by `PairRequestLimiter`.
    private func beginPairing(_ channel: TLSMessageChannel, viewer: Fingerprint) {
        let now = ProcessInfo.processInfo.systemUptime
        switch limiter.request(peer: viewer, address: channel.remoteHost, now: now) {
        case .prompt:
            break
        case .busy:
            if let f = try? MessageCodec.frame(.pairResult, PairResult(accepted: false, reason: .busy)) { channel.send(f) }
            channel.queue.asyncAfter(deadline: .now() + 0.5) { channel.close() }
            listener?.forget(channel)
            return
        case .ignore:
            NSLog("paneshare: ignored a pairing request from %@", channel.remoteHost)
            channel.close()
            listener?.forget(channel)
            return
        }
        let request = PairingRequest(channel: channel, viewer: viewer, hostFingerprint: identity.fingerprint,
                                     hostName: AppInfo.deviceName)
        let expiresAt = Date().addingTimeInterval(PairingGate.lifetime)
        request.onPrompt = { [weak self, weak request] name in
            guard let self, let request else { return }
            onMain {
                guard self.request === request else { return }
                self.showPrompt(for: request, name: name, expiresAt: expiresAt)
            }
        }
        request.onWrongCode = { [weak self] left in
            guard let self else { return }
            onMain {
                guard let prompt = self.prompt else { return }
                prompt.checking = false
                prompt.message = left == 1 ? "That code didn't match. 1 try left." : "That code didn't match. \(left) tries left."
            }
        }
        request.onEnd = { [weak self, weak request] outcome in
            guard let self, let request else { return }
            onMain { self.pairingEnded(request, outcome, channel: channel) }
        }
        self.request = request
        request.start()
    }

    private func showPrompt(for request: PairingRequest, name: String, expiresAt: Date) {
        let prompt = PairPrompt(viewerName: name, viewerID: request.viewer.shortID, address: request.address,
                                expiresAt: expiresAt)
        prompt.onAccept = { [weak prompt, weak request] code in
            prompt?.checking = true
            prompt?.message = nil
            request?.submit(code: code)
        }
        prompt.onDecline = { [weak request] in request?.decline() }
        self.prompt = prompt
        PairPromptPanel.shared.show(prompt)
    }

    private func endPrompt() {
        prompt = nil
        PairPromptPanel.shared.close()
    }

    private func pairingEnded(_ ended: PairingRequest, _ outcome: PairingRequest.Outcome, channel: TLSMessageChannel) {
        listener?.forget(channel)
        let now = ProcessInfo.processInfo.systemUptime
        guard request === ended else { return }
        request = nil
        let hadPrompt = prompt != nil
        endPrompt()
        switch outcome {
        case .paired(let fp, let name):
            limiter.finished(.paired, now: now)
            trust.pin(PairedPeer(fingerprint: fp, name: name, role: .viewer, pairedAt: Date(),
                                 lastAddress: channel.remoteDescription))
            pairingMessage = "Paired with \(name)."
        case .declined:
            limiter.finished(.declined, now: now)
            pairingMessage = "Declined a pairing request."
        case .failed(let reason):
            limiter.finished(.failed, now: now)
            pairingMessage = reason
        case .cancelled:
            limiter.finished(.cancelled, now: now)
            if hadPrompt { pairingMessage = "The other Mac cancelled its pairing request." }
        }
    }

    // MARK: Admission

    private func refreshAdmission(pairingOpen: Bool? = nil) {
        let viewers = Set(trust.store.peers.filter { $0.role == .viewer }.map(\.fingerprint))
        admission.update(viewers: viewers, pairingOpen: pairingOpen ?? isHosting)
        // A viewer removed from the trust list loses its live session too.
        for p in peers where !viewers.contains(p.viewer) { p.stop() }
    }
}

/// What the TLS verify block reads, inside the handshake, on the network queue.
final class AdmissionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var viewers: Set<Fingerprint> = []
    private var pairingOpen = false

    func update(viewers: Set<Fingerprint>, pairingOpen: Bool) {
        lock.lock(); self.viewers = viewers; self.pairingOpen = pairingOpen; lock.unlock()
    }

    func admits(_ peer: Fingerprint, alpn: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch alpn {
        case PinnedTLS.sessionALPN: return viewers.contains(peer)
        case PinnedTLS.pairingALPN: return pairingOpen
        // ALPN not visible yet: admit only someone who could pass either check. `accept` enforces
        // the ALPN-specific rule (pinned for sessions, the request limiter for pairing) after the handshake.
        case nil: return viewers.contains(peer) || pairingOpen
        default: return false
        }
    }
}
#endif
