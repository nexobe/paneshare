// swift-tools-version:5.9
import PackageDescription

// PaneshareCore is platform-neutral and unit-tested on Linux and macOS. Every other target wraps
// its sources in `#if os(macOS)`, so the whole package still builds (as empty modules) on Linux.
let package = Package(
    name: "paneshare",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaneshareCore", targets: ["PaneshareCore"]),
        .executable(name: "paneshare", targets: ["PaneshareApp"]),
        .executable(name: "paneshare-dock-helper", targets: ["PaneshareDockHelper"]),
    ],
    // Upper bounds are the last releases whose manifests need at most Swift 5.10, so the package
    // resolves on Xcode 15.3 and later. Raise them when older toolchains are dropped.
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", "1.0.0"..<"2.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", "1.0.0"..<"2.0.0"),
        // Auto-update (MIT). A prebuilt XCFramework; only the macOS app links it.
        .package(url: "https://github.com/sparkle-project/Sparkle", "2.10.1"..<"3.0.0"),
    ],
    targets: [
        .target(
            name: "PaneshareCore",
            dependencies: [
                "PaneshareDockLink",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .target(name: "PaneshareCapture", dependencies: ["PaneshareCore"]),
        .target(name: "PaneshareEncode", dependencies: ["PaneshareCore"]),
        .target(name: "PaneshareDecode", dependencies: ["PaneshareCore"]),
        // App audio: process-tap / ScreenCaptureKit capture, AAC-ELD, AVAudioEngine playback.
        .target(name: "PaneshareAudio", dependencies: ["PaneshareCore"]),
        // The only code that touches private API (CGVirtualDisplay), looked up at run time and
        // feature-checked; see docs/ARCHITECTURE.md §7.3.
        .target(name: "PaneshareVirtualDisplay", dependencies: ["PaneshareCore"]),
        .target(
            name: "PaneshareTransport",
            dependencies: ["PaneshareCore", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(name: "PaneshareDiscovery", dependencies: ["PaneshareCore"]),
        .target(name: "PaneshareInput", dependencies: ["PaneshareCore"]),
        .target(name: "PaneshareViewer", dependencies: ["PaneshareCore", "PaneshareDecode"]),
        // The local link between the main app and its Dock helpers. Foundation only, so the helper
        // stays small; the framing is unit-tested on Linux.
        .target(name: "PaneshareDockLink"),
        // One copy ships in paneshare.app/Contents/Helpers; the viewer copies it into each generated
        // Dock helper and re-signs it in process. The linker must reserve a signature slot.
        .executableTarget(
            name: "PaneshareDockHelper",
            dependencies: ["PaneshareDockLink"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-adhoc_codesign"], .when(platforms: [.macOS]))]
        ),
        .executableTarget(
            name: "PaneshareApp",
            dependencies: [
                "PaneshareCore", "PaneshareCapture", "PaneshareEncode", "PaneshareDecode", "PaneshareAudio", "PaneshareVirtualDisplay",
                "PaneshareTransport", "PaneshareDiscovery", "PaneshareInput", "PaneshareViewer",
                "PaneshareDockLink",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            exclude: ["Info.plist", "paneshare.entitlements"],
            linkerSettings: [
                // Embeds Info.plist in the bare executable so `swift run` / Xcode runs get a bundle
                // identifier and the Local Network / Bonjour usage keys. scripts/make-app.sh builds a
                // proper .app bundle for real testing (stable TCC identity).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/PaneshareApp/Info.plist",
                    // Sparkle.framework lives in Contents/Frameworks in the bundle (scripts/make-app.sh).
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(name: "PaneshareCoreTests", dependencies: ["PaneshareCore", "PaneshareDockLink"]),
    ]
)
