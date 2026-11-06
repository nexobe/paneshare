import XCTest
@testable import PaneshareCore

final class AdaptiveBitrateTests: XCTestCase {
    func testStepsDownAfterThreeDropsInTheWindow() {
        var rate = AdaptiveBitrate()
        XCTAssertNil(rate.update(dropped: 1, now: 0))
        XCTAssertNil(rate.update(dropped: 1, now: 0.5))
        XCTAssertEqual(rate.update(dropped: 1, now: 1), 0.75)
        XCTAssertEqual(rate.factor, 0.75)
    }

    func testOccasionalDropsDoNotChangeTheRate() {
        var rate = AdaptiveBitrate()
        for t in stride(from: 0.0, to: 30, by: 2) {
            XCTAssertNil(rate.update(dropped: 1, now: t))
        }
        XCTAssertEqual(rate.factor, 1)
    }

    func testStopsAtTheLowestLevel() {
        var rate = AdaptiveBitrate()
        var t = 0.0
        for _ in 0..<20 {
            _ = rate.update(dropped: 5, now: t)
            t += 0.5
        }
        XCTAssertEqual(rate.factor, AdaptiveBitrate.levels.last)
    }

    func testComesBackOneLevelAfterAQuietPeriod() {
        var rate = AdaptiveBitrate()
        _ = rate.update(dropped: 3, now: 0)
        _ = rate.update(dropped: 3, now: 1)
        XCTAssertEqual(rate.factor, 0.5)
        XCTAssertNil(rate.update(dropped: 0, now: 15.9))
        XCTAssertEqual(rate.update(dropped: 0, now: 16), 0.75)
        XCTAssertNil(rate.update(dropped: 0, now: 30.9))
        XCTAssertEqual(rate.update(dropped: 0, now: 31), 1)
        XCTAssertNil(rate.update(dropped: 0, now: 100))
    }

    func testADropRestartsTheQuietPeriod() {
        var rate = AdaptiveBitrate()
        _ = rate.update(dropped: 3, now: 0)
        _ = rate.update(dropped: 1, now: 10)
        XCTAssertNil(rate.update(dropped: 0, now: 16))
        XCTAssertEqual(rate.update(dropped: 0, now: 25), 1)
    }

    func testScaledRateHasAFloorAndNeverRises() {
        XCTAssertEqual(AdaptiveBitrate.scaled(20_000_000, factor: 1), 20_000_000)
        XCTAssertEqual(AdaptiveBitrate.scaled(20_000_000, factor: 0.5), 10_000_000)
        XCTAssertEqual(AdaptiveBitrate.scaled(4_000_000, factor: 0.25), StreamTuning.minBitrate)
        XCTAssertEqual(AdaptiveBitrate.scaled(1_000_000, factor: 0.25), 1_000_000)
    }

    func testOpenWindowFieldIsOptional() throws {
        let old = #"{"windowID":1,"viewerBackingScale":2}"#
        XCTAssertNil(try JSONDecoder().decode(OpenWindow.self, from: Data(old.utf8)).adaptiveQuality)
        let new = OpenWindow(windowID: 1, viewerBackingScale: 2, adaptiveQuality: true)
        let round = try JSONDecoder().decode(OpenWindow.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(round.adaptiveQuality, true)
    }
}
