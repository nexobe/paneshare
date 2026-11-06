#if canImport(Darwin)
import Darwin
import Foundation

/// A Unix-domain stream socket in a 0700 directory, itself 0600, so only this user can reach it.
/// The listener still checks every peer's code identity (see the main app's `DockLinkServer`).
public enum DockLinkSocket {
    public enum Failure: Error, Sendable {
        case pathTooLong
        case system(String, Int32)
    }

    /// From <sys/un.h>; spelled out so the import doesn't depend on macro bridging.
    static let solLocal: Int32 = 0
    static let localPeerPID: Int32 = 0x002
    static let localPeerToken: Int32 = 0x006

    public static func listen(path: String) throws -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory, 0o700) == 0 else { throw Failure.system("chmod", errno) }
        var address = try socketAddress(path)
        let fd = try makeSocket()
        _ = unlink(path)
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        _ = umask(previous)
        guard bound == 0 else { let e = errno; _ = Darwin.close(fd); throw Failure.system("bind", e) }
        guard chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            let e = errno; _ = Darwin.close(fd); _ = unlink(path); throw Failure.system("listen", e)
        }
        return fd
    }

    public static func connect(path: String) throws -> Int32 {
        var address = try socketAddress(path)
        let fd = try makeSocket()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { let e = errno; _ = Darwin.close(fd); throw Failure.system("connect", e) }
        return fd
    }

    public static func accept(listener: Int32) -> Int32? {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        configure(fd)
        return fd
    }

    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, solLocal, localPeerPID, &pid, &length) == 0 ? pid : nil
    }

    /// The peer's `audit_token_t` (32 bytes), which names the exact process even if its PID is reused.
    public static func peerAuditToken(_ fd: Int32) -> Data? {
        var token = [UInt8](repeating: 0, count: 32)
        var length = socklen_t(token.count)
        guard getsockopt(fd, solLocal, localPeerToken, &token, &length) == 0, length == 32 else { return nil }
        return Data(token)
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        configure(fd)
        return fd
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // A stuck peer can block a write for at most a second; messages are tiny.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        guard DockLinkPaths.fitsSocketAddress(path) else { throw Failure.pathTooLong }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        return address
    }
}

/// One framed, bidirectional link over a connected socket. Everything runs on `queue`.
public final class DockLinkConnection: @unchecked Sendable {
    public let fd: Int32
    public let queue: DispatchQueue
    public var onMessage: (@Sendable (DockLinkMessage) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    private var source: DispatchSourceRead?
    private var decoder = DockLinkFraming.Decoder()
    private var closed = false

    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    public func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [fd] in _ = Darwin.close(fd) }
            self.source = source
            source.resume()
        }
    }

    public func send(_ message: DockLinkMessage) {
        queue.async { [self] in
            guard !closed, let data = try? DockLinkFraming.encode(message) else { return }
            let ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            if !ok { closeNow() }
        }
    }

    public func close() {
        queue.async { [self] in closeNow() }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(fd, &buffer, buffer.count)
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        guard count > 0 else { return closeNow() }
        do {
            for message in try decoder.feed(Data(buffer[0..<count])) where !closed { onMessage?(message) }
        } catch {
            closeNow()
        }
    }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        if let source { source.cancel() } else { _ = Darwin.close(fd) }
        source = nil
        let handler = onClose
        onClose = nil
        onMessage = nil
        handler?()
    }
}

/// Accepts connections on a listening socket; removes the socket file when stopped.
public final class DockLinkListener: @unchecked Sendable {
    public let path: String
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    public var onAccept: (@Sendable (Int32) -> Void)?

    public init(path: String, queue: DispatchQueue) throws {
        self.path = path
        self.queue = queue
        fd = try DockLinkSocket.listen(path: path)
    }

    public func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, let client = DockLinkSocket.accept(listener: self.fd) else { return }
                if let onAccept = self.onAccept { onAccept(client) } else { _ = Darwin.close(client) }
            }
            source.setCancelHandler { [fd, path] in _ = Darwin.close(fd); _ = unlink(path) }
            self.source = source
            source.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            if let source { source.cancel() } else { _ = Darwin.close(fd); _ = unlink(path) }
            source = nil
        }
    }
}
#endif
