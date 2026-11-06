import Crypto
import Foundation
import XCTest
@testable import PaneshareCore

final class PairingCodeTests: XCTestCase {
    func testGeneratedCodesAreSixAsciiDigits() {
        var rng = SeededGenerator(seed: 1)
        for _ in 0..<500 {
            let code = PairingCode.generate(using: &rng)
            XCTAssertEqual(code.count, 6)
            XCTAssertEqual(PairingCode.check(code), .success(code))
        }
        XCTAssertEqual(PairingCode.check(PairingCode.generate()).map(\.count), .success(6))
    }

    func testLeadingZerosArePreserved() {
        XCTAssertEqual(PairingCode.format(0), "000000")
        XCTAssertEqual(PairingCode.format(42), "000042")
        XCTAssertEqual(PairingCode.format(999_999), "999999")
    }

    func testCheckNormalizesAndRejectsLength() {
        XCTAssertEqual(PairingCode.grouped("482913"), "482 913")
        XCTAssertEqual(PairingCode.check("482 913"), .success("482913"))
        XCTAssertEqual(PairingCode.check("482-913"), .success("482913"))
        XCTAssertEqual(PairingCode.check("482\u{00A0}913"), .success("482913"))
        XCTAssertEqual(PairingCode.check("12345"), .failure(.length))
        XCTAssertEqual(PairingCode.check("1234567"), .failure(.length))
        XCTAssertEqual(PairingCode.check("12345a"), .failure(.length))
        XCTAssertEqual(PairingCode.check("١٢٣٤٥٦"), .failure(.length)) // non-ASCII digits
    }

    func testDigitsAreRoughlyUniform() {
        var rng = SeededGenerator(seed: 5)
        var counts = [Int](repeating: 0, count: 10)
        for _ in 0..<3000 {
            for ch in PairingCode.generate(using: &rng) { counts[ch.wholeNumberValue!] += 1 }
        }
        let expected = 3000.0 * 6 / 10
        for c in counts { XCTAssertEqual(Double(c), expected, accuracy: expected * 0.1) }
    }
}

final class Curve25519FieldTests: XCTestCase {
    private func element(bigEndianHex hex: String) -> FieldElement {
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        return FieldElement(littleEndian: bytes.reversed())
    }

    func testArithmeticIdentities() {
        let a = element(bigEndianHex: "608d892b641f0328523802a6603427c26e55e6f27e71a91a478148d45b5093cd")
        let b = element(bigEndianHex: "46f5b22494bfeaa7f232cc8d054be68561af50230234d7d1d63d1d9abeca8da5")
        XCTAssertEqual(a * a.inverse, .one)
        XCTAssertEqual((a + b) - b, a)
        XCTAssertEqual(a + (-a), .zero)
        XCTAssertEqual(a * (b + .one), a * b + a)
        XCTAssertEqual(FieldElement.zero.inverse, .zero)
        // p − 1 = −1; (−1)² = 1; −1 is a square mod p (p ≡ 1 mod 4).
        let minusOne = -FieldElement.one
        XCTAssertEqual(minusOne * minusOne, .one)
        XCTAssertTrue(minusOne.isSquare)
        XCTAssertFalse(FieldElement(limbs: [2, 0, 0, 0]).isSquare) // Z = 2 is a non-square
    }

    func testEncodingReducesAndIgnoresTopBit() {
        // 2^255 − 1 with bit 255 set: bit 255 is dropped, then p is subtracted, leaving 18.
        let max = FieldElement(littleEndian: [UInt8](repeating: 0xFF, count: 32))
        XCTAssertEqual(max, FieldElement(limbs: [18, 0, 0, 0]))
        XCTAssertEqual(FieldElement(littleEndian: max.littleEndianBytes), max)
    }

    /// RFC 9380 Appendix J.4.2 (curve25519_XMD:SHA-512_ELL2_NU_): u[0] maps to Q.x.
    func testElligator2MatchesRFC9380Vectors() {
        let vectors = [
            ("608d892b641f0328523802a6603427c26e55e6f27e71a91a478148d45b5093cd",
             "51125222da5e763d97f3c10fcc92ea6860b9ccbbd2eb1285728f566721c1e65b"),
            ("46f5b22494bfeaa7f232cc8d054be68561af50230234d7d1d63d1d9abeca8da5",
             "7d56d1e08cb0ccb92baf069c18c49bb5a0dcd927eff8dcf75ca921ef7f3e6eeb"),
            ("235fe40c443766ce7e18111c33862d66c3b33267efa50d50f9e8e5d252a40aaa",
             "3fbe66b9c9883d79e8407150e7c2a1c8680bee496c62fabe4619a72b3cabe90f"),
            ("001e92a544463bda9bd04ddbe3d6eed248f82de32f522669efc5ddce95f46f5b",
             "227e0bb89de700385d19ec40e857db6e6a3e634b1c32962f370d26f84ff19683"),
        ]
        for (u, qx) in vectors {
            XCTAssertEqual(Elligator2.map(element(bigEndianHex: u)), element(bigEndianHex: qx), u)
        }
    }

