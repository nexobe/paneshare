#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest
@testable import PaneshareCore

final class InputMappingTests: XCTestCase {
    let view = CGSize(width: 800, height: 600)

    func testFlippedNormalization() {
        XCTAssertEqual(InputMapping.normalize(flippedPoint: .zero, viewSize: view), NormalizedPoint(x: 0, y: 0))
        XCTAssertEqual(InputMapping.normalize(flippedPoint: CGPoint(x: 400, y: 150), viewSize: view), NormalizedPoint(x: 0.5, y: 0.25))
        XCTAssertEqual(InputMapping.normalize(flippedPoint: CGPoint(x: 800, y: 600), viewSize: view), NormalizedPoint(x: 1, y: 1))
    }

    func testBottomLeftNormalizationFlipsY() {
        // AppKit's default: y = 0 is the bottom edge, which is y = 1 on the wire.
        XCTAssertEqual(InputMapping.normalize(bottomLeftPoint: CGPoint(x: 0, y: 0), viewSize: view), NormalizedPoint(x: 0, y: 1))
        XCTAssertEqual(InputMapping.normalize(bottomLeftPoint: CGPoint(x: 200, y: 450), viewSize: view), NormalizedPoint(x: 0.25, y: 0.25))
    }

    func testNormalizationClampsOutsideAndNonFinite() {
        XCTAssertEqual(InputMapping.normalize(flippedPoint: CGPoint(x: -50, y: 9000), viewSize: view), NormalizedPoint(x: 0, y: 1))
        XCTAssertEqual(InputMapping.normalize(flippedPoint: CGPoint(x: CGFloat.nan, y: 10), viewSize: view).x, 0)
        XCTAssertEqual(InputMapping.normalize(flippedPoint: CGPoint(x: 10, y: 10), viewSize: .zero), NormalizedPoint(x: 0, y: 0))
    }

    func testGlobalMappingOnSecondaryDisplayWithNegativeOrigin() {
        // A window on a display left of and above the main display.
        let frame = CGRect(x: -1920, y: -300, width: 1000, height: 500)
        let p = InputMapping.globalPoint(NormalizedPoint(x: 0.5, y: 0.5), windowFrame: frame)
        XCTAssertEqual(p.x, -1420, accuracy: 1e-9)
        XCTAssertEqual(p.y, -50, accuracy: 1e-9)
    }

    func testGlobalMappingClampsToInsetFrame() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let topLeft = InputMapping.globalPoint(NormalizedPoint(x: 0, y: 0), windowFrame: frame)
        XCTAssertEqual(topLeft, CGPoint(x: 100.5, y: 200.5))
        let bottomRight = InputMapping.globalPoint(NormalizedPoint(x: 1, y: 1), windowFrame: frame)
        XCTAssertEqual(bottomRight, CGPoint(x: 499.5, y: 499.5))
        // Out-of-range values from a hostile viewer can never leave the window.
        let hostile = InputMapping.globalPoint(NormalizedPoint(x: 50, y: -3), windowFrame: frame)
        XCTAssertTrue(frame.contains(hostile))
    }

    func testViewerToHostRoundTripWithinHalfPoint() {
        // Viewer window 1200×800 pt shows a host window of the same point size somewhere else.
        let viewerSize = CGSize(width: 1200, height: 800)
        let hostFrame = CGRect(x: 2560, y: 40, width: 1200, height: 800)
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<1000 {
            let vp = CGPoint(x: CGFloat.random(in: 1...1199, using: &rng), y: CGFloat.random(in: 1...799, using: &rng))
            let n = InputMapping.normalize(flippedPoint: vp, viewSize: viewerSize)
            let g = InputMapping.globalPoint(n, windowFrame: hostFrame)
            XCTAssertEqual(g.x - hostFrame.minX, vp.x, accuracy: 0.5)
            XCTAssertEqual(g.y - hostFrame.minY, vp.y, accuracy: 0.5)
            let back = InputMapping.normalize(globalPoint: g, windowFrame: hostFrame)
            XCTAssertEqual(back.x, n.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, n.y, accuracy: 1e-9)
        }
    }

    func testScaledViewerMapsProportionally() {
        // Viewer shows the host window at a different size (before a resize round trip settles).
        let n = InputMapping.normalize(flippedPoint: CGPoint(x: 300, y: 200), viewSize: CGSize(width: 600, height: 400))
        let g = InputMapping.globalPoint(n, windowFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertEqual(g, CGPoint(x: 600, y: 400))
    }

    func testInputEventValidation() {
        XCTAssertTrue(InputEvent(kind: .mouseMove, position: NormalizedPoint(x: 0.1, y: 0.9)).isWellFormed)
        XCTAssertFalse(InputEvent(kind: .mouseMove).isWellFormed)
        XCTAssertFalse(InputEvent(kind: .mouseMove, position: NormalizedPoint(x: 1.5, y: 0)).isWellFormed)
        XCTAssertFalse(InputEvent(kind: .mouseDown, position: NormalizedPoint(x: 0.5, y: 0.5)).isWellFormed) // no button
        XCTAssertFalse(InputEvent(kind: .mouseDown, position: NormalizedPoint(x: 0.5, y: 0.5), button: .left, clickCount: 9).isWellFormed)
        XCTAssertFalse(InputEvent(kind: .scroll, position: NormalizedPoint(x: 0.5, y: 0.5), scrollDeltaY: .infinity).isWellFormed)
        XCTAssertTrue(InputEvent(kind: .keyDown, keyCode: 0x24).isWellFormed)
        XCTAssertFalse(InputEvent(kind: .keyDown).isWellFormed)
        XCTAssertFalse(InputEvent(kind: .keyDown, keyCode: 0x1FF).isWellFormed)
    }
}

