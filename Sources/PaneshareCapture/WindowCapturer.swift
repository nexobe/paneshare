#if os(macOS)
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PaneshareCore
import ScreenCaptureKit

/// Captures one window with `SCContentFilter(desktopIndependentWindow:)` at an exact pixel size, in
/// BGRA: full colour resolution goes to the encoder, which picks the chroma format it can code.
/// Only `.complete` frames are delivered; `.idle` (unchanged) frames are skipped, so a still window
/// costs nearly nothing. `onFrame` runs on the capture queue and must return quickly.
public final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let queue = DispatchQueue(label: "dev.paneshare.capture", qos: .userInteractive)
    public var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    /// The stream stopped by itself (window closed, permission revoked).
    public var onStop: (@Sendable (Error?) -> Void)?

    private var stream: SCStream?
    private let fps: Int
    /// The window's backing scale on the host (2 on Retina), known once capture started.
    public private(set) var sourceScale: Double?
    public static let pixelFormatName = "BGRA"

    public init(fps: Int = 60) { self.fps = fps }

    static func configuration(pixelSize: PixelSize, fps: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = pixelSize.width
        c.height = pixelSize.height
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        c.queueDepth = 5
        c.showsCursor = false
        c.scalesToFit = true
        c.ignoreShadowsSingleWindow = true
        c.capturesAudio = false
        c.captureResolution = .best
        return c
    }

    public func start(window: SCWindow, pixelSize: PixelSize) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        sourceScale = Double(filter.pointPixelScale)
        let stream = SCStream(filter: filter, configuration: Self.configuration(pixelSize: pixelSize, fps: fps), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Starts capturing a whole screen, minus the given windows.
    public func start(display: SCDisplay, excluding: [SCWindow], pixelSize: PixelSize) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: excluding)
        sourceScale = Double(filter.pointPixelScale)
        let stream = SCStream(filter: filter, configuration: Self.configuration(pixelSize: pixelSize, fps: fps), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Replaces the windows a whole-screen capture leaves out.
    public func update(display: SCDisplay, excluding: [SCWindow]) async throws {
        try await stream?.updateContentFilter(SCContentFilter(display: display, excludingWindows: excluding))
    }

    /// New output size after a resize.
    public func update(pixelSize: PixelSize) async throws {
        try await stream?.updateConfiguration(Self.configuration(pixelSize: pixelSize, fps: fps))
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
#endif
