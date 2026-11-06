import Crypto
import Foundation
import XCTest
@testable import PaneshareCore
import PaneshareDockLink

final class HelperBundlePlanTests: XCTestCase {
    func testNamingAndInfoPlist() throws {
        let host = try XCTUnwrap(Fingerprint(bytes: Array(repeating: 0xAB, count: 32)))
        let short = host.shortID.lowercased()
        let plan = HelperBundlePlan(host: host, hostName: "Studio", remoteBundleID: "com.apple.dt.Xcode",
                                    remoteAppName: "Xcode", mainBundleID: "dev.paneshare.app")
        XCTAssertEqual(plan.bundleIdentifier, "dev.paneshare.dock.\(short).com-apple-dt-xcode")
        XCTAssertEqual(plan.bundleName, "Xcode on Studio")
        XCTAssertEqual(plan.relativePath, "\(short)/com-apple-dt-xcode/Xcode on Studio.app")
        XCTAssertEqual(plan.infoPlist["CFBundleExecutable"], .string("paneshare-dock-helper"))
        XCTAssertEqual(plan.infoPlist["CFBundlePackageType"], .string("APPL"))
        XCTAssertEqual(plan.infoPlist["LSMultipleInstancesProhibited"], .bool(true))
        XCTAssertEqual(plan.infoPlist[HelperBundlePlan.hostIDKey], .string(host.hex))
        XCTAssertEqual(plan.infoPlist[HelperBundlePlan.remoteBundleIDKey], .string("com.apple.dt.Xcode"))
        XCTAssertEqual(plan.infoPlist[HelperBundlePlan.mainBundleIDKey], .string("dev.paneshare.app"))
        // The helper shares the main app's prefix, so the host's window policy never offers one.
        XCTAssertTrue(plan.bundleIdentifier.hasPrefix("dev.paneshare."))
    }

    func testHostileNamesStayInsideTheirDirectory() throws {
        let host = try XCTUnwrap(Fingerprint(bytes: Array(repeating: 0xAB, count: 32)))
        let weird = HelperBundlePlan(host: host, hostName: "../../evil", remoteBundleID: "",
                                     remoteAppName: "Ünïcode / App: 2", mainBundleID: "dev.paneshare.app")
        XCTAssertEqual(weird.bundleIdentifier.split(separator: ".").last, "n-code-app-2")
        XCTAssertFalse(weird.relativePath.contains(".."))
        XCTAssertEqual(weird.relativePath.split(separator: "/").count, 3)
        let empty = HelperBundlePlan(host: host, hostName: "", remoteBundleID: "", remoteAppName: "",
                                     mainBundleID: "dev.paneshare.app")
        XCTAssertTrue(empty.bundleIdentifier.hasSuffix(".app"))
        XCTAssertEqual(empty.bundleName, "Remote App on \(host.shortID)")
    }

