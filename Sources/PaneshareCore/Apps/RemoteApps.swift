import Foundation

/// An app a host lets paired viewers open. It's only ever sent when the host's user turned that on.
public struct RemoteApp: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var isRunning: Bool

    public init(bundleID: String, name: String, isRunning: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isRunning = isRunning
    }
}

public struct OpenAppRequest: Codable, Equatable, Sendable {
    public var bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
}

/// The host's answer to `OpenAppRequest`, sent after any new windows are offered.
public struct OpenAppResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case opened, noWindows, refused, notFound, failed
    }

    public var bundleID: String
    public var outcome: Outcome

    public init(bundleID: String, outcome: Outcome) {
        self.bundleID = bundleID
        self.outcome = outcome
    }
}

public enum RemoteAppRules {
    public static let maxApps = 2000
    public static let maxBundleIDBytes = 255
    public static let maxNameCharacters = 128

    /// The whole-app rules of `WindowPolicy`. The host checks these for the list and again for each
    /// request, because a viewer can ask for a bundle ID that isn't in the list.
    public static func isAllowed(bundleID: String, policy: WindowPolicy) -> Bool {
        guard !bundleID.isEmpty, bundleID.utf8.count <= maxBundleIDBytes else { return false }
        // Our process ID is never a real app's here: only the bundle ID decides.
        return policy.appRejection(bundleID: bundleID, processID: -1) == nil
    }

    /// What a viewer may see: allowed apps, once each, sorted by name. A running copy wins over an
    /// installed one with the same bundle ID.
    public static func list(_ found: [RemoteApp], policy: WindowPolicy) -> [RemoteApp] {
        var byID: [String: RemoteApp] = [:]
        for app in found where isAllowed(bundleID: app.bundleID, policy: policy) {
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var clean = app
            clean.name = String(name.prefix(maxNameCharacters))
            if let existing = byID[app.bundleID], existing.isRunning || !app.isRunning { continue }
            byID[app.bundleID] = clean
        }
        let sorted = byID.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
        return Array(sorted.prefix(maxApps))
    }
}

/// Limits how often one viewer can open apps, so a paired Mac can't flood the host with launches.
public struct OpenAppLimiter: Equatable, Sendable {
    public static let maxRequests = 10
    public static let window: TimeInterval = 60

    private var recent: [TimeInterval] = []

    public init() {}

    public mutating func allow(now: TimeInterval) -> Bool {
        recent.removeAll { now - $0 >= Self.window }
        guard recent.count < Self.maxRequests else { return false }
        recent.append(now)
        return true
    }
}
