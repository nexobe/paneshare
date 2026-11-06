#if os(macOS)
import PaneshareInput
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up paneshare").font(.largeTitle.bold())
            Text("To view windows from another Mac, you don't need any permissions. To share this Mac's windows, grant two:")
                .foregroundStyle(.secondary)

            PermissionStep(
                number: 1, title: "Screen Recording",
                detail: "Lets paneshare capture only the windows you choose to share.",
                granted: model.screenRecording,
                request: { Permissions.open(.screenRecording) },
                note: "If paneshare isn't in the list, click + below the list and choose it from Applications. Then turn it on. macOS may ask you to quit and reopen paneshare.")
            PermissionStep(
                number: 2, title: "Accessibility",
                detail: "Lets a paired viewer click, type and resize inside a shared window. Without it, sharing is view-only.",
                granted: model.accessibility,
                request: { Permissions.requestAccessibility(); Permissions.open(.accessibility) },
                note: nil)

            Text("paneshare also asks to find devices on your local network. Allow it so Macs can find each other; a Tailscale address works without it.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(model.screenRecording && model.accessibility ? "Done" : "Skip for now") { model.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(maxWidth: 640)
    }
}

struct PermissionStep: View {
    let number: Int
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    let note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title)
                .foregroundStyle(granted ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note, !granted {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.green)
            } else {
                Button("Open System Settings", action: request)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let pane: Permissions.Pane

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open System Settings") { Permissions.open(pane) }
            }
        }
    }
}
#endif
