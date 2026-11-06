import Foundation

/// The one HTTP/1.1 request a share-link connection may send before it is answered (or upgraded to a
/// WebSocket). Only what the web viewer needs: GET, a path, and a few headers (docs/ARCHITECTURE.md §7.4).
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// The path without the query string.
    public var path: String
    /// Lowercased names. A repeated header keeps its first value.
    public var headers: [String: String]

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// True for a WebSocket upgrade (RFC 6455 §4.1): `Upgrade: websocket`, a `Connection` that lists
    /// `upgrade`, version 13 and a key.
    public var isWebSocketUpgrade: Bool {
        guard method == "GET",
              header("upgrade")?.lowercased() == "websocket",
              let connection = header("connection")?.lowercased(),
              connection.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }),
              header("sec-websocket-version") == "13",
              let key = header("sec-websocket-key"), Data(base64Encoded: key)?.count == 16
        else { return false }
        return true
    }

    public enum ParseError: Error, Equatable, Sendable {
        case tooLarge, malformed, unsupportedVersion
    }

    /// Largest request head accepted (request line plus headers).
    public static let maxHeadSize = 8 * 1024
    public static let maxHeaders = 40

    /// Parses a request head from the start of `bytes`. Returns nil if it isn't complete yet, else the
    /// request and how many bytes it used. A body isn't read: the viewer only ever sends GETs.
    public static func parse(_ bytes: [UInt8]) throws -> (HTTPRequest, consumed: Int)? {
        guard let end = headEnd(bytes) else {
            if bytes.count > maxHeadSize { throw ParseError.tooLarge }
            return nil
        }
        guard end <= maxHeadSize else { throw ParseError.tooLarge }
        guard let text = String(bytes: bytes[0..<end], encoding: .utf8) else { throw ParseError.malformed }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformed }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else { throw ParseError.malformed }
        guard requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else { throw ParseError.unsupportedVersion }
        let method = String(requestLine[0])
        let target = requestLine[1]
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isUppercase }), target.hasPrefix("/") else {
            throw ParseError.malformed
        }
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard path.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        var count = 0
        for line in lines where !line.isEmpty {
            count += 1
            guard count <= maxHeaders, let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" ") else { throw ParseError.malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil { headers[name] = value }
        }
        return (HTTPRequest(method: method, path: path, headers: headers), end + 4)
    }

    /// Index of the blank line's `\r\n\r\n`.
    private static func headEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i
        }
        return nil
    }
}

/// A complete response with `Connection: close` (keep-alive isn't supported) and the headers every
/// share-link response carries.
public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var reason: String
    public var contentType: String?
    public var body: [UInt8]
    public var extraHeaders: [(String, String)] = []

    public init(status: Int, reason: String, contentType: String? = nil, body: [UInt8] = [], extraHeaders: [(String, String)] = []) {
        self.status = status; self.reason = reason; self.contentType = contentType; self.body = body
        self.extraHeaders = extraHeaders
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.reason == b.reason && a.contentType == b.contentType && a.body == b.body
            && a.extraHeaders.map { "\($0.0):\($0.1)" } == b.extraHeaders.map { "\($0.0):\($0.1)" }
    }

    /// Locks the page down: only our own script and style, connections only back to this host, no
    /// framing, no referrer, nothing cached.
    public static let securityHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Cache-Control", "no-store"),
        ("Cross-Origin-Opener-Policy", "same-origin"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
    ]

    public func encoded() -> [UInt8] {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in Self.securityHeaders + extraHeaders { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Array(head.utf8) + body
    }

    public static func text(_ status: Int, _ reason: String, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: "text/plain; charset=utf-8", body: Array(message.utf8))
    }
}
