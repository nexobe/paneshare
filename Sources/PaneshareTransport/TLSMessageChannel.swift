#if os(macOS)
import Foundation
import Network
import PaneshareCore

public enum ChannelError: Error, CustomStringConvertible {
    case protocolError(FrameError)
    case network(NWError)
    case closedByPeer
    case notReady(String)

    public var description: String {
        switch self {
        case .protocolError(let e): return "Protocol error: \(e)"
        case .network(let e):
            if case .tls(let status) = e, status == -9808 || status == -9825 {
                return "The other Mac's identity is not trusted. Pair again."
            }
            return "Network error: \(e)"
        case .closedByPeer: return "The other Mac closed the connection."
        case .notReady(let s): return s
        }
    }
}

/// `MessageChannel` over one TLS `NWConnection`. Frames are parsed by `FrameDecoder` with the
/// payload limit of the direction this side receives. All callbacks run on `queue`.
public final class TLSMessageChannel: MessageChannel, @unchecked Sendable {
    public let connection: NWConnection
    public let queue: DispatchQueue
    public var onMessage: (@Sendable (Frame) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?
    /// Called once, when TLS is up.
    public var onReady: (@Sendable () -> Void)?

    private var decoder: FrameDecoder
    private var closed = false
    private var queuedVideo = 0
    private let lock = NSLock()

    public private(set) var peerFingerprint: Fingerprint?
    public private(set) var alpn: String?
    public private(set) var isReady = false
    /// When false, reading waits for `startReceiving()`, so an owner that installs its handlers
    /// later (on another queue) can't miss the first frames.
    public var receivesWhenReady = true

    /// `receiveLimit` is `FrameDecoder.hostToViewerLimit` on a viewer, `.viewerToHostLimit` on a host.
    public init(connection: NWConnection, queue: DispatchQueue, receiveLimit: UInt32) {
        self.connection = connection
        self.queue = queue
        self.decoder = FrameDecoder(maxPayload: receiveLimit)
    }

    public var remoteDescription: String {
        switch connection.endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        case .service(let name, _, _, _): return name
        default: return "\(connection.endpoint)"
        }
    }

    /// The peer's address without the port: what the pairing limiter counts requests by.
    public var remoteHost: String {
        switch connection.endpoint {
        case .hostPort(let host, _): return "\(host)"
        default: return remoteDescription
        }
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            peerFingerprint = PinnedTLS.peerFingerprint(connection)
            alpn = PinnedTLS.negotiatedALPN(connection)
            guard peerFingerprint != nil else { return finish(ChannelError.notReady("The peer sent no usable certificate.")) }
            isReady = true
            onReady?()
            if receivesWhenReady { receive() }
        case .waiting(let error):
            // A dial that waits is a dial that failed: report it and let the owner decide to retry.
            finish(ChannelError.network(error))
        case .failed(let error):
            finish(ChannelError.network(error))
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.append(data) {
                        self.onMessage?(frame)
                        if self.isClosed { return }
                    }
                } catch let e as FrameError {
                    self.sendError(code: "protocol", message: "\(e)")
                    return self.finish(ChannelError.protocolError(e))
                } catch {
                    return self.finish(error)
                }
            }
            if let error { return self.finish(ChannelError.network(error)) }
            if isComplete { return self.finish(ChannelError.closedByPeer) }
            self.receive()
        }
    }

    /// Starts reading, once. For channels with `receivesWhenReady == false`.
    public func startReceiving() {
        queue.async { [weak self] in
            guard let self, self.isReady, !self.isClosed, !self.receiving else { return }
            self.receive()
        }
    }

    private var receiving = false

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    public func send(_ frame: Frame) {
        guard !isClosed else { return }
        connection.send(content: frame.encoded(), completion: .contentProcessed { [weak self] error in
            if let error { self?.queue.async { self?.finish(ChannelError.network(error)) } }
        })
    }

    @discardableResult
    public func sendDroppable(_ frame: Frame) -> Bool {
        lock.lock()
        if closed || queuedVideo >= SessionRules.maxQueuedVideoFrames { lock.unlock(); return false }
        queuedVideo += 1
        lock.unlock()
        connection.send(content: frame.encoded(), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self.queuedVideo -= 1; self.lock.unlock()
            if let error { self.queue.async { self.finish(ChannelError.network(error)) } }
        })
        return true
    }

    public func sendError(code: String, message: String) {
        if let f = try? MessageCodec.frame(.error, ProtocolErrorMessage(code: code, message: message)) { send(f) }
    }

    public func close() {
        queue.async { [weak self] in self?.finish(nil) }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = onClose
        onClose = nil
        onMessage = nil
        onReady = nil
        handler?(error)
    }
}
#endif
