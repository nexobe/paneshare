#if os(macOS)
// TLS option pattern adapted from Sill (github.com/Saffsanity/sill, Sources/StreamProtocol/RemoteTLS.swift),
// Copyright 2026 Noah Saffer, Apache License 2.0. Changes: paneshare ALPNs, swift-crypto fingerprints, no
// home-door variant. See THIRD_PARTY.md.
import Foundation
import Network
import PaneshareCore
import Security

/// TLS 1.3, mutual authentication, and a verify block that pins the peer's SPKI fingerprint and
/// never evaluates a chain, a name or a date (docs/ARCHITECTURE.md §3.1, §4). There is no option to
/// turn verification off: every connection goes through `verify`.
public enum PinnedTLS {
    public static let sessionALPN = "paneshare/1"
    /// Version 2: the viewer asks, the host prompts and its user types the viewer's code there.
    public static let pairingALPN = "paneshare-pair/2"
    public static let serverALPNs = [sessionALPN, pairingALPN]
    /// The SNI every client sends, so a MagicDNS name never crosses the network in clear.
    public static let serverName = "paneshare"
    public static let defaultPort: UInt16 = 47821
    public static let serviceType = "_paneshare._tcp"
    public static let dialTimeout = 10

    public enum Role: Sendable {
        case server
        case client(alpn: String)
    }

    /// `verify` gets the peer's fingerprint (nil when there is no P-256 leaf) and the ALPN negotiated
    /// so far, and must answer at once. It runs on `queue`.
    public static func options(identity: sec_identity_t, role: Role, queue: DispatchQueue,
                               verify: @escaping @Sendable (_ peer: Fingerprint?, _ alpn: String?) -> Bool) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sp = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sp, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sp, .TLSv13)
        sec_protocol_options_set_local_identity(sp, identity)
        sec_protocol_options_set_tls_tickets_enabled(sp, false)
        sec_protocol_options_set_tls_resumption_enabled(sp, false)
        switch role {
        case .server:
            sec_protocol_options_set_peer_authentication_required(sp, true)
            for alpn in serverALPNs { sec_protocol_options_add_tls_application_protocol(sp, alpn) }
        case .client(let alpn):
            sec_protocol_options_add_tls_application_protocol(sp, alpn)
            sec_protocol_options_set_tls_server_name(sp, serverName)
        }
        sec_protocol_options_set_verify_block(sp, { metadata, _, complete in
            // The pin is the whole of trust. The trust object is never evaluated, because evaluation
            // can fetch issuers over the network (AIA) while holding this queue.
            complete(verify(PinnedTLS.peerLeaf(metadata).flatMap(PinnedTLS.fingerprint(of:)),
                            PinnedTLS.negotiatedALPN(metadata)))
        }, queue)
        return options
    }

    public static func tcpOptions(dialing: Bool) -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 15
        if dialing { tcp.connectionTimeout = dialTimeout }
        return tcp
    }

    public static func parameters(tls: NWProtocolTLS.Options, dialing: Bool) -> NWParameters {
        let p = NWParameters(tls: tls, tcp: tcpOptions(dialing: dialing))
        p.serviceClass = .interactiveVideo
        p.includePeerToPeer = false
        return p
    }

    public static func negotiatedALPN(_ connection: NWConnection) -> String? {
        guard let m = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return negotiatedALPN(m.securityProtocolMetadata)
    }

    public static func peerFingerprint(_ connection: NWConnection) -> Fingerprint? {
        guard let m = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return peerLeaf(m.securityProtocolMetadata).flatMap(fingerprint(of:))
    }

    /// SHA-256 of the leaf's SPKI, via its X9.63 public point. Nil for anything but P-256.
    public static func fingerprint(of certificate: SecCertificate) -> Fingerprint? {
        guard let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return Fingerprint(x963PublicKey: point)
    }

    /// The first certificate the peer sent, as sent. Never evaluated.
    static func peerLeaf(_ metadata: sec_protocol_metadata_t) -> SecCertificate? {
        var leaf: SecCertificate?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { cert in
            if leaf == nil { leaf = sec_certificate_copy_ref(cert).takeRetainedValue() }
        }
        return leaf
    }

    // `sec_protocol_metadata_copy_negotiated_protocol` replaces this from the macOS 15.5 SDK, but it
    // isn't declared in the macOS 14 SDK at all, so `#available` can't select it on Xcode 15.
    static func negotiatedALPN(_ metadata: sec_protocol_metadata_t) -> String? {
        sec_protocol_metadata_get_negotiated_protocol(metadata).map { String(cString: $0) }
    }
}
#endif
