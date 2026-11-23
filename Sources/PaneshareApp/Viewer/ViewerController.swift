#if os(macOS)
import AppKit
import Foundation
import Network
import PaneshareCore
import PaneshareDiscovery
import PaneshareTransport
import PaneshareViewer

/// The viewer role: Bonjour discovery, pairing, and one `ViewerSession` per paired host.
@MainActor
final class ViewerController: ObservableObject {
    @Published private(set) var discovered: [DiscoveredHost] = []
    @Published private(set) var discoveryStatus = ""
    /// macOS blocks Local Network access for paneshare: no Bonjour in either direction.
    @Published private(set) var localNetworkBlocked = false
    @Published private(set) var sessions: [ViewerSession] = []
    @Published private(set) var pairingBusy = false
    @Published var pairingMessage: String?
    /// The request in flight: the code this Mac shows and who it's waiting on.
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingTarget: String?
    /// Set once a pairing succeeds, so the sheet can close.
    @Published private(set) var pairedName: String?

    private let identity: TLSIdentity
    private let trust: TrustModel
    private let browser = HostBrowser()
    private let dock: DockPresenter
    private var pairing: PairingClient?

    init(identity: TLSIdentity, trust: TrustModel, dock: DockPresenter) {
        self.identity = identity
        self.trust = trust
        self.dock = dock
        browser.onChange = { [weak self] hosts in
            MainActor.assumeIsolated { self?.discovered = hosts }
        }
        browser.onState = { [weak self] text in
            MainActor.assumeIsolated { self?.discoveryStatus = text }
        }
        browser.onLocalNetworkBlocked = { [weak self] blocked in
            MainActor.assumeIsolated {
                guard let self, self.localNetworkBlocked != blocked else { return }
                self.localNetworkBlocked = blocked
            }
        }
    }

    private var activeObserver: NSObjectProtocol?

    func start() {
        browser.start()
        syncSessions()
        // After the user turns Local Network on in System Settings, browse again when they come back.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.localNetworkBlocked else { return }
                self.browser.start()
            }
        }
    }

    /// Discovered hosts this viewer hasn't paired with, leaving out this Mac itself.
    var unpaired: [DiscoveredHost] {
        let pinned = Set(trust.hosts.map(\.fingerprint.shortID)).union([ownID])
        return discovered.filter { host in host.hostID.map { !pinned.contains($0) } ?? true }
    }

    func session(for host: PairedPeer) -> ViewerSession? { sessions.first { $0.id == host.fingerprint } }

    /// One session per paired host, created on demand and dropped when the host is unpaired.
    func syncSessions() {
        let hosts = trust.hosts
        let keep = Set(hosts.map(\.fingerprint))
        for s in sessions where !keep.contains(s.id) { s.disconnect() }
        sessions.removeAll { !keep.contains($0.id) }
        for h in hosts where session(for: h) == nil {
            let fp = h.fingerprint
            let s = ViewerSession(host: h, identity: identity, dock: dock) { [weak self] in
                self?.endpoint(for: fp)
            }
            sessions.append(s)
        }
    }

    /// Bonjour first (it follows the host across address changes), then the last manual address.
    private func endpoint(for fp: Fingerprint) -> NWEndpoint? {
        if let found = discovered.first(where: { $0.hostID == fp.shortID }) { return found.endpoint }
        guard let address = trust.store.peer(fp)?.lastAddress else { return nil }
        return Dialer.endpoint(fromAddress: address)
    }

    // MARK: Pairing

    /// This Mac's ID, which the host's prompt shows for the user to compare.
    var ownID: String { identity.fingerprint.shortID }

    func pair(with host: DiscoveredHost) {
        pair(endpoint: host.endpoint, expectedHostID: host.hostID, address: nil, target: host.name)
    }

    func pair(address: String) {
        guard let endpoint = Dialer.endpoint(fromAddress: address), let parsed = HostAddress.parse(address, defaultPort: PinnedTLS.defaultPort) else {
            pairingMessage = "That address isn't valid. Use a name or IP, optionally with :port."
            return
        }
        pair(endpoint: endpoint, expectedHostID: nil, address: parsed.display, target: parsed.host)
    }

    /// Asks the host to pair. The code is made here, shown here, and typed on the host, so pairing
    /// needs a person at both Macs and nothing has to be set up on the host first.
    private func pair(endpoint: NWEndpoint, expectedHostID: String?, address: String?, target: String) {
        pairing?.cancel()
        let code = PairingCode.generate()
        pairingBusy = true
        pairingCode = code
        pairingTarget = target
        pairedName = nil
        pairingMessage = "Asking “\(target)”…"
        let client = PairingClient()
        pairing = client
        client.pair(endpoint: endpoint, expectedHostID: expectedHostID, code: code, identity: identity,
                    viewerName: AppInfo.deviceName, fallbackName: target, progress: { [weak self, weak client] step in
            guard let self, let client else { return }
            onMain {
                guard self.pairing === client else { return }
                switch step {
                case .prompted:
                    self.pairingMessage = "On “\(target)”, type this code and click Accept."
                case .wrongCode(let left):
                    self.pairingMessage = "The code typed on “\(target)” didn't match. \(left) \(left == 1 ? "try" : "tries") left."
                }
            }
        }) { [weak self, weak client] result in
            guard let self, let client else { return }
            onMain {
                guard self.pairing === client else { return }
                self.pairingBusy = false
                self.pairingCode = nil
                self.pairing = nil
                switch result {
                case .paired(let fp, let name):
                    self.trust.pin(PairedPeer(fingerprint: fp, name: name, role: .host, pairedAt: Date(), lastAddress: address))
                    self.pairingMessage = "Paired with \(name)."
                    self.pairedName = name
                    self.syncSessions()
                    self.session(for: self.trust.store.peer(fp) ?? PairedPeer(fingerprint: fp, name: name, role: .host, pairedAt: Date()))?.connect()
                case .failed(let why):
                    self.pairingMessage = why
                case .cancelled:
                    self.pairingMessage = nil
                }
            }
        }
    }

    func cancelPairing() {
        let client = pairing
        pairing = nil
        client?.cancel()
        pairingBusy = false
        pairingCode = nil
        pairingMessage = nil
    }

    /// Opens every offered window of one remote app, connecting first if needed (a pinned Dock
    /// helper was clicked). `hostID` is the host fingerprint in hex.
    func openRemoteApp(hostID: String, bundleID: String) {
        guard let session = sessions.first(where: { $0.id.hex == hostID }) else { return }
        session.openApp(bundleID: bundleID)
    }

    func forget(_ host: PairedPeer) {
        session(for: host)?.disconnect()
        trust.remove(host.fingerprint, role: .host)
        AudioMixStore.shared.forget(host: host.fingerprint)
        syncSessions()
    }

    func setAddress(_ address: String, for host: PairedPeer) {
        guard let parsed = HostAddress.parse(address, defaultPort: PinnedTLS.defaultPort) else { return }
        trust.updateAddress(host.fingerprint, address: parsed.display)
    }
}
#endif
