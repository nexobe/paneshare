#if os(macOS)
import Foundation
import PaneshareDockLink
import Security

/// The main app's end of the local link (docs/ARCHITECTURE.md §6.3). A connecting process is
/// accepted only after its `hello` names a helper we generated and the kernel's audit token for
/// the socket peer resolves to running code with exactly that helper's identifier and cdhash.
final class DockLinkServer: @unchecked Sendable {
    enum Event: Sendable {
        case hello(String, coldStart: Bool)
        case activated(String)
        case choose(String, windowID: UInt32)
        case closeAll(String)
        case userQuit(String)
        case disconnected(String)
    }

    private final class Peer: @unchecked Sendable {
        var key: String?
    }

    private let queue = DispatchQueue(label: "dev.paneshare.docklink", qos: .userInitiated)
    private var listener: DockLinkListener?
    /// Queue-confined: helper key → its verified link, and helper key → the cdhash it must run as.
    private var links: [String: DockLinkConnection] = [:]
    private var allowed: [String: String] = [:]
    /// Queue-confined: accepted links that haven't said hello. Nothing else owns them until then.
    private var pending: [ObjectIdentifier: DockLinkConnection] = [:]
    /// Delivered on the main queue.
    var onEvent: (@Sendable (Event) -> Void)?

    func start() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let listener = try DockLinkListener(path: DockLinkPaths.socketPath(applicationSupport: support.path), queue: queue)
        listener.onAccept = { [weak self] fd in self?.accept(fd) }
        self.listener = listener
        listener.start()
    }

    func stop() {
        listener?.stop()
        queue.async { [self] in
            for link in links.values { link.close() }
            links.removeAll()
            for link in pending.values { link.close() }
            pending.removeAll()
        }
    }

    func allow(_ key: String, cdhash: String) {
        queue.async { [self] in allowed[key] = cdhash }
    }

    func send(_ message: DockLinkMessage, to key: String) {
        queue.async { [self] in links[key]?.send(message) }
    }

    private func accept(_ fd: Int32) {
        guard let token = DockLinkSocket.peerAuditToken(fd) else {
            _ = Darwin.close(fd)
            return
        }
        let link = DockLinkConnection(fd: fd, queue: queue)
        let peer = Peer()
        let id = ObjectIdentifier(link)
        pending[id] = link
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.received(message, link: link, peer: peer, token: token)
        }
        link.onClose = { [weak self, weak link] in
            guard let self else { return }
            self.pending[id] = nil
            guard let key = peer.key else { return }
            if let link, self.links[key] === link {
                self.links[key] = nil
                self.emit(.disconnected(key))
            }
        }
        link.start()
        queue.asyncAfter(deadline: .now() + 3) { [weak link] in
            if peer.key == nil { link?.close() }
        }
    }

    private func received(_ message: DockLinkMessage, link: DockLinkConnection, peer: Peer, token: Data) {
        guard let key = peer.key else {
            guard message.kind == .hello, message.protocolVersion == DockLinkMessage.protocolVersion,
                  let key = message.helperKey, let cdhash = allowed[key],
                  Self.verify(token: token, identifier: key, cdhash: cdhash) else {
                return link.close()
            }
            peer.key = key
            if let previous = links[key], previous !== link { previous.close() }
            links[key] = link
            pending[ObjectIdentifier(link)] = nil
            return emit(.hello(key, coldStart: message.coldStart ?? false))
        }
        switch message.kind {
        case .activated: emit(.activated(key))
        case .choose: if let id = message.windowID { emit(.choose(key, windowID: id)) }
        case .closeAll: emit(.closeAll(key))
        case .userQuit: emit(.userQuit(key))
        case .hello, .menu, .quit: break
        }
    }

    private func emit(_ event: Event) {
        guard let onEvent else { return }
        DispatchQueue.main.async { onEvent(event) }
    }

    /// The running code behind `token` must be valid and match `identifier` and `cdhash` exactly.
    static func verify(token: Data, identifier: String, cdhash: String) -> Bool {
        guard identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              cdhash.count == 40, cdhash.allSatisfy(\.isHexDigit) else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("identifier \"\(identifier)\" and cdhash H\"\(cdhash)\"" as CFString, [],
                                             &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
#endif
