import Foundation

/// A bidirectional, authenticated, ordered message channel to one peer (docs/ARCHITECTURE.md §5).
/// The MVP implementation is `TLSMessageChannel` (TCP + TLS 1.3, Network.framework); another
/// transport only has to deliver whole `Frame`s in order and say who the peer is.
public protocol MessageChannel: AnyObject, Sendable {
    /// The peer's SPKI fingerprint as the authenticated channel reports it, never as a message claims it.
    var peerFingerprint: Fingerprint? { get }
    var onMessage: (@Sendable (Frame) -> Void)? { get set }
    var onClose: (@Sendable (Error?) -> Void)? { get set }
    func send(_ frame: Frame)
    /// Sends a frame that may be dropped under backpressure (non-key video). Returns false if dropped.
    @discardableResult func sendDroppable(_ frame: Frame) -> Bool
    func close()
}

/// The rules every session applies to the first frames, shared by host and viewer.
public enum SessionRules {
    /// A session that has not said `hello` within this many seconds is closed.
    public static let helloTimeout: TimeInterval = 10
    /// The most non-key video frames allowed in the send queue before new ones are dropped.
    public static let maxQueuedVideoFrames = 2
    /// Concurrent connections a host accepts (sessions plus pairing attempts).
    public static let maxConnections = 8

    public enum HelloProblem: Error, Equatable, Sendable {
        case notHello, malformed, unsupportedVersion(Int), wrongRole
    }

    /// Validates the first frame of a session. `expecting` is the role the peer must claim.
    public static func checkHello(_ frame: Frame, expecting role: PeerRole) -> Result<Hello, HelloProblem> {
        guard frame.kind == .hello else { return .failure(.notHello) }
        guard let hello = try? MessageCodec.decode(Hello.self, from: frame) else { return .failure(.malformed) }
        guard hello.protocolVersion == Int(Frame.version) else { return .failure(.unsupportedVersion(hello.protocolVersion)) }
        guard hello.role == role else { return .failure(.wrongRole) }
        return .success(hello)
    }

    /// Re-dial delay after `attempt` consecutive failures: 0.5, 1, 2, 4, 8, then 10 s.
    public static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(10, 0.5 * pow(2, Double(max(0, attempt))))
    }
}

/// How long a viewer waits before each new try. A session must have lasted before the wait starts
/// over: a host that accepts the connection and then drops it at once must not be retried at full speed.
public struct ReconnectBackoff: Equatable, Sendable {
    /// A session that lasted this many seconds counts as working.
    public static let stableAfter: TimeInterval = 5

    private var attempt = 0

    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }
        return SessionRules.reconnectDelay(attempt: attempt)
    }

    /// `lasted` is how long the session ran after both sides said hello, or nil if they never did.
    public mutating func sessionEnded(lasted: TimeInterval?) {
        if let lasted, lasted >= Self.stableAfter { attempt = 0 }
    }

    /// The user stopped trying, so their next try starts fresh.
    public mutating func reset() { attempt = 0 }
}
