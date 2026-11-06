import Foundation

/// What the share-link server does with a request (ARCHITECTURE §7.4). Everything not listed is a
/// 404, and the page itself is a 404 unless its link is live, so the server reveals nothing to
/// someone without a link.
public enum WebRoute: Equatable, Sendable {
    case respond(HTTPResponse)
    /// Answer with the 101 handshake for this key; the first WebSocket message must be a `join`.
    case upgrade(key: String)
}

public enum WebRouter {
    public static func route(_ request: HTTPRequest, isLinkActive: (String) -> Bool) -> WebRoute {
        guard request.method == "GET" else {
            return .respond(HTTPResponse(status: 405, reason: "Method Not Allowed", extraHeaders: [("Allow", "GET")]))
        }
        switch request.path {
        case "/viewer.js":
            return .respond(HTTPResponse(status: 200, reason: "OK", contentType: "text/javascript; charset=utf-8",
                                         body: Array(WebViewerAssets.js.utf8)))
        case "/viewer.css":
            return .respond(HTTPResponse(status: 200, reason: "OK", contentType: "text/css; charset=utf-8",
                                         body: Array(WebViewerAssets.css.utf8)))
        case "/ws":
            guard request.isWebSocketUpgrade, let key = request.header("sec-websocket-key") else {
                return .respond(.text(400, "Bad Request", "Expected a WebSocket upgrade."))
            }
            guard originMatches(request) else { return .respond(.text(403, "Forbidden", "Wrong origin.")) }
            return .upgrade(key: key)
        default:
            let parts = request.path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 3, parts[1] == "s", Base64URL.isWellFormed(String(parts[2])), isLinkActive(String(parts[2])) {
                return .respond(HTTPResponse(status: 200, reason: "OK", contentType: "text/html; charset=utf-8",
                                             body: Array(WebViewerAssets.html.utf8)))
            }
            return .respond(.text(404, "Not Found", "This link has expired or doesn't exist. Ask the host for a new one."))
        }
    }

    /// A WebSocket may only be opened by our own page: its `Origin` must be this server as the browser
    /// addressed it. Blocks other sites from driving a guest's browser into the socket.
    public static func originMatches(_ request: HTTPRequest) -> Bool {
        guard let origin = request.header("origin")?.lowercased(), let host = request.header("host")?.lowercased(),
              !host.isEmpty else { return false }
        return origin == "https://" + host
    }
}
