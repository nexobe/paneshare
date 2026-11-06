import Crypto
import Foundation
import SwiftASN1
import X509

/// This install's long-term identity: a P-256 key and a self-signed certificate made from it.
/// The certificate carries nothing meaningful (random CN, far-future validity); trust is the key's
/// fingerprint alone (docs/ARCHITECTURE.md §4.1). Storage is the app's job (Keychain on macOS).
public struct DeviceIdentity: @unchecked Sendable {  // immutable; the key type predates Sendable
    public let privateKey: P256.Signing.PrivateKey
    public let certificateDER: [UInt8]
    public let fingerprint: Fingerprint

    public static func generate() throws -> DeviceIdentity {
        try DeviceIdentity(privateKey: P256.Signing.PrivateKey())
    }

    /// Rebuilds the identity from a stored raw private key (32 bytes).
    public init(rawPrivateKey: Data) throws {
        try self.init(privateKey: P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey))
    }

    public init(privateKey: P256.Signing.PrivateKey) throws {
        self.privateKey = privateKey
        self.fingerprint = Fingerprint(publicKey: privateKey.publicKey)
        self.certificateDER = try SelfSignedCertificate.make(privateKey: privateKey)
    }
}

public enum SelfSignedCertificate {
    /// 2026-01-01T00:00:00Z
    static let notBefore = Date(timeIntervalSince1970: 1_767_225_600)
    /// 9999-12-31T23:59:59Z
    static let notAfter = Date(timeIntervalSince1970: 253_402_300_799)

    public static func make(privateKey: P256.Signing.PrivateKey) throws -> [UInt8] {
        let cn = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let name = try DistinguishedName { CommonName("paneshare-\(cn)") }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(privateKey.publicKey),
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: Certificate.PrivateKey(privateKey)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    /// The fingerprint of a DER certificate's key, if it is a P-256 key. Used by tests and as a
    /// portable cross-check of the platform path (SecCertificateCopyKey on macOS).
    public static func fingerprint(ofCertificateDER der: [UInt8]) -> Fingerprint? {
        guard let certificate = try? Certificate(derEncoded: der),
              let key = P256.Signing.PublicKey(certificate.publicKey) else { return nil }
        return Fingerprint(publicKey: key)
    }
}
