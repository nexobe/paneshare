#if os(macOS)
import Foundation
import PaneshareCore

/// Keeps this Mac and its display from idle sleep while any window is being streamed. A sleeping
/// display stops capture. It doesn't stop sleep from closing the lid on battery, or a manual sleep.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    private var hold = ActivityHold()
    private var activity: NSObjectProtocol?

    func acquire() {
        guard hold.acquire() else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
            reason: "paneshare is sharing a window")
    }

    func release() {
        guard hold.release(), let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
#endif
