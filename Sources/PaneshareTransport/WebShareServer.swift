#if os(macOS)
import Foundation
import Network
import PaneshareCore

/// The share-link server (ARCHITECTURE §7.4): HTTPS with a self-signed `WebCertificate`, serving the
/// web viewer and one WebSocket per guest. It only runs while the host has a live link. No request
/// gets anything but static files without a live link ID, and a socket does nothing until its first
/// message, a `join`, has been accepted by the owner with the link's token or a session secret.
public final class WebShareServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 47822
    public static let maxConnections = 24
    /// Seconds a connection may take to send its request head, and a socket its `join`.
    public static let handshakeTimeout: TimeInterval = 10

    public let queue = DispatchQueue(label: "dev.paneshare.web", qos: .userInteractive)
    public let certificate: WebCertificate
    public let port: UInt16
    private let identity: sec_identity_t
    private var listener: NWListener?
    private var live: [ObjectIdentifier: WebConnection] = [:]

    /// Whether a link ID is live. Called on `queue`; must answer at once.
    public var isLinkActive: (@Sendable (String) -> Bool) = { _ in false }
    /// A socket's first message, already parsed. Runs on `queue`. The owner accepts it (and from then on
    /// reads `onText`) or closes the connection.
    public var onJoin: (@Sendable (WebConnection, GuestInbound) -> Void)?
    public var onState: (@Sendable (String) -> Void)?

    public init(certificate: WebCertificate, port: UInt16 = WebShareServer.defaultPort) throws {
        self.certificate = certificate
        self.port = port
        self.identity = try TLSIdentity.webIdentity(certificate)
    }

    public func start() throws {
        let tls = NWProtocolTLS.Options()
        let sp = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sp, .TLSv12)
        sec_protocol_options_set_local_identity(sp, identity)
        sec_protocol_options_add_tls_application_protocol(sp, "http/1.1")
        // Browsers have no client certificate; the link token is the credential.
        sec_protocol_options_set_peer_authentication_required(sp, false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: tls, tcp: tcp)
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = false
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ChannelError.notReady("Bad port \(port)") }
        let listener = try NWListener(using: params, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?("Share links on port \(self?.port ?? 0)")
            case .failed(let e): self?.onState?("Share-link server failed: \(e)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            for c in live.values { c.close(code: .hostStopped) }
            live.removeAll()
        }
    }

    private func accept(_ nw: NWConnection) {
        guard live.count < Self.maxConnections else { return nw.cancel() }
        let connection = WebConnection(connection: nw, queue: queue)
        let key = ObjectIdentifier(connection)
        live[key] = connection
        connection.route = { [weak self] request in
            WebRouter.route(request, isLinkActive: { self?.isLinkActive($0) ?? false })
        }
        connection.onJoinMessage = { [weak self, weak connection] join in
            guard let self, let connection else { return }
            self.onJoin?(connection, join)
        }
        connection.onFinished = { [weak self] in self?.live[key] = nil }
        connection.start()
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak connection] in
            connection?.closeIfNotJoined()
        }
    }
}

/// One browser connection: an HTTP request, answered and closed, or a WebSocket. As a `MessageChannel`
/// it takes what `HostStream` sends a viewer and forwards the browser's share of it (`GuestWire`).
public final class WebConnection: MessageChannel, @unchecked Sendable {
    private enum Phase { case head, socket, closed }

