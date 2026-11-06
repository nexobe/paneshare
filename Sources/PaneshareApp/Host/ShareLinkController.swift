#if os(macOS)
import AppKit
import Foundation
import PaneshareCapture
import PaneshareCore
import PaneshareTransport
import SystemConfiguration

/// Share links for browser guests (ARCHITECTURE §7.4): the links, the HTTPS server that exists only
/// while one is live, and one `HostStream` per connected guest over a `WebConnection`.
@MainActor
final class ShareLinkController: ObservableObject {
    struct Guest: Identifiable {
        let session: GuestSession
        let connection: WebConnection
        var stream: HostStream?
        var pointer = GuestPointer()
        let overlay: GuestPointerOverlay
        var id: String { session.id }
    }

    struct LinkURL: Identifiable {
        let label: String
        let url: String
        var id: String { url }
    }

    /// A link the host just made, with its secret, shown once.
    struct Created: Identifiable {
        let link: ShareLinkRecord
        let urls: [LinkURL]
        let certificateSHA256: String
        var id: String { link.id }
    }

    @Published private(set) var links: [ShareLinkRecord] = []
    @Published private(set) var guests: [Guest] = []
    @Published var created: Created?
    @Published var lastError: String?

    static let maxGuests = 8

    private weak var host: HostController?
    private var store = ShareLinkStore()
    private var server: WebShareServer?
    private let activeIDs = Locked<Set<String>>([])
    private var expiryTimer: Timer?
    private var nextStreamID: UInt16 = 1

    init(host: HostController) {
        self.host = host
    }

    // MARK: Links

    func create(for window: WindowInfo, lifetime: TimeInterval, pointerAllowed: Bool) {
        guard let host, host.isHosting, host.isOffered(window.windowID) else {
            lastError = "Turn sharing on and share the window first."
            return
        }
        do {
            let server = try startServerIfNeeded()
            let (link, token) = try store.create(windowID: window.windowID, windowTitle: window.displayTitle,
                                                 lifetime: lifetime, pointerAllowed: pointerAllowed, now: Date())
            let urls = ShareAddresses.rank(ipv4: LocalAddresses.ipv4(), localHostName: LocalAddresses.bonjourName())
                .map { c -> LinkURL in
                    let label: String
                    switch c.kind {
                    case .tailscale: label = "Tailscale"
                    case .lan: label = "Local network"
                    case .bonjour: label = "Local name"
                    }
                    return LinkURL(label: label, url: ShareAddresses.url(host: c.host, port: server.port, linkID: link.id, token: token))
                }
            created = Created(link: link, urls: urls, certificateSHA256: server.certificate.sha256)
            publish()
        } catch {
            lastError = "Couldn't make a link: \(error)"
            publish()
            stopServerIfIdle()
        }
    }

    func revoke(_ linkID: String) {
        disconnect(store.revoke(linkID: linkID), code: .rejected)
        publish()
        stopServerIfIdle()
    }

    func kick(_ sessionID: String) {
        if let session = store.kick(sessionID: sessionID) { disconnect([session], code: .kicked) }
        publish()
        stopServerIfIdle()
    }

    func setPointerAllowed(_ allowed: Bool, linkID: String) {
        store.setPointerAllowed(allowed, linkID: linkID)
        for i in guests.indices where guests[i].session.linkID == linkID {
            if !allowed {
                for event in guests[i].pointer.revoke() { guests[i].stream?.handle(event) }
            }
            var n = GuestNotice(t: "pointer")
            n.pointer = allowed
            guests[i].connection.sendNotice(n)
        }
        publish()
    }

    /// The host stopped sharing a window.
    func windowUnshared(_ windowID: UInt32) {
        disconnect(store.revoke(windowID: windowID), code: .windowClosed)
        publish()
        stopServerIfIdle()
    }

    /// Hosting turned off: every link goes.
    func stopAll() {
        disconnect(store.removeAll(), code: .hostStopped)
        for g in guests { endGuest(g.session.id, code: .hostStopped) }
        publish()
        stopServerIfIdle()
    }

    func timeLeft(_ link: ShareLinkRecord) -> TimeInterval { max(0, link.expiresAt.timeIntervalSinceNow) }

    // MARK: Server

    private func startServerIfNeeded() throws -> WebShareServer {
        if let server { return server }
        let names = [LocalAddresses.bonjourName().map { $0 + ".local" }, "localhost"].compactMap { $0 }
        let certificate = try WebCertificate(dnsNames: names, ipv4: LocalAddresses.ipv4() + ["127.0.0.1"], now: Date())
        let server = try WebShareServer(certificate: certificate)
        let active = activeIDs
        server.isLinkActive = { id in active.withLock { $0.contains(id) } }
        server.onJoin = { [weak self] connection, join in
            guard let self else { return connection.close(code: .rejected) }
            onMain { self.join(connection, join) }
        }
        try server.start()
        self.server = server
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
        return server
    }

