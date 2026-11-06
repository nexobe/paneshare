#if os(macOS)
import AppKit
import Foundation
import PaneshareCore
import PaneshareDockLink
import Security
import UniformTypeIdentifiers

/// Writes, signs and records Dock helper bundles under
/// `~/Library/Application Support/paneshare/DockHelpers` (docs/ARCHITECTURE.md §6.2). Signing is
/// done in process (`AdHocSigner`); before a bundle is used, Security.framework must accept it
/// statically and its cdhash must be the one we computed.
@MainActor
final class DockHelperFactory {
    enum Failure: Error { case noHelperBinary, signatureRejected }

    let helpersDirectory: URL
    let mainBundleID: String
    /// Our own Team ID when Developer ID signed (nil for ad hoc builds); it goes into each helper so
    /// the helper can require it of the link's server, and into its App Management policy.
    let mainTeamID: String?
    private(set) var ledger: DockHelperLedger
    private let ledgerURL: URL
    private let helperExecutable: URL?
    private let fileManager = FileManager.default

    init(mainBundleID: String) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        helpersDirectory = support.appendingPathComponent("paneshare/DockHelpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        ledgerURL = helpersDirectory.appendingPathComponent("ledger.json")
        ledger = (try? Data(contentsOf: ledgerURL)).flatMap { try? DockHelperLedger.decode($0) } ?? DockHelperLedger()
        self.mainBundleID = mainBundleID
        mainTeamID = Self.ownTeamID()
        helperExecutable = Self.locateHelperExecutable()
    }