    public let connection: NWConnection
    public let queue: DispatchQueue
    public var peerFingerprint: Fingerprint? { nil }
    /// Unused: guests don't speak paneshare frames. Their messages come through `onText`.
    public var onMessage: (@Sendable (Frame) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?
    /// Guest messages after the join was accepted. Runs on `queue`.
    public var onText: (@Sendable (String) -> Void)?

    var route: ((HTTPRequest) -> WebRoute)?
    var onJoinMessage: ((GuestInbound) -> Void)?
    var onFinished: (() -> Void)?

    private let lock = NSLock()
    private var phase = Phase.head
    private var joined = false
    private var awaitingJoin = false
    private var head: [UInt8] = []
    private var decoder = WebSocketCodec.Decoder(maxMessage: GuestInbound.maxSize)
    private var queuedVideo = 0

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// The guest's address without the port, for the host's list of guests.
    public var remoteHost: String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive()
            case .failed, .waiting: self?.finish()
            case .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.currentPhase != .closed else { return }
            if let data, !data.isEmpty { self.handle([UInt8](data)) }
            if error != nil || isComplete { return self.finish() }
            if self.currentPhase != .closed { self.receive() }
        }
    }

    private var currentPhase: Phase { lock.lock(); defer { lock.unlock() }; return phase }

    private func handle(_ bytes: [UInt8]) {
        switch currentPhase {
        case .head:
            head += bytes
            let parsed: (HTTPRequest, consumed: Int)?
            do { parsed = try HTTPRequest.parse(head) } catch {
                return respondAndClose(.text(400, "Bad Request", "Bad request."))
            }
            guard let parsed else { return }
            let (request, consumed) = parsed
            let rest = Array(head[consumed...])
            head = []
            switch route?(request) ?? .respond(.text(404, "Not Found", "")) {
            case .respond(let response):
                respondAndClose(response)
            case .upgrade(let key):
                lock.lock(); phase = .socket; awaitingJoin = true; lock.unlock()
                write(WebSocketCodec.handshakeResponse(key: key))
                if !rest.isEmpty { handleSocket(rest) }
            }
        case .socket:
            handleSocket(bytes)
        case .closed:
            break
        }
    }

    private func handleSocket(_ bytes: [UInt8]) {
        let messages: [WebSocketCodec.Message]
        do { messages = try decoder.append(bytes) } catch {
            return close(code: .protocolError)
        }
        for m in messages {
            switch m {
            case .text(let text):
                lock.lock()
                let isJoin = awaitingJoin
                awaitingJoin = false
                let accepted = joined
                lock.unlock()
                if isJoin {
                    guard let join = GuestInbound.decode(text), join.t == "join" else { return close(code: .protocolError) }
                    onJoinMessage?(join)
                } else if accepted {
                    onText?(text)
                }
            case .binary:
                return close(code: .protocolError)
            case .ping(let payload):
                write(WebSocketCodec.encode(.pong, payload))
            case .pong:
                break
            case .close:
                write(WebSocketCodec.encode(.close, []))
                return finish()
            }
        }
    }

    /// The owner accepted the join: deliver later messages to `onText`.
    public func markJoined() {
        lock.lock(); joined = true; lock.unlock()
    }

    func closeIfNotJoined() {
        lock.lock()
        let stale = phase == .head || (phase == .socket && !joined)
        lock.unlock()
        if stale { close(code: .rejected) }
    }

    public func sendNotice(_ notice: GuestNotice) {
        guard currentPhase == .socket else { return }
        write(WebSocketCodec.encode(.text, Array(notice.json().utf8)))
    }

    // MARK: MessageChannel

    public func send(_ frame: Frame) {
        guard currentPhase == .socket, let out = GuestWire.translate(frame) else { return }
        switch out {
        case .text(let s): write(WebSocketCodec.encode(.text, Array(s.utf8)))
        case .binary(let b): write(WebSocketCodec.encode(.binary, b))
        case .close(let code, _): close(code: GuestCloseCode(rawValue: code) ?? .hostStopped)
        }
    }

    @discardableResult
    public func sendDroppable(_ frame: Frame) -> Bool {
        guard currentPhase == .socket, let out = GuestWire.translate(frame) else { return false }
        guard case .binary(let b) = out else { send(frame); return true }
        lock.lock()
        if queuedVideo >= SessionRules.maxQueuedVideoFrames { lock.unlock(); return false }
        queuedVideo += 1
        lock.unlock()
        connection.send(content: Data(WebSocketCodec.encode(.binary, b)), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self.queuedVideo -= 1; self.lock.unlock()
            if error != nil { self.queue.async { self.finish() } }
        })
        return true
    }

    public func close() { close(code: .hostStopped) }

    public func close(code: GuestCloseCode) {
        queue.async { [weak self] in
            guard let self, self.currentPhase == .socket else { self?.finish(); return }
            self.connection.send(content: Data(WebSocketCodec.closeFrame(code: code.rawValue, reason: "\(code)")),
                                 completion: .contentProcessed { [weak self] _ in self?.finish() })
        }
    }

    private func respondAndClose(_ response: HTTPResponse) {
        connection.send(content: Data(response.encoded()), completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.finish() }
        })
    }

    private func write(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.queue.async { self?.finish() } }
        })
    }

    private func finish() {
        lock.lock()
        if phase == .closed { lock.unlock(); return }
        phase = .closed
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = onClose
        onClose = nil
        onText = nil
        onJoinMessage = nil
        handler?(nil)
        onFinished?()
        onFinished = nil
    }
}
#endif
