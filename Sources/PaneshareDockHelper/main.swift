#if os(macOS)
import AppKit
import PaneshareDockLink
import Security

/// A Dock helper: a generated app that exists only so one remote app gets its own Dock tile and
/// Command-Tab entry (docs/ARCHITECTURE.md §6). It owns no windows and sees no video or input. It
/// tells the main app when it is activated or its Dock menu is used, and shows the menu the main
/// app sends. It quits when told to, or when the main app goes away.
@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private let helperKey = Bundle.main.bundleIdentifier ?? ""
    private let mainBundleID = Bundle.main.object(forInfoDictionaryKey: "PaneshareMainBundleID") as? String ?? ""
    /// Set only when paneshare is Developer ID signed (docs/RELEASING.md); a helper that has it never
    /// falls back to the weaker bundle-ID check.
    private let mainTeamID = Bundle.main.object(forInfoDictionaryKey: DockLinkTrust.mainTeamIDKey) as? String
    private let queue = DispatchQueue(label: "dev.paneshare.dock-helper.link")
    private var link: DockLinkConnection?
    private var parentPID: pid_t?
    private var items: [DockLinkMessage.MenuItem] = []
    private var quitRequestedByMain = false
    private var watchdog: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !helperKey.isEmpty, !mainBundleID.isEmpty else { exit(0) }
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment[DockLinkPaths.parentPIDVariable], let pid = pid_t(raw), pid > 1 {
            parentPID = pid
            connect(coldStart: false, deadline: Date().addingTimeInterval(5))
        } else {
            // The Dock launched us (a pinned tile): bring up the main app first.
            guard launchMainApp() else { exit(0) }
            connect(coldStart: true, deadline: Date().addingTimeInterval(15))
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkParent() }
        }
    }

    private func launchMainApp() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID).isEmpty { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainBundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        return true
    }

    private func connect(coldStart: Bool, deadline: Date) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            exit(0)
        }
        let path = DockLinkPaths.socketPath(applicationSupport: support.path)
        guard let fd = try? DockLinkSocket.connect(path: path) else {
            if Date() > deadline { exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.connect(coldStart: coldStart, deadline: deadline) }
            return
        }
        // Only the real main app may drive us: same bundle ID, and our parent when it launched us.
        guard let pid = DockLinkSocket.peerPID(fd),
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == mainBundleID,
              parentPID.map({ $0 == pid }) ?? true,
              peerIsSignedByOurTeam(fd) else {
            _ = Darwin.close(fd)
            exit(0)
        }
        parentPID = pid
        let link = DockLinkConnection(fd: fd, queue: queue)
        link.onMessage = { message in DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(message) } } }
        link.onClose = { DispatchQueue.main.async { MainActor.assumeIsolated { self.mainWentAway() } } }
        self.link = link
        link.start()
        link.send(.hello(helperKey: helperKey, coldStart: coldStart))
    }

    private func peerIsSignedByOurTeam(_ fd: Int32) -> Bool {
        guard let mainTeamID else { return true }
        guard let text = DockLinkTrust.mainAppRequirement(mainBundleID: mainBundleID, teamID: mainTeamID),
              let token = DockLinkSocket.peerAuditToken(fd) else { return false }
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func handle(_ message: DockLinkMessage) {
        switch message.kind {
        case .menu:
            items = Array((message.items ?? []).prefix(64))
        case .quit:
            quitRequestedByMain = true
            NSApp.terminate(nil)
        case .hello, .activated, .choose, .closeAll, .userQuit:
            break
        }
    }

    private func mainWentAway() {
        quitRequestedByMain = true
        NSApp.terminate(nil)
    }

    private func checkParent() {
        guard let pid = parentPID else { return }
        if kill(pid, 0) != 0, errno == ESRCH { mainWentAway() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard link != nil else { return }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: mainBundleID)
        link?.send(DockLinkMessage(kind: .activated, helperKey: helperKey))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: mainBundleID)
        link?.send(DockLinkMessage(kind: .activated, helperKey: helperKey))
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for item in items {
            let entry = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = Int(item.windowID)
            menu.addItem(entry)
        }
        if !items.isEmpty {
            menu.addItem(.separator())
            let closeAll = NSMenuItem(title: "Close All", action: #selector(closeAll(_:)), keyEquivalent: "")
            closeAll.target = self
            menu.addItem(closeAll)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: mainBundleID)
        link?.send(DockLinkMessage(kind: .choose, helperKey: helperKey, windowID: UInt32(truncatingIfNeeded: sender.tag)))
    }

    @objc private func closeAll(_ sender: NSMenuItem) {
        link?.send(DockLinkMessage(kind: .closeAll, helperKey: helperKey))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitRequestedByMain || link == nil { return .terminateNow }
        // The user quit this tile: the main app closes this remote app's windows.
        link?.send(DockLinkMessage(kind: .userQuit, helperKey: helperKey))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = HelperDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    let appMenuItem = NSMenuItem()
    appMenuItem.submenu = NSMenu()
    appMenuItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(appMenuItem)
    app.mainMenu = menu
    withExtendedLifetime(delegate) { app.run() }
}
#else
print("paneshare-dock-helper only runs on macOS.")
#endif