    private func stopServerIfIdle() {
        guard store.links.isEmpty, guests.isEmpty, let server else { return }
        server.stop()
        self.server = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    private func expire() {
        disconnect(store.expire(now: Date()), code: .expired)
        publish()
        stopServerIfIdle()
    }

    private func publish() {
        links = store.links
        let ids = Set(store.links.filter { !$0.isExpired(at: Date()) }.map(\.id))
        activeIDs.withLock { $0 = ids }
    }

    // MARK: Guests

    private func join(_ connection: WebConnection, _ join: GuestInbound) {
        guard let host, host.isHosting, let linkID = join.link, Base64URL.isWellFormed(linkID) else {
            return connection.close(code: .rejected)
        }
        let now = Date()
        let session: GuestSession
        var secret: String?
        if let token = join.token, Base64URL.isWellFormed(token) {
            switch store.redeem(linkID: linkID, token: token, name: join.name ?? "", address: connection.remoteHost, now: now) {
            case .success(let redeemed):
                session = redeemed.session
                secret = redeemed.secret
            case .failure(let why):
                disconnect(store.takeBurned(), code: .rejected)
                publish()
                connection.close(code: why == .expired ? .expired : .rejected)
                return stopServerIfIdle()
            }
        } else if let id = join.session, let s = join.secret, Base64URL.isWellFormed(id), Base64URL.isWellFormed(s) {
            switch store.resume(sessionID: id, secret: s, now: now) {
            case .success(let resumed): session = resumed
            case .failure(let why): return connection.close(code: why == .expired ? .expired : .rejected)
            }
            guard session.linkID == linkID else { return connection.close(code: .rejected) }
        } else {
            return connection.close(code: .rejected)
        }
        // A returning guest replaces its previous connection (a reload, or the same session in another tab).
        endGuest(session.id, code: .replaced)
        guard guests.count < Self.maxGuests else { return connection.close(code: .tooMany) }
        guard let link = store.link(for: session), host.isOffered(link.windowID) else {
            return connection.close(code: .windowClosed)
        }
        connection.markJoined()
        connection.onText = { [weak self] text in
            guard let self, let message = GuestInbound.decode(text) else { return }
            onMain { self.guestMessage(session.id, message) }
        }
        connection.onClose = { [weak self] _ in
            guard let self else { return }
            onMain { self.connectionClosed(session.id, connection) }
        }
        var welcome = GuestNotice(t: "welcome")
        welcome.session = session.id
        welcome.secret = secret
        welcome.title = link.windowTitle
        welcome.pointer = link.pointerAllowed
        welcome.expires = link.expiresAt.timeIntervalSince1970 * 1000
        connection.sendNotice(welcome)
        guests.append(Guest(session: session, connection: connection, stream: nil, overlay: GuestPointerOverlay(name: session.name)))
        publish()
        startStream(for: session.id, windowID: link.windowID, scale: join.scale ?? 1)
    }

    private func startStream(for sessionID: String, windowID: UInt32, scale: Double) {
        guard let host, let g = guests.first(where: { $0.id == sessionID }) else { return }
        let streamID = nextStreamID
        nextStreamID = nextStreamID == .max ? 1 : nextStreamID + 1
        let connection = g.connection
        let viewerScale = scale.isFinite ? min(2, max(1, scale)) : 1
        Task {
            do {
                guard let entry = try await ShareableWindows.find(windowID, policy: host.policy) else {
                    return connection.close(code: .windowClosed)
                }
                guard let i = guests.firstIndex(where: { $0.id == sessionID && $0.connection === connection }) else { return }
                let stream = HostStream(streamID: streamID, entry: entry, viewerScale: viewerScale, quality: .balanced,
                                        chroma: [.yuv420], channel: connection, viewer: nil, viewerDisplay: nil,
                                        allowHEVC: false, policy: host.policy)
                stream.onEnded = { [weak self, weak stream] reason in
                    guard let self, let stream, let g = self.guests.first(where: { $0.id == sessionID }), g.stream === stream else { return }
                    self.endGuest(sessionID, code: reason == .windowClosed ? .windowClosed : .hostStopped)
                    self.publish()
                }
                guests[i].stream = stream
                try await stream.start()
            } catch {
                NSLog("paneshare share link: couldn't start a guest stream: %@", "\(error)")
                connection.close(code: .hostStopped)
            }
        }
    }

    private func guestMessage(_ sessionID: String, _ message: GuestInbound) {
        guard let i = guests.firstIndex(where: { $0.id == sessionID }),
              let link = store.link(for: guests[i].session), !link.isExpired(at: Date()) else { return }
        let actions = guests[i].pointer.handle(message, pointerAllowed: link.pointerAllowed,
                                               now: ProcessInfo.processInfo.systemUptime)
        for action in actions {
            switch action {
            case .show(let p):
                if let frame = guests[i].stream?.currentFrame { guests[i].overlay.show(at: p, in: frame) }
            case .hide:
                guests[i].overlay.hide()
            case .inject(let event):
                guests[i].stream?.handle(event)
            case .keyframe:
                guests[i].stream?.requestKeyframe()
            }
        }
    }

    private func connectionClosed(_ sessionID: String, _ connection: WebConnection) {
        guard let g = guests.first(where: { $0.id == sessionID }), g.connection === connection else { return }
        // The session stays in the store, so the guest can come back until the link expires.
        endGuest(sessionID, code: nil)
        publish()
        stopServerIfIdle()
    }

    private func disconnect(_ sessions: [GuestSession], code: GuestCloseCode) {
        for s in sessions { endGuest(s.id, code: code) }
    }

    /// Stops a guest's stream and pointer; `code` also closes its socket with that reason.
    private func endGuest(_ sessionID: String, code: GuestCloseCode?) {
        guard let i = guests.firstIndex(where: { $0.id == sessionID }) else { return }
        var g = guests.remove(at: i)
        for event in g.pointer.revoke() { g.stream?.handle(event) }
        g.stream?.end(.hostStopped, notify: false)
        g.overlay.close()
        if let code { g.connection.close(code: code) }
    }
}

/// IPv4 addresses of interfaces that are up, from `getifaddrs` (no shell, no network calls).
enum LocalAddresses {
    /// The Bonjour name (System Settings → General → Sharing → Local hostname), without ".local".
    static func bonjourName() -> String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func ipv4() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}
#endif
