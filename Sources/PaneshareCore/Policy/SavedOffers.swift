import Foundation

/// The apps a host keeps offering across restarts. Window IDs change whenever an app restarts, so the
/// saved thing is the app. Whole screens have their own setting and are never saved here.
public struct SavedOffers: Equatable, Sendable {
    public static let maxApps = 256

    public private(set) var bundleIDs: Set<String>

    public init(saved: [String]? = nil) {
        bundleIDs = Set((saved ?? []).prefix(Self.maxApps))
    }

    public var encoded: [String] { bundleIDs.sorted() }

    /// The user ticked or unticked one of this app's windows. Unticking stops the whole app, or the
    /// next check would offer that window again.
    public mutating func userChanged(_ window: WindowInfo, offered: Bool, policy: WindowPolicy) {
        guard window.displayID == nil else { return }
        if !offered {
            bundleIDs.remove(window.bundleID)
        } else if bundleIDs.count < Self.maxApps, policy.appRejection(bundleID: window.bundleID, processID: window.processID) == nil {
            bundleIDs.insert(window.bundleID)
        }
    }

    /// Windows of saved apps that aren't offered yet. The policy is checked again, because a saved
    /// app can join the deny-list later.
    public func windowsToOffer(from windows: [WindowInfo], alreadyOffered: Set<UInt32>, policy: WindowPolicy) -> [WindowInfo] {
        windows.filter { w in
            w.displayID == nil && bundleIDs.contains(w.bundleID) && !alreadyOffered.contains(w.windowID) && policy.isShareable(w)
        }
    }

    /// Only the screens from a list, for the setting that offers them when sharing starts.
    public static func screens(in windows: [WindowInfo], alreadyOffered: Set<UInt32>) -> [WindowInfo] {
        windows.filter { $0.displayID != nil && !alreadyOffered.contains($0.windowID) }
    }
}
