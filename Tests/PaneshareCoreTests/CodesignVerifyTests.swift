#if os(macOS)
import Foundation
import XCTest
@testable import PaneshareCore

/// Builds a Dock helper bundle the way the app does and asks Apple's `codesign` to verify it.
/// Only the test runs a process; the app signs and checks in process.
final class CodesignVerifyTests: XCTestCase {
    func testGeneratedHelperPassesStrictVerification() throws {
        let buildDir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let helper = buildDir.appendingPathComponent(HelperBundlePlan.executableName)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("Build the helper first: swift build --product \(HelperBundlePlan.executableName)")
        }
        let host = try XCTUnwrap(Fingerprint(bytes: Array(repeating: 0x5A, count: 32)))
        let plan = HelperBundlePlan(host: host, hostName: "Test Host", remoteBundleID: "com.example.notes",
                                    remoteAppName: "Notes", mainBundleID: "dev.paneshare.app")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pw-sign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("\(plan.bundleName).app")
        let contents = bundle.appendingPathComponent("Contents")
        for sub in ["MacOS", "Resources", "_CodeSignature"] {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let info = PlistValue.dict(plan.infoPlist).xmlDocument
        let icns = ICNSWriter.icns(pngs: [("ic07", Data(repeating: 1, count: 64))])
        let seal = BundleSeal.codeResources(resources: ["Resources/AppIcon.icns": icns])
        let signed = try AdHocSigner.sign(executable: try Data(contentsOf: helper), identifier: plan.bundleIdentifier,
                                          infoPlist: info, codeResources: seal)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try icns.write(to: contents.appendingPathComponent("Resources/AppIcon.icns"))
        try seal.write(to: contents.appendingPathComponent("_CodeSignature/CodeResources"))
        let exe = contents.appendingPathComponent("MacOS/\(HelperBundlePlan.executableName)")
        try signed.executable.write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let (status, output) = try run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=4", bundle.path])
        XCTAssertEqual(status, 0, output)
        let (_, details) = try run("/usr/bin/codesign", ["-d", "--verbose=4", bundle.path])
        XCTAssertTrue(details.contains("CDHash=\(signed.cdhashHex)"), details)
        XCTAssertTrue(details.contains("Identifier=\(plan.bundleIdentifier)"), details)
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
}
#endif
