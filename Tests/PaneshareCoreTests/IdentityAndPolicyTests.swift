import Crypto
import Foundation
import XCTest
@testable import PaneshareCore

final class IdentityTests: XCTestCase {
    func testSelfSignedCertificateCarriesTheKey() throws {
        let identity = try DeviceIdentity.generate()
        XCTAssertGreaterThan(identity.certificateDER.count, 200)
        XCTAssertEqual(identity.certificateDER.first, 0x30) // DER SEQUENCE
        XCTAssertEqual(SelfSignedCertificate.fingerprint(ofCertificateDER: identity.certificateDER), identity.fingerprint)
    }

    func testIdentityIsStableAcrossReload() throws {
        let a = try DeviceIdentity.generate()
        let b = try DeviceIdentity(rawPrivateKey: a.privateKey.rawRepresentation)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        // Certificates differ (random CN and serial) but pin the same key.
        XCTAssertNotEqual(a.certificateDER, b.certificateDER)
        XCTAssertEqual(SelfSignedCertificate.fingerprint(ofCertificateDER: b.certificateDER), a.fingerprint)
    }

    func testFingerprintFromX963MatchesDER() throws {
        let key = P256.Signing.PrivateKey()
        let fromKey = Fingerprint(publicKey: key.publicKey)
        let fromPoint = try XCTUnwrap(Fingerprint(x963PublicKey: key.publicKey.x963Representation))
        XCTAssertEqual(fromKey, fromPoint)
        XCTAssertNil(Fingerprint(x963PublicKey: Data(repeating: 4, count: 65)))
        XCTAssertNil(Fingerprint(x963PublicKey: Data([1, 2, 3])))
    }

    func testFingerprintHexAndShortID() throws {
        let fp = try XCTUnwrap(Fingerprint(bytes: Array(0..<32)))
        XCTAssertEqual(fp.hex.count, 64)
        XCTAssertEqual(Fingerprint(hex: fp.hex), fp)
        XCTAssertNil(Fingerprint(hex: "zz"))
        XCTAssertEqual(fp.shortID.count, 16)
        // 0x00 0x01 0x02 … → known Crockford base32.
        XCTAssertEqual(CrockfordBase32.encode([0x00, 0x01, 0x02, 0x03, 0x04]), "000G40R4")
        XCTAssertEqual(CrockfordBase32.encode([0xFF]), "ZW")
        let json = try JSONEncoder().encode([fp])
        XCTAssertEqual(try JSONDecoder().decode([Fingerprint].self, from: json), [fp])
    }

