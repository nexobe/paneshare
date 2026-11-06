import Foundation
import XCTest
@testable import PaneshareCore

final class VirtualDisplayPlannerTests: XCTestCase {
    let laptop = [WireSize(width: 1512, height: 944)]
    let small = WireSize(width: 800, height: 600)
    let viewer = WireSize(width: 2560, height: 1415)

    func testModeSetting() {
        XCTAssertEqual(VirtualDisplayMode(setting: nil), .off)
        XCTAssertEqual(VirtualDisplayMode(setting: "auto"), .auto)
        XCTAssertEqual(VirtualDisplayMode(setting: "always"), .always)
        XCTAssertEqual(VirtualDisplayMode(setting: "sometimes"), .off)
    }

    func testOffNeverUsesAVirtualDisplay() {
        XCTAssertEqual(VirtualDisplayPlanner.decide(mode: .off, apiProblem: nil, physicalScreens: [], window: small,
                                                    viewerDisplay: viewer), .useRealScreen)
    }

    func testAutoStaysOnTheRealScreenWhenTheWindowFits() {
        XCTAssertEqual(VirtualDisplayPlanner.decide(mode: .auto, apiProblem: nil, physicalScreens: laptop, window: small,
                                                    wanted: WireSize(width: 1400, height: 900), viewerDisplay: viewer), .useRealScreen)
    }

    func testAutoUsesOneForOversizedWindowsAndHeadlessHosts() {
        XCTAssertEqual(VirtualDisplayPlanner.decide(mode: .auto, apiProblem: nil, physicalScreens: laptop, window: small,
                                                    wanted: WireSize(width: 2400, height: 1300), viewerDisplay: viewer),
                       .useVirtual(WireSize(width: 2560, height: 1414)))
        XCTAssertEqual(VirtualDisplayPlanner.decide(mode: .auto, apiProblem: nil, physicalScreens: [], window: small, viewerDisplay: nil),
                       .useVirtual(VirtualDisplayPlanner.defaultSize), "headless")
        XCTAssertEqual(VirtualDisplayPlanner.decide(mode: .auto, apiProblem: nil, physicalScreens: laptop,
                                                    window: WireSize(width: 1600, height: 900), viewerDisplay: viewer),
                       .useVirtual(WireSize(width: 2560, height: 1414)), "already larger than the host's screen")
    }

    func testAlwaysAndUnavailable() {
        XCTAssertEqual(VirtualDisplayPlanner.decide(mode: .always, apiProblem: nil, physicalScreens: laptop, window: small, viewerDisplay: viewer),
                       .useVirtual(WireSize(width: 2560, height: 1414)))
        XCTAssertEqual(VirtualDisplayPlanner.decide(mode: .always, apiProblem: "class missing", physicalScreens: laptop, window: small,
                                                    viewerDisplay: viewer), .unavailable("class missing"))
        XCTAssertEqual(VirtualDisplayPlanner.decide(mode: .auto, apiProblem: "class missing", physicalScreens: laptop, window: small,
                                                    viewerDisplay: viewer), .useRealScreen, "no need, so no complaint")
    }

    func testDisplaySizeGrowsClampsAndRounds() {
        XCTAssertEqual(VirtualDisplayPlanner.displaySize(viewer: WireSize(width: 1440, height: 875), need: WireSize(width: 1800, height: 600)),
                       WireSize(width: 1800, height: 874))
        XCTAssertEqual(VirtualDisplayPlanner.displaySize(viewer: WireSize(width: 9000, height: 100), need: small),
                       WireSize(width: 3840, height: 600))
        XCTAssertEqual(VirtualDisplayPlanner.displaySize(viewer: WireSize(width: .nan, height: 0), need: WireSize(width: 0, height: 0)),
                       VirtualDisplayPlanner.defaultSize)
        XCTAssertEqual(VirtualDisplayPlanner.displaySize(viewer: nil, need: WireSize(width: .infinity, height: 10)),
                       VirtualDisplayPlanner.defaultSize)
        let max = VirtualDisplayPlanner.maxSize
        XCTAssertLessThanOrEqual(Int(max.width * 2) * Int(max.height * 2), Sizing.maxPixelArea)
    }

    func testPlacementCentresOrPinsTopLeft() {
        let visible = WireRect(x: 3000, y: 25, width: 2560, height: 1390)
        XCTAssertEqual(VirtualDisplayPlanner.placement(window: WireSize(width: 1000, height: 790), visible: visible),
                       WirePoint(x: 3780, y: 325))
        XCTAssertEqual(VirtualDisplayPlanner.placement(window: WireSize(width: 3000, height: 2000), visible: visible),
                       WirePoint(x: 3000, y: 25))
    }

