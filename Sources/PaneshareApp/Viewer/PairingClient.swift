#if os(macOS)
import Foundation
import Network
import PaneshareCore
import PaneshareTransport

/// The viewer side of pairing (docs/ARCHITECTURE.md §4.2): dial `paneshare-pair/2` and ask. The
/// host shows a prompt; each time its user types the code this Mac shows, the host sends a
/// challenge keyed by what was typed, bound to both TLS fingerprints, and this side answers with
/// its share and tag under its own code. The handshake accepts any P-256 host key (optionally only
/// one matching the Bonjour host ID), because nothing is trusted until the host's confirmation
/// checks out, which only a host whose user typed this code can produce. This side keeps its own
/// `PairingGate`, so a host (or anyone in the middle) gets at most 5 guesses in 5 minutes.
final class PairingClient: @unchecked Sendable {
    enum Result: Sendable {
        case paired(host: Fingerprint, name: String)
        case failed(String)
        case cancelled
    }

    enum Progress: Sendable {
        /// The prompt is up on the host.
        case prompted
        /// The host's user typed a different code.
        case wrongCode(attemptsLeft: Int)
    }

    private struct Pending {
        let host: Fingerprint
        let expectedHostConfirm: Data
    }

    private let queue = DispatchQueue(label: "dev.paneshare.pairing.client", qos: .userInitiated)
    private var channel: TLSMessageChannel?
    private let finished = Locked(false)
    private var finish: (@Sendable (Result) -> Void)?

    func pair(endpoint: NWEndpoint, expectedHostID: String?, code: String, identity: TLSIdentity, viewerName: String,
              fallbackName: String, progress: @escaping @Sendable (Progress) -> Void,
              done: @escaping @Sendable (Result) -> Void) {
        let channel = Dialer.connect(to: endpoint, identity: identity, alpn: PinnedTLS.pairingALPN, queue: queue) { fp in
            expectedHostID.map { fp.shortID == $0 } ?? true
        }
        let finish: @Sendable (Result) -> Void = { [finished] r in
            guard finished.withLock({ was in defer { was = true }; return !was }) else { return }
            channel.close()
            done(r)
        }
        self.channel = channel
        self.finish = finish
        let me = identity.fingerprint
        let viewerNonce = PairingExchange.freshNonce()
        let pending = Locked<Pending?>(nil)
        let gate = Locked(PairingGate(openedAt: ProcessInfo.processInfo.systemUptime))
        let unexpected = "The host answered with something unexpected. Nothing was saved."

        channel.onReady = {
            guard channel.peerFingerprint != nil,
                  let f = try? MessageCodec.frame(.pairBegin, PairBegin(viewerName: viewerName, nonce: viewerNonce)) else {
                return finish(.failed("The host sent no usable certificate."))
            }
            channel.send(f)
        }
        channel.onMessage = { frame in
            switch frame.kind {
            case .pairStatus:
                guard let status = try? MessageCodec.decode(PairStatus.self, from: frame) else { return finish(.failed(unexpected)) }
                switch status.state {
                case .prompted:
                    progress(.prompted)
                case .wrongCode:
                    guard pending.withLock({ p in defer { p = nil }; return p != nil }) else { return finish(.failed(unexpected)) }
                    switch gate.withLock({ $0.finish(matched: false) }) {
                    case .wrongCode(let left): progress(.wrongCode(attemptsLeft: left))
                    default: finish(.failed(Self.explain(.exhausted)))
                    }
                }
            case .pairChallenge:
                guard pending.withLock({ $0 == nil }), let host = channel.peerFingerprint,
                      let challenge = try? MessageCodec.decode(PairChallenge.self, from: frame),
                      challenge.nonce.count == PairingExchange.nonceLength else {
                    return finish(.failed(unexpected))
                }
                switch gate.withLock({ $0.begin(now: ProcessInfo.processInfo.systemUptime) }) {
                case .challenge: break
                case .expired: return finish(.failed(Self.explain(.expired)))
                default: return finish(.failed(Self.explain(.exhausted)))
                }
                guard let exchange = try? PairingExchange(role: .viewer, code: code, host: host, viewer: me,
                                                          viewerNonce: viewerNonce, hostNonce: challenge.nonce),
                      let confirmations = try? exchange.confirmations(peerShare: challenge.share),
                      let f = try? MessageCodec.frame(.pairResponse, PairResponse(share: exchange.share, confirm: confirmations.viewer)) else {
                    return finish(.failed("The host's key share was invalid. Nothing was saved."))
                }
                pending.withLock { $0 = Pending(host: host, expectedHostConfirm: confirmations.host) }
                channel.send(f)
            case .pairResult:
                guard let result = try? MessageCodec.decode(PairResult.self, from: frame) else { return finish(.failed(unexpected)) }
                guard result.accepted else { return finish(.failed(Self.explain(result.reason))) }
                guard let p = pending.withLock({ $0 }), let confirm = result.confirm,
                      PairingExchange.constantTimeEqual(confirm, p.expectedHostConfirm),
                      gate.withLock({ $0.finish(matched: true) }) == .accepted else {
                    return finish(.failed("The host couldn't prove its user typed this code. Nothing was saved."))
                }
                let name = result.hostName.map { String($0.prefix(64)) }.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
                finish(.paired(host: p.host, name: name))
            default:
                finish(.failed(unexpected))
            }
        }
        channel.onClose = { error in
            finish(.failed(error.map { "\($0)" } ?? "The host closed the connection."))
        }
        channel.start()
        queue.asyncAfter(deadline: .now() + PairingGate.lifetime + 10) {
            finish(.failed(Self.explain(.expired)))
        }
    }

    /// The user gave up on this Mac; the host's prompt closes when the connection does.
    func cancel() {
        queue.async { self.finish?(.cancelled) }
    }

    static func explain(_ reason: PairResult.Reason?) -> String {
        switch reason {
        case .wrongCode: return "The code typed on the host didn't match."
        case .expired: return "The request expired. Click Pair to try again."
        case .exhausted: return "Too many wrong codes were typed on the host. Click Pair to try again."
        case .notOpen: return "That Mac stopped sharing."
        case .busy: return "That Mac is answering another pairing request. Try again in a moment."
        case .declined: return "The request was declined on that Mac."
        case .malformed, .none: return "The host rejected the request."
        }
    }
}
#endif
