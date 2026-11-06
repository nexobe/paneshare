#if os(macOS)
import Foundation
import PaneshareCore
import PaneshareTransport

/// The host side of one pairing request (docs/ARCHITECTURE.md §4.2) on a `paneshare-pair/2`
/// connection. The viewer asks with `pairBegin`; the host shows a prompt and answers `pairStatus`.
/// Each time its user types the code the viewer shows and clicks Accept, the host sends a
/// `pairChallenge` keyed by that code (spending one of 5 attempts) and checks the viewer's
/// `pairResponse`. The fingerprints fed to the exchange come from this TLS session.
final class PairingRequest: @unchecked Sendable {
    enum Outcome: Sendable {
        case paired(Fingerprint, name: String)
        /// The host user declined.
        case declined
        /// Wrong codes used up, expired, or malformed; the reason is for the host's status line.
        case failed(String)
        /// The viewer cancelled, or never sent its request.
        case cancelled
    }

    private enum Stage {
        case awaitingBegin
        /// The prompt is up; waiting for the host user.
        case prompted
        case checking(PairingExchange)
        case finished
    }

    let viewer: Fingerprint
    let address: String
    private let channel: TLSMessageChannel
    private let hostFingerprint: Fingerprint
    private let hostName: String
    private let lock = NSLock()
    private var stage = Stage.awaitingBegin
    private var gate: PairingGate
    private var viewerNonce = Data()
    private var viewerName = ""

    /// The request arrived: show the prompt. Runs on the channel's queue.
    var onPrompt: (@Sendable (_ viewerName: String) -> Void)?
    /// The code typed on this Mac didn't match. Channel queue.
    var onWrongCode: (@Sendable (_ attemptsLeft: Int) -> Void)?
    /// Exactly once. Channel queue.
    var onEnd: (@Sendable (Outcome) -> Void)?

    init(channel: TLSMessageChannel, viewer: Fingerprint, hostFingerprint: Fingerprint, hostName: String) {
        self.channel = channel
        self.viewer = viewer
        self.address = channel.remoteHost
        self.hostFingerprint = hostFingerprint
        self.hostName = hostName
        self.gate = PairingGate(openedAt: ProcessInfo.processInfo.systemUptime)
    }

    func start() {
        channel.onMessage = { [weak self] frame in self?.handle(frame) }
        channel.onClose = { [weak self] _ in self?.end(nil, .cancelled) }
        channel.startReceiving()
        channel.queue.asyncAfter(deadline: .now() + SessionRules.helloTimeout) { [weak self] in
            guard let self, self.isAwaitingBegin else { return }
            self.end(nil, .cancelled)
        }
        channel.queue.asyncAfter(deadline: .now() + PairingGate.lifetime) { [weak self] in
            self?.end(PairResult(accepted: false, reason: .expired), .failed("The pairing request expired."))
        }
    }

    // MARK: From the prompt (any thread)

    /// The host user typed `code` and clicked Accept.
    func submit(code: String) {
        channel.queue.async { self.challenge(code) }
    }

    func decline() {
        channel.queue.async { self.end(PairResult(accepted: false, reason: .declined), .declined) }
    }

    /// Sharing was turned off.
    func cancel() {
        channel.queue.async { self.end(PairResult(accepted: false, reason: .notOpen), .cancelled) }
    }

    // MARK: Channel queue

    private var isAwaitingBegin: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .awaitingBegin = stage { return true }
        return false
    }

    private func handle(_ frame: Frame) {
        lock.lock()
        let current = stage
        lock.unlock()
        switch (current, frame.kind) {
        case (.awaitingBegin, .pairBegin?):
            guard let request = try? MessageCodec.decode(PairBegin.self, from: frame),
                  request.nonce.count == PairingExchange.nonceLength else { return malformed() }
            let trimmed = Self.displayable(request.viewerName)
            let name = trimmed.isEmpty ? viewer.shortID : trimmed
            lock.lock(); viewerNonce = request.nonce; viewerName = name; stage = .prompted; lock.unlock()
            send(.pairStatus, PairStatus(state: .prompted))
            onPrompt?(name)
        case (.checking(let exchange), .pairResponse?):
            guard let response = try? MessageCodec.decode(PairResponse.self, from: frame) else { return malformed() }
            verify(response, exchange)
        case (.finished, _):
            return
        default:
            malformed()
        }
    }

    private func challenge(_ code: String) {
        lock.lock()
        guard case .prompted = stage else { lock.unlock(); return }
        let admission = gate.begin(now: ProcessInfo.processInfo.systemUptime)
        let nonceV = viewerNonce
        lock.unlock()
        switch admission {
        case .challenge:
            let nonceH = PairingExchange.freshNonce()
            guard let exchange = try? PairingExchange(role: .host, code: code, host: hostFingerprint, viewer: viewer,
                                                      viewerNonce: nonceV, hostNonce: nonceH) else {
                lock.lock(); gate.abandon(); lock.unlock()
                return
            }
            lock.lock(); stage = .checking(exchange); lock.unlock()
            send(.pairChallenge, PairChallenge(nonce: nonceH, share: exchange.share))
        case .busy, .closed:
            return
        case .expired:
            end(PairResult(accepted: false, reason: .expired), .failed("The pairing request expired."))
        case .exhausted:
            end(PairResult(accepted: false, reason: .exhausted), .failed("Too many wrong codes."))
        }
    }

    private func verify(_ response: PairResponse, _ exchange: PairingExchange) {
        let confirmations = try? exchange.confirmations(peerShare: response.share)
        let matched = confirmations.map { PairingExchange.constantTimeEqual(response.confirm, $0.viewer) } ?? false
        lock.lock()
        let verdict = gate.finish(matched: matched)
        if case .wrongCode = verdict { stage = .prompted }
        let name = viewerName
        lock.unlock()
        switch verdict {
        case .accepted:
            end(PairResult(accepted: true, hostName: hostName, confirm: confirmations?.host), .paired(viewer, name: name))
        case .wrongCode(let left):
            send(.pairStatus, PairStatus(state: .wrongCode, attemptsLeft: left))
            onWrongCode?(left)
        case .exhausted:
            end(PairResult(accepted: false, reason: .exhausted), .failed("Too many wrong codes."))
        case .closed:
            end(PairResult(accepted: false, reason: .notOpen), .cancelled)
        }
    }

    private func malformed() {
        end(PairResult(accepted: false, reason: .malformed), .failed("A pairing request was malformed."))
    }

    /// Ends the request once: sends `result` if there is one, lets it flush, then closes.
    private func end(_ result: PairResult?, _ outcome: Outcome) {
        lock.lock()
        if case .finished = stage { lock.unlock(); return }
        stage = .finished
        lock.unlock()
        if let result, let f = try? MessageCodec.frame(.pairResult, result) {
            channel.send(f)
            let channel = self.channel
            channel.queue.asyncAfter(deadline: .now() + 0.5) { channel.close() }
        } else {
            channel.close()
        }
        onEnd?(outcome)
    }

    /// The requester picks its own name, so drop control and format characters (bidi overrides
    /// could reorder the prompt's text) and cap the length.
    static func displayable(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter {
            let c = $0.properties.generalCategory
            return c != .control && c != .format && c != .lineSeparator && c != .paragraphSeparator
        }
        return String(String.UnicodeScalarView(scalars).prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send<T: Encodable>(_ kind: MessageKind, _ value: T) {
        if let f = try? MessageCodec.frame(kind, value) { channel.send(f) }
    }
}
#endif
