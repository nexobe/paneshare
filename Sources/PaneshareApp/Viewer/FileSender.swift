#if os(macOS)
import Crypto
import Foundation
import PaneshareCore

/// Sends dropped files to the host one at a time, as fast as the host acknowledges them.
@MainActor
final class FileSender {
    private struct Active {
        let id: UInt32
        let name: String
        let handle: FileHandle
        var pacer: FileSendPacer
        var hasher = SHA256()
        var accepted = false
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
            finish(message: "\(current.name): \(reply.reason ?? "refused.")")
            waiting.removeAll()
            return
        }
        if reply.done == true { return finish(message: "\(current.name) saved in Downloads/paneshare on that Mac.") }
        current.accepted = true
        if let received = reply.received {
            current.pacer.acknowledge(received)
            let total = max(current.pacer.size, 1)
            status("Sending \(current.name): \(received * 100 / total)%")
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
