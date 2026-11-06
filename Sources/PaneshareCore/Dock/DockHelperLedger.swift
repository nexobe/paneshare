import Foundation

/// What the viewer has generated under `DockHelpers/`, saved as `ledger.json`. The cdhash is the
/// only thing the local link trusts: a helper connecting to the main app must be running code with
/// exactly the cdhash recorded here when it was signed.
public struct DockHelperLedger: Codable, Equatable, Sendable {
    public static let idleLimit: TimeInterval = 30 * 24 * 3600

    public struct Entry: Codable, Equatable, Sendable {
        public var bundleIdentifier: String
        public var relativePath: String
        public var hostID: String
        public var remoteBundleID: String
        public var cdhash: String
        public var lastUsed: Date
        /// `HelperBundlePlan.revision` when it was written; absent in ledgers from before revisions.
        public var revision: Int?

        public init(bundleIdentifier: String, relativePath: String, hostID: String, remoteBundleID: String,
                    cdhash: String, lastUsed: Date, revision: Int? = HelperBundlePlan.revision) {
            self.bundleIdentifier = bundleIdentifier; self.relativePath = relativePath; self.hostID = hostID
            self.remoteBundleID = remoteBundleID; self.cdhash = cdhash; self.lastUsed = lastUsed
            self.revision = revision
        }

        /// Written by this paneshare for this plan, so it can be reused if its signature still checks out.
        public func isCurrent(for plan: HelperBundlePlan) -> Bool {
            relativePath == plan.relativePath && revision == HelperBundlePlan.revision
        }
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public mutating func record(_ plan: HelperBundlePlan, cdhash: String, now: Date) {
        entries[plan.bundleIdentifier] = Entry(bundleIdentifier: plan.bundleIdentifier, relativePath: plan.relativePath,
                                               hostID: plan.host.hex, remoteBundleID: plan.remoteBundleID,
                                               cdhash: cdhash, lastUsed: now)
    }

    public mutating func touch(_ bundleIdentifier: String, now: Date) {
        entries[bundleIdentifier]?.lastUsed = now
    }

    public mutating func remove(_ bundleIdentifier: String) {
        entries[bundleIdentifier] = nil
    }

    /// Helpers to delete: those of hosts no longer paired, and those idle past `idleLimit` unless
    /// the user keeps them in the Dock. `pinnedPaths` holds helper paths relative to the helpers
    /// directory (see `DockPins`). Helpers that are running are never stale.
    public func stale(now: Date, pairedHostIDs: Set<String>, pinnedPaths: Set<String>, running: Set<String>) -> [Entry] {
        entries.values.filter { e in
            if running.contains(e.bundleIdentifier) { return false }
            if !pairedHostIDs.contains(e.hostID) { return true }
            return now.timeIntervalSince(e.lastUsed) > Self.idleLimit && !pinnedPaths.contains(e.relativePath)
        }.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DockHelperLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DockHelperLedger.self, from: data)
    }
}

/// Reads which of our helpers the user has kept in the Dock, from the Dock's own preferences
/// (`com.apple.dock` → `persistent-apps` → `tile-data` → `file-data` → `_CFURLString`).
public enum DockPins {
    /// Paths of pinned helpers relative to `helpersDirectory` (a standardized absolute path).
    public static func pinnedHelperPaths(persistentApps: [Any], helpersDirectory: String) -> Set<String> {
        let base = helpersDirectory.hasSuffix("/") ? helpersDirectory : helpersDirectory + "/"
        var out = Set<String>()
        for case let tile as [String: Any] in persistentApps {
            guard let tileData = tile["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String else { continue }
            let path: String
            if let url = URL(string: urlString), url.isFileURL {
                path = url.standardizedFileURL.path
            } else if urlString.hasPrefix("/") {
                path = URL(fileURLWithPath: urlString).standardizedFileURL.path
            } else {
                continue
            }
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            if trimmed.hasPrefix(base) { out.insert(String(trimmed.dropFirst(base.count))) }
        }
        return out
    }
}