    func testInfoPlistXMLIsValidAndDeterministic() throws {
        let host = try XCTUnwrap(Fingerprint(bytes: Array(repeating: 1, count: 32)))
        let plan = HelperBundlePlan(host: host, hostName: "A & B <Mac>", remoteBundleID: "com.example.app",
                                    remoteAppName: "Example", mainBundleID: "dev.paneshare.app")
        let xml = PlistValue.dict(plan.infoPlist).xmlDocument
        XCTAssertEqual(xml, PlistValue.dict(plan.infoPlist).xmlDocument)
        let parsed = try XCTUnwrap(PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any])
        XCTAssertEqual(parsed["CFBundleName"] as? String, "Example on A & B <Mac>")
        XCTAssertEqual(parsed["LSMultipleInstancesProhibited"] as? Bool, true)
        XCTAssertEqual(parsed.count, plan.infoPlist.count)
    }

    func testDeveloperIDBuildsAddTeamAndUpdatePolicy() throws {
        let host = try XCTUnwrap(Fingerprint(bytes: Array(repeating: 2, count: 32)))
        let local = HelperBundlePlan(host: host, hostName: "Studio", remoteBundleID: "com.example.app",
                                     remoteAppName: "Example", mainBundleID: "dev.paneshare.app")
        XCTAssertNil(local.infoPlist[HelperBundlePlan.mainTeamIDKey])
        XCTAssertNil(local.infoPlist["NSUpdateSecurityPolicy"])

        let signed = HelperBundlePlan(host: host, hostName: "Studio", remoteBundleID: "com.example.app",
                                      remoteAppName: "Example", mainBundleID: "dev.paneshare.app", mainTeamID: "AB12CD34EF")
        XCTAssertEqual(signed.infoPlist[HelperBundlePlan.mainTeamIDKey], .string("AB12CD34EF"))
        XCTAssertEqual(signed.infoPlist["NSUpdateSecurityPolicy"],
                       .dict(["AllowProcesses": .dict(["AB12CD34EF": .array([.string("dev.paneshare.app")])])]))
        let xml = PlistValue.dict(signed.infoPlist).xmlDocument
        let parsed = try XCTUnwrap(PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any])
        let policy = try XCTUnwrap(parsed["NSUpdateSecurityPolicy"] as? [String: Any])
        XCTAssertEqual((policy["AllowProcesses"] as? [String: [String]])?["AB12CD34EF"], ["dev.paneshare.app"])

        // Anything that isn't a Team ID never reaches the plist or a requirement string.
        for bad in ["ab12cd34ef", "AB12CD34E", "AB12CD34EF1", "AB12CD\"4EF", ""] {
            let p = HelperBundlePlan(host: host, hostName: "S", remoteBundleID: "a", remoteAppName: "a",
                                     mainBundleID: "dev.paneshare.app", mainTeamID: bad)
            XCTAssertNil(p.mainTeamID, bad)
            XCTAssertNil(DockLinkTrust.mainAppRequirement(mainBundleID: "dev.paneshare.app", teamID: bad), bad)
        }
        XCTAssertEqual(DockLinkTrust.mainAppRequirement(mainBundleID: "dev.paneshare.app", teamID: "AB12CD34EF"),
                       "anchor apple generic and identifier \"dev.paneshare.app\" and certificate leaf[subject.OU] = \"AB12CD34EF\"")
        XCTAssertNil(DockLinkTrust.mainAppRequirement(mainBundleID: "dev\" or true", teamID: "AB12CD34EF"))
    }
}

/// A minimal arm64 MH_EXECUTE: __TEXT (two pages), __LINKEDIT, and a reserved signature.
private func syntheticMachO(oldSignatureSize: Int = 0x40) -> Data {
    var b: [UInt8] = []
    func u32(_ v: UInt32) { b += withUnsafeBytes(of: v.littleEndian, Array.init) }
    func u64(_ v: UInt64) { b += withUnsafeBytes(of: v.littleEndian, Array.init) }
    func name(_ s: String) { b += Array(s.utf8) + [UInt8](repeating: 0, count: 16 - s.utf8.count) }
    let dataoff: UInt64 = 0x8030
    u32(0xFEED_FACF); u32(0x0100_000C); u32(0); u32(2); u32(3); u32(72 + 72 + 16); u32(0); u32(0)
    u32(0x19); u32(72); name("__TEXT"); u64(0x1_0000_0000); u64(0x8000); u64(0); u64(0x8000); u32(5); u32(5); u32(0); u32(0)
    u32(0x19); u32(72); name("__LINKEDIT"); u64(0x1_0000_8000); u64(0x4000); u64(0x8000)
    u64(dataoff - 0x8000 + UInt64(oldSignatureSize)); u32(1); u32(1); u32(0); u32(0)
    u32(0x1D); u32(16); u32(UInt32(dataoff)); u32(UInt32(oldSignatureSize))
    while b.count < Int(dataoff) { b.append(UInt8(truncatingIfNeeded: b.count &* 31)) }
    b += [UInt8](repeating: 0xEE, count: oldSignatureSize)
    return Data(b)
}

