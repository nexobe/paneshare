import Crypto
import Foundation

/// `Contents/_CodeSignature/CodeResources` for a generated bundle: the hashes of every sealed
/// resource plus the standard rule sets that tell the verifier which paths are sealed, optional,
/// omitted or nested. Our bundles only ever contain Info.plist (bound in the code signature
/// itself, so omitted here), the executable (nested, sealed by its own signature) and files under
/// Resources/.
public enum BundleSeal {
    /// - Parameter resources: paths relative to `Contents/`, e.g. `Resources/AppIcon.icns`.
    public static func codeResources(resources: [String: Data]) -> Data {
        var files: [String: PlistValue] = [:]
        var files2: [String: PlistValue] = [:]
        for (path, data) in resources {
            let sha1 = Data(Insecure.SHA1.hash(data: data))
            let sha256 = Data(SHA256.hash(data: data))
            if path.hasPrefix("Resources/") { files[path] = .data(sha1) }
            files2[path] = .dict(["hash2": .data(sha256)])
        }
        return PlistValue.dict([
            "files": .dict(files),
            "files2": .dict(files2),
            "rules": .dict(rules),
            "rules2": .dict(rules2),
        ]).xmlDocument
    }

    private static func rule(weight: Int, _ flags: [String] = []) -> PlistValue {
        var d: [String: PlistValue] = ["weight": .real(Double(weight))]
        for f in flags { d[f] = .bool(true) }
        return .dict(d)
    }

    static let rules: [String: PlistValue] = [
        "^Resources/": .bool(true),
        "^Resources/.*\\.lproj/": rule(weight: 1000, ["optional"]),
        "^Resources/.*\\.lproj/locversion.plist$": rule(weight: 1100, ["omit"]),
        "^Resources/Base\\.lproj/": rule(weight: 1010),
        "^version.plist$": .bool(true),
    ]

    static let rules2: [String: PlistValue] = [
        ".*\\.dSYM($|/)": rule(weight: 11),
        "^(.*/)?\\.DS_Store$": rule(weight: 2000, ["omit"]),
        "^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/":
            rule(weight: 10, ["nested"]),
        "^.*": .bool(true),
        "^Info\\.plist$": rule(weight: 20, ["omit"]),
        "^PkgInfo$": rule(weight: 20, ["omit"]),
        "^Resources/": rule(weight: 20),
        "^Resources/.*\\.lproj/": rule(weight: 1000, ["optional"]),
        "^Resources/.*\\.lproj/locversion.plist$": rule(weight: 1100, ["omit"]),
        "^Resources/Base\\.lproj/": rule(weight: 1010),
        "^[^/]+$": rule(weight: 10, ["nested"]),
        "^embedded\\.provisionprofile$": rule(weight: 20),
        "^version\\.plist$": rule(weight: 20),
    ]
}

/// An `.icns` container of PNG images (Apple Icon Image format: "icns", big-endian total length,
/// then type/length/data entries).
public enum ICNSWriter {
    /// Pixel size for each PNG-capable entry type, 16 pt through 512 pt @2x. The 16 and 32 px
    /// entries matter: the Dock, Command-Tab and Finder lists use them instead of scaling 128 px down.
    public static let types: [(type: String, pixels: Int)] = [
        ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
    ]

    public static func icns(pngs: [(type: String, png: Data)]) -> Data {
        var body = Data()
        for entry in pngs where entry.type.utf8.count == 4 {
            body.append(contentsOf: Array(entry.type.utf8))
            body.appendBigEndian(UInt32(8 + entry.png.count))
            body.append(entry.png)
        }
        var out = Data("icns".utf8)
        out.appendBigEndian(UInt32(8 + body.count))
        out.append(body)
        return out
    }
}
