#if os(macOS)
import Foundation
import Network
import PaneshareCore

/// The host's single TLS listener, advertised over Bonjour. It never accepts a connection without
/// TLS, and the verify block decides before any application byte is read:
/// - `paneshare/1` only for a viewer whose fingerprint is pinned;
/// - `paneshare-pair/2` from anyone (the listener only exists while sharing is on); what a
///   request may do from there is up to the owner's request limiter and the host user;
/// - anything else is refused.
public final class HostListener: @unchecked Sendable {
    /// `alpn` is nil if the stack hasn't exposed the negotiated protocol to the verify block yet. The
    /// owner must then re-check the ALPN once the channel is ready.
    public typealias Admission = @Sendable (_ peer: Fingerprint, _ alpn: String?) -> Bool

    public let queue = DispatchQueue(label: "dev.paneshare.host.net", qos: .userInteractive)
    private let identity: TLSIdentity
    private let port: UInt16
    private let serviceName: String
    private let admit: Admission
    private var listener: NWListener?
    private var live: [ObjectIdentifier: TLSMessageChannel] = [:]

    /// A new channel, already TLS-ready, with its negotiated ALPN set. Runs on `queue`. The owner
    /// installs its handlers, then calls `startReceiving()`.
    public var onChannel: (@Sendable (TLSMessageChannel) -> Void)?
    public var onState: (@Sendable (String) -> Void)?

    /// `admit` runs inside the TLS handshake on `queue` and must answer at once.
    public init(identity: TLSIdentity, port: UInt16 = PinnedTLS.defaultPort, serviceName: String, admit: @escaping Admission) {
        self.identity = identity
        self.port = port
        self.serviceName = serviceName
        self.admit = admit
    }

    public func start() throws {
        let tls = PinnedTLS.options(identity: identity.tls, role: .server, queue: queue) { [admit] peer, alpn in
            guard let peer else { return false }
            return admit(peer, alpn)
        }
        let params = PinnedTLS.parameters(tls: tls, dialing: false)
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ChannelError.notReady("Bad port \(port)") }
        let listener = try NWListener(using: params, on: nwPort)
        let txt = NWTXTRecord(["v": "\(Frame.version)", "id": identity.fingerprint.shortID])
        listener.service = NWListener.Service(name: serviceName, type: PinnedTLS.serviceType, txtRecord: txt)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?("Listening on port \(self?.port ?? 0)")
            case .waiting(let e): self?.onState?("Waiting: \(e)")
            case .failed(let e): self?.onState?("Listener failed: \(e)")
            case .cancelled: self?.onState?("Stopped")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        guard live.count < SessionRules.maxConnections else {
            connection.cancel()
            return
        }
        let channel = TLSMessageChannel(connection: connection, queue: queue, receiveLimit: FrameDecoder.viewerToHostLimit)
        channel.receivesWhenReady = false
        let key = ObjectIdentifier(channel)
        live[key] = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.onChannel?(channel)
        }
        // The owner replaces onClose once it takes the channel; this one covers a failed handshake.
        channel.onClose = { [weak self] _ in self?.live[key] = nil }
        channel.start()
        // A handshake that never completes doesn't hold a slot.
        queue.asyncAfter(deadline: .now() + SessionRules.helloTimeout) { [weak channel] in
            if let channel, !channel.isReady { channel.close() }
        }
    }

    /// The owner calls this when a channel it took closes.
    public func forget(_ channel: TLSMessageChannel) {
        queue.async { self.live[ObjectIdentifier(channel)] = nil }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            for c in live.values { c.close() }
            live.removeAll()
        }
    }
}

/// Dials a host. The viewer side of both ALPNs.
public enum Dialer {
    /// `verify` gets the host's fingerprint from the handshake. For a session it must be a pinned host;
    /// for pairing it's checked against the Bonjour hint when there is one, and the pairing proof
    /// authenticates it afterwards.
    public static func connect(to endpoint: NWEndpoint, identity: TLSIdentity, alpn: String, queue: DispatchQueue,
                               verify: @escaping @Sendable (Fingerprint) -> Bool) -> TLSMessageChannel {
        let tls = PinnedTLS.options(identity: identity.tls, role: .client(alpn: alpn), queue: queue) { peer, _ in
            guard let peer else { return false }
            return verify(peer)
        }
        let connection = NWConnection(to: endpoint, using: PinnedTLS.parameters(tls: tls, dialing: true))
        return TLSMessageChannel(connection: connection, queue: queue, receiveLimit: FrameDecoder.hostToViewerLimit)
    }

    /// "host", "host:port", "[v6]:port" → an endpoint. Nil for anything unparsable.
    public static func endpoint(fromAddress text: String) -> NWEndpoint? {
        guard let parsed = HostAddress.parse(text, defaultPort: PinnedTLS.defaultPort),
              let port = NWEndpoint.Port(rawValue: parsed.port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(parsed.host), port: port)
    }
}
#endif
