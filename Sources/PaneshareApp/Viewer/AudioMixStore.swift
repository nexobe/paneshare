#if os(macOS)
import Foundation
import PaneshareCore

/// The viewer's per-(host, app) mute and volume, saved in UserDefaults (`AudioMixSettings`).
@MainActor
final class AudioMixStore: ObservableObject {
    static let shared = AudioMixStore()
    nonisolated static let key = "audioMix"

    @Published private(set) var settings = AudioMixSettings(data: UserDefaults.standard.data(forKey: AudioMixStore.key))

    func mix(host: Fingerprint, bundleID: String) -> AudioMix { settings.mix(host: host, bundleID: bundleID) }

    func set(_ mix: AudioMix, host: Fingerprint, bundleID: String) {
        settings.set(mix, host: host, bundleID: bundleID)
        UserDefaults.standard.set(settings.encoded(), forKey: Self.key)
    }

    func forget(host: Fingerprint) {
        settings.forget(host: host)
        UserDefaults.standard.set(settings.encoded(), forKey: Self.key)
    }
}
#endif
