#if os(macOS)
import AppKit
import PaneshareCore
import SwiftUI

/// A browser guest's pointer, drawn over the shared window on the host so the host user sees where
/// the guest points. Click-through, never activates, and kept out of screen capture.
@MainActor
final class GuestPointerOverlay {
    private let panel: NSPanel
    private var hideTimer: Timer?
    private static let size = NSSize(width: 200, height: 28)
    /// Where the pointer's tip sits inside the panel, from its top-left.
    private static let tip = CGPoint(x: 4, y: 4)

    init(name: String) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: GuestPointerBadge(name: name))
    }

    /// `frame` is the window's frame in global top-left coordinates.
    func show(at p: NormalizedPoint, in frame: CGRect) {
        let x = frame.minX + p.x * frame.width
        let yFromTop = frame.minY + p.y * frame.height
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let top = primaryHeight - (yFromTop - Self.tip.y)
        panel.setFrameOrigin(NSPoint(x: x - Self.tip.x, y: top - Self.size.height))
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }

    func close() {
        hide()
        panel.close()
    }
}

private struct GuestPointerBadge: View {
    let name: String

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.orange)
                .shadow(color: .black.opacity(0.6), radius: 1)
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange))
                .foregroundStyle(.white)
                .offset(y: 10)
            Spacer(minLength: 0)
        }
        .frame(width: 200, height: 28, alignment: .topLeading)
    }
}
#endif
