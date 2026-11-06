#if os(macOS)
import AppKit
import Foundation
import PaneshareCore

/// The colour that marks each paired Mac. Starts as the one its fingerprint picks, and the user can change it.
enum HostColors {
    /// UserDefaults key: fingerprint hex → palette index.
    static let choicesKey = "hostColors"
    /// UserDefaults key for outlining remote windows. Off until the user turns it on.
    static let borderKey = "remoteWindowBorder"

    static func index(for host: Fingerprint) -> Int {
        let choices = UserDefaults.standard.dictionary(forKey: choicesKey) as? [String: Int] ?? [:]
        return SourceMacColor.index(for: host, choice: choices[host.hex])
    }

    static func setIndex(_ index: Int, for host: Fingerprint) {
        var choices = UserDefaults.standard.dictionary(forKey: choicesKey) as? [String: Int] ?? [:]
        choices[host.hex] = index
        UserDefaults.standard.set(choices, forKey: choicesKey)
    }

    static func color(index: Int) -> NSColor {
        let c = SourceMacColor.palette[index]
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    static func color(for host: Fingerprint) -> NSColor { color(index: index(for: host)) }

    /// nil while the setting is off.
    static func borderColor(for host: Fingerprint) -> CGColor? {
        UserDefaults.standard.bool(forKey: borderKey) ? color(for: host).cgColor : nil
    }
}
#endif
