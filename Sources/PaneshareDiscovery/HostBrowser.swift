#if os(macOS)
import Foundation
import Network

/// A host seen on Bonjour. `hostID` comes from the TXT record and is only a hint: trust always
/// comes from the TLS pin, and the dialer checks the hint against the handshake when pairing.
public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public var name: String
    public var hostID: String?
    public var protocolVersion: Int?
    public var endpoint: NWEndpoint
    public var id: String { hostID ?? name }

    public static func == (a: DiscoveredHost, b: DiscoveredHost) -> Bool { a.id == b.id && a.endpoint == b.endpoint }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Browses `_paneshare._tcp` on the local network. Results are delivered on the main queue.
public final class HostBrowser {
    public static let serviceType = "_paneshare._tcp"

    private var browser: NWBrowser?
    public var onChange: (([DiscoveredHost]) -> Void)?
    public var onState: ((String) -> Void)?
    /// True when macOS blocks Local Network access for this app, false once browsing works.
    public var onLocalNetworkBlocked: ((Bool) -> Void)?

    public init() {}

    /// macOS reports a denied Local Network permission as kDNSServiceErr_PolicyDenied (-65570).
    /// It doesn't prompt again after the first answer, so the UI must say how to turn it on.
    public static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    public func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            let text: String?
            var blocked: Bool?
            switch state {
            case .ready:
                text = "Looking for hosts…"
                blocked = false
            case .waiting(let e), .failed(let e):
                if Self.isLocalNetworkDenied(e) {
                    text = "Local Network access is off for paneshare, so it can't find other Macs."
                    blocked = true
                } else if case .waiting = state {
                    text = "Local network unavailable (\(e))."
                } else {
                    text = "Discovery failed: \(e)"
                }
            default: text = nil
            }
            DispatchQueue.main.async {
                if let text { self?.onState?(text) }
                if let blocked { self?.onLocalNetworkBlocked?(blocked) }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap(Self.host(from:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self?.onChange?(hosts) }
        }
        browser.start(queue: DispatchQueue(label: "dev.paneshare.discovery"))
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    static func host(from result: NWBrowser.Result) -> DiscoveredHost? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var hostID: String?
        var version: Int?
        if case .bonjour(let txt) = result.metadata {
            hostID = txt["id"].flatMap { $0.count == 16 ? $0 : nil }
            version = txt["v"].flatMap(Int.init)
        }
        return DiscoveredHost(name: name, hostID: hostID, protocolVersion: version, endpoint: result.endpoint)
    }
}
#endif
