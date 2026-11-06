#if os(macOS)
import PaneshareCore
import SwiftUI

/// The apps a host lets this Mac open. Only shown when that host sends a list.
struct RemoteAppsSection: View {
    @ObservedObject var session: ViewerSession
    @State private var expanded = false
    @State private var search = ""

    private var shown: [RemoteApp] {
        search.isEmpty ? session.apps : session.apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        DisclosureGroup("Apps on this Mac (\(session.apps.count))", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(shown, id: \.bundleID) { app in
                            HStack {
                                Text(app.name).lineLimit(1)
                                if app.isRunning {
                                    Text("Running").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open") { session.requestApp(app) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(.top, 4)
        }
        .font(.callout)
        .padding(.leading, 16)
        .onAppear { session.refreshApps() }
    }
}
#endif
