#if os(macOS)
import Foundation
import PaneshareCore
import PaneshareVirtualDisplay

/// The host's virtual displays: at most one per viewer, shared by that viewer's windows, created on
/// demand and destroyed when its last window leaves (docs/ARCHITECTURE.md §7.3).
@MainActor
final class VirtualDisplayManager {
    static let shared = VirtualDisplayManager()

    private struct Entry {
        let display: VirtualDisplay
        var users: Int
    }
    private var displays: [Fingerprint: Entry] = [:]
    private var loggedProblem = false

    var mode: VirtualDisplayMode { VirtualDisplayMode(setting: UserDefaults.standard.string(forKey: VirtualDisplayMode.key)) }

    /// nil when the private API is usable on this Mac.
    var apiProblem: String? { VirtualDisplay.apiProblem }

    func plan(window: WireSize, wanted: WireSize?, viewerDisplay: WireSize?) -> VirtualDisplayPlanner.Decision {
        let ours = Set(displays.values.map(\.display.displayID))
        let decision = VirtualDisplayPlanner.decide(mode: mode, apiProblem: mode == .off ? nil : apiProblem,
                                                    physicalScreens: VirtualDisplay.physicalScreenSizes(excluding: ours),
                                                    window: window, wanted: wanted, viewerDisplay: viewerDisplay)
        if case .unavailable(let why) = decision, !loggedProblem {
            loggedProblem = true
            NSLog("paneshare host: virtual display unavailable, windows stay on the real screen: %@", why)
        }
        return decision
    }

    /// The viewer's display, made at `size` if it doesn't exist yet. nil if it can't be made.
    func acquire(viewer: Fingerprint, size: WireSize) async -> VirtualDisplay? {
        if var entry = displays[viewer], entry.display.isAlive {
            entry.users += 1
            displays[viewer] = entry
            return entry.display
        }
        do {
            let display = try VirtualDisplay(name: "paneshare \(viewer.shortID)", widthPt: Int(size.width), heightPt: Int(size.height),
                                             serial: VirtualDisplayPlanner.serial(for: viewer))
            display.onTerminated = { [weak self] in self?.displays[viewer] = nil }
            displays[viewer] = Entry(display: display, users: 1)
            if !(await display.waitUntilOnline()) {
                NSLog("paneshare host: virtual display %.0fx%.0f pt came up at %ldx%ld px instead of HiDPI",
                      size.width, size.height, display.pixelSize.width, display.pixelSize.height)
            }
            guard display.isAlive else {
                displays[viewer] = nil
                display.destroy()
                return nil
            }
            return display
        } catch {
            NSLog("paneshare host: couldn't create a virtual display: %@", "\(error)")
            return nil
        }
    }

    func release(viewer: Fingerprint) {
        guard var entry = displays[viewer] else { return }
        entry.users -= 1
        if entry.users > 0 {
            displays[viewer] = entry
        } else {
            displays[viewer] = nil
            entry.display.destroy()
        }
    }

    /// On quit, after the streams have put their windows back.
    func destroyAll() {
        for entry in displays.values { entry.display.destroy() }
        displays.removeAll()
    }
}
#endif
