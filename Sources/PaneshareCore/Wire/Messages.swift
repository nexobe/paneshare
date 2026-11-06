import Foundation

public enum PeerRole: String, Codable, Sendable { case host, viewer }

public enum VideoCodec: UInt8, Codable, Sendable { case h264 = 1, hevc = 2 }

public struct WirePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct WireSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct WireRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct PixelSize: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// A shareable window as the host describes it. `frame` is in global display points, top-left
/// origin (the ScreenCaptureKit / CGWindow coordinate space).
public struct WindowInfo: Codable, Equatable, Sendable {
    public var windowID: UInt32
    public var title: String
    public var appName: String
    public var bundleID: String
    public var processID: Int32
    public var frame: WireRect
    public var layer: Int
    public var isOnScreen: Bool
    /// Set when this offer is a whole screen, not a window (`ScreenOffer`).
    public var displayID: UInt32?

    public init(windowID: UInt32, title: String, appName: String, bundleID: String, processID: Int32,
                frame: WireRect, layer: Int = 0, isOnScreen: Bool = true) {
        self.windowID = windowID; self.title = title; self.appName = appName; self.bundleID = bundleID
        self.processID = processID; self.frame = frame; self.layer = layer; self.isOnScreen = isOnScreen
    }

    /// "App — Title", or just the app name for an untitled window.
    public var displayTitle: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var appVersion: String
    public var deviceName: String
    public var role: PeerRole
    public init(protocolVersion: Int = Int(Frame.version), appVersion: String, deviceName: String, role: PeerRole) {
        self.protocolVersion = protocolVersion; self.appVersion = appVersion
        self.deviceName = deviceName; self.role = role
    }
}

/// How many pixels per backing pixel the viewer wants: the capture size is the window's points ×
/// the viewer's backing scale × this factor.
public enum StreamQuality: String, Codable, CaseIterable, Sendable {
    case native, balanced, economy

    public var factor: Double {
        switch self {
        case .native: return 1
        case .balanced: return 0.75
        case .economy: return 0.5
        }
    }
}

public struct OpenWindow: Codable, Equatable, Sendable {
    public var windowID: UInt32
    public var viewerBackingScale: Double
    /// Absent means `.native`.
    public var quality: StreamQuality?
    /// Chroma formats the viewer will decode. Absent means 4:2:0 only.
    public var chroma: [ChromaFormat]?
    /// Whether the viewer wants this app's audio. Absent means no (older viewers can't play it).
    public var audio: Bool?
    /// The usable area of the viewer's screen in points, for sizing a virtual display on the host.
    public var viewerDisplay: WireSize?
    /// Whether the host may lower the bitrate when frames drop. Absent means no.
    public var adaptiveQuality: Bool?
    public init(windowID: UInt32, viewerBackingScale: Double, quality: StreamQuality? = nil, chroma: [ChromaFormat]? = nil,
                audio: Bool? = nil, viewerDisplay: WireSize? = nil, adaptiveQuality: Bool? = nil) {
        self.adaptiveQuality = adaptiveQuality
        self.windowID = windowID; self.viewerBackingScale = viewerBackingScale; self.quality = quality
        self.chroma = chroma
        self.audio = audio
        self.viewerDisplay = viewerDisplay
    }
}

