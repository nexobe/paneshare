#if os(macOS)
import AppKit
import Foundation
import PaneshareCore

/// Finds the apps on this Mac. It reads each bundle's Info.plist and runs nothing.
enum AppCatalog {
    struct Entry: Sendable {
        let app: RemoteApp
        let url: URL
    }

    private static let folders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    static func installed() -> [Entry] {
        var entries: [Entry] = []
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                guard let info = Bundle(url: url)?.infoDictionary, let id = info["CFBundleIdentifier"] as? String,
                      info["LSBackgroundOnly"] as? Bool != true, info["LSUIElement"] as? Bool != true else { continue }
                let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
                entries.append(Entry(app: RemoteApp(bundleID: id, name: name, isRunning: false), url: url))
            }
        }
        return entries
    }

    @MainActor
    static func running() -> [Entry] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            return Entry(app: RemoteApp(bundleID: id, name: app.localizedName ?? id, isRunning: true), url: url)
        }
    }
}
#endif
