#if os(macOS)
import Foundation
import PaneshareCore

/// Saves files another Mac sends into `Downloads/paneshare`, one at a time. A file gets its final
/// name only after its size and digest match, and it is quarantined, so Gatekeeper still checks
/// anything run from it. The host uses it for files dropped on a remote window, and the viewer for
/// files a host sends. Each side has its own setting, off unless the user turns it on.
@MainActor
final class FileReceiver {
    /// UserDefaults key for accepting files dropped on this Mac's shared windows (host side).
    nonisolated static let enabledKey = "receiveFiles"
    /// UserDefaults key for accepting files from Macs this Mac connects to (viewer side).
    nonisolated static let fromHostsKey = "receiveFilesFromHosts"

    private struct Active {
        let id: UInt32
        let name: String
        let part: URL
        let handle: FileHandle
        var check: FileReceiveCheck
        var shownPercent = -1
    }

    private var active: Active?
    private let settingKey: String
    private let hasOpenStream: () -> Bool
    private let reply: (FileReply) -> Void
    private let finished: (URL, UInt64) -> Void
    /// The file name and whole percent received, each time the percent changes.
    private let progress: (String, Int) -> Void

    init(settingKey: String, hasOpenStream: @escaping () -> Bool, reply: @escaping (FileReply) -> Void,
         progress: @escaping (String, Int) -> Void = { _, _ in },
         finished: @escaping (URL, UInt64) -> Void) {
        self.settingKey = settingKey
        self.hasOpenStream = hasOpenStream
        self.reply = reply
        self.progress = progress
        self.finished = finished
    }

    func offer(_ offer: FileOffer) {
        func refuse(_ reason: String) { reply(FileReply(id: offer.id, accepted: false, reason: reason)) }
        guard UserDefaults.standard.bool(forKey: settingKey) else { return refuse("That Mac doesn't accept files. Turn it on in This Mac.") }
        guard hasOpenStream() else { return refuse("No window is open.") }
        guard active == nil else { return refuse("Another file is arriving.") }
        guard offer.size <= FileTransferRules.maxBytes else { return refuse("Files can be up to 2 GB.") }
        guard let name = FileTransferRules.safeName(offer.name) else { return refuse("The file name isn't usable.") }
        do {
            let folder = try Self.folder()
            let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard FileTransferRules.hasRoom(free: free, size: offer.size) else {
                return refuse("That Mac doesn't have enough free space.")
            }
            let part = folder.appendingPathComponent("\(UUID().uuidString).part")
            guard FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return refuse("That Mac couldn't create the file.")
            }
            active = Active(id: offer.id, name: name, part: part, handle: try FileHandle(forWritingTo: part),
                            check: FileReceiveCheck(size: offer.size))
            reply(FileReply(id: offer.id, accepted: true, received: 0))
        } catch {
            refuse("That Mac couldn't create the file.")
        }
    }

    func chunk(_ payload: Data) {
        guard let (id, bytes) = FileTransferRules.decodeChunk(payload), var current = active, current.id == id else { return }
        do {
            try current.check.add(bytes)
            try current.handle.write(contentsOf: bytes)
            let percent = FileTransferRules.percent(received: current.check.received, total: current.check.size)
            if percent != current.shownPercent {
                current.shownPercent = percent
                progress(current.name, percent)
            }
            active = current
            reply(FileReply(id: id, accepted: true, received: current.check.received))
        } catch {
            discard()
            reply(FileReply(id: id, accepted: false, reason: "The file didn't arrive correctly."))
        }
    }

    func end(_ end: FileEnd) {
        guard let current = active, current.id == end.id else { return }
        guard let digest = end.sha256 else { return discard() }
        do {
            try current.check.finish(sha256: digest)
            try current.handle.close()
            let final = try Self.place(current.part, name: current.name)
            active = nil
            reply(FileReply(id: end.id, accepted: true, received: current.check.size, done: true))
            finished(final, current.check.size)
        } catch {
            discard()
            reply(FileReply(id: end.id, accepted: false, reason: "The file didn't arrive correctly."))
        }
    }

    /// Removes a partial file. Called when a transfer fails or the viewer goes away.
    func discard() {
        guard let current = active else { return }
        active = nil
        try? current.handle.close()
        try? FileManager.default.removeItem(at: current.part)
    }

    private static func folder() throws -> URL {
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = downloads.appendingPathComponent("paneshare", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func place(_ part: URL, name: String) throws -> URL {
        let folder = part.deletingLastPathComponent()
        let unique = FileTransferRules.uniqueName(name) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        var final = folder.appendingPathComponent(unique)
        try FileManager.default.moveItem(at: part, to: final)
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
                                       kLSQuarantineAgentNameKey as String: "paneshare"]
        try final.setResourceValues(values)
        return final
    }
}
#endif
