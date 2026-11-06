#if os(macOS)
import Foundation
import PaneshareCore
import PaneshareTransport

/// The pinned peers, saved to the Keychain on every change.
@MainActor
final class TrustModel: ObservableObject {
    @Published private(set) var store: TrustStore
    @Published var saveError: String?
    private let keychain: KeychainStore
    var onChange: (() -> Void)?

    init(keychain: KeychainStore) throws {
        self.keychain = keychain
        self.store = try keychain.loadTrust()
    }

    func pin(_ peer: PairedPeer) {
        store.pin(peer)
        save()
    }

    func remove(_ fp: Fingerprint, role: PeerRole) {
        store.remove(fp, role: role)
        save()
    }

    func updateAddress(_ fp: Fingerprint, address: String) {
        guard store.peer(fp)?.lastAddress != address else { return }
        store.updateAddress(fp, address: address)
        save()
    }

    var hosts: [PairedPeer] { store.peers.filter { $0.role == .host }.sorted { $0.name < $1.name } }
    var viewers: [PairedPeer] { store.peers.filter { $0.role == .viewer }.sorted { $0.name < $1.name } }

    private func save() {
        do { try keychain.saveTrust(store); saveError = nil } catch { saveError = "\(error)" }
        onChange?()
    }
}
#endif
