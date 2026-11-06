#if os(macOS)
// Session settings follow Sill (github.com/Saffsanity/sill, Sources/SillHost/HEVCEncoder.swift),
// Copyright 2026 Noah Saffer, Apache License 2.0: real-time, no reordering, on-demand keyframes with
// a long safety interval, drop rather than queue. Rewritten and simplified; see THIRD_PARTY.md.
import CoreMedia
import CoreVideo
import Foundation
import PaneshareCore
import VideoToolbox

public struct EncodedFrame: Sendable {
    public let codec: VideoCodec
    public let isKeyframe: Bool
    /// A quality top-up of a still picture (`StreamTuning.topUpPasses`).
    public let isTopUp: Bool
    /// Present on every keyframe.
    public let parameterSets: ParameterSets?
    public let payload: VideoFramePayload
}

public enum EncoderError: Error, CustomStringConvertible {
    case create(OSStatus)
    public var description: String {
        switch self { case .create(let s): return "The video encoder could not be created (\(s))." }
    }
}

/// A low-latency `VTCompressionSession`. At most one frame is inside VideoToolbox; a newer frame
/// replaces a waiting one, and older ones are dropped, never queued.
///
/// When the picture stops changing for `StreamTuning.topUpIdleDelay`, the last frame is encoded
/// again as P-frames at `topUpBitrate`: ScreenCaptureKit sends nothing for a still window, so
/// without this the text would stay at the quality of the last frame coded at the motion rate.
public final class VideoEncoder: @unchecked Sendable {
    public let codec: VideoCodec
    public let pixelSize: PixelSize
    public let isHardware: Bool
    public let chroma: ChromaFormat
    /// The VideoToolbox profile in use.
    public let profile: String
    private let fullBitrate: Int
    private var rateFactor = 1.0
    /// The motion rate now, after any adaptive lowering.
    public var bitrate: Int {
        lock.lock(); defer { lock.unlock() }
        return AdaptiveBitrate.scaled(fullBitrate, factor: rateFactor)
    }
    public var topUpBitrate: Int { StreamTuning.topUpBitrate(normal: bitrate) }
    /// Runs on a VideoToolbox thread.
    public var onEncoded: (@Sendable (EncodedFrame) -> Void)?
    /// Runs once, on a VideoToolbox or encode thread, after `failureLimit` frames in a row fail.
    public var onFailed: (@Sendable () -> Void)?
    public static let failureLimit = 30

    private let session: VTCompressionSession
    private let lock = NSLock()
    private var inFlight = false
    private var waiting: (CVPixelBuffer, CMTime)?
    private var keyframeRequested = true
    private var lastFrame: CVPixelBuffer?
    private var lastPTS = CMTime.invalid
    private var consecutiveFailures = 0
    private var failed = false
    /// Bumped by every captured frame; a scheduled top-up only runs if none came since.
    private var generation = 0
    private var topUpsLeft = 0
    private let encodeQueue = DispatchQueue(label: "dev.paneshare.encode", qos: .userInteractive)

    /// Tries hardware HEVC, then hardware H.264, then software H.264 (failure modes, ARCHITECTURE §9).
    /// `chroma` lists what the viewer can decode; the richest one the encoder offers is used.
    public static func make(pixelSize: PixelSize, fps: Int = 60, preferHEVC: Bool = true,
                            chroma: [ChromaFormat] = [.yuv420]) throws -> VideoEncoder {
        var attempts: [(VideoCodec, Bool)] = [(.h264, false), (.h264, true)]
        if preferHEVC { attempts.insert((.hevc, false), at: 0) }
        var last: OSStatus = -1
        for (codec, software) in attempts {
            do { return try VideoEncoder(pixelSize: pixelSize, codec: codec, fps: fps, software: software, chroma: chroma) }
            catch EncoderError.create(let s) { last = s }
        }
        throw EncoderError.create(last)
    }

