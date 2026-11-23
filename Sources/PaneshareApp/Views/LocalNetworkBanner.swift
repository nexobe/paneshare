#if os(macOS)
import PaneshareInput
import SwiftUI

/// macOS asks for Local Network access only once. If the answer was no, Bonjour fails in both
/// directions with no prompt and no error, so this banner says what happened and how to fix it.
struct LocalNetworkBanner: View {
    @ObservedObject var viewer: ViewerController

    var body: some View {
        if viewer.localNetworkBlocked {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Other Macs can't find this Mac, and it can't find them.").font(.headline)
                    Text(LocalNetworkHelp.fix).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Settings") { Permissions.open(.localNetwork) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        }
    }
}

enum LocalNetworkHelp {
    static let fix = "Turn on paneshare in System Settings > Privacy & Security > Local Network. If paneshare isn't listed, quit it and open it again. Pair by address still works."
}

/// Onboarding step 3 and the This Mac row read the same flag.
struct LocalNetworkStep: View {
    @ObservedObject var viewer: ViewerController

    var body: some View {
        PermissionStep(
            number: 3, title: "Local Network",
            detail: "Lets your Macs find each other on this network. Click Allow when macOS asks.",
            granted: !viewer.localNetworkBlocked,
            request: { Permissions.open(.localNetwork) },
            note: LocalNetworkHelp.fix,
            grantedLabel: "On")
    }
}

struct LocalNetworkRow: View {
    @ObservedObject var viewer: ViewerController

    var body: some View {
        LabeledContent("Local Network") {
            if viewer.localNetworkBlocked {
                Button("Open System Settings") { Permissions.open(.localNetwork) }
            } else {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}
#endif
