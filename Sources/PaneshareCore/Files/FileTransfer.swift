import Crypto
import Foundation

public struct FileOffer: Codable, Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var size: UInt64
    public init(id: UInt32, name: String, size: UInt64) { self.id = id; self.name = name; self.size = size }
}

/// The host's answer: refused (`reason`), progress (`received`), or finished (`done`).
public struct FileReply: Codable, Equatable, Sendable {
    public var id: UInt32
    public var accepted: Bool
    public var reason: String?
    public var received: UInt64?
    public var done: Bool?
    public init(id: UInt32, accepted: Bool, reason: String? = nil, received: UInt64? = nil, done: Bool? = nil) {
        self.id = id; self.accepted = accepted; self.reason = reason; self.received = received; self.done = done
    }
}

/// The last message of a transfer. A nil digest means the viewer cancelled it.
public struct FileEnd: Codable, Equatable, Sendable {
    public var id: UInt32
    public var sha256: String?
    public init(id: UInt32, sha256: String?) { self.id = id; self.sha256 = sha256 }
}

public enum FileTransferRules {
    public static let maxBytes: UInt64 = 2 * 1024 * 1024 * 1024
    public static let chunkBytes = 256 * 1024
    /// Chunks that may be unacknowledged, so that input isn't stuck behind a long send queue.
    public static let windowChunks = 4
    /// Seconds a sender waits for the first answer to an offer. A Mac too old to receive in this
    /// direction drops the offer without a word, so the sender stops waiting after this.
    public static let offerTimeout: TimeInterval = 15

    /// True when an offer made at `offeredAt` has had no answer for too long.
    public static func offerTimedOut(offeredAt: TimeInterval, now: TimeInterval) -> Bool {
        now - offeredAt >= offerTimeout
    }

    /// A safe file name from what the other Mac sent, or nil if nothing usable is left.
    /// It keeps only the last path component, so a sent path can't leave the folder.
    public static func safeName(_ sent: String) -> String? {
        let last = sent.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = String(String.UnicodeScalarView(last.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":"
                && !CharacterSet.illegalCharacters.contains($0)
        }))
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        while name.utf8.count > 200 { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    /// `name`, or `name 2.ext`, `name 3.ext` and so on: never an existing file.
    public static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    public static func encodeChunk(id: UInt32, bytes: Data) -> Data {
        var out = Data(capacity: bytes.count + 4)
        withUnsafeBytes(of: id.bigEndian) { out.append(contentsOf: $0) }
        out.append(bytes)
        return out
    }

    public static func decodeChunk(_ payload: Data) -> (id: UInt32, bytes: Data)? {
        guard payload.count > 4, payload.count <= chunkBytes + 4 else { return nil }
        let id = payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (id, Data(payload.dropFirst(4)))
    }

    public static func digestHex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Checks an incoming file as it arrives: no more bytes than offered, and a matching digest.
public struct FileReceiveCheck: Sendable {
    public enum Problem: Error, Equatable, Sendable { case tooMuch, incomplete, digestMismatch }

    public let size: UInt64
    public private(set) var received: UInt64 = 0
    private var hasher = SHA256()

    public init(size: UInt64) { self.size = size }

    public mutating func add(_ bytes: Data) throws {
        guard received + UInt64(bytes.count) <= size else { throw Problem.tooMuch }
        received += UInt64(bytes.count)
        hasher.update(data: bytes)
    }

    public func finish(sha256: String) throws {
        guard received == size else { throw Problem.incomplete }
        guard FileTransferRules.digestHex(hasher.finalize()) == sha256 else { throw Problem.digestMismatch }
    }
}

/// How far a sender may go: it stops `windowChunks` ahead of what the host acknowledged.
public struct FileSendPacer: Equatable, Sendable {
    public let size: UInt64
    public private(set) var sent: UInt64 = 0
    public private(set) var acknowledged: UInt64 = 0

    public init(size: UInt64) { self.size = size }

    public var isFullySent: Bool { sent >= size }

    /// Bytes to read and send next, or nil when it must wait for an acknowledgement or is finished.
    public mutating func next() -> Int? {
        guard !isFullySent else { return nil }
        let window = UInt64(FileTransferRules.windowChunks * FileTransferRules.chunkBytes)
        guard sent - acknowledged < window else { return nil }
        let count = min(UInt64(FileTransferRules.chunkBytes), size - sent)
        sent += count
        return Int(count)
    }

    public mutating func acknowledge(_ received: UInt64) {
        acknowledged = max(acknowledged, min(received, sent))
    }
}
