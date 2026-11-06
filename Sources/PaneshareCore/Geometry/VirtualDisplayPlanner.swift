import Foundation

/// The host setting for virtual displays (docs/ARCHITECTURE.md §7.3).
public enum VirtualDisplayMode: String, Codable, CaseIterable, Sendable {
    /// Never. Windows stay on the host's real screens. The default.
    case off
    /// Only when needed: the host has no screen (headless Mac mini), or the window, or the size the
    /// viewer asks for, doesn't fit on any of the host's screens.
    case auto
    /// Every shared window goes onto a virtual display sized to its viewer.
    case always

    public static let key = "virtualDisplay"

    public init(setting: String?) {
        self = setting.flatMap(VirtualDisplayMode.init(rawValue:)) ?? .off
    }
}

/// Decides when a shared window goes onto a virtual display, how big the display is and where the
/// window sits on it. Pure; the private display API lives in `PaneshareVirtualDisplay`.
public enum VirtualDisplayPlanner {
    public enum Decision: Equatable, Sendable {
        case useRealScreen
        /// A HiDPI virtual display of this size in points.
        case useVirtual(WireSize)
        /// A virtual display was needed but can't be made here; the window stays where it is.
        case unavailable(String)
    }

    /// Used when the viewer didn't say how big its screen is.
    public static let defaultSize = WireSize(width: 1920, height: 1200)
    public static let minSize = WireSize(width: 640, height: 480)
    /// At 2× this is 7680 × 4800 px, inside the encoder's 40-megapixel area limit (`Sizing`).
    public static let maxSize = WireSize(width: 3840, height: 2400)

    /// - Parameters:
    ///   - apiProblem: nil when the private API checked out; otherwise why not.
    ///   - physicalScreens: visible-frame sizes (points) of the host's real screens, excluding
    ///     virtual displays. Empty means headless.
    ///   - window: the window's current size in points.
    ///   - wanted: a size the viewer asked for, if any.
    ///   - viewerDisplay: the viewer's screen (points), if it said.
    public static func decide(mode: VirtualDisplayMode, apiProblem: String?, physicalScreens: [WireSize],
                              window: WireSize, wanted: WireSize? = nil, viewerDisplay: WireSize?) -> Decision {
        guard mode != .off else { return .useRealScreen }
        let need = WireSize(width: max(window.width, wanted?.width ?? 0), height: max(window.height, wanted?.height ?? 0))
        if mode == .auto, !physicalScreens.isEmpty, fits(need, onAnyOf: physicalScreens) { return .useRealScreen }
        if let apiProblem { return .unavailable(apiProblem) }
        return .useVirtual(displaySize(viewer: viewerDisplay, need: need))
    }

    /// Whether a viewer may move a window off the host's screens. Moving back has no such check.
    public static func canMoveAway(settingOn: Bool, isScreen: Bool, apiProblem: String?, accessibility: Bool) -> Bool {
        settingOn && !isScreen && apiProblem == nil && accessibility
    }

    public static func fits(_ size: WireSize, onAnyOf screens: [WireSize]) -> Bool {
        screens.contains { $0.width >= size.width && $0.height >= size.height }
    }

    /// The viewer's screen size, grown to hold `need`, clamped and rounded to even whole points.
    public static func displaySize(viewer: WireSize?, need: WireSize) -> WireSize {
        let base = viewer.flatMap { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 ? $0 : nil } ?? defaultSize
        func dim(_ v: Double, _ n: Double, _ lo: Double, _ hi: Double) -> Double {
            let want = max(v, n.isFinite ? n : 0)
            let clamped = min(hi, max(lo, want))
            return (clamped / 2).rounded(.down) * 2
        }
        return WireSize(width: dim(base.width, need.width, minSize.width, maxSize.width),
                        height: dim(base.height, need.height, minSize.height, maxSize.height))
    }

    /// Where the window's top-left goes on the display (global points, top-left origin): centred in
    /// `visible`, or at its top-left corner when the window is as large or larger.
    public static func placement(window: WireSize, visible: WireRect) -> WirePoint {
        let x = visible.x + max(0, (visible.width - window.width) / 2)
        let y = visible.y + max(0, (visible.height - window.height) / 2)
        return WirePoint(x: x.rounded(), y: y.rounded())
    }

    /// A display serial number stable per viewer, so macOS puts that viewer's display back where it
    /// was last time instead of adding a new entry to System Settings › Displays. Never zero.
    public static func serial(for viewer: Fingerprint) -> UInt32 {
        let v = viewer.bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return v == 0 ? 1 : v
    }
}

/// How Objective-C type encodings reported by the runtime are compared with the ones the private
/// display code was written for. Pure, so the rules are tested on Linux.
///
/// Adapted from Sill (`Sources/SillHost/VirtualDisplay.swift`, `VirtualDisplay.TypeEncoding`, Copyright 2026
/// Noah Saffer, Apache-2.0); see THIRD_PARTY.md. Changed: moved to a standalone type.
public enum ObjCTypeEncoding {
    /// `v24@0:8@16` → `v@:@`. Offsets vary by architecture; the types are what matter.
    public static func normalized(_ encoding: String) -> String {
        String(encoding.filter { !$0.isNumber })
    }

    /// The spellings that count as `expected`: itself and, for a `BOOL` return written "B" (C99
    /// `bool`), the same with "c" (`signed char`), which x86_64 builds and Rosetta report.
    public static func accepted(_ expected: String) -> [String] {
        expected.first == "B" ? [expected, "c" + expected.dropFirst()] : [expected]
    }

    public static func matches(found: String, expected: String) -> Bool {
        accepted(expected).contains(normalized(found))
    }
}
