import Crypto
import Foundation

/// A link that lets one browser guest watch one shared window (ARCHITECTURE §7.4). The secret
/// token is only in the URL fragment, which browsers never send in a request; the store keeps its
/// SHA-256 only.
public struct ShareLinkRecord: Equatable, Sendable, Identifiable {
    public let id: String
    public let windowID: UInt32
    public let windowTitle: String
    public let createdAt: Date
    public let expiresAt: Date
    /// Whether its guest may click, drag and scroll (never type). The host can change it at any time.
    public var pointerAllowed: Bool
    /// A token is good for one guest; after that only that guest's session can come back.
    public internal(set) var redeemed: Bool
    let tokenDigest: [UInt8]
    var failedAttempts: Int

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }
}

/// The guest a link was redeemed by. It can reconnect (page reload, network blip) with its
/// session secret until the link expires or the host kicks it.
public struct GuestSession: Equatable, Sendable, Identifiable {
    public let id: String
    public let linkID: String
    public let name: String
    public let address: String
    public let joinedAt: Date
    let secretDigest: [UInt8]
}

public struct ShareLinkStore: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        /// No such link (never existed, revoked, or burned).
        case unknownLink
        case expired
        /// The token was already used by another guest.
        case alreadyUsed
        case badToken
        /// No such session (kicked, or its link is gone).
        case unknownSession
    }

    public enum CreateError: Error, Equatable, Sendable { case tooManyLinks, badLifetime }

    /// The choices the host UI offers.
    public static let lifetimes: [TimeInterval] = [15 * 60, 60 * 60, 8 * 60 * 60, 24 * 60 * 60, 7 * 24 * 60 * 60]
    public static let defaultLifetime: TimeInterval = 60 * 60
    public static let maxLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let maxLinks = 16
    /// Wrong tokens a link survives before it is burned.
    public static let maxFailedAttempts = 5

    public private(set) var links: [ShareLinkRecord] = []
    public private(set) var sessions: [GuestSession] = []
    /// Sessions of links burned by wrong tokens, waiting to be disconnected.
    private var burned: [GuestSession] = []

    public init() {}

    /// A new link and its secret token (shown to the host user once, in the URL).
    public mutating func create(windowID: UInt32, windowTitle: String, lifetime: TimeInterval, pointerAllowed: Bool,
                                now: Date) throws -> (link: ShareLinkRecord, token: String) {
        guard lifetime > 0, lifetime <= Self.maxLifetime else { throw CreateError.badLifetime }
        guard links.count < Self.maxLinks else { throw CreateError.tooManyLinks }
        let token = Base64URL.random(bytes: 32)
        let link = ShareLinkRecord(id: Base64URL.random(bytes: 16), windowID: windowID, windowTitle: windowTitle,
                             createdAt: now, expiresAt: now.addingTimeInterval(lifetime), pointerAllowed: pointerAllowed,
                             redeemed: false, tokenDigest: Self.digest(token), failedAttempts: 0)
        links.append(link)
        return (link, token)
    }

    /// The link a page or join refers to, if it's still usable.
    public func activeLink(id: String, now: Date) -> ShareLinkRecord? {
        links.first { $0.id == id && !$0.isExpired(at: now) }
    }

    /// First join with the link's token. Wrong tokens count against the link, which is burned
    /// (revoked) after `maxFailedAttempts`. Call `takeBurned()` after a failure to disconnect its guests.
    public mutating func redeem(linkID: String, token: String, name: String, address: String,
                                now: Date) -> Result<(session: GuestSession, secret: String), Rejection> {
        guard let i = links.firstIndex(where: { $0.id == linkID }) else { return .failure(.unknownLink) }
        guard !links[i].isExpired(at: now) else { return .failure(.expired) }
        guard Self.equal(Self.digest(token), links[i].tokenDigest) else {
            links[i].failedAttempts += 1
            if links[i].failedAttempts >= Self.maxFailedAttempts { burned += revoke(linkID: linkID) }
            return .failure(.badToken)
        }
        guard !links[i].redeemed else { return .failure(.alreadyUsed) }
        links[i].redeemed = true
        let secret = Base64URL.random(bytes: 32)
        let session = GuestSession(id: Base64URL.random(bytes: 12), linkID: linkID, name: GuestName.sanitize(name),
                                   address: address, joinedAt: now, secretDigest: Self.digest(secret))
        sessions.append(session)
        return .success((session, secret))
    }

    /// The sessions lost to burned links since the last call. The caller must disconnect them.
    public mutating func takeBurned() -> [GuestSession] {
        defer { burned = [] }
        return burned
    }

    /// A returning guest.
    public mutating func resume(sessionID: String, secret: String, now: Date) -> Result<GuestSession, Rejection> {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              Self.equal(Self.digest(secret), session.secretDigest) else { return .failure(.unknownSession) }
        guard let link = links.first(where: { $0.id == session.linkID }) else { return .failure(.unknownSession) }
        guard !link.isExpired(at: now) else { return .failure(.expired) }
        return .success(session)
    }

    public func link(for session: GuestSession) -> ShareLinkRecord? { links.first { $0.id == session.linkID } }

    public mutating func setPointerAllowed(_ allowed: Bool, linkID: String) {
        guard let i = links.firstIndex(where: { $0.id == linkID }) else { return }
        links[i].pointerAllowed = allowed
    }

    /// Ends one guest's session for good; the link stays (already redeemed, so it can't be reused).
    @discardableResult
    public mutating func kick(sessionID: String) -> GuestSession? {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        return sessions.remove(at: i)
    }

    /// Deletes a link and returns the sessions that must be disconnected.
    @discardableResult
    public mutating func revoke(linkID: String) -> [GuestSession] {
        links.removeAll { $0.id == linkID }
        let gone = sessions.filter { $0.linkID == linkID }
        sessions.removeAll { $0.linkID == linkID }
        return gone
    }

    /// The host stopped sharing a window: its links go too.
    public mutating func revoke(windowID: UInt32) -> [GuestSession] {
        links.filter { $0.windowID == windowID }.flatMap { revoke(linkID: $0.id) }
    }

    /// Removes expired links and returns their sessions.
    public mutating func expire(now: Date) -> [GuestSession] {
        links.filter { $0.isExpired(at: now) }.flatMap { revoke(linkID: $0.id) }
    }

    public mutating func removeAll() -> [GuestSession] {
        let gone = sessions
        links.removeAll()
        sessions.removeAll()
        return gone
    }

    static func digest(_ s: String) -> [UInt8] { Array(SHA256.hash(data: Data(s.utf8))) }

    /// Compares digests without an early exit.
    static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