    func testElligator2SmallInputs() {
        // −1/2 is a non-square, so 1 + 2u² never vanishes. u = 0 lands on the low-order point 0,
        // which PairingExchange rejects (a hash hitting it is a 2^-254 event).
        XCTAssertFalse((-FieldElement(limbs: [2, 0, 0, 0]).inverse).isSquare)
        XCTAssertEqual(Elligator2.map(.zero), .zero)
        XCTAssertEqual(Elligator2.map(.one),
                       element(bigEndianHex: "555555555555555555555555555555555555555555555555555555555552db9c"))
    }
}

final class PairingExchangeTests: XCTestCase {
    let host = Fingerprint(publicKey: P256.Signing.PrivateKey().publicKey)
    let viewer = Fingerprint(publicKey: P256.Signing.PrivateKey().publicKey)
    let mitm = Fingerprint(publicKey: P256.Signing.PrivateKey().publicKey)
    let code = "482913"

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Vectors from an independent Python implementation (hashlib/hmac, RFC 7748 ladder, the
    /// RFC 9380 map) of docs/ARCHITECTURE.md §4.2: run `python3 scripts/pake-vectors.py`.
    func testFixedVectorsMatchIndependentImplementation() throws {
        let h = try XCTUnwrap(Fingerprint(bytes: Array(0..<32)))
        let v = try XCTUnwrap(Fingerprint(bytes: Array(32..<64)))
        let nonceV = Data(64..<96), nonceH = Data(96..<128)
        XCTAssertEqual(hex(PairingExchange.generator(code: code, channel: h.bytes + v.bytes, session: Array(nonceV + nonceH))),
                       "e22c3e6cc2de704c4f76e0fa5f7abe75b1a7dc7ca62d13f653ae1caeedf01d53")
        let hostSecret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: (0..<32).map { UInt8(0xA0 + $0 % 16) })
        let viewerSecret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: (0..<32).map { UInt8(0xC0 + $0 % 16) })
        let hostSide = try PairingExchange(role: .host, code: code, host: h, viewer: v, viewerNonce: nonceV, hostNonce: nonceH, secret: hostSecret)
        let viewerSide = try PairingExchange(role: .viewer, code: code, host: h, viewer: v, viewerNonce: nonceV, hostNonce: nonceH, secret: viewerSecret)
        XCTAssertEqual(hex(hostSide.share), "3ed0831da132ffe49ca3345bf5e4a90c85853494d7d0bfcfcba1efcd4d52ff39")
        XCTAssertEqual(hex(viewerSide.share), "9a646976f600fe97480398758cdebcb231abb6e5a10d7735ab4292a1e6875466")
        let c = try viewerSide.confirmations(peerShare: hostSide.share)
        XCTAssertEqual(hex(c.viewer), "8714a18b08637f66623c47367d2741480cbd726349aaafcbb90df82769f5ad07")
        XCTAssertEqual(hex(c.host), "ae3197f3692003162586a87f6bd365a4db8cea9941822af61694a3a05569b14b")
        XCTAssertEqual(try hostSide.confirmations(peerShare: viewerSide.share), c)
    }

    private func run(viewerCode: String, hostCode: String, hostSeesViewer: Fingerprint? = nil,
                     viewerSeesHost: Fingerprint? = nil) throws -> (host: PairingExchange.Confirmations, viewer: PairingExchange.Confirmations) {
        let nonceV = PairingExchange.freshNonce(), nonceH = PairingExchange.freshNonce()
        let hostSide = try PairingExchange(role: .host, code: hostCode, host: host, viewer: hostSeesViewer ?? viewer,
                                           viewerNonce: nonceV, hostNonce: nonceH)
        let viewerSide = try PairingExchange(role: .viewer, code: viewerCode, host: viewerSeesHost ?? host, viewer: viewer,
                                             viewerNonce: nonceV, hostNonce: nonceH)
        return (try hostSide.confirmations(peerShare: viewerSide.share), try viewerSide.confirmations(peerShare: hostSide.share))
    }

    func testHonestExchangeAgrees() throws {
        let r = try run(viewerCode: code, hostCode: code)
        XCTAssertEqual(r.host, r.viewer)
        XCTAssertNotEqual(r.host.viewer, r.host.host) // a reflected tag is not the other role's tag
    }

    func testWrongCodeDisagrees() throws {
        let r = try run(viewerCode: "482914", hostCode: code)
        XCTAssertNotEqual(r.host.viewer, r.viewer.viewer)
        XCTAssertNotEqual(r.host.host, r.viewer.host)
    }

    func testRelayInTheMiddleDisagreesEvenWithTheRightCode() throws {
        // The viewer's TLS peer is the relay, and the host's TLS peer is the relay too.
        XCTAssertNotEqual(try run(viewerCode: code, hostCode: code, viewerSeesHost: mitm).host.viewer,
                          try run(viewerCode: code, hostCode: code, viewerSeesHost: mitm).viewer.viewer)
        let r = try run(viewerCode: code, hostCode: code, hostSeesViewer: mitm)
        XCTAssertNotEqual(r.host.viewer, r.viewer.viewer)
    }

    func testFreshSecretsGiveFreshShares() throws {
        let nonce = PairingExchange.freshNonce()
        let a = try PairingExchange(role: .host, code: code, host: host, viewer: viewer, viewerNonce: nonce, hostNonce: nonce)
        let b = try PairingExchange(role: .host, code: code, host: host, viewer: viewer, viewerNonce: nonce, hostNonce: nonce)
        XCTAssertNotEqual(a.share, b.share)
        XCTAssertNotEqual(PairingExchange.freshNonce(), PairingExchange.freshNonce())
    }

    func testRejectsMalformedInputs() throws {
        let n = PairingExchange.freshNonce()
        XCTAssertThrowsError(try PairingExchange(role: .host, code: "12345", host: host, viewer: viewer, viewerNonce: n, hostNonce: n))
        XCTAssertThrowsError(try PairingExchange(role: .host, code: "12345a", host: host, viewer: viewer, viewerNonce: n, hostNonce: n))
        XCTAssertThrowsError(try PairingExchange(role: .host, code: code, host: host, viewer: viewer, viewerNonce: Data(count: 31), hostNonce: n))
        let side = try PairingExchange(role: .host, code: code, host: host, viewer: viewer, viewerNonce: n, hostNonce: n)
        XCTAssertThrowsError(try side.confirmations(peerShare: Data(count: 31)))
        // Low-order shares give an all-zero secret: 0, 1, and the order-8 point from RFC 7748 §6.1.
        XCTAssertThrowsError(try side.confirmations(peerShare: Data(count: 32)))
        XCTAssertThrowsError(try side.confirmations(peerShare: Data([1] + [UInt8](repeating: 0, count: 31))))
        var order8 = [UInt8](repeating: 0, count: 32)
        let hex8 = "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"
        for i in 0..<32 { order8[i] = UInt8(hex8.dropFirst(2 * i).prefix(2), radix: 16)! }
        XCTAssertThrowsError(try side.confirmations(peerShare: Data(order8)))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(PairingExchange.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(PairingExchange.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(PairingExchange.constantTimeEqual(Data([1, 2, 3]), Data([1, 2])))
    }
}

final class PairingGateTests: XCTestCase {
    func testAttemptIsSpentAtChallengeAndOnlyOneInFlight() {
        var gate = PairingGate(openedAt: 0)
        XCTAssertEqual(gate.begin(now: 1), .challenge(attemptsLeft: 4))
        XCTAssertEqual(gate.begin(now: 1), .busy)
        XCTAssertEqual(gate.finish(matched: false), .wrongCode(attemptsLeft: 4))
        XCTAssertEqual(gate.begin(now: 2), .challenge(attemptsLeft: 3))
        gate.abandon() // viewer hung up: the attempt stays spent
        XCTAssertEqual(gate.attemptsLeft, 3)
        XCTAssertEqual(gate.finish(matched: true), .closed) // nothing in flight any more
    }

    func testFiveAttemptsThenLocks() {
        var gate = PairingGate(openedAt: 0)
        for left in stride(from: 4, through: 1, by: -1) {
            XCTAssertEqual(gate.begin(now: 1), .challenge(attemptsLeft: left))
            XCTAssertEqual(gate.finish(matched: false), .wrongCode(attemptsLeft: left))
        }
        XCTAssertEqual(gate.begin(now: 1), .challenge(attemptsLeft: 0))
        XCTAssertEqual(gate.finish(matched: false), .exhausted)
        XCTAssertEqual(gate.begin(now: 1), .exhausted)
        XCTAssertFalse(gate.isOpen(now: 1))
    }

    func testLastAttemptCanStillSucceed() {
        var gate = PairingGate(openedAt: 0)
        for _ in 0..<4 { _ = gate.begin(now: 1); _ = gate.finish(matched: false) }
        XCTAssertEqual(gate.begin(now: 1), .challenge(attemptsLeft: 0))
        XCTAssertEqual(gate.finish(matched: true), .accepted)
    }

    func testExpiresAndIsSingleUse() {
        var late = PairingGate(openedAt: 100)
        XCTAssertTrue(late.isOpen(now: 399))
        XCTAssertEqual(late.begin(now: 400), .expired)
        XCTAssertEqual(late.begin(now: 50), .expired) // clock went backwards

        var once = PairingGate(openedAt: 0)
        XCTAssertEqual(once.begin(now: 1), .challenge(attemptsLeft: 4))
        XCTAssertEqual(once.finish(matched: true), .accepted)
        XCTAssertEqual(once.begin(now: 2), .closed)
        XCTAssertFalse(once.isOpen(now: 2))
    }
}

final class PairRequestLimiterTests: XCTestCase {
    private func peer() -> Fingerprint { Fingerprint(publicKey: P256.Signing.PrivateKey().publicKey) }

    func testOnePromptAtATime() {
        var l = PairRequestLimiter()
        let a = peer(), b = peer()
        XCTAssertEqual(l.request(peer: a, address: "10.0.0.2", now: 0), .prompt)
        XCTAssertEqual(l.request(peer: b, address: "10.0.0.3", now: 1), .busy)
        l.finished(.paired, now: 2)
        XCTAssertEqual(l.request(peer: b, address: "10.0.0.3", now: 3), .prompt)
    }

    func testDeclineCoolsDownTheKeyAndTheAddress() {
        var l = PairRequestLimiter()
        let a = peer()
        XCTAssertEqual(l.request(peer: a, address: "10.0.0.2", now: 0), .prompt)
        l.finished(.declined, now: 10)
        XCTAssertEqual(l.request(peer: a, address: "10.0.0.9", now: 20), .ignore)       // same key, new address
        XCTAssertEqual(l.request(peer: peer(), address: "10.0.0.2", now: 20), .ignore)  // new key, same address
        XCTAssertEqual(l.request(peer: a, address: "10.0.0.2", now: 10 + PairRequestLimiter.cooldown), .prompt)
    }

    func testCancelledRequestsDontCoolDown() {
        var l = PairRequestLimiter()
        let a = peer()
        _ = l.request(peer: a, address: "10.0.0.2", now: 0)
        l.finished(.cancelled, now: 1)
        XCTAssertEqual(l.request(peer: a, address: "10.0.0.2", now: 2), .prompt)
    }

    func testPerAddressAndOverallLimitsWithFreshKeys() {
        var l = PairRequestLimiter()
        for i in 0..<PairRequestLimiter.maxPerAddress {
            XCTAssertEqual(l.request(peer: peer(), address: "10.0.0.66", now: Double(i)), .prompt)
            l.finished(.cancelled, now: Double(i))
        }
        XCTAssertEqual(l.request(peer: peer(), address: "10.0.0.66", now: 5), .ignore)
        var n = 0
        while l.admitsHandshake(now: 6) {
            XCTAssertEqual(l.request(peer: peer(), address: "10.1.0.\(n)", now: 6), .prompt)
            l.finished(.cancelled, now: 6)
            n += 1
        }
        XCTAssertEqual(n + PairRequestLimiter.maxPerAddress, PairRequestLimiter.maxOverall)
        XCTAssertEqual(l.request(peer: peer(), address: "10.2.0.1", now: 7), .ignore)
        XCTAssertTrue(l.admitsHandshake(now: 6 + PairRequestLimiter.window))
        XCTAssertEqual(l.request(peer: peer(), address: "10.0.0.66", now: 6 + PairRequestLimiter.window), .prompt)
    }
}