    func testSerialIsStablePerViewerAndNeverZero() {
        let a = Fingerprint(bytes: [0x12, 0x34, 0x56, 0x78] + [UInt8](repeating: 0, count: 28))!
        XCTAssertEqual(VirtualDisplayPlanner.serial(for: a), 0x1234_5678)
        XCTAssertEqual(VirtualDisplayPlanner.serial(for: Fingerprint(bytes: [UInt8](repeating: 0, count: 32))!), 1)
    }

    func testOpenWindowViewerDisplayIsOptional() throws {
        let old = try MessageCodec.decode(OpenWindow.self, from: Frame(kind: .openWindow, payload: Data(#"{"windowID":5,"viewerBackingScale":2}"#.utf8)))
        XCTAssertNil(old.viewerDisplay)
        let new = OpenWindow(windowID: 5, viewerBackingScale: 2, viewerDisplay: WireSize(width: 1512, height: 944))
        XCTAssertEqual(try MessageCodec.decode(OpenWindow.self, from: try MessageCodec.frame(.openWindow, new)).viewerDisplay,
                       WireSize(width: 1512, height: 944))
    }
}

final class ObjCTypeEncodingTests: XCTestCase {
    func testNormalizationAndBoolSpellings() {
        XCTAssertEqual(ObjCTypeEncoding.normalized("v24@0:8@16"), "v@:@")
        XCTAssertEqual(ObjCTypeEncoding.normalized("v32@0:8{CGSize=dd}16"), "v@:{CGSize=dd}")
        XCTAssertEqual(ObjCTypeEncoding.accepted("B@:@"), ["B@:@", "c@:@"])
        XCTAssertEqual(ObjCTypeEncoding.accepted("v@:I"), ["v@:I"])
        XCTAssertTrue(ObjCTypeEncoding.matches(found: "B24@0:8@16", expected: "B@:@"))
        XCTAssertTrue(ObjCTypeEncoding.matches(found: "c24@0:8@16", expected: "B@:@"), "x86_64 and Rosetta")
        XCTAssertFalse(ObjCTypeEncoding.matches(found: "v24@0:8@16", expected: "B@:@"))
        XCTAssertFalse(ObjCTypeEncoding.matches(found: "v20@0:8i16", expected: "v@:I"), "signed vs unsigned")
    }

    func testMoveAwayNeedsEveryCondition() {
        XCTAssertTrue(VirtualDisplayPlanner.canMoveAway(settingOn: true, isScreen: false, apiProblem: nil, accessibility: true))
        XCTAssertFalse(VirtualDisplayPlanner.canMoveAway(settingOn: false, isScreen: false, apiProblem: nil, accessibility: true))
        XCTAssertFalse(VirtualDisplayPlanner.canMoveAway(settingOn: true, isScreen: true, apiProblem: nil, accessibility: true))
        XCTAssertFalse(VirtualDisplayPlanner.canMoveAway(settingOn: true, isScreen: false, apiProblem: "gone", accessibility: true))
        XCTAssertFalse(VirtualDisplayPlanner.canMoveAway(settingOn: true, isScreen: false, apiProblem: nil, accessibility: false))
    }

    func testPlacementMessagesAndOptionalFields() throws {
        XCTAssertEqual(MessageKind.windowPlacement.rawValue, 0x25)
        let placement = WindowPlacement(away: true)
        XCTAssertEqual(try MessageCodec.decode(WindowPlacement.self, from: MessageCodec.frame(.windowPlacement, placement)), placement)
        var info = StreamInfo(sourceScale: nil, sourcePoints: WireSize(width: 1, height: 1), capturePixels: PixelSize(width: 1, height: 1),
                              captureFormat: "BGRA", encodedPixels: PixelSize(width: 1, height: 1), codec: .h264, chroma: .yuv420,
                              profile: "p", hardware: true, bitrate: 1, topUpBitrate: 1)
        let old = try JSONDecoder().decode(StreamInfo.self, from: JSONEncoder().encode(info))
        XCTAssertNil(old.movable)
        XCTAssertNil(old.movedAway)
        info.movable = true
        info.movedAway = false
        let new = try JSONDecoder().decode(StreamInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(new.movable, true)
        XCTAssertEqual(new.movedAway, false)
    }
}
