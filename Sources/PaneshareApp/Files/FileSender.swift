#if os(macOS)
import Crypto
import Foundation
import PaneshareCore

/// Sends files to the other Mac one at a time, as fast as it acknowledges them. The viewer uses it
/// for files dropped on a remote window, and the host for files its user sends to a viewer.
@MainActor
final class FileSender {
    private struct Active {
        let id: UInt32
        let name: String
        let handle: FileHandle
        var pacer: FileSendPacer
        var hasher = SHA256()
        var accepted = false
        var shownPercent = -1
    }

    private var waiting: [URL] = []
    private var active: Active?
    private var nextID: UInt32 = 1
    private let send: (Frame) -> Void
    private let status: (String?) -> Void

    init(send: @escaping (Frame) -> Void, status: @escaping (String?) -> Void) {
        self.send = send
        self.status = status
    }

    func enqueue(_ urls: [URL]) {
        waiting += urls
        startNext()
    }

    func reply(_ reply: FileReply) {
        guard var current = active, current.id == reply.id else { return }
        guard reply.accepted else {
            // Clear the queue first: `finish` starts the next file.
            waiting.removeAll()
            return finish(message: "\(current.name): \(reply.reason ?? "refused.")")
        }
        if reply.done == true { return finish(message: "\(current.name) saved in Downloads/paneshare on that Mac.") }
        current.accepted = true
        if let received = reply.received {
            current.pacer.acknowledge(received)
            let percent = FileTransferRules.percent(received: received, total: current.pacer.size)
            if percent != current.shownPercent {
                current.shownPercent = percent
                status("Sending \(current.name): \(percent)%")
            }
        }
        active = current
        pump()
    }

    /// The connection went away; a partial file is removed on the host.
    func stop() {
        waiting.removeAll()
        try? active?.handle.close()
        active = nil
    }

    private func startNext() {
        guard active == nil, !waiting.isEmpty else { return }
        let url = waiting.removeFirst()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, let handle = try? FileHandle(forReadingFrom: url) else {
            status("\(url.lastPathComponent): only single files can be sent, not folders.")
            return startNext()
        }
        let id = nextID
        nextID &+= 1
        active = Active(id: id, name: url.lastPathComponent, handle: handle, pacer: FileSendPacer(size: UInt64(size)))
        if let frame = try? MessageCodec.frame(.fileOffer, FileOffer(id: id, name: url.lastPathComponent, size: UInt64(size))) {
            send(frame)
        }
        status("Offering \(url.lastPathComponent)…")
        let offeredAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + FileTransferRules.offerTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.checkAnswered(id, offeredAt: offeredAt) }
        }
    }

    /// An older Mac drops offers it can't take without answering; stop waiting for it.
    private func checkAnswered(_ id: UInt32, offeredAt: TimeInterval) {
        guard let current = active, current.id == id, !current.accepted,
              FileTransferRules.offerTimedOut(offeredAt: offeredAt, now: ProcessInfo.processInfo.systemUptime) else { return }
        waiting.removeAll()
        fail(current, message: "\(current.name): that Mac didn't answer. It may need a newer paneshare.")
    }

    private func pump() {
        guard var current = active, current.accepted else { return }
        defer { if active != nil { active = current } }
        while let count = current.pacer.next() {
            guard let bytes = try? current.handle.read(upToCount: count), bytes.count == count else {
                active = current
                return fail(current, message: "\(current.name) couldn't be read.")
            }
            current.hasher.update(data: bytes)
            send(Frame(kind: .fileChunk, payload: FileTransferRules.encodeChunk(id: current.id, bytes: bytes)))
        }
        if current.pacer.isFullySent, current.pacer.acknowledged == current.pacer.size,
           let frame = try? MessageCodec.frame(.fileEnd, FileEnd(id: current.id, sha256: FileTransferRules.digestHex(current.hasher.finalize()))) {
            send(frame)
        }
    }

    private func fail(_ current: Active, message: String) {
        if let frame = try? MessageCodec.frame(.fileEnd, FileEnd(id: current.id, sha256: nil)) { send(frame) }
        finish(message: message)
    }

    private func finish(message: String) {
        try? active?.handle.close()
        active = nil
        status(message)
        startNext()
    }
}
#endif