final class AdHocSignerTests: XCTestCase {
    private func be32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
    private func be64(_ b: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(b[o + $1]) } }
    private func le32(_ b: [UInt8], _ o: Int) -> Int { (0..<4).reduce(0) { $0 | Int(b[o + $1]) << (8 * $1) } }
    private func le64(_ b: [UInt8], _ o: Int) -> UInt64 { (0..<4 * 2).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }

    func testSignatureLayoutAndHashes() throws {
        let info = Data("<plist/>".utf8), resources = Data("seal".utf8)
        let signed = try AdHocSigner.sign(executable: syntheticMachO(), identifier: "dev.paneshare.dock.x.y",
                                          infoPlist: info, codeResources: resources)
        let out = [UInt8](signed.executable)
        // Load commands: signature at 0x8030 with the new size; __LINKEDIT grown to cover it.
        let sigCmd = 32 + 72 + 72
        let dataoff = le32(out, sigCmd + 8), datasize = le32(out, sigCmd + 12)
        XCTAssertEqual(dataoff, 0x8030)
        XCTAssertEqual(out.count, dataoff + datasize)
        XCTAssertEqual(datasize % 16, 0)
        let linkedit = 32 + 72
        XCTAssertEqual(le64(out, linkedit + 48), UInt64(dataoff + datasize - 0x8000))
        XCTAssertEqual(le64(out, linkedit + 32) % 0x4000, 0)
        XCTAssertGreaterThanOrEqual(le64(out, linkedit + 32), le64(out, linkedit + 48))

        // SuperBlob → CodeDirectory, requirements, CMS.
        let sb = Array(out[dataoff...])
        XCTAssertEqual(be32(sb, 0), 0xFADE_0CC0)
        XCTAssertEqual(be32(sb, 8), 3)
        XCTAssertEqual([be32(sb, 12), be32(sb, 20), be32(sb, 28)], [0, 2, 0x10000])
        let cdStart = be32(sb, 16), reqStart = be32(sb, 24), cmsStart = be32(sb, 32)
        XCTAssertEqual(Array(sb[reqStart..<reqStart + 12]), [0xFA, 0xDE, 0x0C, 0x01, 0, 0, 0, 12, 0, 0, 0, 0])
        XCTAssertEqual(Array(sb[cmsStart..<cmsStart + 8]), [0xFA, 0xDE, 0x0B, 0x01, 0, 0, 0, 8])
        let cdLength = be32(sb, cdStart + 4)
        let cd = Array(sb[cdStart..<cdStart + cdLength])
        XCTAssertEqual(be32(cd, 0), 0xFADE_0C02)
        XCTAssertEqual(be32(cd, 8), 0x20400)
        XCTAssertEqual(be32(cd, 12), 0x2) // ad hoc, and no longer "linker signed"
        let hashOffset = be32(cd, 16), identOffset = be32(cd, 20)
        let nSpecial = be32(cd, 24), nCode = be32(cd, 28), codeLimit = be32(cd, 32)
        XCTAssertEqual(identOffset, 88)
        XCTAssertEqual(Array(cd[36..<40]), [32, 2, 0, 12])
        XCTAssertEqual(codeLimit, dataoff)
        XCTAssertEqual(nCode, (dataoff + 4095) / 4096)
        XCTAssertEqual(nSpecial, 3)
        XCTAssertEqual(be64(cd, 64), 0) // execSegBase = __TEXT fileoff
        XCTAssertEqual(be64(cd, 72), 0x8000) // execSegLimit = __TEXT filesize
        XCTAssertEqual(be64(cd, 80), 1) // main binary
        let identEnd = cd[identOffset...].firstIndex(of: 0)!
        XCTAssertEqual(String(decoding: cd[identOffset..<identEnd], as: UTF8.self), "dev.paneshare.dock.x.y")
        func slot(_ i: Int) -> [UInt8] { Array(cd[hashOffset + 32 * i..<hashOffset + 32 * i + 32]) }
        XCTAssertEqual(slot(-1), Array(SHA256.hash(data: info)))
        XCTAssertEqual(slot(-2), Array(SHA256.hash(data: Data(sb[reqStart..<reqStart + 12]))))
        XCTAssertEqual(slot(-3), Array(SHA256.hash(data: resources)))
        for page in 0..<nCode {
            let range = page * 4096..<min((page + 1) * 4096, codeLimit)
            XCTAssertEqual(slot(page), Array(SHA256.hash(data: out[range])), "page \(page)")
        }
        XCTAssertEqual(signed.cdhash, Array(SHA256.hash(data: cd).prefix(20)))
        XCTAssertEqual(signed.cdhashHex.count, 40)
    }

    func testResigningIsStableAndBindsInputs() throws {
        let first = try AdHocSigner.sign(executable: syntheticMachO(), identifier: "a", infoPlist: Data("1".utf8), codeResources: nil)
        let again = try AdHocSigner.sign(executable: first.executable, identifier: "a", infoPlist: Data("1".utf8), codeResources: nil)
        XCTAssertEqual(first.executable, again.executable)
        XCTAssertEqual(first.cdhash, again.cdhash)
        // A larger old signature is replaced, not kept.
        let fromBig = try AdHocSigner.sign(executable: syntheticMachO(oldSignatureSize: 0x400), identifier: "a",
                                           infoPlist: Data("1".utf8), codeResources: nil)
        XCTAssertEqual(fromBig.cdhash, first.cdhash)
        let otherPlist = try AdHocSigner.sign(executable: syntheticMachO(), identifier: "a", infoPlist: Data("2".utf8), codeResources: nil)
        let otherName = try AdHocSigner.sign(executable: syntheticMachO(), identifier: "b", infoPlist: Data("1".utf8), codeResources: nil)
        XCTAssertNotEqual(first.cdhash, otherPlist.cdhash)
        XCTAssertNotEqual(first.cdhash, otherName.cdhash)
    }

    func testRejectsWhatItCannotSign() {
        XCTAssertThrowsError(try AdHocSigner.sign(executable: Data([0xCA, 0xFE, 0xBA, 0xBE] + [UInt8](repeating: 0, count: 60)),
                                                  identifier: "a", infoPlist: nil, codeResources: nil)) {
            XCTAssertEqual($0 as? AdHocSigner.Failure, .fatBinary)
        }
        XCTAssertThrowsError(try AdHocSigner.sign(executable: Data("#!/bin/sh\necho hi\n".utf8) + Data(count: 40),
                                                  identifier: "a", infoPlist: nil, codeResources: nil)) {
            XCTAssertEqual($0 as? AdHocSigner.Failure, .notMachO)
        }
        var noSlot = [UInt8](syntheticMachO())
        noSlot[16] = 2 // drop LC_CODE_SIGNATURE from ncmds
        XCTAssertThrowsError(try AdHocSigner.sign(executable: Data(noSlot), identifier: "a", infoPlist: nil, codeResources: nil)) {
            XCTAssertEqual($0 as? AdHocSigner.Failure, .noSignatureCommand)
        }
        var truncated = [UInt8](syntheticMachO())
        truncated[20] = 0xFF; truncated[21] = 0xFF // sizeofcmds past the end
        XCTAssertThrowsError(try AdHocSigner.sign(executable: Data(truncated.prefix(200)), identifier: "a", infoPlist: nil, codeResources: nil))
    }
}

