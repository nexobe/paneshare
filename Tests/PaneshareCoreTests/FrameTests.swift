import Foundation
import XCTest
@testable import PaneshareCore

final class FrameTests: XCTestCase {
    func testHeaderLayoutIsBigEndianAndTwelveBytes() {
        let frame = Frame(kind: .videoFrame, flags: .keyframe, streamID: 0x0102, payload: Data([0xAA, 0xBB, 0xCC]))
        let bytes = [UInt8](frame.encoded())
        XCTAssertEqual(bytes.count, 12 + 3)
        XCTAssertEqual(Array(bytes[0..<12]), [0x50, 0x57, 0x01, 0x07, 0x01, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00, 0x03])
        XCTAssertEqual(Array(bytes[12...]), [0xAA, 0xBB, 0xCC])
    }

    func testRoundTripSingleFrame() throws {
        let frame = Frame(kind: .hello, streamID: 7, payload: Data("hi".utf8))
        var decoder = FrameDecoder(maxPayload: 1024)
        XCTAssertEqual(try decoder.append(frame.encoded()), [frame])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamingDecodeByteByByte() throws {
        let frames = (0..<5).map { i in
            Frame(kind: .input, streamID: UInt16(i), payload: Data(repeating: UInt8(i), count: i * 37))
        }
        let wire = frames.reduce(Data()) { $0 + $1.encoded() }
        var decoder = FrameDecoder(maxPayload: 1024)
        var out: [Frame] = []
        for byte in wire { out += try decoder.append(Data([byte])) }
        XCTAssertEqual(out, frames)
    }

    func testStreamingDecodeArbitraryChunks() throws {
        var rng = SeededGenerator(seed: 42)
        let frames = (0..<50).map { i in
            Frame(kind: MessageKind.allCases[i % MessageKind.allCases.count], streamID: UInt16(i),
                  payload: Data((0..<Int.random(in: 0...3000, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
        let wire = frames.reduce(Data()) { $0 + $1.encoded() }
        var decoder = FrameDecoder(maxPayload: 4096)
        var out: [Frame] = []
        var i = 0
        while i < wire.count {
            let n = min(Int.random(in: 1...5000, using: &rng), wire.count - i)
            out += try decoder.append(wire.subdata(in: i..<(i + n)))
            i += n
        }
        XCTAssertEqual(out, frames)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testEmptyPayloadFrame() throws {
        var decoder = FrameDecoder(maxPayload: 16)
        let f = Frame(kind: .requestKeyframe, streamID: 3)
        XCTAssertEqual(try decoder.append(f.encoded()), [f])
    }

    func testRejectsBadMagicImmediately() {
        var decoder = FrameDecoder(maxPayload: 1024)
        XCTAssertThrowsError(try decoder.append(Data([0x47]))) { XCTAssertEqual($0 as? FrameError, .badMagic) }
        // Poisoned: later valid input still fails.
        XCTAssertThrowsError(try decoder.append(Frame(kind: .hello).encoded()))
    }

    func testRejectsPlaintextHTTPProbe() {
        var decoder = FrameDecoder(maxPayload: 1024)
        XCTAssertThrowsError(try decoder.append(Data("GET / HTTP/1.1\r\n".utf8)))
    }

    func testRejectsUnknownVersion() {
        var bytes = [UInt8](Frame(kind: .hello).encoded())
        bytes[2] = 2
        var decoder = FrameDecoder(maxPayload: 1024)
        XCTAssertThrowsError(try decoder.append(Data(bytes))) { XCTAssertEqual($0 as? FrameError, .unsupportedVersion(2)) }
    }

    func testRejectsReservedBits() {
        var bytes = [UInt8](Frame(kind: .hello).encoded())
        bytes[4] = 0x80
        var d1 = FrameDecoder(maxPayload: 1024)
        XCTAssertThrowsError(try d1.append(Data(bytes))) { XCTAssertEqual($0 as? FrameError, .reservedBitsSet) }
        bytes[4] = 0; bytes[5] = 1
        var d2 = FrameDecoder(maxPayload: 1024)
        XCTAssertThrowsError(try d2.append(Data(bytes))) { XCTAssertEqual($0 as? FrameError, .reservedBitsSet) }
    }

    func testTopUpFlagRoundTrips() throws {
        let frame = Frame(kind: .videoFrame, flags: .topUp, streamID: 3, payload: Data([1, 2, 3]))
        var decoder = FrameDecoder(maxPayload: 1024)
        let decoded = try decoder.append(frame.encoded())
        XCTAssertEqual(decoded.first?.flags, .topUp)
        XCTAssertFalse(decoded.first?.flags.contains(.keyframe) ?? true)
    }

    func testRejectsOversizePayloadFromHeaderAlone() {
        // Header claims one byte over the limit but only the header arrives: must fail without buffering the body.
        var bytes = [UInt8](Frame(kind: .input).encoded())
        bytes[8] = 0x00; bytes[9] = 0x10; bytes[10] = 0x00; bytes[11] = 0x01
        var decoder = FrameDecoder(maxPayload: FrameDecoder.viewerToHostLimit)
        XCTAssertThrowsError(try decoder.append(Data(bytes))) {
            XCTAssertEqual($0 as? FrameError, .payloadTooLarge(length: 0x100001, limit: 1024 * 1024))
        }
    }

    func testUnknownKindIsSurfacedNotRejected() throws {
        var decoder = FrameDecoder(maxPayload: 16)
        let f = Frame(kindRaw: 0xEE, payload: Data([1]))
        let out = try decoder.append(f.encoded())
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].kind)
        XCTAssertEqual(out[0].kindRaw, 0xEE)
    }

    func testKindRawValuesAreStable() {
        // Protocol v1 constants: changing any of these breaks interop.
        XCTAssertEqual(MessageKind.hello.rawValue, 0x01)
        XCTAssertEqual(MessageKind.videoFrame.rawValue, 0x07)
        XCTAssertEqual(MessageKind.input.rawValue, 0x08)
        XCTAssertEqual(MessageKind.pairBegin.rawValue, 0x10)
        XCTAssertEqual(MessageKind.pairResult.rawValue, 0x11)
        XCTAssertEqual(MessageKind.pairChallenge.rawValue, 0x12)
        XCTAssertEqual(MessageKind.pairResponse.rawValue, 0x13)
        XCTAssertEqual(MessageKind.inputState.rawValue, 0x14)
        XCTAssertEqual(MessageKind.pairStatus.rawValue, 0x15)
        XCTAssertEqual(MessageKind.streamInfo.rawValue, 0x16)
        XCTAssertEqual(Set(MessageKind.allCases.map(\.rawValue)).count, MessageKind.allCases.count)
    }
}

/// Deterministic xorshift generator for reproducible tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
