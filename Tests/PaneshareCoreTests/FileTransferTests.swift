import Crypto
import XCTest
@testable import PaneshareCore

final class FileTransferTests: XCTestCase {
    func testSafeNameCannotLeaveTheFolder() {
        XCTAssertEqual(FileTransferRules.safeName("report.pdf"), "report.pdf")
        XCTAssertEqual(FileTransferRules.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileTransferRules.safeName("/Users/me/.ssh/authorized_keys"), "authorized_keys")
        XCTAssertEqual(FileTransferRules.safeName("..\\..\\win.ini"), "win.ini")
        XCTAssertEqual(FileTransferRules.safeName(".bashrc"), "bashrc")
        XCTAssertEqual(FileTransferRules.safeName("a\u{0}b\nc:d"), "abcd")
        for bad in ["", "/", "..", "...", "   ", "\u{0}"] { XCTAssertNil(FileTransferRules.safeName(bad), bad) }
        let long = FileTransferRules.safeName(String(repeating: "é", count: 500) + ".txt")
        XCTAssertLessThanOrEqual(long?.utf8.count ?? 999, 200)
        XCTAssertEqual(long?.hasSuffix(".txt"), true)
    }

    func testUniqueNameNeverOverwrites() {
        var taken: Set<String> = []
        func next(_ n: String) -> String {
            let u = FileTransferRules.uniqueName(n) { taken.contains($0) }
            taken.insert(u)
            return u
        }
        XCTAssertEqual(next("a.txt"), "a.txt")
        XCTAssertEqual(next("a.txt"), "a 2.txt")
        XCTAssertEqual(next("a.txt"), "a 3.txt")
        XCTAssertEqual(next("noext"), "noext")
        XCTAssertEqual(next("noext"), "noext 2")
    }

    func testChunkRoundTripAndLimits() throws {
        let c = try XCTUnwrap(FileTransferRules.decodeChunk(FileTransferRules.encodeChunk(id: 0x01020304, bytes: Data([9, 8]))))
        XCTAssertEqual(c.id, 0x01020304)
        XCTAssertEqual(c.bytes, Data([9, 8]))
        XCTAssertNil(FileTransferRules.decodeChunk(Data([1, 2, 3, 4])), "no bytes")
        XCTAssertNil(FileTransferRules.decodeChunk(Data(count: FileTransferRules.chunkBytes + 5)))
        XCTAssertLessThanOrEqual(UInt32(FileTransferRules.chunkBytes + 4), FrameDecoder.viewerToHostLimit)
    }

    func testReceiveCheck() throws {
        let body = Data("hello".utf8)
        let good = FileTransferRules.digestHex(SHA256.hash(data: body))
        var c = FileReceiveCheck(size: 5)
        try c.add(body.prefix(2))
        XCTAssertThrowsError(try c.finish(sha256: good)) { XCTAssertEqual($0 as? FileReceiveCheck.Problem, .incomplete) }
        try c.add(body.dropFirst(2))
        XCTAssertNoThrow(try c.finish(sha256: good))
        XCTAssertThrowsError(try c.finish(sha256: String(repeating: "0", count: 64))) { XCTAssertEqual($0 as? FileReceiveCheck.Problem, .digestMismatch) }
        XCTAssertThrowsError(try c.add(Data([1]))) { XCTAssertEqual($0 as? FileReceiveCheck.Problem, .tooMuch) }
    }

    func testPacerStopsAtTheWindowAndFinishes() {
        let chunk = UInt64(FileTransferRules.chunkBytes)
        var p = FileSendPacer(size: chunk * 6 + 10)
        for _ in 0..<FileTransferRules.windowChunks { XCTAssertEqual(p.next(), Int(chunk)) }
        XCTAssertNil(p.next(), "waits for an acknowledgement")
        p.acknowledge(chunk)
        XCTAssertEqual(p.next(), Int(chunk))
        XCTAssertNil(p.next())
        p.acknowledge(chunk * 5)
        XCTAssertEqual(p.next(), Int(chunk))
        XCTAssertEqual(p.next(), 10)
        XCTAssertTrue(p.isFullySent)
        XCTAssertNil(p.next())
        p.acknowledge(UInt64.max)
        XCTAssertEqual(p.acknowledged, p.size, "never above what was sent")
    }

    func testEmptyFileIsFullySentAtOnce() {
        var p = FileSendPacer(size: 0)
        XCTAssertTrue(p.isFullySent)
        XCTAssertNil(p.next())
    }

    func testUnansweredOfferTimesOut() {
        XCTAssertFalse(FileTransferRules.offerTimedOut(offeredAt: 100, now: 100))
        XCTAssertFalse(FileTransferRules.offerTimedOut(offeredAt: 100, now: 100 + FileTransferRules.offerTimeout - 0.1))
        XCTAssertTrue(FileTransferRules.offerTimedOut(offeredAt: 100, now: 100 + FileTransferRules.offerTimeout))
    }

    /// Both directions use the same messages, so a reply with only the old fields still decodes.
    func testReplyFromEitherDirectionDecodesWithAndWithoutOptionalFields() throws {
        let bare = try JSONDecoder().decode(FileReply.self, from: Data(#"{"id":7,"accepted":false}"#.utf8))
        XCTAssertEqual(bare, FileReply(id: 7, accepted: false))
        let full = FileReply(id: 7, accepted: true, reason: nil, received: 10, done: true)
        XCTAssertEqual(try JSONDecoder().decode(FileReply.self, from: JSONEncoder().encode(full)), full)
    }
}