    init(pixelSize: PixelSize, codec: VideoCodec, fps: Int, software: Bool, chroma accepted: [ChromaFormat]) throws {
        var spec: [CFString: Any] = [:]
        if software {
            spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = false
        } else {
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
        }
        if codec == .h264 {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(pixelSize.width), height: Int32(pixelSize.height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let session = s else { throw EncoderError.create(status) }

        @discardableResult
        func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus { VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)

        let base = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        var profile = base as String
        var chroma = ChromaFormat.yuv420
        if accepted.contains(where: { $0 != .yuv420 }),
           let rich = StreamTuning.profile(supported: Self.supportedProfiles(session), codec: codec, accepted: accepted),
           set(kVTCompressionPropertyKey_ProfileLevel, rich.name as CFString) == noErr {
            profile = rich.name
            chroma = rich.chroma
        } else {
            set(kVTCompressionPropertyKey_ProfileLevel, base)
        }
        // Capture is sRGB BGRA; VideoToolbox converts to Y'CbCr with this matrix and tags the stream,
        // so the viewer's decoder converts back with the same one (no colour or contrast shift on text).
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        let bitrate = StreamTuning.bitrate(for: pixelSize, fps: fps, chroma: chroma)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 4) as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        Self.setRate(session, bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.session = session
        self.codec = codec
        self.pixelSize = pixelSize
        self.isHardware = !software
        self.chroma = chroma
        self.profile = profile
        self.fullBitrate = bitrate
    }

    /// Changes the rate without rebuilding the session, so no keyframe is needed.
    public func setRateFactor(_ factor: Double) {
        lock.lock()
        rateFactor = factor
        lock.unlock()
        Self.setRate(session, bitrate)
    }

    private static func setRate(_ session: VTCompressionSession, _ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8 * 3 / 2, 1] as CFArray)
    }

