#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest
@testable import PaneshareCore

final class StreamTuningTests: XCTestCase {
    func testBitrateScalesWithPixelsAndChromaAndClamps() {
        let retina = PixelSize(width: 2880, height: 1800)
        XCTAssertEqual(StreamTuning.bitrate(for: retina, fps: 60), 31_104_000)
        XCTAssertEqual(StreamTuning.bitrate(for: retina, fps: 60, chroma: .yuv444), 46_656_000)
        XCTAssertEqual(StreamTuning.bitrate(for: PixelSize(width: 200, height: 100), fps: 60), StreamTuning.minBitrate)
        XCTAssertEqual(StreamTuning.bitrate(for: PixelSize(width: 7680, height: 4320), fps: 60), StreamTuning.maxBitrate)
        XCTAssertEqual(StreamTuning.bitrate(for: PixelSize(width: 7680, height: 4320), fps: 60, chroma: .yuv444), 75_000_000)
    }

    func testTopUpIsFarAboveTheMotionRateAndCapped() {
        XCTAssertEqual(StreamTuning.topUpBitrate(normal: 31_104_000), 248_832_000)
        XCTAssertEqual(StreamTuning.topUpBitrate(normal: 2_000_000), 40_000_000)
        XCTAssertEqual(StreamTuning.topUpBitrate(normal: 75_000_000), StreamTuning.maxTopUpBitrate)
    }

    private let hevcProfiles = ["HEVC_Main_AutoLevel", "HEVC_Main10_AutoLevel", "HEVC_Main42210_AutoLevel",
                                "HEVC_Main444_10_AutoLevel", "HEVC_Main444_AutoLevel", "H264_High_AutoLevel"]

    func testProfilePicksRichestAcceptedChroma() {
        XCTAssertEqual(StreamTuning.profile(supported: hevcProfiles, codec: .hevc, accepted: ChromaFormat.viewerDefault)?.name,
                       "HEVC_Main444_AutoLevel") // 8-bit before 10-bit
        XCTAssertEqual(StreamTuning.profile(supported: hevcProfiles, codec: .hevc, accepted: [.yuv422, .yuv420])?.chroma, .yuv422)
        XCTAssertNil(StreamTuning.profile(supported: hevcProfiles, codec: .hevc, accepted: [.yuv420]))
    }

    func testProfileFallsBackWhenTheEncoderHasNoRichChroma() {
        XCTAssertNil(StreamTuning.profile(supported: ["HEVC_Main_AutoLevel", "HEVC_Main10_AutoLevel"], codec: .hevc,
                                          accepted: ChromaFormat.viewerDefault))
        XCTAssertNil(StreamTuning.profile(supported: [], codec: .hevc, accepted: ChromaFormat.viewerDefault))
        // Another codec's names never match.
        XCTAssertNil(StreamTuning.profile(supported: hevcProfiles, codec: .h264, accepted: ChromaFormat.viewerDefault))
        XCTAssertEqual(StreamTuning.profile(supported: ["H264_High444Predictive_AutoLevel"], codec: .h264, accepted: [.yuv444])?.chroma,
                       .yuv444)
    }

    func testChromaOrdering() {
        XCTAssertLessThan(ChromaFormat.yuv420, .yuv444)
        XCTAssertEqual(ChromaFormat.viewerDefault.first, .yuv444)
    }

    func testHiddenChromaSetting() {
        XCTAssertEqual(ChromaFormat.accepted(setting: nil), ChromaFormat.viewerDefault)
        XCTAssertEqual(ChromaFormat.accepted(setting: "auto"), ChromaFormat.viewerDefault)
        XCTAssertEqual(ChromaFormat.accepted(setting: "4:2:0"), [.yuv420])
        XCTAssertEqual(ChromaFormat.accepted(setting: "420"), [.yuv420])
        XCTAssertEqual(ChromaFormat.accepted(setting: "4:2:2"), [.yuv422, .yuv420])
        XCTAssertEqual(ChromaFormat.accepted(setting: " 444 "), ChromaFormat.viewerDefault)
        XCTAssertEqual(ChromaFormat.accepted(setting: "ultra"), ChromaFormat.viewerDefault)
    }
}

