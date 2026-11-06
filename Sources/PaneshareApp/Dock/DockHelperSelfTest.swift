#if os(macOS)
import AppKit
import Foundation
import PaneshareCore
import PaneshareDockLink

/// `paneshare --dock-helper-selftest <result file>`: generates, signs and launches one Dock helper
/// exactly as a remote window would, waits for it to connect over the verified link, quits it and
/// removes it. It needs no host or network, so it shows on a fresh Mac, or on a quarantined copy of
/// a release (`scripts/release.sh`), whether Gatekeeper and code signing let generated helpers run.
/// The verdict is the file's last line: `dock-helper-selftest: PASS` or `FAIL <reason>`.
@MainActor
final class DockHelperSelfTest {
    static let flag = "--dock-helper-selftest"
    static let connectTimeout: TimeInterval = 20

    static func requested(_ arguments: [String] = CommandLine.arguments) -> Bool { arguments.contains(flag) }

    static func run(arguments: [String] = CommandLine.arguments) -> Never {
        let resultPath = arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let test = DockHelperSelfTest(resultPath: resultPath)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async { test.start() }
        app.run()
        exit(1)
    }

    private let resultPath: String?
    private var lines: [String] = []
    private var factory: DockHelperFactory?
    private var server: DockLinkServer?
    private var plan: HelperBundlePlan?
    private var helper: NSRunningApplication?
    private var finished = false

    private init(resultPath: String?) { self.resultPath = resultPath }

    private func log(_ line: String) {
        lines.append(line)
        print(line)
    }

    private func start() {
        let main = Bundle.main
        log("app: \(main.bundleURL.path)")
        log("app quarantined: \(DockHelperFactory.hasQuarantine(main.bundleURL) ? "yes" : "no")")
        guard let mainBundleID = main.bundleIdentifier else { return finish(false, "not running from an app bundle") }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else { return finish(false, "another paneshare is running; quit it first") }

        let factory: DockHelperFactory
        do { factory = try DockHelperFactory(mainBundleID: mainBundleID) } catch {
            return finish(false, "helpers directory: \(error)")
        }
        self.factory = factory
        log("team: \(factory.mainTeamID ?? "none (ad hoc build)")")
        let server = DockLinkServer()
        do { try server.start() } catch { return finish(false, "local link: \(error)") }
        self.server = server

        let host = Fingerprint(bytes: [UInt8](repeating: 0x5E, count: 32))!
        let plan = HelperBundlePlan(host: host, hostName: "Self-Test", remoteBundleID: "dev.paneshare.selftest",
                                    remoteAppName: "Dock Check", mainBundleID: mainBundleID, mainTeamID: factory.mainTeamID)
        self.plan = plan
        let prepared: (url: URL, cdhash: String)
        do { prepared = try factory.prepare(plan, icon: nil) } catch { return finish(false, "generate or sign: \(error)") }
        log("helper: \(prepared.url.path)")
        log("helper cdhash: \(prepared.cdhash)")
        log("helper quarantined: \(DockHelperFactory.hasQuarantine(prepared.url) ? "yes" : "no")")

        let key = plan.bundleIdentifier
        server.allow(key, cdhash: prepared.cdhash)
        server.onEvent = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event {
                case .hello(let k, _) where k == key:
                    self.log("helper connected and passed the link's code signature check")
                    self.server?.send(DockLinkMessage(kind: .quit), to: key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.finish(true, nil) }
                case .disconnected(let k) where k == key:
                    self.finish(true, nil)
                default:
                    break
                }
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        configuration.environment = [
            DockLinkPaths.parentPIDVariable: String(ProcessInfo.processInfo.processIdentifier),
            DockLinkPaths.helperKeyVariable: key,
        ]
        NSWorkspace.shared.openApplication(at: prepared.url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let app else { return self.finish(false, "launch refused: \(error.map { "\($0)" } ?? "unknown")") }
                    self.helper = app
                    self.log("helper launched, pid \(app.processIdentifier)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                let state = self.helper.map { $0.isTerminated ? "and exited" : "but is still running" } ?? "and never launched"
                self.finish(false, "helper didn't connect within \(Int(Self.connectTimeout)) s \(state); see docs/RELEASING.md §5")
            }
        }
    }

    private func finish(_ passed: Bool, _ reason: String?) {
        guard !finished else { return }
        finished = true
        if let helper, !helper.isTerminated { helper.forceTerminate() }
        server?.stop()
        if let plan { factory?.remove(plan) }
        log(passed ? "dock-helper-selftest: PASS" : "dock-helper-selftest: FAIL \(reason ?? "")")
        if let resultPath {
            try? (lines.joined(separator: "\n") + "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
        }
        exit(passed ? 0 : 1)
    }
}
#endif
