#if os(macOS)
import AppKit
import PaneshareCore
import SwiftUI
import UserNotifications

/// One pairing request as the host's prompt shows it.
@MainActor
final class PairPrompt: ObservableObject {
    let viewerName: String
    /// The requester's ID from its TLS key, which its own pairing sheet also shows.
    let viewerID: String
    let address: String
    let expiresAt: Date
    @Published var message: String?
    /// A typed code is being checked with the requester.
    @Published var checking = false
    var onAccept: ((String) -> Void)?
    var onDecline: (() -> Void)?

    init(viewerName: String, viewerID: String, address: String, expiresAt: Date) {
        self.viewerName = viewerName; self.viewerID = viewerID; self.address = address; self.expiresAt = expiresAt
    }
}

/// The host's pairing prompt: a floating, non-activating panel on every Space, so it can be typed
/// into without leaving the app in front. It's `sharingType = .none`, so neither our captures nor a
/// screen recorder sees what is typed. When paneshare isn't the active app, the Dock icon bounces
/// and a notification is posted too.
@MainActor
final class PairPromptPanel {
    static let shared = PairPromptPanel()
    private var panel: NSPanel?
    private var attention: Int?
    private let notificationID = "dev.paneshare.pair-request"

    func show(_ prompt: PairPrompt) {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pairing request"
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PairPromptView(prompt: prompt))
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
        if !NSApp.isActive {
            attention = NSApp.requestUserAttention(.criticalRequest)
            Self.notify(id: notificationID, viewerName: prompt.viewerName)
        }
        NSApp.activate()
    }

    func close() {
        if let attention { NSApp.cancelUserAttentionRequest(attention) }
        attention = nil
        panel?.close()
        panel = nil
        Self.withdraw(id: notificationID)
    }

    /// Notifications need a real app bundle; a bare executable (`swift run`) has none.
    private static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    private static func notify(id: String, viewerName: String) {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Pairing request"
            content.body = "“\(viewerName)” wants to pair with this Mac. Accept or decline in the paneshare prompt."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private static func withdraw(id: String) {
        guard canNotify else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

private struct PairPromptView: View {
    @ObservedObject var prompt: PairPrompt
    @State private var code = ""
    @FocusState private var focused: Bool

    private var digits: String? {
        if case .success(let d) = PairingCode.check(code) { return d }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.laptopcomputer").font(.title)
                Text("“\(prompt.viewerName)” wants to pair with this Mac").font(.title3.bold())
            }
            Text("It will be able to open and control the windows you share. To allow it, type the code shown on “\(prompt.viewerName)”.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            TextField("6-digit code", text: $code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(prompt.checking)
                .onSubmit(accept)
            if let message = prompt.message {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Its ID: \(prompt.viewerID) · from \(prompt.address) · expires in \(remaining(at: context.date))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                if prompt.checking { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                Spacer()
                Button("Decline") { prompt.onDecline?() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept", action: accept)
                    .keyboardShortcut(.defaultAction)
                    .disabled(digits == nil || prompt.checking)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { focused = true }
        .onChange(of: prompt.checking) { _, checking in
            if !checking, prompt.message != nil { code = ""; focused = true }
        }
    }

    private func accept() {
        guard let digits, !prompt.checking else { return }
        prompt.onAccept?(digits)
    }

    private func remaining(at now: Date) -> String {
        let s = max(0, Int(prompt.expiresAt.timeIntervalSince(now)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
#endif
