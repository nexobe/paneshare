import Foundation

/// One pairing request's limits, kept on both sides (docs/ARCHITECTURE.md §4.2): 5 attempts,
/// 5 minutes, single use. An attempt is spent when a challenge is issued (host) or received (viewer),
/// before any answer, and only one may be in flight, so each live exchange tests at most one guess.
/// Pure; the clock is passed in.
public struct PairingGate: Sendable {
    public static let maxAttempts = 5
    public static let lifetime: TimeInterval = 300

    public enum Admission: Equatable, Sendable {
        /// Go ahead and send a challenge; this attempt has already been counted.
        case challenge(attemptsLeft: Int)
        case busy
        case expired
        case exhausted
        case closed
    }

    public enum Verdict: Equatable, Sendable {
        /// The viewer's confirmation matched; pin it.
        case accepted
        case wrongCode(attemptsLeft: Int)
        case exhausted
        case closed
    }

    public let openedAt: TimeInterval
    public private(set) var attemptsLeft = PairingGate.maxAttempts
    public private(set) var isUsed = false
    public private(set) var attemptInFlight = false

    public init(openedAt: TimeInterval) {
        self.openedAt = openedAt
    }

    public func isOpen(now: TimeInterval) -> Bool {
        !isUsed && attemptsLeft > 0 && now - openedAt < Self.lifetime && now >= openedAt
    }

    /// A challenge is about to go out (host) or just came in (viewer). Spends an attempt if admitted.
    public mutating func begin(now: TimeInterval) -> Admission {
        if isUsed { return .closed }
        if attemptsLeft <= 0 { return .exhausted }
        if now - openedAt >= Self.lifetime || now < openedAt { return .expired }
        if attemptInFlight { return .busy }
        attemptsLeft -= 1
        attemptInFlight = true
        return .challenge(attemptsLeft: attemptsLeft)
    }

    /// The attempt was settled; `matched` is whether the confirmation tag verified.
    /// The deadline is not re-checked: the attempt was admitted while the window was open.
    public mutating func finish(matched: Bool) -> Verdict {
        guard attemptInFlight, !isUsed else { return .closed }
        attemptInFlight = false
        if matched {
            isUsed = true
            return .accepted
        }
        return attemptsLeft > 0 ? .wrongCode(attemptsLeft: attemptsLeft) : .exhausted
    }

    /// The peer went away without answering. The attempt stays spent.
    public mutating func abandon() {
        attemptInFlight = false
    }
}