    static func ownTeamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              DockLinkTrust.isTeamID(team) else { return nil }
        return team
    }

    /// `paneshare.app/Contents/Helpers/paneshare-dock-helper`, or next to the main binary for `swift run`.
    static func locateHelperExecutable() -> URL? {
        let name = HelperBundlePlan.executableName
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func url(for plan: HelperBundlePlan) -> URL {
        helpersDirectory.appendingPathComponent(plan.relativePath, isDirectory: true)
    }

    /// The helper bundle for `plan`, generated and signed if it is missing or no longer valid.
    func prepare(_ plan: HelperBundlePlan, icon: NSImage?) throws -> (url: URL, cdhash: String) {
        let destination = url(for: plan)
        if let entry = ledger.entries[plan.bundleIdentifier], entry.isCurrent(for: plan),
           Self.isValid(destination, cdhash: entry.cdhash) {
            ledger.touch(plan.bundleIdentifier, now: Date())
            save()
            return (destination, entry.cdhash)
        }
        guard let helperExecutable else { throw Failure.noHelperBinary }
        let info = PlistValue.dict(plan.infoPlist).xmlDocument
        let icns = HelperIcon.icns(icon: icon, color: HelperIcon.color(for: plan.host))
        let seal = BundleSeal.codeResources(resources: ["Resources/AppIcon.icns": icns])
        let signed = try AdHocSigner.sign(executable: try Data(contentsOf: helperExecutable), identifier: plan.bundleIdentifier,
                                          infoPlist: info, codeResources: seal)

        // Built beside the destination, checked, then moved into place: a half-written or
        // rejected bundle is never launched.
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        for sub in ["MacOS", "Resources", "_CodeSignature"] {
            try fileManager.createDirectory(at: contents.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try icns.write(to: contents.appendingPathComponent("Resources/AppIcon.icns"))
        try seal.write(to: contents.appendingPathComponent("_CodeSignature/CodeResources"))
        let executable = contents.appendingPathComponent("MacOS/\(HelperBundlePlan.executableName)")
        try signed.executable.write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        // We write every byte ourselves, so nothing should carry quarantine; if something ever did
        // (a policy that quarantines all files this app writes), Gatekeeper would assess the
        // unnotarized helper at launch and refuse it.
        Self.removeQuarantine(under: staging)
        guard Self.isValid(staging, cdhash: signed.cdhashHex) else { throw Failure.signatureRejected }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        ledger.record(plan, cdhash: signed.cdhashHex, now: Date())
        save()
        return (destination, signed.cdhashHex)
    }

    /// Deletes helpers of unpaired hosts and helpers idle for 30 days that aren't kept in the Dock.
    func cleanUp(pairedHostIDs: Set<String>) {
        let persistent = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") ?? []
        let pinned = DockPins.pinnedHelperPaths(persistentApps: persistent,
                                                helpersDirectory: helpersDirectory.standardizedFileURL.path)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .filter { $0.hasPrefix(HelperBundlePlan.bundleIDPrefix + ".") })
        for entry in ledger.stale(now: Date(), pairedHostIDs: pairedHostIDs, pinnedPaths: pinned, running: running) {
            let bundle = helpersDirectory.appendingPathComponent(entry.relativePath, isDirectory: true)
            // Only ever delete inside our own directory.
            if bundle.standardizedFileURL.path.hasPrefix(helpersDirectory.standardizedFileURL.path + "/") {
                try? fileManager.removeItem(at: bundle)
            }
            ledger.remove(entry.bundleIdentifier)
        }
        save()
    }

    func remove(_ plan: HelperBundlePlan) {
        let bundle = url(for: plan)
        if bundle.standardizedFileURL.path.hasPrefix(helpersDirectory.standardizedFileURL.path + "/") {
            try? fileManager.removeItem(at: bundle.deletingLastPathComponent())
        }
        ledger.remove(plan.bundleIdentifier)
        save()
    }

    static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private func save() {
        guard let data = try? ledger.encoded() else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    static func removeQuarantine(under root: URL) {
        var paths = [root.path]
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in walker { paths.append(root.appendingPathComponent(relative).path) }
        }
        for path in paths { _ = removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    static func isValid(_ bundle: URL, cdhash: String) -> Bool {
        guard cdhash.count == 40, cdhash.allSatisfy(\.isHexDigit) else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(cdhash)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate))
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

/// The helper's Dock icon (`HelperIconLayout`): the remote app's icon inside a ring in the source
/// Mac's colour on the macOS icon grid, plus a small paneshare badge from 64 px, drawn separately at
/// every size so the ring still reads at 16 px. The same app from two Macs (or the local copy) can
/// be told apart at a glance.
enum HelperIcon {
    static func color(for host: Fingerprint) -> NSColor {
        HostColors.color(for: host)
    }

    static func icns(icon: NSImage?, color: NSColor) -> Data {
        let source = icon ?? NSWorkspace.shared.icon(for: .application)
        let badge = NSImage(named: NSImage.applicationIconName)
        let pngs = ICNSWriter.types.compactMap { entry -> (type: String, png: Data)? in
            png(source, badge: badge, layout: HelperIconLayout(pixels: entry.pixels), color: color).map { (entry.type, $0) }
        }
        return ICNSWriter.icns(pngs: pngs)
    }

    private static func png(_ icon: NSImage, badge: NSImage?, layout: HelperIconLayout, color: NSColor) -> Data? {
        let pixels = layout.pixels
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let rings = layout.ringOutlines()
        let ring = NSBezierPath()
        ring.windingRule = .evenOdd
        for outline in [rings.outer, rings.inner] {
            ring.move(to: NSPoint(x: outline[0].x, y: outline[0].y))
            for p in outline.dropFirst() { ring.line(to: NSPoint(x: p.x, y: p.y)) }
            ring.close()
        }
        // A faint dark edge keeps a light ring visible on a light Dock.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = max(0.5, CGFloat(pixels) * 0.012)
        shadow.shadowOffset = NSSize(width: 0, height: -max(0.5, CGFloat(pixels) * 0.006))
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        color.setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()

        icon.draw(in: rect(layout.remoteIcon), from: .zero, operation: .sourceOver, fraction: 1)
        if let badge, let b = layout.badge {
            badge.draw(in: rect(b), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func rect(_ r: HelperIconLayout.Rect) -> NSRect {
        NSRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}
#endif
