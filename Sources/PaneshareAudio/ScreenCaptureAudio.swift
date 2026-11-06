#if os(macOS)
import AudioToolbox
import CoreMedia
import Foundation
import PaneshareCore
import ScreenCaptureKit

/// Fallback capture of one app's audio through ScreenCaptureKit, for macOS 14.0–14.1 or when a
/// process tap can't be made. Uses the Screen Recording permission paneshare already has. The video
/// side of the stream is kept tiny and slow; only the audio output is used.
public final class ScreenCaptureAudio: NSObject, AppAudioCapture, SCStreamOutput, SCStreamDelegate {
    public let source = AudioSource.screenCaptureKit
    public let bundleID: String

    private let queue = DispatchQueue(label: "dev.paneshare.audio.sck", qos: .userInteractive)
    private var stream: SCStream?
    private var onAudio: (@Sendable (CapturedAudio) -> Void)?

    public init(bundleID: String) {
        self.bundleID = bundleID
    }

    public func start(onAudio: @escaping @Sendable (CapturedAudio) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw AudioCaptureError.unavailable("\(bundleID) isn't running.")
        }
        guard let display = content.displays.first else { throw AudioCaptureError.unavailable("No display to attach to.") }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.onAudio = onAudio
        self.stream = stream
        try await stream.startCapture()
    }

    public func stop() {
        guard let stream else { return }
        self.stream = nil
        onAudio = nil
        stream.stopCapture { _ in }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let onAudio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var samples: [Float] = []
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            if planar {
                let pointers = list.prefix(2).compactMap { b -> UnsafeBufferPointer<Float>? in
                    guard let p = b.mData else { return nil }
                    return UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4)
                }
                samples = AudioSamples.stereo(planar: pointers, frames: frames)
            } else {
                let buffer = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(first.mDataByteSize) / 4)
                samples = AudioSamples.stereo(interleaved: buffer, channels: channels, frames: frames)
            }
        }
        guard !samples.isEmpty else { return }
        let pts = AudioSamples.micros(seconds: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp))
        onAudio(CapturedAudio(samples: samples, frames: samples.count / 2, sampleRate: asbd.mSampleRate, hostPtsMicros: pts,
                                 source: .screenCaptureKit))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("paneshare audio: ScreenCaptureKit audio for %@ stopped: %@", bundleID, "\(error)")
    }
}

/// Picks the best capture for this Mac: a process tap on macOS 14.2 and later, falling back to
/// ScreenCaptureKit when the tap can't start (permission denied, older macOS).
public enum AppAudioCapturer {
    public static func start(bundleID: String, processID: pid_t,
                             onAudio: @escaping @Sendable (CapturedAudio) -> Void) async throws -> AppAudioCapture {
        if #available(macOS 14.2, *), UserDefaults.standard.string(forKey: "audioCapture") != "screenCaptureKit" {
            let tap = ProcessTapCapture(bundleID: bundleID, processID: processID)
            do {
                try await tap.start(onAudio: onAudio)
                return tap
            } catch {
                tap.stop()
                NSLog("paneshare audio: process tap for %@ failed (%@); using ScreenCaptureKit", bundleID, "\(error)")
            }
        }
        let sck = ScreenCaptureAudio(bundleID: bundleID)
        try await sck.start(onAudio: onAudio)
        return sck
    }
}
#endif
