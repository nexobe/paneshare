import XCTest
@testable import PaneshareCore

final class ClipboardTests: XCTestCase {
    private func ready() -> ClipboardSync {
        var s = ClipboardSync()
        s.localEnabled = true
        s.peerEnabled = true
        s.focused = true
        return s
    }

    func testNeedsBothMacsAndFocus() {
        for (local, peer, focus) in [(false, true, true), (true, false, true), (true, true, false)] {
            var s = ClipboardSync()
            s.localEnabled = local
            s.peerEnabled = peer
            s.focused = focus
            XCTAssertFalse(s.canSync)
            XCTAssertFalse(s.needsRead(changeCount: 1), "must not even read the clipboard")
            XCTAssertNil(s.localChanged(changeCount: 1, types: [], text: "secret"))
            XCTAssertNil(s.received(Data("x".utf8)))
        }
        XCTAssertFalse(ClipboardSync().canSync, "off by default")
    }

    func testSendsEachChangeOnce() {
        var s = ready()
        XCTAssertEqual(s.localChanged(changeCount: 5, types: ["public.utf8-plain-text"], text: "hi"), Data("hi".utf8))
        XCTAssertFalse(s.needsRead(changeCount: 5))
        XCTAssertNil(s.localChanged(changeCount: 5, types: [], text: "hi"))
        XCTAssertEqual(s.localChanged(changeCount: 6, types: [], text: "next"), Data("next".utf8))
    }

    func testPrivateItemsStayHere() {
        for type in ClipboardSync.privateTypes {
            var s = ready()
            XCTAssertNil(s.localChanged(changeCount: 1, types: ["public.utf8-plain-text", type], text: "password"))
            XCTAssertFalse(s.needsRead(changeCount: 1), "it isn't retried")
        }
    }

    func testNonTextAndOversizeStayHere() {
        var s = ready()
        XCTAssertNil(s.localChanged(changeCount: 1, types: ["public.png"], text: nil))
        XCTAssertNil(s.localChanged(changeCount: 2, types: [], text: ""))
        XCTAssertNil(s.localChanged(changeCount: 3, types: [], text: String(repeating: "a", count: ClipboardSync.maxBytes + 1)))
        let limit = String(repeating: "a", count: ClipboardSync.maxBytes)
        XCTAssertEqual(s.localChanged(changeCount: 4, types: [], text: limit)?.count, ClipboardSync.maxBytes)
    }

    func testReceivedTextIsCheckedAndNotEchoed() {
        var s = ready()
        XCTAssertEqual(s.received(Data("hello".utf8)), "hello")
        XCTAssertNil(s.received(Data()))
        XCTAssertNil(s.received(Data([0xFF, 0xFE])), "not UTF-8")
        XCTAssertNil(s.received(Data(repeating: 0x61, count: ClipboardSync.maxBytes + 1)))
        s.wrote(changeCount: 9)
        XCTAssertFalse(s.needsRead(changeCount: 9))
        XCTAssertTrue(s.needsRead(changeCount: 10))
    }

    func testLargestTextFitsBothDirections() {
        XCTAssertEqual(UInt32(ClipboardSync.maxBytes), FrameDecoder.viewerToHostLimit)
        XCTAssertLessThan(UInt32(ClipboardSync.maxBytes), FrameDecoder.hostToViewerLimit)
    }

    func testStateMessageRoundTrip() throws {
        let f = try MessageCodec.frame(.clipboardState, ClipboardState(enabled: true, active: false))
        XCTAssertEqual(try MessageCodec.decode(ClipboardState.self, from: f), ClipboardState(enabled: true, active: false))
    }
}
