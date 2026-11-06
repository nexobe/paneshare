#if os(macOS)
import AppKit
import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0-dev"
    }
    static var bundleID: String? { Bundle.main.bundleIdentifier }
    /// The Mac's user-visible name ("Studio"), sent in `hello` and used as the Bonjour name.
    static var deviceName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return String(name.prefix(63))
    }
}
#endif
