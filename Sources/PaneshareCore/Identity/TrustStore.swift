import Foundation

/// A peer this install has paired with, pinned by fingerprint.
public struct PairedPeer: Codable, Equatable, Sendable, Identifiable {
    public var fingerprint: Fingerprint
    public var name: String
    public var role: PeerRole
    public var pairedAt: Date
    /// Last address that worked (host peers only), e.g. "100.101.102.103:47821" over Tailscale.
    public var lastAddress: String?

    public var id: Fingerprint { fingerprint }

    public init(fingerprint: Fingerprint, name: String, role: PeerRole, pairedAt: Date, lastAddress: String? = nil) {
        self.fingerprint = fingerprint; self.name = name; self.role = role
        self.pairedAt = pairedAt; self.lastAddress = lastAddress
    }
}

/// The pin list. Pure value type; the macOS app persists `encoded()` in the Keychain.
public struct TrustStore: Codable, Equatable, Sendable {
    public private(set) var peers: [PairedPeer] = []

    public init(peers: [PairedPeer] = []) { self.peers = peers }

    public func isTrusted(_ fp: Fingerprint, as role: PeerRole) -> Bool {
        peers.contains { $0.fingerprint == fp && $0.role == role }
    }

    public func peer(_ fp: Fingerprint) -> PairedPeer? { peers.first { $0.fingerprint == fp } }

    /// Adds or replaces (same fingerprint and role) a peer.
    public mutating func pin(_ peer: PairedPeer) {
        peers.removeAll { $0.fingerprint == peer.fingerprint && $0.role == peer.role }
        peers.append(peer)
    }

    public mutating func remove(_ fp: Fingerprint) {
        peers.removeAll { $0.fingerprint == fp }
    }

    /// Unpins one role only: a Mac can be both a host and a viewer of this one.
    public mutating func remove(_ fp: Fingerprint, role: PeerRole) {
        peers.removeAll { $0.fingerprint == fp && $0.role == role }
    }

    public mutating func updateAddress(_ fp: Fingerprint, address: String) {
        guard let i = peers.firstIndex(where: { $0.fingerprint == fp }) else { return }
        peers[i].lastAddress = address
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> TrustStore {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(TrustStore.self, from: data)
    }
}
