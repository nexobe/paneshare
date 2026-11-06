import Foundation

/// A manually typed host address: `mac-mini.local`, `100.101.102.103:47821`, `[fd7a::1]:5000`,
/// a bare IPv6 address, or a MagicDNS name. Used for Tailscale and for dialing without Bonjour.
public struct HostAddress: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) { self.host = host; self.port = port }

    public static func parse(_ text: String, defaultPort: UInt16) -> HostAddress? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 253, !s.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }) else { return nil }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard !host.isEmpty, host.contains(":") else { return nil }
            if rest.isEmpty { return HostAddress(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let port = parsePort(rest.dropFirst()) else { return nil }
            return HostAddress(host: host, port: port)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons > 1 { return HostAddress(host: s, port: defaultPort) }   // bare IPv6
        if colons == 1 {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts[0].count > 0, let port = parsePort(parts[1]) else { return nil }
            return HostAddress(host: String(parts[0]), port: port)
        }
        return HostAddress(host: s, port: defaultPort)
    }

    private static func parsePort(_ s: Substring) -> UInt16? {
        guard !s.isEmpty, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber), let v = UInt16(s), v > 0 else { return nil }
        return v
    }

    public var display: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}
