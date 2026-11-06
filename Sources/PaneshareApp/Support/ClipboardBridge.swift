#if os(macOS)
import AppKit
import Foundation
import PaneshareCore

/// Connects one session to the general pasteboard. It polls `changeCount`, which macOS doesn't treat
/// as reading the clipboard, and reads the contents only while `ClipboardSync.canSync` is true.
@MainActor
final class ClipboardBridge {
    /// UserDefaults key for the setting. Off unless the user turns it on.
    nonisolated static let enabledKey = "clipboardSync"

    private var sync = ClipboardSync()
    private var timer: Timer?
    private var reported: ClipboardState?
    private let isViewer: Bool
    /// Viewer: a remote window is in front here. Host: a stream is open for this viewer.
    private let localFocus: () -> Bool
    private let sendState: (ClipboardState) -> Void
    private let sendText: (Data) -> Void
    private var peerActive = false

    init(isViewer: Bool, localFocus: @escaping () -> Bool,
         sendState: @escaping (ClipboardState) -> Void, sendText: @escaping (Data) -> Void) {
        self.isViewer = isViewer
        self.localFocus = localFocus
        self.sendState = sendState
        self.sendText = sendText
    }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        reported = nil
        peerActive = false
        sync.peerEnabled = false
        sync.focused = false
    }

    func peerState(_ state: ClipboardState) {
        sync.peerEnabled = state.enabled
        peerActive = state.active
        tick()
    }

    func received(_ payload: Data) {
        refresh()
        guard let text = sync.received(payload) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        sync.wrote(changeCount: board.changeCount)
    }

    private func refresh() {
        sync.localEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        sync.focused = isViewer ? localFocus() : (peerActive && localFocus())
    }

    private func tick() {
        refresh()
        let state = ClipboardState(enabled: sync.localEnabled, active: isViewer && sync.focused)
        if state != reported {
            reported = state
            sendState(state)
        }
        let board = NSPasteboard.general
        guard sync.needsRead(changeCount: board.changeCount) else { return }
        let types = board.types?.map(\.rawValue) ?? []
        if let data = sync.localChanged(changeCount: board.changeCount, types: types, text: board.string(forType: .string)) {
            sendText(data)
        }
    }
}
#endif
