#if os(macOS)
import AppKit
import SwiftUI

@main
enum PaneshareEntry {
    @MainActor
    static func main() {
        // Before SwiftUI: no window, discovery or update prompt.
        if DockHelperSelfTest.requested() { DockHelperSelfTest.run() }
        if DoctorRunner.requested() { DoctorRunner.run() }
        PaneshareMain.main()
    }
}

struct PaneshareMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("paneshare", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 860, height: 600)
        .commands { UpdateCommands(updater: delegate.updater) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = UpdaterController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // After the main window is up, so a first-launch consent question has something behind it.
        DispatchQueue.main.async { self.updater.startAfterConsent() }
    }

    /// Closing the main window leaves remote windows open; quitting closes everything.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#else
@main
enum PaneshareMain {
    static func main() {
        print("paneshare is a macOS 14+ app. On this platform only PaneshareCore builds; run `swift test`.")
    }
}
#endif