/// Host → viewer, per stream, after `streamStarted` and after every capture or encoder rebuild:
/// what the host is actually producing, for the viewer's diagnostics overlay and log.
public struct StreamInfo: Codable, Equatable, Sendable {
    /// The source window's backing scale on the host (2 on Retina), when ScreenCaptureKit reports it.
    public var sourceScale: Double?
    public var sourcePoints: WireSize
    public var capturePixels: PixelSize
    /// e.g. "BGRA".
    public var captureFormat: String
    public var encodedPixels: PixelSize
    public var codec: VideoCodec
    public var chroma: ChromaFormat
    /// VideoToolbox profile name, e.g. "HEVC_Main_AutoLevel".
    public var profile: String
    public var hardware: Bool
    public var bitrate: Int
    public var topUpBitrate: Int
    /// The viewer may ask to move this window off the host's screens. Absent means no.
    public var movable: Bool?
    /// The window is on a virtual display, off the host's screens. Absent means no.
    public var movedAway: Bool?
    public init(sourceScale: Double?, sourcePoints: WireSize, capturePixels: PixelSize, captureFormat: String,
                encodedPixels: PixelSize, codec: VideoCodec, chroma: ChromaFormat, profile: String, hardware: Bool,
                bitrate: Int, topUpBitrate: Int) {
        self.sourceScale = sourceScale; self.sourcePoints = sourcePoints; self.capturePixels = capturePixels
        self.captureFormat = captureFormat; self.encodedPixels = encodedPixels; self.codec = codec
        self.chroma = chroma; self.profile = profile; self.hardware = hardware
        self.bitrate = bitrate; self.topUpBitrate = topUpBitrate
    }
}

/// Viewer → host, per stream: move the window onto a virtual display, or back where it was.
/// The host answers with a new `StreamInfo`.
public struct WindowPlacement: Codable, Equatable, Sendable {
    public var away: Bool
    public init(away: Bool) { self.away = away }
}

public struct StreamStarted: Codable, Equatable, Sendable {
    public var streamID: UInt16
    public var window: WindowInfo
    public var pointSize: WireSize
    public var pixelSize: PixelSize
    public var codec: VideoCodec
    public var appIconPNG: Data?
    /// False when the host can't inject input (no Accessibility trust): the stream is view-only.
    /// Absent means unknown, treated as enabled.
    public var inputEnabled: Bool?
    public init(streamID: UInt16, window: WindowInfo, pointSize: WireSize, pixelSize: PixelSize,
                codec: VideoCodec, appIconPNG: Data? = nil, inputEnabled: Bool? = nil) {
        self.streamID = streamID; self.window = window; self.pointSize = pointSize
        self.pixelSize = pixelSize; self.codec = codec; self.appIconPNG = appIconPNG
        self.inputEnabled = inputEnabled
    }
}

public struct ResizeRequest: Codable, Equatable, Sendable {
    public var pointSize: WireSize
    /// False while the viewer's live resize is still going: the host resizes the window but keeps
    /// the stream's pixel size until the final request. Absent means final.
    public var final: Bool?
    public init(pointSize: WireSize, final: Bool? = nil) { self.pointSize = pointSize; self.final = final }
}

public struct Resized: Codable, Equatable, Sendable {
    public var pointSize: WireSize
    public var pixelSize: PixelSize
    /// True once the stream has been re-sized for the final request.
    public var final: Bool?
    public init(pointSize: WireSize, pixelSize: PixelSize, final: Bool? = nil) {
        self.pointSize = pointSize; self.pixelSize = pixelSize; self.final = final
    }
}

/// Host → viewer, per stream, whenever the host starts or stops dropping the viewer's input.
public struct InputState: Codable, Equatable, Sendable {
    public enum Pause: String, Codable, Sendable {
        /// Something on the host has secure keyboard entry on (a password field, a terminal's
        /// secure keyboard entry): key presses are dropped, pointer events still flow.
        case secureInput
        /// The host has lost Accessibility trust: all input is dropped (view only).
        case noAccessibility
    }
    /// Nil when input flows normally.
    public var paused: Pause?
    public init(paused: Pause?) { self.paused = paused }
}

public struct CloseStream: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case viewerClosed, windowClosed, hostStopped, error }
    public var reason: Reason
    public init(reason: Reason) { self.reason = reason }
}

public struct ProtocolErrorMessage: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

/// Viewer → host, first message on a `paneshare-pair/2` connection: the pairing request. The host
/// shows a prompt; nothing else happens until its user types the viewer's code there.
public struct PairBegin: Codable, Equatable, Sendable {
    public var viewerName: String
    public var nonce: Data
    public init(viewerName: String, nonce: Data) { self.viewerName = viewerName; self.nonce = nonce }
}