final class BundleSealTests: XCTestCase {
    func testCodeResourcesListsResourcesWithBothHashes() throws {
        let icon = Data("icon bytes".utf8)
        let xml = BundleSeal.codeResources(resources: ["Resources/AppIcon.icns": icon])
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any])
        let files = try XCTUnwrap(plist["files"] as? [String: Any])
        XCTAssertEqual(files["Resources/AppIcon.icns"] as? Data, Data(Insecure.SHA1.hash(data: icon)))
        let files2 = try XCTUnwrap(plist["files2"] as? [String: [String: Any]])
        XCTAssertEqual(files2["Resources/AppIcon.icns"]?["hash2"] as? Data, Data(SHA256.hash(data: icon)))
        let rules2 = try XCTUnwrap(plist["rules2"] as? [String: Any])
        XCTAssertEqual((rules2["^Info\\.plist$"] as? [String: Any])?["omit"] as? Bool, true)
        XCTAssertNotNil(plist["rules"])
    }

    func testICNSContainer() {
        let out = [UInt8](ICNSWriter.icns(pngs: [("ic07", Data([1, 2, 3])), ("ic08", Data([4])), ("bad", Data([9]))]))
        XCTAssertEqual(Array(out[0..<4]), Array("icns".utf8))
        XCTAssertEqual(Int(out[4]) << 24 | Int(out[5]) << 16 | Int(out[6]) << 8 | Int(out[7]), out.count)
        XCTAssertEqual(out.count, 8 + (8 + 3) + (8 + 1))
        XCTAssertEqual(Array(out[8..<12]), Array("ic07".utf8))
        XCTAssertEqual(Array(out[12..<16]), [0, 0, 0, 11])
        XCTAssertEqual(Array(out[16..<19]), [1, 2, 3])
        XCTAssertEqual(Array(out[19..<23]), Array("ic08".utf8))
    }
}

