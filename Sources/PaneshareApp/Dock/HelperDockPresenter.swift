#if os(macOS)
import AppKit
import Foundation
import PaneshareCore
import PaneshareDockLink
import PaneshareViewer

/// Gives each remote app its own Dock tile and Command-Tab entry through a generated Dock helper
/// (docs/ARCHITECTURE.md §6). The windows stay in this process; the helper only relays
/// activation and its Dock menu. Any helper that can't be generated, signed or launched falls back
/// to `SingleProcessDockPresenter` for its windows, so remote windows always open.
@MainActor
final class HelperDockPresenter: DockPresenter {
    private struct Group {
        let plan: HelperBundlePlan
        let url: URL
        var windows: [UInt32: Weak] = [:]
        /// Window IDs, most recently active last.
        var order: [UInt32] = []
        var app: NSRunningApplication?
        var relaunches = 0
        /// The current helper process has said hello on the link.
        var connected = false
        var launchAttempt = 0
    }

    /// How long a launched helper has to connect. A helper that Gatekeeper or the kernel's code
    /// signing check stops at launch never connects and never disconnects, so only this notices.
    static let helloTimeout: TimeInterval = 10
    /// Helpers that launched but never connected this session; at `maxSilentHelpers` every app
    /// uses the single Dock tile until paneshare is relaunched.
    private var silentHelpers = 0
    private static let maxSilentHelpers = 2
    private var helpersBlocked: Bool { silentHelpers >= Self.maxSilentHelpers }

    private struct Weak { weak var window: NSWindow?; let title: String }

    private let factory: DockHelperFactory
    private let server: DockLinkServer
    private let fallback: SingleProcessDockPresenter
    private var groups: [String: Group] = [:]
    private var fellBack: Set<RemoteWindowIdentity> = []

    /// A pinned helper was clicked while no window of its app was open: open that app's windows.
    var onColdStart: ((_ hostID: String, _ remoteBundleID: String) -> Void)?

    /// A helper-backed presenter, or the single-tile one if helpers can't work on this Mac.
    static func make(mainBundleID: String?, enabled: Bool) -> (DockPresenter, HelperDockPresenter?) {
        let single = SingleProcessDockPresenter()
        guard enabled, let mainBundleID, let factory = try? DockHelperFactory(mainBundleID: mainBundleID) else {
            return (single, nil)
        }
        let server = DockLinkServer()
        do { try server.start() } catch {
            NSLog("paneshare: Dock helpers off, local link failed: %@", "\(error)")
            return (single, nil)
        }
        let presenter = HelperDockPresenter(factory: factory, server: server, fallback: single)
        return (presenter, presenter)
    }

