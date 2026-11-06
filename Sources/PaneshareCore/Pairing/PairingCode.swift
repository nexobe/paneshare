import Foundation

/// The 6-digit pairing code the host shows, displayed as "482 913". It never crosses the wire:
/// it only seeds the key exchange's base point (`PairingExchange`), so its strength comes from the
/// host's five-attempt limit, not from its length. There is no check digit; a typo spends one try.
public enum PairingCode {
    public static let length = 6

    /// A fresh code, uniform over 000000–999999 (inject a deterministic generator in tests).
    public static func generate<R: RandomNumberGenerator>(using random: inout R) -> String {
        format(UInt32.random(in: 0..<1_000_000, using: &random))
    }

    static func format(_ value: UInt32) -> String {
        let digits = String(value % 1_000_000)
        return String(repeating: "0", count: length - digits.count) + digits
    }

    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    public enum Problem: Error, Equatable, Sendable { case length }

    /// Normalizes typed input (spaces, hyphens, non-breaking spaces removed) and validates it.
    public static func check(_ input: String) -> Result<String, Problem> {
        let kept = input.filter { $0 != " " && $0 != "-" && $0 != "\u{00A0}" }
        guard kept.count == length, kept.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .failure(.length) }
        return .success(kept)
    }

    public static func grouped(_ code: String) -> String {
        guard code.count == length else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
