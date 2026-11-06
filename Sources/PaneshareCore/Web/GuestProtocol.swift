import Foundation

/// What a browser's WebCodecs `VideoDecoder` needs to decode paneshare's H.264 stream: an RFC 6381
/// codec string and an `avcC` record (ISO/IEC 14496-15 §5.3.3.1) built from the SPS and PPS. Frames
/// are already AVCC (4-byte lengths), which is what a decoder configured with `description` expects.
public struct H264DecoderConfig: Equatable, Sendable {
    /// "avc1.PPCCLL": profile_idc, constraint flags, level_idc in hex.
    public let codec: String
    public let avcC: [UInt8]

    /// nil unless there is at least one SPS (NAL type 7) and one PPS (type 8).
    public init?(parameterSets: [[UInt8]]) {
        let sps = parameterSets.filter { ($0.first ?? 0) & 0x1F == 7 && $0.count >= 4 && $0.count <= 0xFFFF }
        let pps = parameterSets.filter { ($0.first ?? 0) & 0x1F == 8 && $0.count <= 0xFFFF }
        guard let first = sps.first, !pps.isEmpty, sps.count <= 31, pps.count <= 255 else { return nil }
        codec = "avc1." + first[1...3].map { String(format: "%02X", $0) }.joined()
        var r: [UInt8] = [1, first[1], first[2], first[3], 0xFF, 0xE0 | UInt8(sps.count)]
        for s in sps { r += [UInt8(s.count >> 8), UInt8(s.count & 0xFF)] + s }
        r.append(UInt8(pps.count))
        for p in pps { r += [UInt8(p.count >> 8), UInt8(p.count & 0xFF)] + p }
        avcC = r
    }
}

/// Host → guest: JSON text messages, tagged by `t`.
public struct GuestNotice: Codable, Equatable, Sendable {
    public var t: String
    public var session: String?
    public var secret: String?
    public var title: String?
    public var app: String?
    public var pointer: Bool?
    /// Milliseconds since 1970 when the link stops working.
    public var expires: Double?
    public var codec: String?
    public var description: String?
    public var w: Double?
    public var h: Double?
    public var pw: Int?
    public var ph: Int?
    public var input: Bool?
    public var reason: String?

    public init(t: String) { self.t = t }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// WebSocket close codes the host uses (4000–4999 is the application range, RFC 6455 §7.4.2). The
/// viewer page tells the guest what happened and only reconnects after `networkError`-like closes.
public enum GuestCloseCode: UInt16, Sendable {
    case expired = 4001
    /// Unknown link, wrong or already-used token, unknown session.
    case rejected = 4002
    case kicked = 4003
    case windowClosed = 4004
    case hostStopped = 4005
    case tooMany = 4006
    case protocolError = 4007
    /// The same guest connected again (a reload, or another tab); this connection is superseded.
    case replaced = 4008
}

public enum GuestOutbound: Equatable, Sendable {
    case text(String)
    case binary([UInt8])
    case close(code: UInt16, reason: String)
}

/// Turns what `HostStream` sends a viewer into what the browser understands. Video becomes binary
/// `0x01 flags(1) ptsMicros(8, BE) accessUnit`; everything a guest doesn't need is dropped.
public enum GuestWire {
    public static let videoTag: UInt8 = 0x01

    public static func translate(_ frame: Frame) -> GuestOutbound? {
        switch frame.kind {
        case .streamStarted:
            guard let s = try? MessageCodec.decode(StreamStarted.self, from: frame) else { return nil }
            var n = GuestNotice(t: "started")
            n.title = s.window.displayTitle
            n.app = s.window.appName
            n.w = s.pointSize.width; n.h = s.pointSize.height
            n.pw = s.pixelSize.width; n.ph = s.pixelSize.height
            n.input = s.inputEnabled ?? true
            return .text(n.json())
        case .parameterSets:
            guard let sets = try? ParameterSets(decoding: frame.payload), sets.codec == .h264,
                  let config = H264DecoderConfig(parameterSets: sets.sets.map { [UInt8]($0) }) else { return nil }
            var n = GuestNotice(t: "config")
            n.codec = config.codec
            n.description = Data(config.avcC).base64EncodedString()
            return .text(n.json())
        case .videoFrame:
            guard frame.payload.count > 8 else { return nil }
            var out: [UInt8] = [videoTag, frame.flags.rawValue]
            out.reserveCapacity(frame.payload.count + 2)
            out.append(contentsOf: frame.payload)
            return .binary(out)
        case .resized:
            guard let r = try? MessageCodec.decode(Resized.self, from: frame), r.final ?? true else { return nil }
            var n = GuestNotice(t: "size")
            n.w = r.pointSize.width; n.h = r.pointSize.height
            n.pw = r.pixelSize.width; n.ph = r.pixelSize.height
            return .text(n.json())
        case .closeStream:
            let reason = (try? MessageCodec.decode(CloseStream.self, from: frame))?.reason
            let code: GuestCloseCode = reason == .windowClosed ? .windowClosed : .hostStopped
            return .close(code: code.rawValue, reason: "\(code)")
        default:
            return nil
        }
    }
}

/// Guest → host: JSON text messages. The first one is `join`; after that, pointer messages and
/// keyframe requests. Unknown fields are ignored.
public struct GuestInbound: Codable, Equatable, Sendable {
    public var t: String
    // join
    public var link: String?
    public var token: String?
    public var session: String?
    public var secret: String?
    public var name: String?
    public var scale: Double?
    // pointer
    public var x: Double?
    public var y: Double?
    /// DOM `MouseEvent.button`: 0 left, 2 right.
    public var b: Int?
    /// Click count, 1–3.
    public var c: Int?
    /// Scroll deltas in pixels, already in macOS's sign convention (positive y scrolls content down).
    public var dx: Double?
    public var dy: Double?

