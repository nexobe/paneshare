import XCTest
@testable import PaneshareCore

final class RemoteAppsTests: XCTestCase {
    private let policy = WindowPolicy(ownProcessID: 42, ownBundleID: "dev.paneshare.app", extraDeniedBundleIDs: ["com.example.denied"])

    private func app(_ id: String, _ name: String = "App", running: Bool = false) -> RemoteApp {
        RemoteApp(bundleID: id, name: name, isRunning: running)
    }

    func testListLeavesOutEveryRejectedApp() {
        let denied = ["dev.paneshare.app", "dev.paneshare.dock.helper", "dev.paneshare.screen", "com.apple.Passwords",
                      "com.apple.keychainaccess", "com.1password.1password", "com.apple.SecurityAgent",
                      "com.apple.loginwindow", "com.example.denied", ""]
        let listed = RemoteAppRules.list(denied.map { app($0) } + [app("com.apple.Safari", "Safari")], policy: policy)
        XCTAssertEqual(listed.map(\.bundleID), ["com.apple.Safari"])
    }

    func testRequestIsCheckedWithoutTheList() {
        XCTAssertTrue(RemoteAppRules.isAllowed(bundleID: "com.apple.Safari", policy: policy))
        XCTAssertFalse(RemoteAppRules.isAllowed(bundleID: "com.apple.Passwords", policy: policy))
        XCTAssertFalse(RemoteAppRules.isAllowed(bundleID: "dev.paneshare.app", policy: policy))
        XCTAssertFalse(RemoteAppRules.isAllowed(bundleID: "", policy: policy))
        XCTAssertFalse(RemoteAppRules.isAllowed(bundleID: String(repeating: "a", count: 256), policy: policy))
    }

    func testListIsSortedOnceEachAndPrefersTheRunningCopy() {
        let listed = RemoteAppRules.list([
            app("b", "beta"), app("a", "Alpha"), app("b", "beta", running: true), app("b", "beta"), app("n", "  ")
        ], policy: policy)
        XCTAssertEqual(listed, [app("a", "Alpha"), app("b", "beta", running: true)])
    }

    func testListAndNamesAreCapped() {
        let many = (0..<(RemoteAppRules.maxApps + 5)).map { app("com.example.\($0)") }
        XCTAssertEqual(RemoteAppRules.list(many, policy: policy).count, RemoteAppRules.maxApps)
        let long = RemoteAppRules.list([app("x", String(repeating: "n", count: 500))], policy: policy)
        XCTAssertEqual(long.first?.name.count, RemoteAppRules.maxNameCharacters)
    }

    func testLimiterAllowsTenPerMinute() {
        var limiter = OpenAppLimiter()
        for _ in 0..<OpenAppLimiter.maxRequests { XCTAssertTrue(limiter.allow(now: 100)) }
        XCTAssertFalse(limiter.allow(now: 100))
        XCTAssertFalse(limiter.allow(now: 159.9))
        XCTAssertTrue(limiter.allow(now: 160))
    }

    func testMessagesRoundTrip() throws {
        let list = [app("com.apple.Safari", "Safari", running: true)]
        let listFrame = try MessageCodec.frame(.appList, list)
        XCTAssertEqual(try MessageCodec.decode([RemoteApp].self, from: listFrame), list)
        let request = OpenAppRequest(bundleID: "com.apple.Safari")
        XCTAssertEqual(try MessageCodec.decode(OpenAppRequest.self, from: MessageCodec.frame(.openApp, request)), request)
        let result = OpenAppResult(bundleID: "com.apple.Safari", outcome: .noWindows)
        XCTAssertEqual(try MessageCodec.decode(OpenAppResult.self, from: MessageCodec.frame(.openAppResult, result)), result)
    }

    func testNewKindsKeepTheirWireValues() {
        XCTAssertEqual(MessageKind.requestAppList.rawValue, 0x21)
        XCTAssertEqual(MessageKind.appList.rawValue, 0x22)
        XCTAssertEqual(MessageKind.openApp.rawValue, 0x23)
        XCTAssertEqual(MessageKind.openAppResult.rawValue, 0x24)
    }
}
