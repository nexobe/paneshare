#if os(macOS)
import AppKit
import PaneshareCore

/// Which remote window a viewer window shows.
public struct RemoteWindowIdentity: Hashable, Sendable {
    public var host: Fingerprint
    public var hostName: String
    public var windowID: UInt32
    public var appName: String
    public var bundleID: String

    public init(host: Fingerprint, hostName: String, windowID: UInt32, appName: String, bundleID: String) {
        self.host = host; self.hostName = hostName; self.windowID = windowID
        self.appName = appName; self.bundleID = bundleID
    }
}

/// How remote windows appear in the Dock and Command-Tab (docs/ARCHITECTURE.md §6). The MVP ships
/// `SingleProcessDockPresenter` (option A); a per-app helper bundle (option C, see `HelperBundlePlan`)
/// or windows owned by a proxy process (option E) can replace it without touching the sessions.
@MainActor
public protocol DockPresenter: AnyObject {
    func didOpen(_ remote: RemoteWindowIdentity, window: NSWindow, appIcon: NSImage?)
    func didActivate(_ remote: RemoteWindowIdentity)
    func didClose(_ remote: RemoteWindowIdentity)
}

/// Option A: one Dock tile for the whole viewer. Its icon follows the focused remote window's app,
/// and every remote window is listed in the Dock menu and the Window menu.
@MainActor
public final class SingleProcessDockPresenter: DockPresenter {
    private struct Entry { weak var window: NSWindow?; let icon: NSImage? }
    private var entries: [RemoteWindowIdentity: Entry] = [:]
    private let defaultIcon: NSImage?

    public init() { defaultIcon = NSApp.applicationIconImage }

    public func didOpen(_ remote: RemoteWindowIdentity, window: NSWindow, appIcon: NSImage?) {
        entries[remote] = Entry(window: window, icon: appIcon)
        // Listed in the Window menu, and so in the Dock menu, under its title.
        NSApp.addWindowsItem(window, title: window.title, filename: false)
        didActivate(remote)
    }

    public func didActivate(_ remote: RemoteWindowIdentity) {
        guard let entry = entries[remote] else { return }
        NSApp.applicationIconImage = entry.icon.map(Self.badged) ?? defaultIcon
        NSApp.dockTile.badgeLabel = entries.count > 1 ? "\(entries.count)" : nil
    }

    public func didClose(_ remote: RemoteWindowIdentity) {
        entries[remote] = nil
        if entries.isEmpty {
            NSApp.applicationIconImage = defaultIcon
            NSApp.dockTile.badgeLabel = nil
        } else {
            NSApp.dockTile.badgeLabel = entries.count > 1 ? "\(entries.count)" : nil
        }
    }

    /// The remote app's icon with a small ring, so it can't be mistaken for the local app.
    static func badged(_ icon: NSImage) -> NSImage {
        let side: CGFloat = 256
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            icon.draw(in: rect.insetBy(dx: 16, dy: 16))
            let ring = NSBezierPath(ovalIn: NSRect(x: side - 84, y: 8, width: 76, height: 76))
            NSColor.systemBlue.setFill()
            ring.fill()
            NSColor.white.setStroke()
            ring.lineWidth = 6
            ring.stroke()
            return true
        }
    }
}
#endif
