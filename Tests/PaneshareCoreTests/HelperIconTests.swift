import Foundation
import XCTest
@testable import PaneshareCore

final class HelperIconTests: XCTestCase {
    func testSquircleTouchesItsSquareAndIsSymmetric() {
        let points = Squircle.points(centerX: 50, centerY: 50, halfSide: 40, count: 96)
        XCTAssertEqual(points.count, 96)
        XCTAssertEqual(points.map(\.x).max()!, 90, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.x).min()!, 10, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.y).max()!, 90, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.y).min()!, 10, accuracy: 1e-9)
        for p in points {
            XCTAssertTrue((10...90).contains(p.x) && (10...90).contains(p.y))
            // On the curve: |x|^n + |y|^n = 1.
            let u = abs(p.x - 50) / 40, v = abs(p.y - 50) / 40
            XCTAssertEqual(pow(u, Squircle.exponent) + pow(v, Squircle.exponent), 1, accuracy: 1e-9)
        }
        // Squarer than a circle, rounder than a square: the 45° point sits between the two.
        let diagonal = points[12]
        let r = hypot(diagonal.x - 50, diagonal.y - 50)
        XCTAssertGreaterThan(r, 40)
        XCTAssertLessThan(r, 40 * 2.0.squareRoot())
    }

    func testLayoutKeepsTheRingVisibleAtSixteenPixels() {
        let small = HelperIconLayout(pixels: 16)
        XCTAssertGreaterThanOrEqual(small.ringWidth, 1.5)
        XCTAssertNil(small.badge)
        XCTAssertGreaterThan(small.remoteIcon.width, 8)
        let large = HelperIconLayout(pixels: 1024)
        XCTAssertNotNil(large.badge)
        // Relatively thicker when small, so it survives downsampling.
        XCTAssertGreaterThan(small.ringWidth / 16, large.ringWidth / 1024)
    }

    func testRemoteIconBodyLandsInsideTheRing() {
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let l = HelperIconLayout(pixels: pixels)
            let p = Double(pixels)
            XCTAssertEqual(l.body.width, p * 824 / 1024, accuracy: 1e-9)
            XCTAssertEqual(l.body.midX, p / 2, accuracy: 1e-9)
            XCTAssertEqual(l.remoteIcon.midX, p / 2, accuracy: 1e-9)
            XCTAssertEqual(l.remoteIcon.midY, p / 2, accuracy: 1e-9)
            // The remote image's own body (824/1024 of it) is inside the ring's inner edge.
            let remoteBody = l.remoteIcon.width * HelperIconLayout.bodyFraction
            XCTAssertLessThan(remoteBody, l.body.width - 2 * l.ringWidth, "\(pixels)")
            XCTAssertGreaterThan(remoteBody, l.body.width * 0.65, "\(pixels)")
            if let b = l.badge {
                XCTAssertGreaterThanOrEqual(b.x, 0); XCTAssertGreaterThanOrEqual(b.y, 0)
                XCTAssertLessThanOrEqual(b.x + b.width, p); XCTAssertLessThanOrEqual(b.y + b.height, p)
                XCTAssertGreaterThan(b.midX, p / 2); XCTAssertLessThan(b.midY, p / 2) // bottom right, y-up
            }
            let rings = l.ringOutlines(count: 64)
            XCTAssertEqual(rings.outer.map(\.x).max()!, l.body.x + l.body.width, accuracy: 1e-9)
            XCTAssertEqual(rings.inner.map(\.x).max()!, l.body.x + l.body.width - l.ringWidth, accuracy: 1e-9)
        }
    }

    func testChosenColourWinsOnlyIfItIsInThePalette() throws {
        let host = try XCTUnwrap(Fingerprint(bytes: [3] + Array(repeating: 9, count: 31)))
        let own = SourceMacColor.index(for: host)
        XCTAssertEqual(SourceMacColor.index(for: host, choice: nil), own)
        XCTAssertEqual(SourceMacColor.index(for: host, choice: 6), 6)
        XCTAssertEqual(SourceMacColor.index(for: host, choice: 8), own)
        XCTAssertEqual(SourceMacColor.index(for: host, choice: -1), own)
        XCTAssertEqual(SourceMacColor.names.count, SourceMacColor.palette.count)
    }

    func testSourceMacColourIsStablePerHost() throws {
        let a = try XCTUnwrap(Fingerprint(bytes: [3] + Array(repeating: 9, count: 31)))
        let b = try XCTUnwrap(Fingerprint(bytes: [4] + Array(repeating: 9, count: 31)))
        XCTAssertEqual(SourceMacColor.index(for: a), SourceMacColor.index(for: a))
        XCTAssertNotEqual(SourceMacColor.index(for: a), SourceMacColor.index(for: b))
        XCTAssertEqual(SourceMacColor.palette.count, 8)
        XCTAssertEqual(Set(SourceMacColor.palette.map { "\($0.r),\($0.g),\($0.b)" }).count, 8)
    }

    func testICNSHasEverySizeIncludingSixteenAndThirtyTwo() {
        let sizes = ICNSWriter.types.map(\.pixels)
        XCTAssertEqual(Set(sizes), [16, 32, 64, 128, 256, 512, 1024])
        XCTAssertEqual(Set(ICNSWriter.types.map(\.type)).count, ICNSWriter.types.count)
        XCTAssertTrue(ICNSWriter.types.allSatisfy { $0.type.utf8.count == 4 })
    }

    func testHelpersFromAnOlderRevisionAreRegenerated() throws {
        let host = try XCTUnwrap(Fingerprint(bytes: Array(repeating: 5, count: 32)))
        let plan = HelperBundlePlan(host: host, hostName: "Studio", remoteBundleID: "com.example.app",
                                    remoteAppName: "Example", mainBundleID: "dev.paneshare.app")
        var ledger = DockHelperLedger()
        ledger.record(plan, cdhash: String(repeating: "a", count: 40), now: Date())
        XCTAssertTrue(try XCTUnwrap(ledger.entries[plan.bundleIdentifier]).isCurrent(for: plan))
        XCTAssertEqual(plan.infoPlist["CFBundleVersion"], .string("\(HelperBundlePlan.revision)"))

        // A ledger written before revisions existed has no "revision" key.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ledger.encoded()) as? [String: Any])
        var entries = try XCTUnwrap(json["entries"] as? [String: [String: Any]])
        XCTAssertNotNil(entries[plan.bundleIdentifier]?.removeValue(forKey: "revision"))
        json["entries"] = entries
        let old = try DockHelperLedger.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.entries[plan.bundleIdentifier]?.revision)
        XCTAssertFalse(try XCTUnwrap(old.entries[plan.bundleIdentifier]).isCurrent(for: plan))
    }
}