/// Host → viewer, not final: where the request stands on the host.
public struct PairStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The prompt is on the host's screen.
        case prompted
        /// The code typed on the host didn't match; the prompt is still up.
        case wrongCode
    }
    public var state: State
    /// Tries the host prompt has left, for `wrongCode`.
    public var attemptsLeft: Int?
    public init(state: State, attemptsLeft: Int? = nil) { self.state = state; self.attemptsLeft = attemptsLeft }
}

/// Host → viewer: the host's nonce and key share for the code its user typed. Each one spends an
/// attempt on both sides.
public struct PairChallenge: Codable, Equatable, Sendable {
    public var nonce: Data
    public var share: Data
    public init(nonce: Data, share: Data) { self.nonce = nonce; self.share = share }
}

/// Viewer → host: the viewer's key share and its confirmation tag.
public struct PairResponse: Codable, Equatable, Sendable {
    public var share: Data
    public var confirm: Data
    public init(share: Data, confirm: Data) { self.share = share; self.confirm = confirm }
}

/// Host → viewer, last message. `confirm` is the host's tag, present only when accepted.
public struct PairResult: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case wrongCode, expired, exhausted, notOpen, busy, malformed, declined }
    public var accepted: Bool
    public var reason: Reason?
    public var hostName: String?
    public var confirm: Data?
    public init(accepted: Bool, reason: Reason? = nil, hostName: String? = nil, confirm: Data? = nil) {
        self.accepted = accepted; self.reason = reason; self.hostName = hostName; self.confirm = confirm
    }
}

/// VPS/SPS/PPS (HEVC) or SPS/PPS (H.264), exactly as VideoToolbox reports them.
public struct ParameterSets: Equatable, Sendable {
    public var codec: VideoCodec
    public var sets: [Data]
    public init(codec: VideoCodec, sets: [Data]) { self.codec = codec; self.sets = sets }

    /// `codec(1) count(1) [len(2, BE) bytes]…`
    public func encoded() -> Data {
        var d = Data()
        d.append(codec.rawValue)
        d.append(UInt8(sets.count))
        for s in sets {
            d.appendBigEndian(UInt16(s.count))
            d.append(s)
        }
        return d
    }

    public init(decoding data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 2, let codec = VideoCodec(rawValue: b[0]) else { throw MessageError.malformed("parameterSets header") }
        let count = Int(b[1])
        guard count > 0, count <= 8 else { throw MessageError.malformed("parameterSets count") }
        var i = 2
        var sets: [Data] = []
        for _ in 0..<count {
            guard i + 2 <= b.count else { throw MessageError.malformed("parameterSets length") }
            let len = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2
            guard len > 0, i + len <= b.count else { throw MessageError.malformed("parameterSets body") }
            sets.append(Data(b[i..<(i + len)]))
            i += len
        }
        guard i == b.count else { throw MessageError.malformed("parameterSets trailing bytes") }
        self.codec = codec
        self.sets = sets
    }
}

/// One encoded access unit: `ptsMicros(8, BE)` then AVCC data (4-byte length-prefixed NAL units).
public struct VideoFramePayload: Equatable, Sendable {
    public var ptsMicros: UInt64
    public var accessUnit: Data
    public init(ptsMicros: UInt64, accessUnit: Data) { self.ptsMicros = ptsMicros; self.accessUnit = accessUnit }

    public func encoded() -> Data {
        var d = Data(capacity: 8 + accessUnit.count)
        d.appendBigEndian(ptsMicros)
        d.append(accessUnit)
        return d
    }

    public init(decoding data: Data) throws {
        guard data.count > 8 else { throw MessageError.malformed("videoFrame too short") }
        var pts: UInt64 = 0
        for byte in data.prefix(8) { pts = pts << 8 | UInt64(byte) }
        self.ptsMicros = pts
        self.accessUnit = Data(data.dropFirst(8))
    }
}

