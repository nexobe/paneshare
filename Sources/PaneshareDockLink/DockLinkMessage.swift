import Foundation

/// One message on the local link between the main app and a Dock helper (docs/ARCHITECTURE.md
/// §6.3). Helper → main: `hello`, `activated`, `choose`, `closeAll`, `userQuit`. Main → helper:
/// `menu`, `quit`. Nothing else crosses it: the helper never sees video, input or keys.
public struct DockLinkMessage: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public enum Kind: String, Codable, Sendable {
        /// First message from a helper. `coldStart` is true when the Dock launched it on its own.
        case hello
        /// The helper became active (Dock click, Command-Tab); the main app should take over.
        case activated
        /// A window was chosen from the helper's Dock menu.
        case choose
        /// "Close All" from the helper's Dock menu.
        case closeAll
        /// The user quit the helper (Dock menu → Quit, Command-Q in Command-Tab).
        case userQuit
        /// The current windows of this remote app, for the helper's Dock menu.
        case menu
        /// The main app no longer needs the helper.
        case quit
    }

    public struct MenuItem: Codable, Equatable, Sendable {
        public var windowID: UInt32
        public var title: String
        public init(windowID: UInt32, title: String) { self.windowID = windowID; self.title = title }
    }

    public var kind: Kind
    public var helperKey: String?
    public var protocolVersion: Int?
    public var coldStart: Bool?
    public var windowID: UInt32?
    public var items: [MenuItem]?

    public init(kind: Kind, helperKey: String? = nil, protocolVersion: Int? = nil, coldStart: Bool? = nil,
                windowID: UInt32? = nil, items: [MenuItem]? = nil) {
        self.kind = kind; self.helperKey = helperKey; self.protocolVersion = protocolVersion
        self.coldStart = coldStart; self.windowID = windowID; self.items = items
    }

    public static func hello(helperKey: String, coldStart: Bool) -> DockLinkMessage {
        DockLinkMessage(kind: .hello, helperKey: helperKey, protocolVersion: protocolVersion, coldStart: coldStart)
    }
}

/// `length(4, big-endian) ‖ JSON`, at most 64 KiB per message.
public enum DockLinkFraming {
    public static let maxMessage = 64 * 1024

    public enum Failure: Error, Equatable, Sendable { case tooLarge, malformed }

    public static func encode(_ message: DockLinkMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(message)
        guard json.count <= maxMessage else { throw Failure.tooLarge }
        var out = Data()
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(json)
        return out
    }

    /// Feeds bytes as they arrive; returns complete messages. Throws (and the caller should drop
    /// the connection) on an oversize length or undecodable JSON.
    public struct Decoder: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func feed(_ bytes: Data) throws -> [DockLinkMessage] {
            buffer.append(bytes)
            var out: [DockLinkMessage] = []
            while buffer.count >= 4 {
                let b = [UInt8](buffer.prefix(4))
                let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                guard length <= maxMessage else { throw Failure.tooLarge }
                guard buffer.count >= 4 + length else { break }
                let json = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
                buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + length)
                guard let message = try? JSONDecoder().decode(DockLinkMessage.self, from: json) else { throw Failure.malformed }
                out.append(message)
            }
            return out
        }
    }
}

public enum DockLinkPaths {
    /// `~/Library/Application Support/paneshare/run/dock.sock`, given the Application Support path.
    public static func socketPath(applicationSupport: String) -> String {
        (applicationSupport as NSString).appendingPathComponent("paneshare/run/dock.sock")
    }

    /// `sockaddr_un.sun_path` holds 104 bytes including the terminator on macOS.
    public static func fitsSocketAddress(_ path: String) -> Bool { path.utf8.count < 104 }

    public static let parentPIDVariable = "PANESHARE_PARENT_PID"
    public static let helperKeyVariable = "PANESHARE_HELPER_KEY"
}