final class DisplayFitTests: XCTestCase {
    func testNativeUsesTheExactStreamSize() {
        let size = DisplayFit.contentSize(pixels: PixelSize(width: 2402, height: 1600), backingScale: 2, quality: .native,
                                          hostPoints: CGSize(width: 1200.5, height: 800))
        XCTAssertEqual(size, CGSize(width: 1201, height: 800))
        XCTAssertTrue(DisplayFit.isOneToOne(pixels: PixelSize(width: 2402, height: 1600), viewPoints: size, backingScale: 2))
    }

    func testOddPointWidthAtOneX() {
        // 801 pt at 1x is captured as 802 px (even sizes); a 801 pt view would resample every column.
        let pixels = Sizing.pixelSize(points: CGSize(width: 801, height: 600), scale: 1, quality: .native)
        XCTAssertEqual(pixels, PixelSize(width: 802, height: 600))
        XCTAssertFalse(DisplayFit.isOneToOne(pixels: pixels, viewPoints: CGSize(width: 801, height: 600), backingScale: 1))
        let fit = DisplayFit.contentSize(pixels: pixels, backingScale: 1, quality: .native, hostPoints: CGSize(width: 801, height: 600))
        XCTAssertTrue(DisplayFit.isOneToOne(pixels: pixels, viewPoints: fit, backingScale: 1))
    }

    func testFollowsTheHostWhenNotNativeOrFarOff() {
        let host = CGSize(width: 1200, height: 800)
        XCTAssertEqual(DisplayFit.contentSize(pixels: PixelSize(width: 1800, height: 1200), backingScale: 2, quality: .balanced,
                                              hostPoints: host), host)
        // A capture clamped by the area limit, or a viewer whose scale changed since opening.
        XCTAssertEqual(DisplayFit.contentSize(pixels: PixelSize(width: 1200, height: 800), backingScale: 2, quality: .native,
                                              hostPoints: host), host)
        XCTAssertEqual(DisplayFit.contentSize(pixels: PixelSize(width: 2400, height: 1600), backingScale: 0, quality: .native,
                                              hostPoints: host), host)
    }
}

final class StreamDiagnosticsTests: XCTestCase {
    let info = StreamInfo(sourceScale: 2, sourcePoints: WireSize(width: 1440, height: 900),
                          capturePixels: PixelSize(width: 2880, height: 1800), captureFormat: "BGRA",
                          encodedPixels: PixelSize(width: 2880, height: 1800), codec: .hevc, chroma: .yuv444,
                          profile: "HEVC_Main444_AutoLevel", hardware: true, bitrate: 46_656_000, topUpBitrate: 373_248_000)

    func testOverlayShowsEveryStage() {
        let d = StreamDiagnostics(info: info, decodedPixels: PixelSize(width: 2880, height: 1800),
                                  viewPoints: CGSize(width: 1440, height: 900), backingScale: 2,
                                  receivedBitsPerSecond: 12_400_000, receivedFramesPerSecond: 3, topUps: 2)
        XCTAssertEqual(d.mapping, "1:1")
        XCTAssertEqual(d.lines, [
            "host  window 1440×900 pt @2x · capture 2880×1800 BGRA",
            "enc   HEVC 4:4:4 hw · 2880×1800 · 46.7 Mb/s (top-up 373.2 Mb/s)",
            "      HEVC_Main444_AutoLevel",
            "view  decoded 2880×1800 · shown 2880×1800 px = 1440×900 pt @2x · 1:1",
            "rx    12.4 Mb/s · 3 fps · 2 top-ups",
        ])
    }

    func testScaledPictureIsCalledOut() {
        let d = StreamDiagnostics(info: nil, decodedPixels: PixelSize(width: 2880, height: 1800),
                                  viewPoints: CGSize(width: 1438, height: 898), backingScale: 2)
        XCTAssertEqual(d.mapping, "scaled ×0.998")
        XCTAssertEqual(d.lines.first, "host  (no stream info; older host)")
        XCTAssertEqual(StreamDiagnostics(info: nil, decodedPixels: nil, viewPoints: .zero, backingScale: 2).mapping, "no picture yet")
    }

    func testRateMeterSlidesOverOneSecond() {
        var m = RateMeter()
        m.add(bytes: 125_000, at: 10.0)
        m.add(bytes: 125_000, at: 10.5)
        XCTAssertEqual(m.rates(at: 10.9).bitsPerSecond, 2_000_000)
        XCTAssertEqual(m.rates(at: 10.9).framesPerSecond, 2)
        XCTAssertEqual(m.rates(at: 11.4).framesPerSecond, 1)
        XCTAssertEqual(m.rates(at: 20).bitsPerSecond, 0)
    }
}
