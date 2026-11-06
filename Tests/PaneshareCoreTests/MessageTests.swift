import Foundation
import XCTest
@testable import PaneshareCore

final class MessageTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ kind: MessageKind, _ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try MessageCodec.frame(kind, value, streamID: 9)
        var decoder = FrameDecoder(maxPayload: FrameDecoder.hostToViewerLimit)
        let decoded = try decoder.append(frame.encoded())
        XCTAssertEqual(decoded.count, 1, file: file, line: line)
        XCTAssertEqual(decoded[0].kind, kind, file: file, line: line)
        XCTAssertEqual(decoded[0].streamID, 9, file: file, line: line)
        XCTAssertEqual(try MessageCodec.decode(T.self, from: decoded[0]), value, file: file, line: line)
    }

    let window = WindowInfo(windowID: 4242, title: "main.swift — paneshare", appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                            processID: 501, frame: WireRect(x: -1440, y: 25, width: 1200, height: 800))

    func testControlMessagesRoundTrip() throws {
        try roundTrip(.hello, Hello(appVersion: "0.1.0", deviceName: "Studio", role: .host))
        try roundTrip(.windowList, [window])
        try roundTrip(.openWindow, OpenWindow(windowID: 4242, viewerBackingScale: 2))
        try roundTrip(.streamStarted, StreamStarted(streamID: 1, window: window, pointSize: WireSize(width: 1200, height: 800),
                                                    pixelSize: PixelSize(width: 2400, height: 1600), codec: .hevc,
                                                    appIconPNG: Data([0x89, 0x50, 0x4E, 0x47])))
        try roundTrip(.input, InputEvent(kind: .mouseDown, position: NormalizedPoint(x: 0.25, y: 0.75), button: .left, clickCount: 2))
        try roundTrip(.input, InputEvent(kind: .keyDown, keyCode: 0x0D, modifierFlags: 0x100000, isRepeat: false))
        try roundTrip(.resize, ResizeRequest(pointSize: WireSize(width: 900, height: 600)))
        try roundTrip(.resize, ResizeRequest(pointSize: WireSize(width: 900, height: 600), final: false))
        try roundTrip(.resized, Resized(pointSize: WireSize(width: 900, height: 600), pixelSize: PixelSize(width: 1800, height: 1200), final: true))
        try roundTrip(.openWindow, OpenWindow(windowID: 3, viewerBackingScale: 2, quality: .economy))
        try roundTrip(.inputState, InputState(paused: .secureInput))
        try roundTrip(.inputState, InputState(paused: nil))
        try roundTrip(.resized, Resized(pointSize: WireSize(width: 900, height: 600), pixelSize: PixelSize(width: 1800, height: 1200)))
        try roundTrip(.closeStream, CloseStream(reason: .windowClosed))
        try roundTrip(.error, ProtocolErrorMessage(code: "unsupportedVersion", message: "v2"))
        try roundTrip(.pairBegin, PairBegin(viewerName: "MacBook", nonce: Data(repeating: 7, count: 32)))
        try roundTrip(.pairChallenge, PairChallenge(nonce: Data(repeating: 8, count: 32), share: Data(repeating: 9, count: 32)))
        try roundTrip(.pairResponse, PairResponse(share: Data(repeating: 1, count: 32), confirm: Data(repeating: 2, count: 32)))
        try roundTrip(.pairResult, PairResult(accepted: false, reason: .wrongCode))
        try roundTrip(.pairResult, PairResult(accepted: true, hostName: "Studio", confirm: Data(repeating: 3, count: 32)))
        try roundTrip(.pairResult, PairResult(accepted: false, reason: .declined))
        try roundTrip(.pairStatus, PairStatus(state: .prompted))
        try roundTrip(.pairStatus, PairStatus(state: .wrongCode, attemptsLeft: 3))
        try roundTrip(.openWindow, OpenWindow(windowID: 3, viewerBackingScale: 2, quality: .native, chroma: ChromaFormat.viewerDefault))
        try roundTrip(.streamInfo, StreamInfo(sourceScale: 2, sourcePoints: WireSize(width: 1200, height: 800),
                                              capturePixels: PixelSize(width: 2400, height: 1600), captureFormat: "BGRA",
                                              encodedPixels: PixelSize(width: 2400, height: 1600), codec: .hevc, chroma: .yuv444,
                                              profile: "HEVC_Main444_AutoLevel", hardware: true,
                                              bitrate: 34_560_000, topUpBitrate: 276_480_000))
    }

    func testChromaIsSpelledOnTheWire() throws {
        let f = try MessageCodec.frame(.openWindow, OpenWindow(windowID: 1, viewerBackingScale: 2, chroma: [.yuv444, .yuv420]))
        XCTAssertTrue(String(decoding: f.payload, as: UTF8.self).contains(#""chroma":["4:4:4","4:2:0"]"#))
        let old = try MessageCodec.decode(OpenWindow.self, from: Frame(kind: .openWindow, payload: Data(#"{"windowID":5,"viewerBackingScale":2}"#.utf8)))
        XCTAssertNil(old.chroma)
    }

    func testOptionalFieldsFromOlderPeersDecode() throws {
        let open = try MessageCodec.decode(OpenWindow.self, from: Frame(kind: .openWindow, payload: Data(#"{"windowID":5,"viewerBackingScale":2}"#.utf8)))
        XCTAssertNil(open.quality)
        let resize = try MessageCodec.decode(ResizeRequest.self, from: Frame(kind: .resize, payload: Data(#"{"pointSize":{"width":10,"height":20}}"#.utf8)))
        XCTAssertNil(resize.final)
        XCTAssertThrowsError(try MessageCodec.decode(OpenWindow.self, from: Frame(kind: .openWindow,
            payload: Data(#"{"windowID":5,"viewerBackingScale":2,"quality":"ultra"}"#.utf8))))
    }

    func testUnknownJSONFieldsAreIgnored() throws {
        let json = #"{"appVersion":"9","deviceName":"x","protocolVersion":1,"role":"viewer","future":true}"#
        let frame = Frame(kind: .hello, payload: Data(json.utf8))
        XCTAssertEqual(try MessageCodec.decode(Hello.self, from: frame).role, .viewer)
    }

    func testStreamStartedViewOnlyFlagIsOptional() throws {
        let viewOnly = StreamStarted(streamID: 2, window: window, pointSize: WireSize(width: 10, height: 10),
                                     pixelSize: PixelSize(width: 20, height: 20), codec: .h264, inputEnabled: false)
        try roundTrip(.streamStarted, viewOnly)

        var older = viewOnly
        older.inputEnabled = nil
        let frame = try MessageCodec.frame(.streamStarted, older, streamID: 2)
        XCTAssertFalse(String(decoding: frame.payload, as: UTF8.self).contains("inputEnabled"))
        XCTAssertNil(try MessageCodec.decode(StreamStarted.self, from: frame).inputEnabled)
    }

    func testMalformedJSONThrows() {
        let frame = Frame(kind: .hello, payload: Data("{nope".utf8))
        XCTAssertThrowsError(try MessageCodec.decode(Hello.self, from: frame))
    }

    func testParameterSetsRoundTrip() throws {
        let ps = ParameterSets(codec: .hevc, sets: [Data([0x40, 0x01, 0x0C]), Data([0x42, 0x01]), Data([0x44, 0x01, 0xC1, 0x72])])
        XCTAssertEqual(try ParameterSets(decoding: ps.encoded()), ps)
    }

    func testParameterSetsRejectTruncationAndTrailingBytes() {
        let ps = ParameterSets(codec: .h264, sets: [Data([0x67, 0x64]), Data([0x68, 0xEE])]).encoded()
        XCTAssertThrowsError(try ParameterSets(decoding: ps.dropLast()))
        XCTAssertThrowsError(try ParameterSets(decoding: ps + Data([0])))
        XCTAssertThrowsError(try ParameterSets(decoding: Data([0x09, 0x01, 0x00, 0x01, 0xFF]))) // unknown codec
        XCTAssertThrowsError(try ParameterSets(decoding: Data([0x01, 0x00]))) // zero sets
    }

    func testVideoFramePayloadRoundTrip() throws {
        let v = VideoFramePayload(ptsMicros: 0x0102_0304_0506_0708, accessUnit: Data([0, 0, 0, 2, 0x26, 0x01]))
        let encoded = v.encoded()
        XCTAssertEqual(Array(encoded.prefix(8)), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(try VideoFramePayload(decoding: encoded), v)
        XCTAssertThrowsError(try VideoFramePayload(decoding: Data([1, 2, 3])))
    }

    func testWindowDisplayTitle() {
        XCTAssertEqual(window.displayTitle, "Xcode — main.swift — paneshare")
        var untitled = window
        untitled.title = ""
        XCTAssertEqual(untitled.displayTitle, "Xcode")
    }
}

final class PingPayloadTests: XCTestCase {
    func testRoundTripAndLength() {
        let v: UInt64 = 0x0102_0304_0506_0708
        XCTAssertEqual([UInt8](PingPayload.encode(v)), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(PingPayload.decode(PingPayload.encode(v)), v)
        XCTAssertNil(PingPayload.decode(Data([1, 2, 3])))
    }
}
