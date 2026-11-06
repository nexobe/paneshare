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

    public init() {}

    public func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            let text: String?
            switch state {
            case .ready: text = "Looking for hosts…"
            case .waiting(let e): text = "Local network unavailable (\(e)). Check Local Network access in System Settings."
            case .failed(let e): text = "Discovery failed: \(e)"
            default: text = nil
            }
            if let text { DispatchQueue.main.async { self?.onState?(text) } }
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
