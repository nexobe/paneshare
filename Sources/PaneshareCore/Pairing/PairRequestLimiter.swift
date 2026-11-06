import Foundation

/// Which pairing requests may put a prompt on the host's screen (docs/ARCHITECTURE.md §4.2).
/// A stranger can mint a new key per request, so limits apply per address and overall as well as
/// per key. Pure; the clock is passed in.
public struct PairRequestLimiter: Sendable {
    /// Prompts one address may cause per `window`.
    public static let maxPerAddress = 3
    /// Prompts overall per `window`.
    public static let maxOverall = 10
    public static let window: TimeInterval = 600
    /// After a decline or a failed request, that key and that address are ignored this long.
    public static let cooldown: TimeInterval = 120

    public enum Decision: Equatable, Sendable {
        case prompt
        /// Another request's prompt is up. Told, so a legitimate second Mac knows to retry.
        case busy
        /// Over a limit or cooling down. Closed without an answer, so a flood learns nothing.
        case ignore
    }

    public enum Outcome: Sendable { case paired, declined, failed, cancelled }

    private var prompts: [(time: TimeInterval, address: String)] = []
    private var cooling: [String: TimeInterval] = [:]
    public private(set) var active: (peer: Fingerprint, address: String)?

    public init() {}

    public mutating func request(peer: Fingerprint, address: String, now: TimeInterval) -> Decision {
        expire(now)
        if let until = cooling[peer.hex], now < until { return .ignore }
        if let until = cooling[Self.key(address)], now < until { return .ignore }
        if prompts.count >= Self.maxOverall { return .ignore }
        if prompts.filter({ $0.address == address }).count >= Self.maxPerAddress { return .ignore }
        if active != nil { return .busy }
        prompts.append((now, address))
        active = (peer, address)
        return .prompt
    }

    /// The active request ended. A request the host user turned down, or that used up its attempts,
    /// puts its key and address on cooldown; one the requester cancelled or that paired does not.
    public mutating func finished(_ outcome: Outcome, now: TimeInterval) {
        guard let a = active else { return }
        active = nil
        switch outcome {
        case .declined, .failed:
            cooling[a.peer.hex] = now + Self.cooldown
            cooling[Self.key(a.address)] = now + Self.cooldown
        case .paired, .cancelled:
            break
        }
    }

    /// Whether a pairing handshake is worth completing at all right now.
    public mutating func admitsHandshake(now: TimeInterval) -> Bool {
        expire(now)
        return prompts.count < Self.maxOverall
    }

    private mutating func expire(_ now: TimeInterval) {
        prompts.removeAll { now - $0.time >= Self.window || $0.time > now }
        cooling = cooling.filter { now < $0.value }
    }

    private static func key(_ address: String) -> String { "addr:" + address }
}
