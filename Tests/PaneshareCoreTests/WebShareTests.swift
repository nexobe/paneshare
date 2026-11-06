import Crypto
import Foundation
@testable import PaneshareCore
import SwiftASN1
import X509
import XCTest

final class HTTPRequestTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testParsesGETWithHeaders() throws {
        let raw = "GET /s/abc?x=1 HTTP/1.1\r\nHost: 10.0.0.2:47822\r\nUser-Agent: test\r\nHost: evil\r\n\r\nrest"
        let (req, used) = try XCTUnwrap(HTTPRequest.parse(bytes(raw)))
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/s/abc")
        XCTAssertEqual(req.header("HOST"), "10.0.0.2:47822", "first value wins")
        XCTAssertEqual(used, raw.utf8.count - 4)
    }

    func testIncompleteAndLimits() throws {
        XCTAssertNil(try HTTPRequest.parse(bytes("GET / HTTP/1.1\r\nHost: a\r\n")))
        let huge = bytes("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequest.maxHeadSize))
        XCTAssertThrowsError(try HTTPRequest.parse(huge)) { XCTAssertEqual($0 as? HTTPRequest.ParseError, .tooLarge) }
        XCTAssertThrowsError(try HTTPRequest.parse(bytes("GET / HTTP/2\r\n\r\n")))
        XCTAssertThrowsError(try HTTPRequest.parse(bytes("GET noslash HTTP/1.1\r\n\r\n")))
        XCTAssertThrowsError(try HTTPRequest.parse(bytes("get / HTTP/1.1\r\n\r\n")))
        XCTAssertThrowsError(try HTTPRequest.parse(bytes("GET / HTTP/1.1\r\nno colon\r\n\r\n")))
    }

    func testWebSocketUpgradeDetection() throws {
        let raw = "GET /ws HTTP/1.1\r\nHost: h:1\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nOrigin: https://h:1\r\n\r\n"
        let (req, _) = try XCTUnwrap(HTTPRequest.parse(bytes(raw)))
        XCTAssertTrue(req.isWebSocketUpgrade)
        var bad = req
        bad.headers["sec-websocket-version"] = "8"
        XCTAssertFalse(bad.isWebSocketUpgrade)
    }

    func testResponseCarriesSecurityHeaders() {
        let text = String(decoding: HTTPResponse.text(404, "Not Found", "x").encoded(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text.contains("Content-Security-Policy: default-src 'none'; script-src 'self'"))
        XCTAssertTrue(text.contains("Cache-Control: no-store"))
        XCTAssertTrue(text.contains("Content-Length: 1\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nx"))
    }
}

final class WebSocketTests: XCTestCase {
    func testAcceptValueRFCExample() {
        // RFC 6455 §1.3.
        XCTAssertEqual(WebSocketCodec.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testDecodesMaskedHelloAndFragments() throws {
        // RFC 6455 §5.7: masked "Hello", then "Hel" + "lo" fragmented.
        var d = WebSocketCodec.Decoder(maxMessage: 1024)
        let masked: [UInt8] = [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        XCTAssertEqual(try d.append(Array(masked.prefix(5))), [])
        XCTAssertEqual(try d.append(Array(masked.dropFirst(5))), [.text("Hello")])
        func frame(_ b0: UInt8, _ s: String) -> [UInt8] {
            let mask: [UInt8] = [1, 2, 3, 4]
            return [b0, 0x80 | UInt8(s.utf8.count)] + mask + Array(s.utf8).enumerated().map { $1 ^ mask[$0 & 3] }
        }
        XCTAssertEqual(try d.append(frame(0x01, "Hel")), [])
        XCTAssertEqual(try d.append(frame(0x89, "p") + frame(0x80, "lo")), [.ping(Array("p".utf8)), .text("Hello")])
    }

    func testRejectsUnmaskedOversizedAndBadControl() {
        var a = WebSocketCodec.Decoder(maxMessage: 1024)
        XCTAssertThrowsError(try a.append([0x81, 0x05] + Array("Hello".utf8))) { XCTAssertEqual($0 as? WebSocketCodec.DecodeError, .unmasked) }
        XCTAssertThrowsError(try a.append([0x81, 0x80, 0, 0, 0, 0]), "poisoned after an error")
        var b = WebSocketCodec.Decoder(maxMessage: 100)
        XCTAssertThrowsError(try b.append([0x82, 0xFE, 0x01, 0x00])) { XCTAssertEqual($0 as? WebSocketCodec.DecodeError, .tooLarge) }
        var c = WebSocketCodec.Decoder(maxMessage: 100)
        XCTAssertThrowsError(try c.append([0x09, 0x80, 0, 0, 0, 0])) { XCTAssertEqual($0 as? WebSocketCodec.DecodeError, .badControlFrame) }
        var e = WebSocketCodec.Decoder(maxMessage: 100)
        XCTAssertThrowsError(try e.append([0x80, 0x80, 0, 0, 0, 0])) { XCTAssertEqual($0 as? WebSocketCodec.DecodeError, .badContinuation) }
        var f = WebSocketCodec.Decoder(maxMessage: 100)
        XCTAssertThrowsError(try f.append([0x81, 0x81, 0, 0, 0, 0, 0xFF])) { XCTAssertEqual($0 as? WebSocketCodec.DecodeError, .invalidUTF8) }
    }

    func testEncodeLengths() {
        XCTAssertEqual(WebSocketCodec.encode(.text, Array("Hello".utf8)), [0x81, 0x05] + Array("Hello".utf8))
        let mid = WebSocketCodec.encode(.binary, [UInt8](repeating: 7, count: 300))
        XCTAssertEqual(Array(mid.prefix(4)), [0x82, 126, 0x01, 0x2C])
        let big = WebSocketCodec.encode(.binary, [UInt8](repeating: 7, count: 70_000))
        XCTAssertEqual(Array(big.prefix(10)), [0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70])
        XCTAssertEqual(big.count, 70_010)
        XCTAssertEqual(WebSocketCodec.closeFrame(code: 4003), [0x88, 0x02, 0x0F, 0xA3])
    }
}

final class GuestProtocolTests: XCTestCase {
    let sps: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9]
    let pps: [UInt8] = [0x68, 0xEB, 0xE3, 0xCB]

    func testH264DecoderConfig() throws {
        let c = try XCTUnwrap(H264DecoderConfig(parameterSets: [sps, pps]))
        XCTAssertEqual(c.codec, "avc1.640028")
        XCTAssertEqual(c.avcC, [1, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0, 6] + sps + [1, 0, 4] + pps)
        XCTAssertNil(H264DecoderConfig(parameterSets: [sps]), "needs a PPS")
        XCTAssertNil(H264DecoderConfig(parameterSets: [pps]), "needs an SPS")
    }

    func testTranslatesHostFramesForTheBrowser() throws {
        let sets = ParameterSets(codec: .h264, sets: [Data(sps), Data(pps)])
        guard case .text(let config)? = GuestWire.translate(Frame(kind: .parameterSets, streamID: 3, payload: sets.encoded())) else {
            return XCTFail("config expected")
        }
        let notice = try JSONDecoder().decode(GuestNotice.self, from: Data(config.utf8))
        XCTAssertEqual(notice.t, "config")
        XCTAssertEqual(notice.codec, "avc1.640028")
        XCTAssertEqual(notice.description.flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) },
                       H264DecoderConfig(parameterSets: [sps, pps])?.avcC)

        let hevc = ParameterSets(codec: .hevc, sets: [Data([0x40, 1]), Data([0x42, 1]), Data([0x44, 1])])
        XCTAssertNil(GuestWire.translate(Frame(kind: .parameterSets, payload: hevc.encoded())), "browsers get H.264 only")

        let video = VideoFramePayload(ptsMicros: 0x0102, accessUnit: Data([0, 0, 0, 1, 0x65]))
        XCTAssertEqual(GuestWire.translate(Frame(kind: .videoFrame, flags: .keyframe, payload: video.encoded())),
                       .binary([1, 1, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 1, 0x65]))

        let close = try MessageCodec.frame(.closeStream, CloseStream(reason: .windowClosed))
        XCTAssertEqual(GuestWire.translate(close), .close(code: GuestCloseCode.windowClosed.rawValue, reason: "windowClosed"))
        XCTAssertNil(GuestWire.translate(try MessageCodec.frame(.inputState, InputState(paused: .secureInput))))
        let midDrag = try MessageCodec.frame(.resized, Resized(pointSize: WireSize(width: 1, height: 1),
                                                                pixelSize: PixelSize(width: 2, height: 2), final: false))
        XCTAssertNil(GuestWire.translate(midDrag))
    }

    func testInboundDecodingIsBounded() {
        XCTAssertEqual(GuestInbound.decode(#"{"t":"move","x":0.5,"y":0.25,"extra":1}"#)?.x, 0.5)
        XCTAssertNil(GuestInbound.decode("not json"))
        XCTAssertNil(GuestInbound.decode(#"{"t":""# + String(repeating: "a", count: 2000) + #""}"#))
    }

    private func msg(_ t: String, x: Double = 0.5, y: Double = 0.5, b: Int? = 0, c: Int? = nil, dy: Double? = nil) -> GuestInbound {
        var m = GuestInbound(t: t)
        m.x = x; m.y = y; m.b = b; m.c = c; m.dy = dy
        return m
    }

    func testViewOnlyGuestOnlyShowsAPointer() {
        var p = GuestPointer()
        let at = NormalizedPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(p.handle(msg("move"), pointerAllowed: false, now: 0), [.show(at)])
        XCTAssertEqual(p.handle(msg("down"), pointerAllowed: false, now: 0), [.show(at)])
        XCTAssertEqual(p.handle(msg("up"), pointerAllowed: false, now: 0), [.show(at)])
        XCTAssertEqual(p.handle(msg("scroll", dy: 10), pointerAllowed: false, now: 0), [.show(at)])
        XCTAssertNil(p.held)
        XCTAssertEqual(p.handle(GuestInbound(t: "kf"), pointerAllowed: false, now: 0), [.keyframe])
        XCTAssertEqual(p.handle(GuestInbound(t: "leave"), pointerAllowed: false, now: 0), [.hide])
        XCTAssertEqual(p.handle(msg("key"), pointerAllowed: true, now: 0), [], "no keyboard scope at all")
    }

    func testPointerGuestClicksDragsAndScrolls() {
        var p = GuestPointer()
        let at = NormalizedPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(p.handle(msg("move"), pointerAllowed: true, now: 0), [.show(at)], "hover never moves the host's cursor")
        XCTAssertEqual(p.handle(msg("down", c: 2), pointerAllowed: true, now: 0),
                       [.show(at), .inject(InputEvent(kind: .mouseDown, position: at, button: .left, clickCount: 2))])
        XCTAssertEqual(p.handle(msg("move", x: 2, y: -1), pointerAllowed: true, now: 0),
                       [.show(NormalizedPoint(x: 1, y: 0)), .inject(InputEvent(kind: .mouseDrag, position: NormalizedPoint(x: 1, y: 0), button: .left))])
        XCTAssertEqual(p.handle(msg("up", b: 2), pointerAllowed: true, now: 0).count, 1, "a different button's up doesn't release")
        XCTAssertEqual(p.handle(msg("up"), pointerAllowed: true, now: 0),
                       [.show(at), .inject(InputEvent(kind: .mouseUp, position: at, button: .left, clickCount: 1))])
        XCTAssertEqual(p.handle(msg("down", b: 1), pointerAllowed: true, now: 0), [.show(at)], "middle button isn't in scope")
        XCTAssertEqual(p.handle(msg("scroll", dy: 9000), pointerAllowed: true, now: 0),
                       [.show(at), .inject(InputEvent(kind: .scroll, position: at, scrollDeltaX: 0, scrollDeltaY: 2000, scrollUnit: .pixel))])
    }

    func testRevokeReleasesAHeldButtonAndRateLimit() {
        var p = GuestPointer()
        _ = p.handle(msg("down"), pointerAllowed: true, now: 0)
        XCTAssertEqual(p.revoke(), [InputEvent(kind: .mouseUp, position: NormalizedPoint(x: 0.5, y: 0.5), button: .left, clickCount: 1)])
        XCTAssertEqual(p.revoke(), [])
        var q = GuestPointer()
        var shown = 0
        for _ in 0..<(GuestPointer.maxPerSecond + 50) { shown += q.handle(msg("move"), pointerAllowed: false, now: 5).count }
        XCTAssertEqual(shown, GuestPointer.maxPerSecond)
        XCTAssertEqual(q.handle(msg("move"), pointerAllowed: false, now: 6.1).count, 1, "a new second starts a new budget")
    }
}

final class ShareLinkStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testRedeemOnceThenResume() throws {
        var s = ShareLinkStore()
        let (link, token) = try s.create(windowID: 7, windowTitle: "Notes", lifetime: 3600, pointerAllowed: false, now: t0)
        XCTAssertTrue(Base64URL.isWellFormed(link.id) && Base64URL.isWellFormed(token))
        XCTAssertEqual(token.count, 43, "256-bit token")
        XCTAssertNotNil(s.activeLink(id: link.id, now: t0))
        guard case .success(let (session, secret)) = s.redeem(linkID: link.id, token: token, name: "Ann\u{7}\u{202E}", address: "10.0.0.5", now: t0)
        else { return XCTFail("redeem") }
        XCTAssertEqual(session.name, "Ann", "control and bidi-override characters stripped")
        XCTAssertEqual(s.redeem(linkID: link.id, token: token, name: "Bob", address: "x", now: t0).failureValue, .alreadyUsed)
        XCTAssertEqual(s.resume(sessionID: session.id, secret: secret, now: t0 + 60).successValue, session)
        XCTAssertEqual(s.resume(sessionID: session.id, secret: "wrong", now: t0).failureValue, .unknownSession)
        XCTAssertEqual(s.resume(sessionID: session.id, secret: secret, now: t0 + 3600).failureValue, .expired)
        XCTAssertFalse(s.links.contains { String(describing: $0).contains(token) }, "only the digest is stored")
    }

    func testWrongTokensBurnTheLink() throws {
        var s = ShareLinkStore()
        let (link, token) = try s.create(windowID: 1, windowTitle: "", lifetime: 600, pointerAllowed: false, now: t0)
        for _ in 0..<(ShareLinkStore.maxFailedAttempts - 1) {
            XCTAssertEqual(s.redeem(linkID: link.id, token: "guess", name: "", address: "", now: t0).failureValue, .badToken)
        }
        XCTAssertEqual(s.redeem(linkID: link.id, token: "guess", name: "", address: "", now: t0).failureValue, .badToken)
        XCTAssertEqual(s.redeem(linkID: link.id, token: token, name: "", address: "", now: t0).failureValue, .unknownLink)
    }

    func testBurningALinkHandsOverItsGuests() throws {
        var s = ShareLinkStore()
        let (link, token) = try s.create(windowID: 1, windowTitle: "", lifetime: 600, pointerAllowed: false, now: t0)
        let (other, otherToken) = try s.create(windowID: 2, windowTitle: "", lifetime: 600, pointerAllowed: false, now: t0)
        let guest = try XCTUnwrap(s.redeem(linkID: link.id, token: token, name: "", address: "", now: t0).successValue)
        let bystander = try XCTUnwrap(s.redeem(linkID: other.id, token: otherToken, name: "", address: "", now: t0).successValue)
        for _ in 0..<(ShareLinkStore.maxFailedAttempts - 1) {
            _ = s.redeem(linkID: link.id, token: "guess", name: "", address: "", now: t0)
            XCTAssertEqual(s.takeBurned(), [], "the link isn't burned yet")
        }
        _ = s.redeem(linkID: link.id, token: "guess", name: "", address: "", now: t0)
        XCTAssertEqual(s.takeBurned(), [guest.session])
        XCTAssertEqual(s.takeBurned(), [], "each session is handed over once")
        XCTAssertEqual(s.resume(sessionID: guest.session.id, secret: guest.secret, now: t0).failureValue, .unknownSession)
        XCTAssertEqual(s.sessions, [bystander.session])
    }

    func testExpiryKickRevokeAndLimits() throws {
        var s = ShareLinkStore()
        let (a, ta) = try s.create(windowID: 1, windowTitle: "A", lifetime: 900, pointerAllowed: true, now: t0)
        let (b, tb) = try s.create(windowID: 2, windowTitle: "B", lifetime: 3600, pointerAllowed: false, now: t0)
        let sa = try XCTUnwrap(s.redeem(linkID: a.id, token: ta, name: "", address: "", now: t0).successValue)
        XCTAssertEqual(sa.session.name, "Guest")
        let sb = try XCTUnwrap(s.redeem(linkID: b.id, token: tb, name: "B", address: "", now: t0).successValue)
        XCTAssertEqual(s.redeem(linkID: a.id, token: ta, name: "", address: "", now: t0 + 900).failureValue, .expired)
        XCTAssertNil(s.activeLink(id: a.id, now: t0 + 900))
        XCTAssertEqual(s.expire(now: t0 + 901).map(\.id), [sa.session.id])
        XCTAssertEqual(s.links.map(\.id), [b.id])
        XCTAssertEqual(s.kick(sessionID: sb.session.id)?.id, sb.session.id)
        XCTAssertEqual(s.resume(sessionID: sb.session.id, secret: sb.secret, now: t0).failureValue, .unknownSession)
        s.setPointerAllowed(true, linkID: b.id)
        XCTAssertEqual(s.links.first?.pointerAllowed, true)
        XCTAssertEqual(s.revoke(windowID: 2), [])
        XCTAssertTrue(s.links.isEmpty)
        XCTAssertThrowsError(try s.create(windowID: 1, windowTitle: "", lifetime: 2 * ShareLinkStore.maxLifetime, pointerAllowed: false, now: t0))
        for i in 0..<ShareLinkStore.maxLinks { _ = try s.create(windowID: UInt32(i), windowTitle: "", lifetime: 60, pointerAllowed: false, now: t0) }
        XCTAssertThrowsError(try s.create(windowID: 99, windowTitle: "", lifetime: 60, pointerAllowed: false, now: t0)) {
            XCTAssertEqual($0 as? ShareLinkStore.CreateError, .tooManyLinks)
        }
    }

    func testAddressesAndURL() {
        let ranked = ShareAddresses.rank(ipv4: ["192.168.1.20", "8.8.8.8", "100.101.102.103", "169.254.1.1", "172.20.0.1", "192.168.1.20"],
                                         localHostName: "Studio")
        XCTAssertEqual(ranked.map(\.host), ["100.101.102.103", "192.168.1.20", "172.20.0.1", "Studio.local"])
        XCTAssertNil(ShareAddresses.kind(ofIPv4: "100.63.0.1"), "outside Tailscale's CGNAT range")
        XCTAssertEqual(ShareAddresses.url(host: "10.0.0.2", port: 47822, linkID: "L", token: "T"), "https://10.0.0.2:47822/s/L#T")
        XCTAssertEqual(ShareAddresses.url(host: "fd7a::1", port: 1, linkID: "L", token: "T"), "https://[fd7a::1]:1/s/L#T")
    }
}

final class WebRouterTests: XCTestCase {
    private func get(_ path: String, _ headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, headers: headers)
    }

    func testRoutes() {
        let live: (String) -> Bool = { $0 == "abcDEF_-12" }
        guard case .respond(let page) = WebRouter.route(get("/s/abcDEF_-12"), isLinkActive: live) else { return XCTFail() }
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.contentType, "text/html; charset=utf-8")
        guard case .respond(let gone) = WebRouter.route(get("/s/other"), isLinkActive: live) else { return XCTFail() }
        XCTAssertEqual(gone.status, 404)
        guard case .respond(let traversal) = WebRouter.route(get("/s/../etc"), isLinkActive: { _ in true }) else { return XCTFail() }
        XCTAssertEqual(traversal.status, 404)
        guard case .respond(let js) = WebRouter.route(get("/viewer.js"), isLinkActive: live) else { return XCTFail() }
        XCTAssertEqual(js.contentType, "text/javascript; charset=utf-8")
        guard case .respond(let post) = WebRouter.route(HTTPRequest(method: "POST", path: "/ws", headers: [:]), isLinkActive: live)
        else { return XCTFail() }
        XCTAssertEqual(post.status, 405)
    }

    func testWebSocketNeedsSameOrigin() {
        var h = ["upgrade": "websocket", "connection": "Upgrade", "sec-websocket-version": "13",
                 "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==", "host": "10.0.0.2:47822", "origin": "https://10.0.0.2:47822"]
        XCTAssertEqual(WebRouter.route(get("/ws", h), isLinkActive: { _ in false }), .upgrade(key: "dGhlIHNhbXBsZSBub25jZQ=="))
        h["origin"] = "https://evil.example"
        guard case .respond(let r) = WebRouter.route(get("/ws", h), isLinkActive: { _ in false }) else { return XCTFail() }
        XCTAssertEqual(r.status, 403)
        h["origin"] = nil
        guard case .respond(let r2) = WebRouter.route(get("/ws", h), isLinkActive: { _ in false }) else { return XCTFail() }
        XCTAssertEqual(r2.status, 403)
    }

    func testAssetsHaveNoInlineScriptOrEval() {
        XCTAssertFalse(WebViewerAssets.html.contains("<script>"), "CSP allows only /viewer.js")
        XCTAssertFalse(WebViewerAssets.html.contains("style="))
        XCTAssertFalse(WebViewerAssets.js.contains("eval("))
        XCTAssertTrue(WebViewerAssets.css.hasPrefix("[hidden] { display: none !important; }"),
                      "`form { display: flex }` would otherwise keep a hidden form on screen")
        XCTAssertFalse(WebViewerAssets.js.contains("innerHTML"), "guest-visible text is set with textContent")
        XCTAssertTrue(WebViewerAssets.js.contains("history.replaceState"), "the token leaves the address bar")
        for code in [4001, 4002, 4003, 4004, 4005, 4006, 4007, 4008] {
            XCTAssertNotNil(GuestCloseCode(rawValue: UInt16(code)))
            XCTAssertTrue(WebViewerAssets.js.contains("\(code):"), "the page explains close code \(code)")
        }
    }
}

final class WebCertificateTests: XCTestCase {
    func testSelfSignedServerCertificateWithSANs() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let web = try WebCertificate(dnsNames: ["Studio.local", "localhost"], ipv4: ["192.168.1.20", "bogus"], now: now)
        let cert = try Certificate(derEncoded: web.certificateDER)
        XCTAssertEqual(cert.notValidAfter.timeIntervalSince(now), WebCertificate.lifetime, accuracy: 1)
        XCTAssertLessThan(cert.notValidBefore, now)
        let san = try XCTUnwrap(cert.extensions.subjectAlternativeNames)
        XCTAssertEqual(Array(san), [.dnsName("Studio.local"), .dnsName("localhost"),
                                    .ipAddress(ASN1OctetString(contentBytes: [192, 168, 1, 20]))])
        XCTAssertEqual(try cert.extensions.basicConstraints, .notCertificateAuthority)
        XCTAssertEqual(try cert.extensions.extendedKeyUsage.map(Array.init), [.serverAuth])
        XCTAssertEqual(web.sha256.count, 32 * 3 - 1)
        XCTAssertNotEqual(try WebCertificate(dnsNames: [], ipv4: [], now: now).privateKey.rawRepresentation,
                          web.privateKey.rawRepresentation, "a fresh key each time")
    }
}

private extension Result {
    var successValue: Success? { if case .success(let v) = self { return v }; return nil }
    var failureValue: Failure? { if case .failure(let e) = self { return e }; return nil }

    func testLinksCanLastOneWeekButNoLonger() throws {
        var s = ShareLinkStore()
        let week: TimeInterval = 7 * 24 * 60 * 60
        XCTAssertEqual(ShareLinkStore.lifetimes.last, week)
        XCTAssertEqual(ShareLinkStore.lifetimes.max(), ShareLinkStore.maxLifetime)
        XCTAssertEqual(ShareLinkStore.defaultLifetime, 60 * 60)
        let now = Date()
        XCTAssertEqual(try s.create(windowID: 1, windowTitle: "", lifetime: week, pointerAllowed: false, now: now).link.expiresAt,
                       now.addingTimeInterval(week))
        XCTAssertThrowsError(try s.create(windowID: 1, windowTitle: "", lifetime: week + 1, pointerAllowed: false, now: now))
    }
}
