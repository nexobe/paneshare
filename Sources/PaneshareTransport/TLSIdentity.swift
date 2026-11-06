#if os(macOS)
import Crypto
import Foundation
import PaneshareCore
import Security

public enum TLSIdentityError: Error, CustomStringConvertible {
    case key, certificate, fingerprintMismatch, identity

    public var description: String {
        switch self {
        case .key: return "The device key could not be loaded into Security.framework."
        case .certificate: return "The device certificate could not be parsed."
        case .fingerprintMismatch: return "The device certificate does not carry the device key."
        case .identity: return "No TLS identity could be made from the device key and certificate."
        }
    }
}

/// A `DeviceIdentity` (swift-crypto key + swift-certificates certificate) as Network.framework needs it.
public struct TLSIdentity: @unchecked Sendable {
    public let device: DeviceIdentity
    public let secIdentity: SecIdentity
    public let tls: sec_identity_t

    public var fingerprint: Fingerprint { device.fingerprint }

    public init(_ device: DeviceIdentity) throws {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        // X9.63 private form: 04 ‖ X ‖ Y ‖ D (97 bytes), what SecKeyCreateWithData expects for EC.
        guard let key = SecKeyCreateWithData(device.privateKey.x963Representation as CFData, attrs as CFDictionary, nil)
        else { throw TLSIdentityError.key }
        guard let cert = SecCertificateCreateWithData(nil, Data(device.certificateDER) as CFData) else {
            throw TLSIdentityError.certificate
        }
        guard PinnedTLS.fingerprint(of: cert) == device.fingerprint else { throw TLSIdentityError.fingerprintMismatch }
        guard let identity = SecIdentityCreate(nil, cert, key), let tls = sec_identity_create(identity) else {
            throw TLSIdentityError.identity
        }
        self.device = device
        self.secIdentity = identity
        self.tls = tls
    }

    /// The share-link web server's identity (`WebCertificate`), which is unrelated to the device key.
    public static func webIdentity(_ web: WebCertificate) throws -> sec_identity_t {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateWithData(web.privateKey.x963Representation as CFData, attrs as CFDictionary, nil)
        else { throw TLSIdentityError.key }
        guard let cert = SecCertificateCreateWithData(nil, Data(web.certificateDER) as CFData) else {
            throw TLSIdentityError.certificate
        }
        guard let identity = SecIdentityCreate(nil, cert, key), let tls = sec_identity_create(identity) else {
            throw TLSIdentityError.identity
        }
        return tls
    }
}
#endif
