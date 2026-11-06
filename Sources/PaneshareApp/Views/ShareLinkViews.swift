#if os(macOS)
import AppKit
import PaneshareCore
import SwiftUI

struct ShareLinkTarget: Identifiable {
    let window: WindowInfo
    var id: UInt32 { window.windowID }
}

/// Makes a link for one shared window, then shows it once (the token isn't kept anywhere).
struct ShareLinkSheet: View {
    let window: WindowInfo
    @ObservedObject var links: ShareLinkController
    @Environment(\.dismiss) private var dismiss
    @State private var lifetime = ShareLinkStore.defaultLifetime
    @State private var pointer = false
    @State private var qrURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share link").font(.headline)
            Text(window.displayTitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if let created = links.created, created.link.windowID == window.windowID {
                createdView(created)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { links.lastError = nil }
        .onDisappear { links.created = nil }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Someone on your network (or your tailnet) opens the link in a browser and sees only this window. Nothing to install. The link works once, for one person.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Expires after", selection: $lifetime) {
                Text("15 minutes").tag(ShareLinkStore.lifetimes[0])
                Text("1 hour").tag(ShareLinkStore.lifetimes[1])
                Text("8 hours").tag(ShareLinkStore.lifetimes[2])
                Text("1 day").tag(ShareLinkStore.lifetimes[3])
                Text("1 week").tag(ShareLinkStore.lifetimes[4])
            }
            .fixedSize()
            Text("The link stops working if paneshare quits or sharing turns off, whatever you choose here.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Let the guest point, click and scroll", isOn: $pointer)
            Text("Off: the guest can only watch, and you see their pointer. On: their clicks reach this window (never typing). You can change this while they're connected.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = links.lastError { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Link") { links.create(for: window, lifetime: lifetime, pointerAllowed: pointer) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func createdView(_ created: ShareLinkController.Created) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send one of these to your guest. The secret part after # is shown only now.")
                .font(.caption).foregroundStyle(.secondary)
            if created.urls.isEmpty {
                Text("This Mac has no LAN or Tailscale address right now, so there's nothing a guest could open.")
                    .font(.callout).foregroundStyle(.orange)
            }
            ForEach(created.urls) { entry in
                HStack {
                    Text(entry.label).font(.caption).frame(width: 90, alignment: .leading)
                    Text(entry.url).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("QR Code") { qrURL = qrURL == entry.url ? nil : entry.url }
                    Button("Copy") { copy(entry.url) }
                }
            }
            if let qrURL {
                HStack {
                    Spacer()
                    QRCodeView(text: qrURL)
                    Spacer()
                }
                Text("Anyone who can see this code can open the link. The first person to open it becomes the guest.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("The browser will warn that the certificate isn't trusted, because this Mac signed it itself. The guest can check it's really this Mac: the certificate's SHA-256 fingerprint is")
                .font(.caption).foregroundStyle(.secondary)
            Text(created.certificateSHA256).font(.caption2.monospaced()).textSelection(.enabled)
            HStack {
                Text("Expires \(created.link.expiresAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    links.created = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Live links and connected guests, with revoke, kick and the pointer switch.
struct ShareLinksSection: View {
    @ObservedObject var links: ShareLinkController

    var body: some View {
        if !links.links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Share links").font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(links.links) { link in row(link) }
                    }
                }
            }
        }
    }

    private func row(_ link: ShareLinkRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "link")
                Text(link.windowTitle).lineLimit(1)
                Text(remaining(link)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Toggle("Pointer", isOn: Binding(get: { link.pointerAllowed }, set: { links.setPointerAllowed($0, linkID: link.id) }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Let this link's guest click, drag and scroll in the window")
                Button("Revoke", role: .destructive) { links.revoke(link.id) }
            }
            let guests = links.guests.filter { $0.session.linkID == link.id }
            if guests.isEmpty {
                Text(link.redeemed ? "Guest not connected (can come back until the link expires)" : "Not opened yet")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            }
            ForEach(guests) { g in
                HStack {
                    Image(systemName: "person.fill").foregroundStyle(.orange)
                    Text(g.session.name)
                    Text("\(g.session.address) · since \(g.session.joinedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Kick", role: .destructive) { links.kick(g.session.id) }
                }
                .padding(.leading, 22)
            }
        }
    }

    private func remaining(_ link: ShareLinkRecord) -> String {
        let s = Int(links.timeLeft(link))
        if s >= 86400 { return String(format: "%dd %dh left", s / 86400, s / 3600 % 24) }
        return s >= 3600 ? String(format: "%dh %02dm left", s / 3600, s / 60 % 60) : String(format: "%d:%02d left", s / 60, s % 60)
    }
}
#endif