    func testTrustStorePinsByRole() throws {
        let fp = Fingerprint(publicKey: P256.Signing.PrivateKey().publicKey)
        var store = TrustStore()
        XCTAssertFalse(store.isTrusted(fp, as: .viewer))
        store.pin(PairedPeer(fingerprint: fp, name: "MacBook", role: .viewer, pairedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(store.isTrusted(fp, as: .viewer))
        XCTAssertFalse(store.isTrusted(fp, as: .host))
        store.pin(PairedPeer(fingerprint: fp, name: "MacBook Pro", role: .viewer, pairedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(store.peers.count, 1)
        XCTAssertEqual(store.peer(fp)?.name, "MacBook Pro")
        store.updateAddress(fp, address: "100.64.0.2:47821")
        let reloaded = try TrustStore.decode(store.encoded())
        XCTAssertEqual(reloaded, store)
        store.remove(fp)
        XCTAssertFalse(store.isTrusted(fp, as: .viewer))
    }

    func testTrustStoreRemovesOneRoleOnly() {
        let fp = Fingerprint(publicKey: P256.Signing.PrivateKey().publicKey)
        var store = TrustStore()
        store.pin(PairedPeer(fingerprint: fp, name: "Studio", role: .viewer, pairedAt: Date()))
        store.pin(PairedPeer(fingerprint: fp, name: "Studio", role: .host, pairedAt: Date()))
        store.remove(fp, role: .host)
        XCTAssertTrue(store.isTrusted(fp, as: .viewer))
        XCTAssertFalse(store.isTrusted(fp, as: .host))
    }
}

final class PolicyTests: XCTestCase {
    func window(_ bundle: String, pid: Int32 = 900, layer: Int = 0, onScreen: Bool = true, w: Double = 800, h: Double = 600) -> WindowInfo {
        WindowInfo(windowID: 1, title: "t", appName: "a", bundleID: bundle, processID: pid,
                   frame: WireRect(x: 0, y: 0, width: w, height: h), layer: layer, isOnScreen: onScreen)
    }

    let policy = WindowPolicy(ownProcessID: 123, ownBundleID: "dev.paneshare.app", extraDeniedBundleIDs: ["com.example.secret"])

    func testPasswordManagersAreExcluded() {
        for id in ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"] {
            XCTAssertEqual(policy.rejection(for: window(id)), .deniedApp, id)
        }
        XCTAssertEqual(policy.rejection(for: window("com.example.secret")), .deniedApp)
    }

    func testOwnWindowsAndProxiesAreExcluded() {
        XCTAssertEqual(policy.rejection(for: window("com.apple.Terminal", pid: 123)), .ownProcess)
        XCTAssertEqual(policy.rejection(for: window("dev.paneshare.app")), .ownProcess)
        XCTAssertEqual(policy.rejection(for: window("dev.paneshare.proxy.abc.xcode")), .deniedApp)
    }

    func testNonNormalWindowsAreExcluded() {
        XCTAssertEqual(policy.rejection(for: window("com.apple.Terminal", layer: 25)), .notNormalLayer)
        XCTAssertEqual(policy.rejection(for: window("com.apple.Terminal", onScreen: false)), .offScreen)
        XCTAssertEqual(policy.rejection(for: window("com.apple.Terminal", w: 30, h: 600)), .tooSmall)
        XCTAssertNil(policy.rejection(for: window("com.apple.Terminal")))
        XCTAssertEqual(policy.filter([window("com.apple.Terminal"), window("com.1password.1password")]).count, 1)
    }

    func testInputGate() {
        let click = InputEvent(kind: .mouseDown, position: NormalizedPoint(x: 0.5, y: 0.5), button: .left, clickCount: 1)
        let key = InputEvent(kind: .keyDown, keyCode: 0x00)
        let move = InputEvent(kind: .mouseMove, position: NormalizedPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(InputGate.decide(click, streamOwned: true, accessibilityTrusted: true, frontmostPID: 1, targetPID: 2), .raiseThenInject)
        XCTAssertEqual(InputGate.decide(click, streamOwned: true, accessibilityTrusted: true, frontmostPID: 2, targetPID: 2), .inject)
        XCTAssertEqual(InputGate.decide(key, streamOwned: true, accessibilityTrusted: true, frontmostPID: 1, targetPID: 2), .drop(.targetNotFrontmost))
        XCTAssertEqual(InputGate.decide(key, streamOwned: true, accessibilityTrusted: true, frontmostPID: 2, targetPID: 2), .inject)
        XCTAssertEqual(InputGate.decide(move, streamOwned: true, accessibilityTrusted: true, frontmostPID: 1, targetPID: 2), .inject)
        XCTAssertEqual(InputGate.decide(move, streamOwned: false, accessibilityTrusted: true, frontmostPID: 2, targetPID: 2), .drop(.streamNotOwned))
        XCTAssertEqual(InputGate.decide(move, streamOwned: true, accessibilityTrusted: false, frontmostPID: 2, targetPID: 2), .drop(.noAccessibility))
        XCTAssertEqual(InputGate.decide(InputEvent(kind: .mouseMove), streamOwned: true, accessibilityTrusted: true, frontmostPID: 2, targetPID: 2),
                       .drop(.malformed))
    }

    func testSystemAuthPromptsAreAlwaysExcluded() {
        let lenient = WindowPolicy(ownProcessID: 1, ownBundleID: nil)
        for id in ["com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.coreautha",
                   "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent", "com.apple.loginwindow"] {
            XCTAssertEqual(lenient.rejection(for: window(id)), .systemAuthPrompt, id)
        }
        XCTAssertEqual(policy.rejection(for: window("dev.paneshare.dock.ab12.com.apple.dt.xcode")), .deniedApp)
    }

    func testHiddenAppsAreExcluded() {
        XCTAssertEqual(policy.rejection(for: window("com.apple.Terminal"), appHidden: true), .hiddenApp)
        XCTAssertFalse(policy.isShareable(window("com.apple.Terminal"), appHidden: true))
        XCTAssertTrue(policy.isShareable(window("com.apple.Terminal"), appHidden: false))
    }

    func testSecureInputPausesKeyPressesOnly() {
        let down = InputEvent(kind: .keyDown, keyCode: 0x00)
        let up = InputEvent(kind: .keyUp, keyCode: 0x00)
        let click = InputEvent(kind: .mouseDown, position: NormalizedPoint(x: 0.5, y: 0.5), button: .left, clickCount: 1)
        func decide(_ e: InputEvent) -> InputGate.Decision {
            InputGate.decide(e, streamOwned: true, accessibilityTrusted: true, secureInputActive: true, frontmostPID: 2, targetPID: 2)
        }
        XCTAssertEqual(decide(down), .drop(.secureInput))
        XCTAssertEqual(decide(up), .inject)
        XCTAssertEqual(decide(click), .inject)
        XCTAssertEqual(InputGate.pause(accessibilityTrusted: true, secureInputActive: true), .secureInput)
        XCTAssertEqual(InputGate.pause(accessibilityTrusted: false, secureInputActive: true), .noAccessibility)
        XCTAssertNil(InputGate.pause(accessibilityTrusted: true, secureInputActive: false))
    }
}

final class ScreenOfferTests: XCTestCase {
    private let frame = WireRect(x: -100, y: 0, width: 1920, height: 1080)

    func testIDsStayOutOfTheWindowRange() {
        XCTAssertTrue(ScreenOffer.isScreen(windowID: ScreenOffer.windowID(displayID: 1)))
        XCTAssertTrue(ScreenOffer.isScreen(windowID: ScreenOffer.windowID(displayID: 0xFFFF_FFFF)))
        XCTAssertFalse(ScreenOffer.isScreen(windowID: 12345))
        XCTAssertNotEqual(ScreenOffer.windowID(displayID: 1), ScreenOffer.windowID(displayID: 2))
    }

    func testInfoIsTaggedAndOptionalOnTheWire() throws {
        let info = ScreenOffer.info(displayID: 7, number: 2, frame: frame)
        XCTAssertEqual(info.displayID, 7)
        XCTAssertEqual(info.title, "Screen 2 (1920 × 1080)")
        let f = try MessageCodec.frame(.windowList, [info])
        XCTAssertEqual(try MessageCodec.decode([WindowInfo].self, from: f), [info])

        let plain = WindowInfo(windowID: 5, title: "t", appName: "a", bundleID: "b", processID: 1, frame: frame)
        let data = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("displayID"), "older peers see nothing new")
        XCTAssertNil(try JSONDecoder().decode(WindowInfo.self, from: data).displayID)
    }

    func testPolicyStillKeepsAudioOffAScreen() {
        let policy = WindowPolicy(ownProcessID: 1, ownBundleID: "dev.paneshare.app")
        XCTAssertNotNil(policy.appRejection(bundleID: ScreenOffer.bundleID, processID: 0))
    }
}
