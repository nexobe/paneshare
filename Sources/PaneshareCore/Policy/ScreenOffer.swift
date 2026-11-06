/// A whole screen offered like a window. It travels as a `WindowInfo` with a `displayID`, under a
/// window ID in a range that real window IDs don't reach.
public enum ScreenOffer {
    public static let bundleID = "dev.paneshare.screen"
    private static let marker: UInt32 = 0x8000_0000

    public static func windowID(displayID: UInt32) -> UInt32 { marker | (displayID & ~marker) }

    public static func isScreen(windowID: UInt32) -> Bool { windowID & marker != 0 }

    /// `number` counts from 1, in the order the system lists the screens.
    public static func info(displayID: UInt32, number: Int, frame: WireRect) -> WindowInfo {
        var info = WindowInfo(windowID: windowID(displayID: displayID),
                              title: "Screen \(number) (\(Int(frame.width)) × \(Int(frame.height)))",
                              appName: "Whole screen", bundleID: bundleID, processID: 0, frame: frame)
        info.displayID = displayID
        return info
    }
}