    private init(factory: DockHelperFactory, server: DockLinkServer, fallback: SingleProcessDockPresenter) {
        self.factory = factory
        self.server = server
        self.fallback = fallback
        for entry in factory.ledger.entries.values { server.allow(entry.bundleIdentifier, cdhash: entry.cdhash) }
        server.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }
    }

    func cleanUp(pairedHostIDs: Set<String>) {
        factory.cleanUp(pairedHostIDs: pairedHostIDs)
    }

    func shutDown() {
        for key in groups.keys { server.send(DockLinkMessage(kind: .quit), to: key) }
        server.stop()
    }

    // MARK: DockPresenter

    func didOpen(_ remote: RemoteWindowIdentity, window: NSWindow, appIcon: NSImage?) {
        let plan = HelperBundlePlan(host: remote.host, hostName: remote.hostName, remoteBundleID: remote.bundleID,
                                    remoteAppName: remote.appName, mainBundleID: factory.mainBundleID,
                                    mainTeamID: factory.mainTeamID)
        let key = plan.bundleIdentifier
        if groups[key] == nil {
            if helpersBlocked { return useFallback(remote, window: window, icon: appIcon) }
            do {
                let prepared = try factory.prepare(plan, icon: appIcon)
                server.allow(key, cdhash: prepared.cdhash)
                groups[key] = Group(plan: plan, url: prepared.url)
            } catch {
                NSLog("paneshare: Dock helper for %@ unavailable: %@", remote.appName, "\(error)")
                return useFallback(remote, window: window, icon: appIcon)
            }
        }
        groups[key]?.windows[remote.windowID] = Weak(window: window, title: window.title)
        groups[key]?.order.removeAll { $0 == remote.windowID }
        groups[key]?.order.append(remote.windowID)
        launchIfNeeded(key)
        sendMenu(key)
    }

    func didActivate(_ remote: RemoteWindowIdentity) {
        if fellBack.contains(remote) { return fallback.didActivate(remote) }
        guard let key = key(for: remote) else { return }
        groups[key]?.order.removeAll { $0 == remote.windowID }
        groups[key]?.order.append(remote.windowID)
    }

    func didClose(_ remote: RemoteWindowIdentity) {
        if fellBack.remove(remote) != nil { return fallback.didClose(remote) }
        guard let key = key(for: remote) else { return }
        groups[key]?.windows[remote.windowID] = nil
        groups[key]?.order.removeAll { $0 == remote.windowID }
        if groups[key]?.windows.isEmpty == true {
            groups[key] = nil
            server.send(DockLinkMessage(kind: .quit), to: key)
        } else {
            sendMenu(key)
        }
    }

    // MARK: Helpers

    private func key(for remote: RemoteWindowIdentity) -> String? {
        groups.first { $0.value.windows[remote.windowID] != nil && $0.value.plan.host == remote.host }?.key
    }

    private func useFallback(_ remote: RemoteWindowIdentity, window: NSWindow, icon: NSImage?) {
        fellBack.insert(remote)
        fallback.didOpen(remote, window: window, appIcon: icon)
    }

    private func launchIfNeeded(_ key: String) {
        guard let group = groups[key] else { return }
        if let app = group.app, !app.isTerminated { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: key).first {
            groups[key]?.app = running
            return
        }
        groups[key]?.connected = false
        groups[key]?.launchAttempt += 1
        let attempt = group.launchAttempt + 1
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        configuration.environment = [
            DockLinkPaths.parentPIDVariable: String(ProcessInfo.processInfo.processIdentifier),
            DockLinkPaths.helperKeyVariable: key,
        ]
        NSWorkspace.shared.openApplication(at: group.url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.groups[key] != nil else { return }
                    if let app {
                        self.groups[key]?.app = app
                        self.expectHello(key, attempt: attempt)
                    } else {
                        NSLog("paneshare: Dock helper %@ didn't launch: %@", key, "\(error.map { "\($0)" } ?? "unknown")")
                        self.moveToFallback(key)
                    }
                }
            }
        }
    }

    private func expectHello(_ key: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let group = self.groups[key], group.launchAttempt == attempt, !group.connected else { return }
                self.silentHelpers += 1
                NSLog("paneshare: Dock helper %@ launched but didn't connect within %.0f s (stopped by Gatekeeper or code signing?)%@",
                      key, Self.helloTimeout, self.helpersBlocked ? "; Dock helpers off until relaunch" : "")
                if let app = group.app, !app.isTerminated { app.forceTerminate() }
                self.moveToFallback(key)
            }
        }
    }

    /// The helper can't run: its windows keep working under the single Dock tile.
    private func moveToFallback(_ key: String) {
        guard let group = groups.removeValue(forKey: key) else { return }
        for (windowID, entry) in group.windows {
            guard let window = entry.window,
                  let controller = window.windowController as? RemoteWindowController,
                  controller.remote.windowID == windowID else { continue }
            useFallback(controller.remote, window: window, icon: nil)
        }
    }

    private func sendMenu(_ key: String) {
        guard let group = groups[key] else { return }
        let items = group.order.reversed().compactMap { id -> DockLinkMessage.MenuItem? in
            guard let entry = group.windows[id] else { return nil }
            return .init(windowID: id, title: entry.window?.title ?? entry.title)
        }
        server.send(DockLinkMessage(kind: .menu, items: items), to: key)
    }

    private func bringFront(_ key: String, windowID: UInt32?) {
        guard let group = groups[key] else { return }
        let id = windowID.flatMap { group.windows[$0] != nil ? $0 : nil } ?? group.order.last
        guard let id, let window = group.windows[id]?.window else { return }
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func closeAll(_ key: String) {
        guard let group = groups[key] else { return }
        for entry in group.windows.values { entry.window?.performClose(nil) }
    }

    private func handle(_ event: DockLinkServer.Event) {
        switch event {
        case .hello(let key, let coldStart):
            if groups[key] != nil {
                groups[key]?.relaunches = 0
                groups[key]?.connected = true
                sendMenu(key)
            } else if coldStart, let entry = factory.ledger.entries[key] {
                onColdStart?(entry.hostID, entry.remoteBundleID)
                // Nothing to show after a while (host offline, app gone): let the helper go.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.groups[key] == nil else { return }
                        self.server.send(DockLinkMessage(kind: .quit), to: key)
                    }
                }
            } else {
                server.send(DockLinkMessage(kind: .quit), to: key)
            }
        case .activated(let key):
            bringFront(key, windowID: nil)
        case .choose(let key, let windowID):
            bringFront(key, windowID: windowID)
        case .closeAll(let key), .userQuit(let key):
            closeAll(key)
        case .disconnected(let key):
            // The helper died with windows still open (crash, force quit): bring it back once or twice.
            guard var group = groups[key], !group.windows.isEmpty else { return }
            group.app = nil
            group.connected = false
            group.relaunches += 1
            groups[key] = group
            if group.relaunches <= 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated { self?.launchIfNeeded(key) }
                }
            } else {
                moveToFallback(key)
            }
        }
    }
}
#endif
