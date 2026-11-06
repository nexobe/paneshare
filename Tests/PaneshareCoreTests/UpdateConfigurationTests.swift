import Foundation
import XCTest
@testable import PaneshareCore

final class UpdateConfigurationTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private func info(_ overrides: [String: Any] = [:], removing: [String] = []) -> [String: Any] {
        var info: [String: Any] = [
            "SUFeedURL": "https://updates.example.org/paneshare/appcast.xml",
            "SUPublicEDKey": key,
            "SURequireSignedFeed": true,
            "SUVerifyUpdateBeforeExtraction": true,
            "SUScheduledCheckInterval": 86400,
        ]
        for k in removing { info[k] = nil }
        info.merge(overrides) { $1 }
        return info
    }

    func testCompleteConfigurationIsAccepted() throws {
        let config = try UpdateConfiguration.from(info: info()).get()
        XCTAssertEqual(config.feedURL.absoluteString, "https://updates.example.org/paneshare/appcast.xml")
        XCTAssertEqual(config.publicEDKey, key)
        XCTAssertEqual(config.checkInterval, 86400)
        // Defaults to daily; plist booleans may arrive as strings from plutil -replace -string.
        let loose = try UpdateConfiguration.from(info: info(["SURequireSignedFeed": "YES"], removing: ["SUScheduledCheckInterval"])).get()
        XCTAssertEqual(loose.checkInterval, UpdateConfiguration.defaultInterval)
    }

    func testLocalBuildsAreNotConfigured() {
        XCTAssertEqual(problem(info(removing: ["SUFeedURL"])), .notConfigured)
        XCTAssertEqual(problem(info(["SUFeedURL": "  "])), .notConfigured)
        XCTAssertEqual(problem([:]), .notConfigured)
    }

    func testFeedMustBeHTTPSAndWellFormed() {
        XCTAssertEqual(problem(info(["SUFeedURL": "http://updates.example.org/appcast.xml"])), .feedNotHTTPS)
        XCTAssertEqual(problem(info(["SUFeedURL": "file:///tmp/appcast.xml"])), .invalidFeedURL)
        XCTAssertEqual(problem(info(["SUFeedURL": "https://user:pw@example.org/appcast.xml"])), .invalidFeedURL)
        XCTAssertEqual(problem(info(["SUFeedURL": "https://example.org/"])), .invalidFeedURL)
        XCTAssertEqual(problem(info(["SUFeedURL": "https://example.org/appcast.xml#x"])), .invalidFeedURL)
        XCTAssertEqual(problem(info(["SUFeedURL": "not a url"])), .invalidFeedURL)
    }

    func testKeyAndSignedFeedAreRequired() {
        XCTAssertEqual(problem(info(removing: ["SUPublicEDKey"])), .missingPublicKey)
        XCTAssertEqual(problem(info(["SUPublicEDKey": "abc"])), .invalidPublicKey)
        XCTAssertEqual(problem(info(["SUPublicEDKey": Data(repeating: 1, count: 33).base64EncodedString()])), .invalidPublicKey)
        XCTAssertEqual(problem(info(["SURequireSignedFeed": false])), .feedNotSigned)
        XCTAssertEqual(problem(info(removing: ["SUVerifyUpdateBeforeExtraction"])), .feedNotSigned)
        XCTAssertEqual(problem(info(["SUScheduledCheckInterval": 60])), .intervalTooShort)
    }

    func testConsentIsAskedOnceAndOnlyForUpdatableBuilds() {
        XCTAssertTrue(UpdateConsent.shouldAsk(configured: true, alreadyAsked: false, automaticChecksSetting: nil))
        XCTAssertFalse(UpdateConsent.shouldAsk(configured: false, alreadyAsked: false, automaticChecksSetting: nil))
        XCTAssertFalse(UpdateConsent.shouldAsk(configured: true, alreadyAsked: true, automaticChecksSetting: nil))
        // Already decided in Sparkle's own setting (for example from an earlier install).
        XCTAssertFalse(UpdateConsent.shouldAsk(configured: true, alreadyAsked: false, automaticChecksSetting: false))
    }

    private func problem(_ info: [String: Any]) -> UpdateConfiguration.Problem? {
        if case .failure(let p) = UpdateConfiguration.from(info: info) { return p }
        return nil
    }
}
