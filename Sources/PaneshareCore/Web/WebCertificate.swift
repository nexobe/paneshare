import Crypto
import Foundation
import SwiftASN1
import X509

/// The share-link web server's certificate: self-signed, separate from the device identity (a browser
/// guest never sees the key paired viewers pin), short-lived, and naming every address a link can use,
/// so the only warning a browser shows is the self-signed one. Guests can compare its SHA-256 with the
/// fingerprint the host shows (ARCHITECTURE §7.4).
public struct WebCertificate: @unchecked Sendable {  // immutable; the key type predates Sendable
    public let privateKey: P256.Signing.PrivateKey
    public let certificateDER: [UInt8]
    public let expiresAt: Date

    /// Browsers cap certificate lifetimes; a month is far below every cap and longer than any link.
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    public init(dnsNames: [String], ipv4: [String], now: Date) throws {
        let key = P256.Signing.PrivateKey()
        var names: [GeneralName] = dnsNames.filter { !$0.isEmpty }.map { .dnsName($0) }
        for a in ipv4 {
            let parts = a.split(separator: ".").compactMap { UInt8($0) }
            if parts.count == 4 { names.append(.ipAddress(ASN1OctetString(contentBytes: ArraySlice(parts)))) }
        }
        let name = try DistinguishedName { CommonName("paneshare share link") }
        let expires = now.addingTimeInterval(Self.lifetime)
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames(names)
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-60 * 60),
            notValidAfter: expires,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        privateKey = key
        certificateDER = serializer.serializedBytes
        expiresAt = expires
    }

    /// SHA-256 of the whole certificate, as browsers' certificate viewers show it ("AB:CD:…").
    public var sha256: String {
        SHA256.hash(data: Data(certificateDER)).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