    /// The profile names this session accepts, e.g. `HEVC_Main_AutoLevel`.
    private static func supportedProfiles(_ session: VTCompressionSession) -> [String] {
        var supported: CFDictionary?
        guard VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported) == noErr,
              let all = supported as NSDictionary? as? [String: Any],
              let entry = all[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any],
              let values = entry[kVTPropertySupportedValueListKey as String] as? [String] else { return [] }
        return values
    }

    deinit {
        let session = self.session
        // Never invalidate with a frame still inside; drain on a background thread.
        DispatchQueue.global(qos: .utility).async {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Capture queue. Returns at once.
    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        lastFrame = pixelBuffer
        generation += 1
        topUpsLeft = StreamTuning.topUpPasses
        let g = generation
        let busy = inFlight
        if busy { waiting = (pixelBuffer, pts) } else { inFlight = true }
        lock.unlock()
        scheduleTopUp(g, after: StreamTuning.topUpIdleDelay)
        if !busy { encodeQueue.async { self.submit(pixelBuffer, pts: pts) } }
    }

    /// The next frame becomes a keyframe. If the window is still, the last frame is re-encoded now.
    public func requestKeyframe() {
        lock.lock()
        keyframeRequested = true
        let reencode = !inFlight ? lastFrame : nil
        if reencode != nil { inFlight = true }
        let pts = lastPTS.isValid ? CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000)) : CMClockGetTime(CMClockGetHostTimeClock())
        lock.unlock()
        if let reencode { encodeQueue.async { self.submit(reencode, pts: pts) } }
    }

    private func scheduleTopUp(_ g: Int, after delay: TimeInterval) {
        encodeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.topUpIfStill(g) }
    }

    /// Encode thread. Re-encodes the last frame at the top-up rate if nothing changed since `g`.
    private func topUpIfStill(_ g: Int) {
        lock.lock()
        guard g == generation, topUpsLeft > 0, !failed, let frame = lastFrame else { lock.unlock(); return }
        if inFlight {
            lock.unlock()
            return scheduleTopUp(g, after: 0.03)
        }
        topUpsLeft -= 1
        inFlight = true
        let pts = CMTimeAdd(lastPTS.isValid ? lastPTS : CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 1, timescale: 1000))
        lock.unlock()
        Self.setRate(session, topUpBitrate)
        submit(frame, pts: pts, topUp: g)
    }

    /// `topUp` is the generation a top-up belongs to, nil for a captured or keyframe-request frame.
    private func submit(_ pixelBuffer: CVPixelBuffer, pts requested: CMTime, topUp: Int? = nil) {
        lock.lock()
        // A top-up never doubles as the keyframe someone asked for: that goes out at the normal rate.
        let forceKey = topUp == nil && keyframeRequested
        if forceKey {
            keyframeRequested = false
            // A keyframe of a still window is coded at the motion rate too; top it up afterwards.
            topUpsLeft = StreamTuning.topUpPasses
        }
        let g = generation
        // Timestamps must increase strictly.
        var pts = requested
        if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 { pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000)) }
        lastPTS = pts
        lock.unlock()
        if forceKey { scheduleTopUp(g, after: StreamTuning.topUpIdleDelay) }

        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sampleBuffer in
            guard let self else { return }
            if topUp != nil { Self.setRate(self.session, self.bitrate) }
            if status == noErr, let sampleBuffer, let frame = self.package(sampleBuffer, topUp: topUp != nil) {
                self.record(delivered: true, error: false, forceKey: forceKey)
                self.onEncoded?(frame)
            } else {
                // A nil buffer with noErr is a frame the encoder chose to drop, not a failure.
                self.record(delivered: false, error: status != noErr, forceKey: forceKey)
            }
            self.frameReturned(afterTopUp: topUp)
        }
        if status != noErr {
            if topUp != nil { Self.setRate(session, bitrate) }
            record(delivered: false, error: true, forceKey: forceKey)
            frameReturned(afterTopUp: topUp)
        }
    }

    private func record(delivered: Bool, error: Bool, forceKey: Bool) {
        lock.lock()
        if forceKey && !delivered { keyframeRequested = true }
        guard error else {
            consecutiveFailures = 0
            lock.unlock()
            return
        }
        consecutiveFailures += 1
        let report = consecutiveFailures >= Self.failureLimit && !failed
        if report { failed = true }
        lock.unlock()
        if report { onFailed?() }
    }

    private func frameReturned(afterTopUp g: Int? = nil) {
        lock.lock()
        var next = waiting
        waiting = nil
        // A keyframe asked for while a still window's top-up was inside VideoToolbox.
        if next == nil, g != nil, keyframeRequested, !failed, let last = lastFrame {
            next = (last, CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000)))
        }
        inFlight = next != nil
        let moreTopUps = g != nil && g == generation && topUpsLeft > 0 && next == nil
        lock.unlock()
        if let next { encodeQueue.async { self.submit(next.0, pts: next.1) } }
        if let g, moreTopUps { scheduleTopUp(g, after: 0.03) }
    }

    private func package(_ sampleBuffer: CMSampleBuffer, topUp: Bool) -> EncodedFrame? {
        guard let block = sampleBuffer.dataBuffer, let data = try? block.dataBytes(), !data.isEmpty else { return nil }
        let isKey = Self.isKeyframe(sampleBuffer)
        var sets: ParameterSets?
        if isKey, let format = sampleBuffer.formatDescription {
            sets = Self.parameterSets(format, codec: codec)
        }
        let seconds = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        let micros = seconds.isFinite && seconds > 0 ? UInt64(seconds * 1_000_000) : 0
        return EncodedFrame(codec: codec, isKeyframe: isKey, isTopUp: topUp && !isKey, parameterSets: sets,
                            payload: VideoFramePayload(ptsMicros: micros, accessUnit: data))
    }

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> ParameterSets? {
        var count = 0
        var sets: [Data] = []
        var status = noErr
        func get(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if codec == .hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer, size > 0 else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let first = get(0) else { return nil }
        sets.append(first)
        if count > 1 {
            for i in 1..<count {
                guard let s = get(i) else { return nil }
                sets.append(s)
            }
        }
        return ParameterSets(codec: codec, sets: sets)
    }
}
#endif