final class DockHelperLedgerTests: XCTestCase {
    func testStaleRules() throws {
        let a = try XCTUnwrap(Fingerprint(bytes: Array(repeating: 1, count: 32)))
        let b = try XCTUnwrap(Fingerprint(bytes: Array(repeating: 2, count: 32)))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-DockHelperLedger.idleLimit - 1)
        func plan(_ host: Fingerprint, _ app: String) -> HelperBundlePlan {
            HelperBundlePlan(host: host, hostName: "H", remoteBundleID: app, remoteAppName: app, mainBundleID: "m")
        }
        var ledger = DockHelperLedger()
        ledger.record(plan(a, "fresh"), cdhash: "00", now: now)
        ledger.record(plan(a, "idle"), cdhash: "01", now: old)
        ledger.record(plan(a, "pinned"), cdhash: "02", now: old)
        ledger.record(plan(a, "running"), cdhash: "03", now: old)
        ledger.record(plan(b, "unpaired"), cdhash: "04", now: now)
        let stale = ledger.stale(now: now, pairedHostIDs: [a.hex], pinnedPaths: [plan(a, "pinned").relativePath],
                                 running: [plan(a, "running").bundleIdentifier])
        XCTAssertEqual(stale.map(\.remoteBundleID), ["idle", "unpaired"])
        ledger.touch(plan(a, "idle").bundleIdentifier, now: now)
        XCTAssertEqual(ledger.stale(now: now, pairedHostIDs: [a.hex, b.hex], pinnedPaths: [], running: []).map(\.remoteBundleID),
                       ["pinned", "running"])
        XCTAssertEqual(try DockHelperLedger.decode(ledger.encoded()), ledger)
    }

    func testDockPinsParsing() {
        let base = "/Users/me/Library/Application Support/paneshare/DockHelpers"
        let apps: [Any] = [
            ["tile-data": ["file-data": ["_CFURLString": "file:///Users/me/Library/Application%20Support/paneshare/DockHelpers/abc/com-x/X%20on%20H.app/",
                                         "_CFURLStringType": 15]]],
            ["tile-data": ["file-data": ["_CFURLString": "file:///Applications/Safari.app/", "_CFURLStringType": 15]]],
            ["tile-data": ["file-data": ["_CFURLString": "\(base)/def/com-y/Y on H.app", "_CFURLStringType": 0]]],
            ["tile-data": "garbage"],
            42,
        ]
        XCTAssertEqual(DockPins.pinnedHelperPaths(persistentApps: apps, helpersDirectory: base),
                       ["abc/com-x/X on H.app", "def/com-y/Y on H.app"])
    }
}

final class DockLinkFramingTests: XCTestCase {
    func testRoundTripAndChunking() throws {
        let messages: [DockLinkMessage] = [
            .hello(helperKey: "dev.paneshare.dock.a.b", coldStart: true),
            DockLinkMessage(kind: .menu, items: [.init(windowID: 7, title: "Main — notes.txt"), .init(windowID: 9, title: "Two")]),
            DockLinkMessage(kind: .choose, helperKey: "k", windowID: 9),
            DockLinkMessage(kind: .quit),
        ]
        var stream = Data()
        for m in messages { stream.append(try DockLinkFraming.encode(m)) }
        var decoder = DockLinkFraming.Decoder()
        var out: [DockLinkMessage] = []
        for byte in stream { out += try decoder.feed(Data([byte])) }
        XCTAssertEqual(out, messages)
        XCTAssertEqual(messages[0].protocolVersion, DockLinkMessage.protocolVersion)
    }

    func testRejectsOversizeAndGarbage() {
        var decoder = DockLinkFraming.Decoder()
        XCTAssertThrowsError(try decoder.feed(Data([0x00, 0x01, 0x00, 0x01]))) {
            XCTAssertEqual($0 as? DockLinkFraming.Failure, .tooLarge)
        }
        var other = DockLinkFraming.Decoder()
        XCTAssertThrowsError(try other.feed(Data([0, 0, 0, 2]) + Data("{x".utf8))) {
            XCTAssertEqual($0 as? DockLinkFraming.Failure, .malformed)
        }
        var unknownKind = DockLinkFraming.Decoder()
        let json = Data(#"{"kind":"openShell"}"#.utf8)
        XCTAssertThrowsError(try unknownKind.feed(Data([0, 0, 0, UInt8(json.count)]) + json))
    }

    func testSocketPathFits() {
        let path = DockLinkPaths.socketPath(applicationSupport: "/Users/someone/Library/Application Support")
        XCTAssertEqual(path, "/Users/someone/Library/Application Support/paneshare/run/dock.sock")
        XCTAssertTrue(DockLinkPaths.fitsSocketAddress(path))
        XCTAssertFalse(DockLinkPaths.fitsSocketAddress(String(repeating: "x", count: 104)))
    }
}
