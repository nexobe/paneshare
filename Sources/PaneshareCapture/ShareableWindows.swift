#if os(macOS)
import AppKit
import Foundation
import PaneshareCore
import ScreenCaptureKit

/// Lists windows that may be shared: ScreenCaptureKit's on-screen windows, minus this app's own,
/// minus everything `WindowPolicy` rejects (password managers, system authentication prompts,
/// hidden apps, non-normal layers, tiny windows).
/// Windows with `sharingType = .none` are already excluded by the system.
public enum ShareableWindows {
    public struct Entry: @unchecked Sendable {
        /// Nil for a whole screen.
        public let window: SCWindow?
        public let display: SCDisplay?
        public let excluding: [SCWindow]
        public let info: WindowInfo

        init(window: SCWindow?, info: WindowInfo, display: SCDisplay? = nil, excluding: [SCWindow] = []) {
            self.window = window
            self.info = info
            self.display = display
            self.excluding = excluding
        }
    }

    /// The screens that can be offered, each one off until the host user turns it on.
    public static func listScreens() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.enumerated().map { index, display in
            ScreenOffer.info(displayID: display.displayID, number: index + 1, frame: WireRect(display.frame))
        }
    }

    /// The windows a whole-screen stream must not show right now: every window of an app the
    /// policy rejects, such as password managers, system password prompts and paneshare itself.
    public static func excludedWindows(policy: WindowPolicy) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return excluded(from: content, policy: policy)
    }

    private static func excluded(from content: SCShareableContent, policy: WindowPolicy) -> [SCWindow] {
        content.windows.filter { w in
            let app = w.owningApplication
            return policy.appRejection(bundleID: app?.bundleIdentifier ?? "", processID: app?.processID ?? 0) != nil
        }
    }

    public static func list(policy: WindowPolicy) async throws -> [Entry] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { w in
            let info = Self.info(w)
            return policy.isShareable(info, appHidden: isHidden(info.processID)) ? Entry(window: w, info: info) : nil
        }
        .sorted { ($0.info.appName, $0.info.title) < ($1.info.appName, $1.info.title) }
    }

    /// A fresh `SCWindow` for an ID, re-checked against the policy. Nil when it's gone or not shareable.
    public static func find(_ windowID: UInt32, policy: WindowPolicy) async throws -> Entry? {
        if ScreenOffer.isScreen(windowID: windowID) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let index = content.displays.firstIndex(where: { ScreenOffer.windowID(displayID: $0.displayID) == windowID }) else { return nil }
            let display = content.displays[index]
            let info = ScreenOffer.info(displayID: display.displayID, number: index + 1, frame: WireRect(display.frame))
            return Entry(window: nil, info: info, display: display, excluding: excluded(from: content, policy: policy))
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let info = Self.info(w)
        // A minimized or other-Space window is off screen; it may keep streaming once opened, but
        // the other checks still apply.
        var onScreen = info
        onScreen.isOnScreen = true
        return policy.isShareable(onScreen, appHidden: isHidden(info.processID)) ? Entry(window: w, info: info) : nil
    }

    private static func isHidden(_ processID: Int32) -> Bool {
        NSRunningApplication(processIdentifier: processID)?.isHidden ?? false
    }

    public static func info(_ w: SCWindow) -> WindowInfo {
        let app = w.owningApplication
        return WindowInfo(
            windowID: w.windowID,
            title: w.title ?? "",
            appName: app?.applicationName ?? "",
            bundleID: app?.bundleIdentifier ?? "",
            processID: app?.processID ?? 0,
            frame: WireRect(w.frame),
            layer: w.windowLayer,
            isOnScreen: w.isOnScreen)
    }

    /// The owning app's icon as PNG (128 pt), for the viewer's window and Dock.
    public static func iconPNG(processID: Int32, side: CGFloat = 128) -> Data? {
        guard let icon = NSRunningApplication(processIdentifier: processID)?.icon else { return nil }
        let size = NSSize(width: side, height: side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