    public init(t: String) { self.t = t }

    public static let maxSize = 1024

    public static func decode(_ text: String) -> GuestInbound? {
        guard text.utf8.count <= maxSize else { return nil }
        return try? JSONDecoder().decode(GuestInbound.self, from: Data(text.utf8))
    }
}

/// A guest's input scope (ARCHITECTURE §7.4): its pointer is always shown to the host user, but it
/// only reaches the window as clicks, drags and scrolls while the host allows it, never as keys,
/// and never as plain mouse moves (which would drag the host's own cursor around).
public struct GuestPointer: Sendable {
    public enum Action: Equatable, Sendable {
        /// Draw the guest's pointer at this point; nothing is injected.
        case show(NormalizedPoint)
        /// The guest's pointer left the picture.
        case hide
        case inject(InputEvent)
        case keyframe
    }

    public private(set) var position: NormalizedPoint?
    public private(set) var held: MouseButton?

    /// At most this many pointer messages per second; the rest are dropped.
    public static let maxPerSecond = 240
    private var windowStart: TimeInterval = 0
    private var countInWindow = 0

    public init() {}

    public mutating func handle(_ m: GuestInbound, pointerAllowed: Bool, now: TimeInterval) -> [Action] {
        if m.t == "kf" { return [.keyframe] }
        if m.t == "leave" { return held == nil ? [.hide] : [] }
        if now - windowStart >= 1 { windowStart = now; countInWindow = 0 }
        countInWindow += 1
        guard countInWindow <= Self.maxPerSecond else { return [] }
        guard let x = m.x, let y = m.y, x.isFinite, y.isFinite else { return [] }
        let p = NormalizedPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        position = p
        switch m.t {
        case "move":
            guard pointerAllowed, let held else { return [.show(p)] }
            return [.show(p), .inject(InputEvent(kind: .mouseDrag, position: p, button: held))]
        case "down":
            guard pointerAllowed, held == nil, let button = Self.button(m.b) else { return [.show(p)] }
            held = button
            let clicks = min(3, max(1, m.c ?? 1))
            return [.show(p), .inject(InputEvent(kind: .mouseDown, position: p, button: button, clickCount: clicks))]
        case "up":
            guard let held, held == Self.button(m.b) else { return [.show(p)] }
            self.held = nil
            guard pointerAllowed else { return [.show(p)] }
            let clicks = min(3, max(1, m.c ?? 1))
            return [.show(p), .inject(InputEvent(kind: .mouseUp, position: p, button: held, clickCount: clicks))]
        case "scroll":
            guard pointerAllowed else { return [.show(p)] }
            let dx = min(2000, max(-2000, m.dx ?? 0)), dy = min(2000, max(-2000, m.dy ?? 0))
            guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return [.show(p)] }
            return [.show(p), .inject(InputEvent(kind: .scroll, position: p, scrollDeltaX: dx, scrollDeltaY: dy, scrollUnit: .pixel))]
        default:
            return []
        }
    }

    /// The host took pointer control away (or the guest left): release a held button so nothing stays pressed.
    public mutating func revoke() -> [InputEvent] {
        defer { held = nil }
        guard let held, let position else { return [] }
        return [InputEvent(kind: .mouseUp, position: position, button: held, clickCount: 1)]
    }

    static func button(_ dom: Int?) -> MouseButton? {
        switch dom {
        case 0: return .left
        case 2: return .right
        default: return nil
        }
    }
}
