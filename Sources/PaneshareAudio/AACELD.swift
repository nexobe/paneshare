#if os(macOS)
import AudioToolbox
import AVFoundation
import Foundation
import PaneshareCore

/// The audio codec: MPEG-4 AAC Enhanced Low Delay through the system's AVAudioConverter.
///
/// Why AAC-ELD rather than Opus: it ships in every macOS (no third-party codec to vendor, build or
/// license), it's designed for conferencing latency (512-sample packets, about 10.7 ms at 48 kHz,
/// with a small algorithmic delay), and it encodes and decodes on both ends with public API.
/// Opus would mean vendoring libopus as a C target. The cost is that browsers can't decode it in
/// WebRTC, which matters only for the browser viewer, where audio is deferred.
public enum AACELD {
    public static let sampleRate: Double = 48_000
    public static let channels: AVAudioChannelCount = 2
    public static let framesPerPacket = 512
    public static let bitrate = 96_000

    static func compressedFormat(sampleRate: Double, channels: UInt32, framesPerPacket: Int) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)
    }

    static func interleavedFloat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true)
    }
}

public enum AudioCodecError: Error, CustomStringConvertible {
    case setup(String)
    public var description: String {
        switch self { case .setup(let what): return "Audio codec setup failed: \(what)" }
    }
}

/// Host side: interleaved stereo Float32 at the capture rate in, timestamped AAC-ELD packets out.
/// Not thread-safe; the host calls it from its capture queue.
public final class AACELDEncoder {
    public let inputRate: Double
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var pending: [AVAudioPCMBuffer] = []
    private var timeline: AudioTimeline
    private var packetsOut: Int64 = 0
    private let leadingFrames: Int64

    public init(inputRate: Double) throws {
        guard let input = AACELD.interleavedFloat(sampleRate: inputRate),
              let output = AACELD.compressedFormat(sampleRate: AACELD.sampleRate, channels: UInt32(AACELD.channels),
                                                   framesPerPacket: AACELD.framesPerPacket),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioCodecError.setup("no AAC-ELD encoder for \(inputRate) Hz")
        }
        converter.bitRate = AACELD.bitrate
        self.inputRate = inputRate
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
        self.timeline = AudioTimeline(sampleRate: inputRate)
        self.leadingFrames = Int64(converter.primeInfo.leadingFrames)
    }

    /// The AudioSpecificConfig the decoder needs, available once the converter exists.
    public var magicCookie: Data? { converter.magicCookie }

    public func encode(_ audio: CapturedAudio) -> [AudioFramePayload] {
        guard audio.frames > 0, audio.sampleRate == inputRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(audio.frames)),
              let dst = buffer.floatChannelData?[0] else { return [] }
        buffer.frameLength = AVAudioFrameCount(audio.frames)
        audio.samples.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: min(src.count, audio.frames * 2))
        }
        timeline.append(frames: audio.frames, hostPtsMicros: audio.hostPtsMicros)
        pending.append(buffer)

        var packets: [AudioFramePayload] = []
        while true {
            let out = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 8,
                                              maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [unowned self] _, inputStatus in
                guard !self.pending.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            if status == .error {
                NSLog("paneshare audio: encode failed: %@", "\(error.map { "\($0)" } ?? "unknown")")
                pending.removeAll()
                break
            }
            if let descriptions = out.packetDescriptions {
                for i in 0..<Int(out.packetCount) {
                    let d = descriptions[i]
                    let data = Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
                    packets.append(AudioFramePayload(ptsMicros: pts(ofPacket: packetsOut), packet: data))
                    packetsOut += 1
                }
            }
            if status != .haveData || out.packetCount == 0 { break }
        }
        return packets
    }

    /// Host time of a packet's first decoded sample: its position in output samples, less the
    /// encoder's delay, mapped back to the capture rate and through the capture timeline.
    private func pts(ofPacket n: Int64) -> UInt64 {
        let output = max(0, n * Int64(AACELD.framesPerPacket) - leadingFrames)
        let input = Int64((Double(output) * inputRate / AACELD.sampleRate).rounded())
        return timeline.pts(ofSample: input) ?? 0
    }
}

/// Viewer side: AAC-ELD packets in, interleaved stereo Float32 out. Not thread-safe; each remote
/// audio stream decodes on its own serial queue.
public final class AACELDDecoder {
    public let sampleRate: Double
    public let framesPerPacket: Int
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    public init(_ started: AudioStarted) throws {
        guard started.codec == .aacELD, started.channels == 2, started.sampleRate >= 8_000, started.sampleRate <= 96_000,
              started.framesPerPacket > 0, started.framesPerPacket <= 2048 else {
            throw AudioCodecError.setup("unsupported stream \(started.codec.rawValue) \(started.channels)ch \(started.sampleRate) Hz")
        }
        guard let input = AACELD.compressedFormat(sampleRate: started.sampleRate, channels: UInt32(started.channels),
                                                  framesPerPacket: started.framesPerPacket),
              let output = AACELD.interleavedFloat(sampleRate: started.sampleRate) else {
            throw AudioCodecError.setup("formats")
        }
        input.magicCookie = started.magicCookie
        guard let converter = AVAudioConverter(from: input, to: output) else { throw AudioCodecError.setup("no AAC-ELD decoder") }
        self.sampleRate = started.sampleRate
        self.framesPerPacket = started.framesPerPacket
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
    }

    public func decode(_ packet: Data) -> [Float] {
        guard !packet.isEmpty, packet.count <= 8192 else { return [] }
        let input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                     mDataByteSize: UInt32(packet.count))
        input.packetCount = 1
        input.byteLength = UInt32(packet.count)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(framesPerPacket * 2)) else { return [] }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength) * 2))
    }
}
#endif