final class SizingTests: XCTestCase {
    func testRetinaPixelSizeIsEven() {
        XCTAssertEqual(Sizing.pixelSize(points: CGSize(width: 1200, height: 800), scale: 2), PixelSize(width: 2400, height: 1600))
        XCTAssertEqual(Sizing.pixelSize(points: CGSize(width: 801, height: 601), scale: 1), PixelSize(width: 802, height: 602))
        XCTAssertEqual(Sizing.pixelSize(points: CGSize(width: 100.25, height: 50.75), scale: 2), PixelSize(width: 200, height: 102))
    }

    func testPixelSizeClampsSideAndArea() {
        let huge = Sizing.pixelSize(points: CGSize(width: 20_000, height: 1_000), scale: 2)
        XCTAssertLessThanOrEqual(huge.width, Sizing.maxPixelDimension)
        XCTAssertEqual(Double(huge.width) / Double(huge.height), 20, accuracy: 0.1)
        let big = Sizing.pixelSize(points: CGSize(width: 6000, height: 4000), scale: 2)
        XCTAssertLessThanOrEqual(big.width * big.height, Sizing.maxPixelArea + 4 * (big.width + big.height))
        XCTAssertEqual(big.width % 2, 0)
        XCTAssertEqual(big.height % 2, 0)
    }

    func testQualityScalesTheBackingScale() {
        let points = CGSize(width: 1200, height: 800)
        XCTAssertEqual(Sizing.pixelSize(points: points, scale: 2, quality: .native), PixelSize(width: 2400, height: 1600))
        XCTAssertEqual(Sizing.pixelSize(points: points, scale: 2, quality: .balanced), PixelSize(width: 1800, height: 1200))
        XCTAssertEqual(Sizing.pixelSize(points: points, scale: 2, quality: .economy), PixelSize(width: 1200, height: 800))
        XCTAssertEqual(Sizing.pixelSize(points: points, scale: 1, quality: .economy), PixelSize(width: 600, height: 400))
        // The scale is clamped before the quality factor applies.
        XCTAssertEqual(Sizing.pixelSize(points: points, scale: 9, quality: .economy), PixelSize(width: 2400, height: 1600))
        XCTAssertEqual(Sizing.pixelSize(points: points, scale: .nan, quality: .balanced), PixelSize(width: 900, height: 600))
    }

    func testStreamSizeIsFrozenUntilTheFinalResize() {
        let a = PixelSize(width: 2400, height: 1600), b = PixelSize(width: 2000, height: 1600)
        XCTAssertFalse(Sizing.shouldReconfigure(final: false, current: a, next: b))
        XCTAssertTrue(Sizing.shouldReconfigure(final: true, current: a, next: b))
        XCTAssertFalse(Sizing.shouldReconfigure(final: true, current: a, next: a))
    }

    func testPixelSizeHandlesBadScale() {
        XCTAssertEqual(Sizing.pixelSize(points: CGSize(width: 10, height: 10), scale: .nan), PixelSize(width: 10, height: 10))
        XCTAssertEqual(Sizing.pixelSize(points: CGSize(width: 0, height: 0), scale: 2), PixelSize(width: 2, height: 2))
    }

    func testClampRequested() {
        XCTAssertEqual(Sizing.clampRequested(CGSize(width: 10, height: 100_000)), CGSize(width: 160, height: 8_192))
        XCTAssertEqual(Sizing.clampRequested(CGSize(width: CGFloat.nan, height: 500)), CGSize(width: 160, height: 500))
    }

    func testResizeCoalescer() {
        var c = ResizeCoalescer(interval: 0.1)
        XCTAssertEqual(c.offer(CGSize(width: 500, height: 400), now: 0), CGSize(width: 500, height: 400))
        XCTAssertNil(c.offer(CGSize(width: 510, height: 400), now: 0.03))
        XCTAssertNil(c.offer(CGSize(width: 520, height: 400), now: 0.06))
        XCTAssertNil(c.poll(now: 0.09))
        XCTAssertEqual(c.poll(now: 0.11), CGSize(width: 520, height: 400))
        XCTAssertNil(c.offer(CGSize(width: 530, height: 400), now: 0.15))
        XCTAssertEqual(c.finish(now: 0.16), CGSize(width: 530, height: 400))
        XCTAssertNil(c.finish(now: 0.2))
        // Re-offering the size already sent does nothing.
        XCTAssertNil(c.offer(CGSize(width: 530, height: 400), now: 5))
    }
}
