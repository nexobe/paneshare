import Crypto
import Foundation

/// RFC 6455 server side: the handshake answer, a decoder for client frames and an encoder for
/// server frames. Written from the RFC; only what the web viewer needs (no extensions, no
/// compression, no subprotocols).
public enum WebSocketCodec {
    public enum Opcode: UInt8, Sendable {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
        var isControl: Bool { rawValue & 0x8 != 0 }
    }

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key` (RFC 6455 §4.2.2).
    public static func acceptValue(forKey key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    public static func handshakeResponse(key: String) -> [UInt8] {
        var head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        head += "Sec-WebSocket-Accept: \(acceptValue(forKey: key))\r\n\r\n"
        return Array(head.utf8)
    }

    /// One unmasked server frame, never fragmented.
    public static func encode(_ opcode: Opcode, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | opcode.rawValue]
        out.reserveCapacity(payload.count + 10)
        switch payload.count {
        case ..<126:
            out.append(UInt8(payload.count))
        case ..<65536:
            out.append(126)
            out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        out.append(contentsOf: payload)
        return out
    }

    /// A close frame with a status code (RFC 6455 §7.4) and a short reason.
    public static func closeFrame(code: UInt16, reason: String = "") -> [UInt8] {
        encode(.close, [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(reason.utf8.prefix(120)))
    }

    public enum Message: Equatable, Sendable {
        case text(String)
        case binary([UInt8])
        case ping([UInt8])
        case pong
        case close(code: UInt16?)
    }

    public enum DecodeError: Error, Equatable, Sendable {
        /// Client frames must be masked (RFC 6455 §5.1).
        case unmasked
        case reservedBits
        case unknownOpcode(UInt8)
        case tooLarge
        case badControlFrame
        case badContinuation
        case invalidUTF8
    }

    /// Reassembles client messages from arbitrary chunks. After an error the connection must close.
    public struct Decoder: Sendable {
        public let maxMessage: Int
        private var buffer: [UInt8] = []
        private var fragments: [UInt8] = []
        private var fragmentOpcode: Opcode?
        private var failure: DecodeError?

        public init(maxMessage: Int) { self.maxMessage = maxMessage }

        public mutating func append(_ bytes: [UInt8]) throws -> [Message] {
            if let failure { throw failure }
            buffer.append(contentsOf: bytes)
            var out: [Message] = []
            do {
                while let m = try next() { if let m { out.append(m) } }
            } catch let e as DecodeError {
                failure = e
                throw e
            }
            return out
        }

        /// nil: need more bytes. .some(nil): a frame was consumed that completes no message.
        private mutating func next() throws -> Message?? {
            guard buffer.count >= 2 else { return nil }
            let b0 = buffer[0], b1 = buffer[1]
            let fin = b0 & 0x80 != 0
            guard b0 & 0x70 == 0 else { throw DecodeError.reservedBits }
            guard let opcode = Opcode(rawValue: b0 & 0x0F) else { throw DecodeError.unknownOpcode(b0 & 0x0F) }
            guard b1 & 0x80 != 0 else { throw DecodeError.unmasked }
            var length = Int(b1 & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return nil }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return nil }
                var l: UInt64 = 0
                for i in 2..<10 { l = l << 8 | UInt64(buffer[i]) }
                guard l <= UInt64(maxMessage) else { throw DecodeError.tooLarge }
                length = Int(l)
                offset = 10
            }
            if opcode.isControl { guard fin, length <= 125 else { throw DecodeError.badControlFrame } }
            guard length <= maxMessage, fragments.count + length <= maxMessage else { throw DecodeError.tooLarge }
            guard buffer.count >= offset + 4 + length else { return nil }
            let mask = Array(buffer[offset..<(offset + 4)])
            var payload = Array(buffer[(offset + 4)..<(offset + 4 + length)])
            for i in payload.indices { payload[i] ^= mask[i & 3] }
            buffer.removeFirst(offset + 4 + length)

            switch opcode {
            case .ping: return .some(.ping(payload))
            case .pong: return .some(.pong)
            case .close:
                let code = payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil
                return .some(.close(code: code))
            case .text, .binary:
                guard fragmentOpcode == nil else { throw DecodeError.badContinuation }
                if !fin {
                    fragmentOpcode = opcode
                    fragments = payload
                    return .some(nil)
                }
                return .some(try Self.message(opcode, payload))
            case .continuation:
                guard let first = fragmentOpcode else { throw DecodeError.badContinuation }
                fragments.append(contentsOf: payload)
                guard fin else { return .some(nil) }
                let whole = fragments
                fragments = []
                fragmentOpcode = nil
                return .some(try Self.message(first, whole))
            }
        }

        private static func message(_ opcode: Opcode, _ payload: [UInt8]) throws -> Message {
            if opcode == .text {
                guard let s = String(strictUTF8: payload) else { throw DecodeError.invalidUTF8 }
                return .text(s)
            }
            return .binary(payload)
        }
    }
}

extension String {
    /// Strict UTF-8 decoding; nil on any invalid sequence (`String(decoding:)` would repair it).
    init?(strictUTF8 bytes: [UInt8]) {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return nil }
        self = s
    }
}
