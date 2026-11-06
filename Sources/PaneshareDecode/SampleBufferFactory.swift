#if os(macOS)
import CoreMedia
import Foundation
import PaneshareCore

public enum DecodeError: Error, CustomStringConvertible {
    case formatDescription(OSStatus)
    case noFormat
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)

    public var description: String {
        switch self {
        case .formatDescription(let s): return "Bad parameter sets (\(s))."
        case .noFormat: return "Video arrived before its parameter sets."
        case .blockBuffer(let s), .sampleBuffer(let s): return "Bad video frame (\(s))."
        }
    }
}

/// Turns wire parameter sets and access units back into `CMSampleBuffer`s that a display layer
/// decodes in hardware. The format description is rebuilt only when the parameter sets change.
public final class SampleBufferFactory {
    public private(set) var format: CMVideoFormatDescription?
    private var currentSets: ParameterSets?

    public init() {}

    /// True if the format changed (new size or codec), so the caller should flush its layer.
    @discardableResult
    public func update(_ sets: ParameterSets) throws -> Bool {
        if sets == currentSets, format != nil { return false }
        format = try Self.makeFormat(sets)
        currentSets = sets
        return true
    }

    public var dimensions: CMVideoDimensions? { format.map(CMVideoFormatDescriptionGetDimensions) }

    static func makeFormat(_ sets: ParameterSets) throws -> CMVideoFormatDescription {
        let buffers = sets.sets.map { [UInt8]($0) }
        var out: CMFormatDescription?
        var status: OSStatus = noErr
        withPointers(buffers) { pointers, sizes in
            switch sets.codec {
            case .hevc:
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &out)
            case .h264:
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
        }
        guard status == noErr, let out else { throw DecodeError.formatDescription(status) }
        return out
    }

    /// Calls `body` with stable pointers into each buffer.
    private static func withPointers(_ buffers: [[UInt8]], _ body: ([UnsafePointer<UInt8>], [Int]) -> Void) {
        func recurse(_ i: Int, _ acc: [UnsafePointer<UInt8>]) {
            if i == buffers.count { return body(acc, buffers.map(\.count)) }
            buffers[i].withUnsafeBufferPointer { bp in recurse(i + 1, acc + [bp.baseAddress!]) }
        }
        recurse(0, [])
    }

    /// One access unit as a sample buffer marked "display immediately".
    public func sampleBuffer(_ payload: VideoFramePayload) throws -> CMSampleBuffer {
        guard let format else { throw DecodeError.noFormat }
        let length = payload.accessUnit.count
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw DecodeError.blockBuffer(status) }
        status = payload.accessUnit.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == noErr else { throw DecodeError.blockBuffer(status) }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(payload.ptsMicros), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sizes = [length]
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw DecodeError.sampleBuffer(status) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
#endif
