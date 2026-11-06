import XCTest
@testable import PaneshareCore

final class SessionTests: XCTestCase {
    func testHelloChecks() throws {
        let good = try MessageCodec.frame(.hello, Hello(appVersion: "0.1", deviceName: "Studio", role: .viewer))
        XCTAssertEqual(try SessionRules.checkHello(good, expecting: .viewer).get().deviceName, "Studio")
        XCTAssertEqual(SessionRules.checkHello(good, expecting: .host), .failure(.wrongRole))

        let future = try MessageCodec.frame(.hello, Hello(protocolVersion: 2, appVersion: "9", deviceName: "x", role: .viewer))
        XCTAssertEqual(SessionRules.checkHello(future, expecting: .viewer), .failure(.unsupportedVersion(2)))

        XCTAssertEqual(SessionRules.checkHello(Frame(kind: .requestWindowList), expecting: .viewer), .failure(.notHello))
        XCTAssertEqual(SessionRules.checkHello(Frame(kind: .hello, payload: Data("{".utf8)), expecting: .viewer),
                       .failure(.malformed))
    }

    func testActivityHoldActsOnlyOnFirstAndLast() {
        var hold = ActivityHold()
        XCTAssertFalse(hold.release(), "a stray release does nothing")
        XCTAssertTrue(hold.acquire())
        XCTAssertFalse(hold.acquire())
        XCTAssertFalse(hold.release())
        XCTAssertTrue(hold.release())
        XCTAssertEqual(hold.count, 0)
    }

    func testReconnectBackoff() {
        XCTAssertEqual((0...6).map(SessionRules.reconnectDelay(attempt:)), [0.5, 1, 2, 4, 8, 10, 10])
        XCTAssertEqual(SessionRules.reconnectDelay(attempt: -3), 0.5)
    }

    func testBackoffKeepsGrowingWhenSessionsDropAtOnce() {
        var backoff = ReconnectBackoff()
        var delays: [TimeInterval] = []
        // The host accepts and drops: first with no hello, then just after one.
        for lasted in [nil, 0.01, nil, 1, nil] as [TimeInterval?] {
            delays.append(backoff.nextDelay())
            backoff.sessionEnded(lasted: lasted)
        }
        XCTAssertEqual(delays, [0.5, 1, 2, 4, 8])
    }

    func testBackoffStartsOverAfterAWorkingSession() {
        var backoff = ReconnectBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.sessionEnded(lasted: ReconnectBackoff.stableAfter)
        XCTAssertEqual(backoff.nextDelay(), 0.5)
    }

    func testBackoffStartsOverWhenTheUserStops() {
        var backoff = ReconnectBackoff()
        _ = backoff.nextDelay()
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 0.5)
    }

    func testScrollPhaseMapping() {
        // NSEvent.Phase: began 1, stationary 2, changed 4, ended 8, cancelled 16, mayBegin 32.
        XCTAssertEqual([0, 1, 2, 4, 8, 16, 32].map { EventCodes.scrollPhase(fromNSPhase: $0) }, [0, 1, 2, 2, 4, 8, 128])
        XCTAssertEqual([0, 1, 2, 4, 8, 16].map { EventCodes.momentumPhase(fromNSPhase: $0) }, [0, 1, 2, 2, 3, 3])
    }

    func testModifierMaskKeepsOnlyDeviceIndependentBits() {
        let shiftCommand: UInt64 = (1 << 17) | (1 << 20)
        let deviceDependentLeftShift: UInt64 = 0x02
        XCTAssertEqual((shiftCommand | deviceDependentLeftShift | (1 << 24)) & EventCodes.modifierMask, shiftCommand)
    }

    func testHostAddressParsing() {
        let d: UInt16 = 47821
        XCTAssertEqual(HostAddress.parse("mac-mini.local", defaultPort: d), HostAddress(host: "mac-mini.local", port: d))
        XCTAssertEqual(HostAddress.parse(" 100.64.0.7:5000 ", defaultPort: d), HostAddress(host: "100.64.0.7", port: 5000))
        XCTAssertEqual(HostAddress.parse("[fd7a:115c::1]:6000", defaultPort: d), HostAddress(host: "fd7a:115c::1", port: 6000))
        XCTAssertEqual(HostAddress.parse("[fd7a:115c::1]", defaultPort: d), HostAddress(host: "fd7a:115c::1", port: d))
        XCTAssertEqual(HostAddress.parse("fe80::1", defaultPort: d), HostAddress(host: "fe80::1", port: d))
        XCTAssertEqual(HostAddress.parse("studio.tail1234.ts.net", defaultPort: d)?.display, "studio.tail1234.ts.net:47821")
        XCTAssertEqual(HostAddress.parse("[::1]:1", defaultPort: d)?.display, "[::1]:1")
        for bad in ["", "  ", "host:", "host:0", "host:65536", "host:12a", ":80", "[::1", "[]:5", "[::1]x",
                    "a b", "http://host", "user@host", "[v4only]:5"] {
            XCTAssertNil(HostAddress.parse(bad, defaultPort: d), bad)
        }
    }
}
