import Crypto
import Foundation

/// SHA-256 of a P-256 public key's DER SubjectPublicKeyInfo: the pin every trust decision compares.
public struct Fingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public init(publicKey: P256.Signing.PublicKey) {
        bytes = Array(SHA256.hash(data: publicKey.derRepresentation))
    }

    /// From a 65-byte uncompressed X9.63 point (what `SecKeyCopyExternalRepresentation` returns
    /// for a P-256 public key). Nil for anything that is not a valid P-256 point.
    public init?(x963PublicKey: Data) {
        guard let key = try? P256.Signing.PublicKey(x963Representation: x963PublicKey) else { return nil }
        self.init(publicKey: key)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// 16 Crockford base32 characters of the first 80 bits: the HostID shown in the UI and in
    /// the Bonjour TXT record. A hint only; never used for trust.
    public var shortID: String { CrockfordBase32.encode(Array(bytes.prefix(10))) }

    public var description: String { shortID }

    public init(from decoder: Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let value = Fingerprint(hex: hex) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad fingerprint"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public init?(hex: String) {
        guard hex.count == 64 else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let b = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(b)
            index = next
        }
        self.init(bytes: out)
    }
}

public enum CrockfordBase32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Most-significant-bit first; the final partial group is zero-padded on the right.
    public static func encode(_ bytes: [UInt8]) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
}
