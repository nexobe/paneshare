import Crypto
import Foundation

/// One side of the pairing key exchange (docs/ARCHITECTURE.md §4.2): a balanced PAKE in the
/// style of CPace (draft-irtf-cfrg-cpace), over X25519, with key confirmation by HKDF/HMAC.
///
/// Both sides map the code, the two TLS fingerprints and both nonces to a Curve25519 point G with
/// Elligator 2, then run Diffie–Hellman with G as the base. Without the code an eavesdropper or a
/// relay in the middle can test at most one code guess per live attempt, and the host allows five,
/// so a 6-digit code is enough. The fingerprints come from the TLS session, never from a message,
/// so a relay terminating TLS on either side derives a different G and fails confirmation.
public struct PairingExchange {
    public enum Role: Sendable { case host, viewer }

    public enum Failure: Error, Equatable, Sendable { case badCode, badNonce, badShare }

    public static let label = "paneshare-pake-v1"
    public static let nonceLength = 32
    public static let shareLength = 32
    public static let confirmLength = 32

    public let role: Role
    /// Y = X25519(y, G), sent to the peer.
    public let share: Data
    private let secret: Curve25519.KeyAgreement.PrivateKey
    private let channel: [UInt8]
    private let session: [UInt8]

    /// - Parameters:
    ///   - host, viewer: both fingerprints as seen in this TLS session.
    ///   - viewerNonce, hostNonce: 32 random bytes each, viewer's first.
    ///   - secret: injectable for test vectors; fresh per attempt otherwise.
    public init(role: Role, code: String, host: Fingerprint, viewer: Fingerprint,
                viewerNonce: Data, hostNonce: Data,
                secret: Curve25519.KeyAgreement.PrivateKey = .init()) throws {
        guard code.count == PairingCode.length, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw Failure.badCode }
        guard viewerNonce.count == Self.nonceLength, hostNonce.count == Self.nonceLength else { throw Failure.badNonce }
        self.role = role
        self.secret = secret
        channel = host.bytes + viewer.bytes
        session = Array(viewerNonce) + Array(hostNonce)
        let base = Self.generator(code: code, channel: channel, session: session)
        share = try Self.multiply(secret, base)
    }

    /// G = Elligator2(SHA-512(lv(label) ‖ lv(code) ‖ lv(fp_host ‖ fp_viewer) ‖ lv(nonce_V ‖ nonce_H))[0..<32]),
    /// as 32 little-endian bytes.
    static func generator(code: String, channel: [UInt8], session: [UInt8]) -> Data {
        var input: [UInt8] = []
        for part in [Array(label.utf8), Array(code.utf8), channel, session] { input += lengthPrefixed(part) }
        let digest = Array(SHA512.hash(data: input))
        return Data(Elligator2.map(FieldElement(littleEndian: Array(digest[0..<32]))).littleEndianBytes)
    }

    /// Both confirmation tags for this exchange once the peer's share is known. The viewer sends
    /// `viewer` first; the host answers with `host` only if that matched.
    public func confirmations(peerShare: Data) throws -> Confirmations {
        guard peerShare.count == Self.shareLength else { throw Failure.badShare }
        let shared = try Self.multiply(secret, peerShare)
        let (hostShare, viewerShare) = role == .host ? (share, peerShare) : (peerShare, share)
        var transcript: [UInt8] = []
        for part in [Array(Self.label.utf8), channel, session, Array(hostShare), Array(viewerShare)] {
            transcript += Self.lengthPrefixed(part)
        }
        let keys = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared),
                                          salt: Array(SHA256.hash(data: transcript)),
                                          info: Array("\(Self.label) confirm".utf8),
                                          outputByteCount: 64)
        let bytes = keys.withUnsafeBytes { Array($0) }
        let viewerKey = SymmetricKey(data: bytes[0..<32])
        let hostKey = SymmetricKey(data: bytes[32..<64])
        return Confirmations(
            viewer: Data(HMAC<SHA256>.authenticationCode(for: Array("viewer".utf8) + transcript, using: viewerKey)),
            host: Data(HMAC<SHA256>.authenticationCode(for: Array("host".utf8) + transcript, using: hostKey)))
    }

    public struct Confirmations: Equatable, Sendable {
        public let viewer: Data
        public let host: Data
    }

    /// X25519 with an arbitrary u-coordinate as the "public key". An all-zero result means a
    /// low-order input (a hostile share, or G landing on one by negligible chance): reject it.
    private static func multiply(_ scalar: Curve25519.KeyAgreement.PrivateKey, _ point: Data) throws -> Data {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: point),
              let shared = try? scalar.sharedSecretFromKeyAgreement(with: peer) else { throw Failure.badShare }
        let bytes = shared.withUnsafeBytes { Data($0) }
        guard bytes.contains(where: { $0 != 0 }) else { throw Failure.badShare }
        return bytes
    }

    private static func lengthPrefixed(_ bytes: [UInt8]) -> [UInt8] {
        [UInt8(truncatingIfNeeded: bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)] + bytes
    }

    public static func freshNonce() -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