public enum Base64URL {
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func random(bytes count: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return encode((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// True for a plausible link or session ID / token: only URL-safe base64 characters.
    public static func isWellFormed(_ s: String, maxLength: Int = 64) -> Bool {
        !s.isEmpty && s.utf8.count <= maxLength
            && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }
}

public enum GuestName {
    public static let maxLength = 32

    /// What the host UI shows for a guest: printable characters only, trimmed, at most 32.
    public static func sanitize(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
                && $0.properties.generalCategory != .format
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(cleaned.prefix(maxLength))
        return name.isEmpty ? "Guest" : name
    }
}

/// Addresses a share link can use, best first: Tailscale (reachable beyond the LAN), then private
/// LAN addresses, then the Bonjour `.local` name. Link-local, loopback and public addresses are left
/// out (the host never invites the internet in).
public enum ShareAddresses {
    public enum Kind: Int, Comparable, Sendable {
        case tailscale = 0, lan = 1, bonjour = 2
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Candidate: Equatable, Sendable {
        public let host: String
        public let kind: Kind
    }

    public static func kind(ofIPv4 address: String) -> Kind? {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        switch (parts[0], parts[1]) {
        case (100, 64...127): return .tailscale
        case (10, _), (192, 168): return .lan
        case (172, 16...31): return .lan
        default: return nil
        }
    }

    public static func rank(ipv4: [String], localHostName: String?) -> [Candidate] {
        var seen = Set<String>()
        var out = ipv4.compactMap { a -> Candidate? in
            guard let k = kind(ofIPv4: a), seen.insert(a).inserted else { return nil }
            return Candidate(host: a, kind: k)
        }
        if let name = localHostName, !name.isEmpty {
            let local = name.hasSuffix(".local") ? name : name + ".local"
            out.append(Candidate(host: local, kind: .bonjour))
        }
        return out.sorted { $0.kind < $1.kind }
    }

    public static func url(host: String, port: UInt16, linkID: String, token: String) -> String {
        let h = host.contains(":") ? "[\(host)]" : host
        return "https://\(h):\(port)/s/\(linkID)#\(token)"
    }
}
