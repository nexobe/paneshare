import XCTest
@testable import PaneshareCore

final class SavedOffersTests: XCTestCase {
    private let policy = WindowPolicy(ownProcessID: 42, ownBundleID: "dev.paneshare.app", extraDeniedBundleIDs: ["com.example.denied"])

    private func window(_ id: UInt32, _ bundle: String, hidden: Bool = false) -> WindowInfo {
        WindowInfo(windowID: id, title: "t", appName: "a", bundleID: bundle, processID: 7,
                   frame: WireRect(x: 0, y: 0, width: 400, height: 300), isOnScreen: !hidden)
    }

    private var screen: WindowInfo {
        ScreenOffer.info(displayID: 1, number: 1, frame: WireRect(x: 0, y: 0, width: 1000, height: 800))
    }

    func testStartsEmpty() {
        XCTAssertTrue(SavedOffers().bundleIDs.isEmpty)
        XCTAssertTrue(SavedOffers(saved: nil).encoded.isEmpty)
        XCTAssertTrue(SavedOffers().windowsToOffer(from: [window(1, "com.example.editor")], alreadyOffered: [], policy: policy).isEmpty)
    }

    func testTickSavesTheAppAndItsNewWindowsAreOffered() {
        var saved = SavedOffers()
        saved.userChanged(window(1, "com.example.editor"), offered: true, policy: policy)
        XCTAssertEqual(SavedOffers(saved: saved.encoded), saved)
        let found = saved.windowsToOffer(from: [window(1, "com.example.editor"), window(2, "com.example.editor"), window(3, "com.other")],
                                         alreadyOffered: [1], policy: policy)
        XCTAssertEqual(found.map(\.windowID), [2])
    }

    func testUntickStopsTheWholeApp() {
        var saved = SavedOffers(saved: ["com.example.editor"])
        saved.userChanged(window(1, "com.example.editor"), offered: false, policy: policy)
        XCTAssertTrue(saved.windowsToOffer(from: [window(1, "com.example.editor"), window(2, "com.example.editor")], alreadyOffered: [], policy: policy).isEmpty)
    }

    func testDeniedAppsAreNeverSavedOrOffered() {
        var saved = SavedOffers()
        for bundle in ["com.apple.Passwords", "com.example.denied", "com.apple.SecurityAgent", "dev.paneshare.app"] {
            saved.userChanged(window(1, bundle), offered: true, policy: policy)
        }
        XCTAssertTrue(saved.bundleIDs.isEmpty)
        let planted = SavedOffers(saved: ["com.apple.Passwords"])
        XCTAssertTrue(planted.windowsToOffer(from: [window(1, "com.apple.Passwords")], alreadyOffered: [], policy: policy).isEmpty)
    }

    func testWindowsThatFailThePolicyAreLeftOut() {
        let saved = SavedOffers(saved: ["com.example.editor"])
        XCTAssertTrue(saved.windowsToOffer(from: [window(1, "com.example.editor", hidden: true)], alreadyOffered: [], policy: policy).isEmpty)
    }

    func testScreensAreSeparateFromSavedApps() {
        var saved = SavedOffers()
        saved.userChanged(screen, offered: true, policy: policy)
        XCTAssertTrue(saved.bundleIDs.isEmpty)
        XCTAssertTrue(SavedOffers(saved: [ScreenOffer.bundleID]).windowsToOffer(from: [screen], alreadyOffered: [], policy: policy).isEmpty)
        XCTAssertEqual(SavedOffers.screens(in: [screen, window(1, "com.example.editor")], alreadyOffered: []).map(\.windowID), [screen.windowID])
        XCTAssertTrue(SavedOffers.screens(in: [screen], alreadyOffered: [screen.windowID]).isEmpty)
    }

    func testSavedListIsCapped() {
        let many = (0..<(SavedOffers.maxApps + 5)).map { "com.example.\($0)" }
        XCTAssertEqual(SavedOffers(saved: many).bundleIDs.count, SavedOffers.maxApps)
    }
}
