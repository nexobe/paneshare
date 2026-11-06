import Crypto
import Foundation
@testable import PaneshareCore
import XCTest

/// Writes what the share-link server would send a browser, made by the real Core code, for
/// `scripts/web-viewer-e2e` to replay to headless Chrome. Skipped unless `PANESHARE_E2E_DIR` points at a
/// directory holding `in.h264` (Annex B, one slice per frame).
final class WebViewerFixtureTests: XCTestCase {
    func testWriteBrowserFixtures() throws {
        guard let dir = ProcessInfo.processInfo.environment["PANESHARE_E2E_DIR"],
              let input = FileManager.default.contents(atPath: dir + "/in.h264") else {
            throw XCTSkip("set PANESHARE_E2E_DIR (see scripts/web-viewer-e2e/run.sh)")
        }
        let out = dir + "/out"
        try? FileManager.default.removeItem(atPath: out)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        var sets: [[UInt8]] = []
        var n = 0
        for nal in Self.annexBUnits([UInt8](input)) {
            let type = nal[0] & 0x1F
            if type == 7 { sets = [nal] } else if type == 8 { sets.append(nal) }
            guard type == 1 || type == 5 else { continue }
            let name = String(format: "%@/%04d", out, n)
            if type == 5 {
                let ps = ParameterSets(codec: .h264, sets: sets.map { Data($0) })
                guard case .text(let config)? = GuestWire.translate(Frame(kind: .parameterSets, payload: ps.encoded())) else {
                    return XCTFail("no decoder config for frame \(n)")
                }
                try config.write(toFile: name + "-config.txt", atomically: true, encoding: .utf8)
            }
            var au = Data()
            au.appendBigEndian(UInt32(nal.count))
            au.append(contentsOf: nal)
            let payload = VideoFramePayload(ptsMicros: UInt64(n) * 33_333, accessUnit: au).encoded()
            guard case .binary(let b)? = GuestWire.translate(Frame(kind: .videoFrame, flags: type == 5 ? .keyframe : [], payload: payload))
            else { return XCTFail("no video message for frame \(n)") }
            try Data(b).write(to: URL(fileURLWithPath: name + "-video.bin"))
            n += 1
        }
        XCTAssertGreaterThan(n, 0)

        var started = GuestNotice(t: "started")
        started.title = "TextEdit — Notes"
        started.pw = 640
        started.ph = 400
        try started.json().write(toFile: dir + "/started.txt", atomically: true, encoding: .utf8)
        let link = "LinkID_0123456789abcd"
        for (name, path) in [("page", "/s/\(link)"), ("js", "/viewer.js"), ("css", "/viewer.css"), ("gone", "/s/nope")] {
            guard case .respond(let r) = WebRouter.route(HTTPRequest(method: "GET", path: path, headers: [:]), isLinkActive: { $0 == link })
            else { return XCTFail(path) }
            try Data(r.encoded()).write(to: URL(fileURLWithPath: "\(dir)/resp-\(name).bin"))
        }
        let web = try WebCertificate(dnsNames: ["localhost"], ipv4: ["127.0.0.1"], now: Date())
        let pem = "-----BEGIN CERTIFICATE-----\n" + Data(web.certificateDER).base64EncodedString(options: .lineLength64Characters)
            + "\n-----END CERTIFICATE-----\n"
        try pem.write(toFile: dir + "/cert.pem", atomically: true, encoding: .utf8)
        try web.privateKey.pemRepresentation.write(toFile: dir + "/key.pem", atomically: true, encoding: .utf8)
    }

    static func annexBUnits(_ b: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var i = 0, start = -1
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 { units.append(Array(b[start..<(i > start && b[i - 1] == 0 ? i - 1 : i)])) }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if start >= 0, start < b.count { units.append(Array(b[start...])) }
        return units.filter { !$0.isEmpty }
    }
}
