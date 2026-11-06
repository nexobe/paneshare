import Foundation

/// Whether a shared app's audio may leave the host (docs/ARCHITECTURE.md §7.2). Audio goes with a
/// window the host user offered and a viewer opened; it never flows for an app the window policy
/// excludes (system auth UI, password managers, our own process), and the host user can turn it off
/// for all apps or per app.
public struct AudioPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case allowed
        /// The window policy excludes the whole app. Can't be overridden.
        case excludedApp(WindowPolicy.Rejection)
        /// The host user turned audio off for this app.
        case turnedOffForApp
        /// The host user turned audio sharing off.
        case turnedOff
    }

    public var windowPolicy: WindowPolicy
    public var enabled: Bool
    /// Apps the host user muted at the source.
    public var mutedBundleIDs: Set<String>

    public init(windowPolicy: WindowPolicy, enabled: Bool = true, mutedBundleIDs: Set<String> = []) {
        self.windowPolicy = windowPolicy
        self.enabled = enabled
        self.mutedBundleIDs = mutedBundleIDs
    }

    public func decision(bundleID: String, processID: Int32) -> Decision {
        if let rejection = windowPolicy.appRejection(bundleID: bundleID, processID: processID) {
            return .excludedApp(rejection)
        }
        if !enabled { return .turnedOff }
        if mutedBundleIDs.contains(bundleID) { return .turnedOffForApp }
        return .allowed
    }

    public func allows(bundleID: String, processID: Int32) -> Bool {
        decision(bundleID: bundleID, processID: processID) == .allowed
    }

    /// The host-side per-app list as stored in UserDefaults (a sorted array of bundle IDs).
    public static func mutedList(from stored: [String]?) -> Set<String> { Set(stored ?? []) }
}

/// One remote app's playback setting on the viewer.
public struct AudioMix: Codable, Equatable, Sendable {
    public var muted: Bool
    /// 0…1, linear gain.
    public var volume: Double
    public init(muted: Bool = false, volume: Double = 1) {
        self.muted = muted
        self.volume = AudioMix.clamp(volume)
    }
    public static let `default` = AudioMix()
    public var effectiveGain: Float { muted ? 0 : Float(volume) }
    static func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 1 }
}

/// The viewer's mute and volume per (host, remote app), kept across launches.
public struct AudioMixSettings: Codable, Equatable, Sendable {
    private var entries: [String: AudioMix]

    public init() { entries = [:] }

    /// Decodes stored settings; anything unreadable starts empty.
    public init(data: Data?) {
        self.entries = data.flatMap { try? JSONDecoder().decode([String: AudioMix].self, from: $0) } ?? [:]
        for (k, v) in entries { entries[k] = AudioMix(muted: v.muted, volume: v.volume) }
    }

    public static func key(host: Fingerprint, bundleID: String) -> String { host.hex + "/" + bundleID }

    public func mix(host: Fingerprint, bundleID: String) -> AudioMix {
        entries[Self.key(host: host, bundleID: bundleID)] ?? .default
    }

    public mutating func set(_ mix: AudioMix, host: Fingerprint, bundleID: String) {
        let clamped = AudioMix(muted: mix.muted, volume: mix.volume)
        entries[Self.key(host: host, bundleID: bundleID)] = clamped == .default ? nil : clamped
    }

    /// Drops every entry of a host, after it's unpaired.
    public mutating func forget(host: Fingerprint) {
        entries = entries.filter { !$0.key.hasPrefix(host.hex + "/") }
    }

    public var count: Int { entries.count }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(entries)) ?? Data()
    }
}
