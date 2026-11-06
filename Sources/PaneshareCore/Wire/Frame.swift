import Foundation

/// Every message kind on the wire (docs/ARCHITECTURE.md §3.3). Raw values are part of protocol v1
/// and must never be reused.
public enum MessageKind: UInt8, Sendable, CaseIterable {
    case hello = 0x01
    case windowList = 0x02
    case requestWindowList = 0x03
    case openWindow = 0x04
    case streamStarted = 0x05
    case parameterSets = 0x06
    case videoFrame = 0x07
    case input = 0x08
    case resize = 0x09
    case resized = 0x0A
    case closeStream = 0x0B
    case requestKeyframe = 0x0C
    case ping = 0x0D
    case pong = 0x0E
    case error = 0x0F
    case pairBegin = 0x10
    case pairResult = 0x11
    case pairChallenge = 0x12
    case pairResponse = 0x13
    case inputState = 0x14
    case pairStatus = 0x15
    case streamInfo = 0x16
    case audioStarted = 0x17
    case audioFrame = 0x18
    case audioStopped = 0x19
    case audioControl = 0x1A
    case clipboardState = 0x1B
    case clipboardText = 0x1C
    case fileOffer = 0x1D
    case fileReply = 0x1E
    case fileChunk = 0x1F
    case fileEnd = 0x20
    case requestAppList = 0x21
    case appList = 0x22
    case openApp = 0x23
    case openAppResult = 0x24
    case windowPlacement = 0x25
}

public struct FrameFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let keyframe = FrameFlags(rawValue: 1 << 0)
    /// A quality top-up of a still window: the same picture, coded at a much higher bitrate.
    public static let topUp = FrameFlags(rawValue: 1 << 1)
    static let known: FrameFlags = [.keyframe, .topUp]
}

/// One protocol frame: a 12-byte header and a payload.
public struct Frame: Equatable, Sendable {
    public static let magic: (UInt8, UInt8) = (0x50, 0x57) // "PW"
    public static let version: UInt8 = 1
    public static let headerSize = 12

    /// Raw kind byte. Use `kind` for the typed value; unknown kinds are kept so a receiver can skip them.
    public let kindRaw: UInt8
    public let flags: FrameFlags
    public let streamID: UInt16
    public let payload: Data

    public var kind: MessageKind? { MessageKind(rawValue: kindRaw) }

    public init(kind: MessageKind, flags: FrameFlags = [], streamID: UInt16 = 0, payload: Data = Data()) {
        self.init(kindRaw: kind.rawValue, flags: flags, streamID: streamID, payload: payload)
    }

    public init(kindRaw: UInt8, flags: FrameFlags = [], streamID: UInt16 = 0, payload: Data = Data()) {
        self.kindRaw = kindRaw
        self.flags = flags
        self.streamID = streamID
        self.payload = payload
    }

    public func encoded() -> Data {
        var out = Data(capacity: Frame.headerSize + payload.count)
        out.append(Frame.magic.0)
        out.append(Frame.magic.1)
        out.append(Frame.version)
        out.append(kindRaw)
        out.append(flags.rawValue)
        out.append(0)
        out.appendBigEndian(streamID)
        out.appendBigEndian(UInt32(payload.count))
        out.append(payload)
        return out
    }
}

public enum FrameError: Error, Equatable, Sendable {
    case badMagic
    case unsupportedVersion(UInt8)
    case reservedBitsSet
    case payloadTooLarge(length: UInt32, limit: UInt32)
}

/// Incremental frame parser. TCP/TLS delivers arbitrary chunks; feed each chunk to `append` and
/// handle every frame it returns. After a thrown error the decoder is poisoned: the caller must
/// close the connection (any later call throws the same error).
public struct FrameDecoder: Sendable {
    /// Largest payload accepted from a viewer: small control and input JSON, or synced clipboard text.
    public static let viewerToHostLimit: UInt32 = 1024 * 1024
    /// Largest payload accepted from a host (an encoded keyframe of a very large window).
    public static let hostToViewerLimit: UInt32 = 16 * 1024 * 1024

    public let maxPayload: UInt32
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var failure: FrameError?

    public init(maxPayload: UInt32) {
        self.maxPayload = maxPayload
    }

    /// Bytes buffered but not yet returned as a frame.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append(_ data: Data) throws -> [Frame] {
        if let failure { throw failure }
        buffer.append(contentsOf: data)
        var frames: [Frame] = []
        do {
            while let frame = try nextFrame() { frames.append(frame) }
        } catch let error as FrameError {
            failure = error
            throw error
        }
        compact()
        return frames
    }

    private mutating func nextFrame() throws -> Frame? {
        let available = buffer.count - readIndex
        guard available >= Frame.headerSize else {
            // Reject bad magic as soon as the first bytes arrive, without waiting for a full header.
            if available >= 1, buffer[readIndex] != Frame.magic.0 { throw FrameError.badMagic }
            if available >= 2, buffer[readIndex + 1] != Frame.magic.1 { throw FrameError.badMagic }
            return nil
        }
        let h = readIndex
        guard buffer[h] == Frame.magic.0, buffer[h + 1] == Frame.magic.1 else { throw FrameError.badMagic }
        guard buffer[h + 2] == Frame.version else { throw FrameError.unsupportedVersion(buffer[h + 2]) }
        let kind = buffer[h + 3]
        let flags = FrameFlags(rawValue: buffer[h + 4])
        guard flags.isSubset(of: .known), buffer[h + 5] == 0 else { throw FrameError.reservedBitsSet }
        let streamID = UInt16(buffer[h + 6]) << 8 | UInt16(buffer[h + 7])
        let length = UInt32(buffer[h + 8]) << 24 | UInt32(buffer[h + 9]) << 16
            | UInt32(buffer[h + 10]) << 8 | UInt32(buffer[h + 11])
        guard length <= maxPayload else { throw FrameError.payloadTooLarge(length: length, limit: maxPayload) }
        let total = Frame.headerSize + Int(length)
        guard available >= total else { return nil }
        let payload = Data(buffer[(h + Frame.headerSize)..<(h + total)])
        readIndex += total
        return Frame(kindRaw: kind, flags: flags, streamID: streamID, payload: payload)
    }

    private mutating func compact() {
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 64 * 1024 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}