public enum AudioCodecKind: String, Codable, Sendable {
    /// MPEG-4 AAC Enhanced Low Delay, raw packets (no ADTS), as Core Audio produces them.
    case aacELD = "aac-eld"
}

public enum AudioSource: String, Codable, Sendable {
    /// A Core Audio process tap (macOS 14.2+).
    case processTap
    /// ScreenCaptureKit app audio.
    case screenCaptureKit
}

/// Host → viewer, on a new audio stream ID: one shared app's audio is starting. Audio streams use
/// the same ID space as window streams; one per (viewer, app), however many of its windows are open.
public struct AudioStarted: Codable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var codec: AudioCodecKind
    public var sampleRate: Double
    public var channels: Int
    public var framesPerPacket: Int
    /// The encoder's magic cookie (the AAC AudioSpecificConfig), which the decoder needs.
    public var magicCookie: Data?
    public var source: AudioSource
    public var bitrate: Int
    public init(bundleID: String, appName: String, codec: AudioCodecKind = .aacELD, sampleRate: Double, channels: Int,
                framesPerPacket: Int, magicCookie: Data?, source: AudioSource, bitrate: Int) {
        self.bundleID = bundleID; self.appName = appName; self.codec = codec; self.sampleRate = sampleRate
        self.channels = channels; self.framesPerPacket = framesPerPacket; self.magicCookie = magicCookie
        self.source = source; self.bitrate = bitrate
    }
}

/// Host → viewer: an audio stream ended. Its stream ID isn't reused.
public struct AudioStopped: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case viewerMuted, windowsClosed, turnedOffOnHost, captureFailed
    }
    public var bundleID: String
    public var reason: Reason
    public init(bundleID: String, reason: Reason) { self.bundleID = bundleID; self.reason = reason }
}

/// Viewer → host: start or stop sending one app's audio (the viewer's mute stops it at the source,
/// so a muted app costs no bandwidth).
public struct AudioControl: Codable, Equatable, Sendable {
    public var bundleID: String
    public var enabled: Bool
    public init(bundleID: String, enabled: Bool) { self.bundleID = bundleID; self.enabled = enabled }
}

/// One encoded audio packet: `ptsMicros(8, BE)` (host time of its first sample, same clock as
/// video) then the raw codec packet.
public struct AudioFramePayload: Equatable, Sendable {
    public var ptsMicros: UInt64
    public var packet: Data
    public init(ptsMicros: UInt64, packet: Data) { self.ptsMicros = ptsMicros; self.packet = packet }

    public func encoded() -> Data {
        var d = Data(capacity: 8 + packet.count)
        d.appendBigEndian(ptsMicros)
        d.append(packet)
        return d
    }

    public init(decoding data: Data) throws {
        guard data.count > 8 else { throw MessageError.malformed("audioFrame too short") }
        self.ptsMicros = data.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
        self.packet = Data(data.dropFirst(8))
    }
}

/// `ping`/`pong` payload: 8 bytes, big-endian, opaque to the side that echoes it.
public enum PingPayload {
    public static func encode(_ value: UInt64) -> Data {
        var d = Data(capacity: 8)
        d.appendBigEndian(value)
        return d
    }

    public static func decode(_ data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        return data.reduce(0) { $0 << 8 | UInt64($1) }
    }
}

public enum MessageError: Error, Equatable, Sendable {
    case malformed(String)
    case unexpectedKind(UInt8)
}

/// JSON encoding of control messages into frames, and back.
public enum MessageCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static func frame<T: Encodable>(_ kind: MessageKind, _ value: T, streamID: UInt16 = 0) throws -> Frame {
        Frame(kind: kind, streamID: streamID, payload: try encoder.encode(value))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from frame: Frame) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: frame.payload)
        } catch {
            throw MessageError.malformed("\(T.self): \(error)")
        }
    }
}
