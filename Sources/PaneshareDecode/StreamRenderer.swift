#if os(macOS)
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import PaneshareCore

/// Feeds one stream's frames to an `AVSampleBufferDisplayLayer`, which decodes in hardware and shows
/// each frame at the next vsync. All calls go through `queue`, off the main thread.
public final class StreamRenderer: @unchecked Sendable {
    public let layer: AVSampleBufferDisplayLayer
    private let factory = SampleBufferFactory()
    private let queue = DispatchQueue(label: "dev.paneshare.render", qos: .userInteractive)
    private var waitingForKeyframe = true

    /// The renderer failed or a frame couldn't be used: ask the host for a keyframe. Any queue.
    public var onNeedsKeyframe: (@Sendable () -> Void)?
    /// The display layer failed to decode (not a missing keyframe). Any queue.
    public var onDecodeFailure: (@Sendable () -> Void)?
    /// The decoded picture size changed (pixels). Main queue.
    public var onDimensions: (@Sendable (CMVideoDimensions) -> Void)?

    private let statsLock = NSLock()
    private var meter = RateMeter()
    private var topUps = 0

    public init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    public func parameterSets(_ sets: ParameterSets) {
        queue.async {
            do {
                if try self.factory.update(sets) {
                    self.layer.sampleBufferRenderer.flush()
                    if let d = self.factory.dimensions { DispatchQueue.main.async { self.onDimensions?(d) } }
                }
            } catch {
                self.onNeedsKeyframe?()
            }
        }
    }

    public func frame(_ payload: VideoFramePayload, isKeyframe: Bool, isTopUp: Bool = false) {
        statsLock.lock()
        meter.add(bytes: payload.accessUnit.count, at: ProcessInfo.processInfo.systemUptime)
        if isTopUp { topUps += 1 }
        statsLock.unlock()
        queue.async {
            let renderer = self.layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                self.waitingForKeyframe = true
                self.onDecodeFailure?()
                self.onNeedsKeyframe?()
            }
            if self.waitingForKeyframe {
                guard isKeyframe else { return }
                self.waitingForKeyframe = false
            }
            do {
                renderer.enqueue(try self.factory.sampleBuffer(payload))
            } catch {
                self.waitingForKeyframe = true
                self.onNeedsKeyframe?()
            }
        }
    }

    /// Received rate over the last second and the number of quality top-ups so far. Any thread.
    public func stats() -> (bitsPerSecond: Double, framesPerSecond: Double, topUps: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        let r = meter.rates(at: ProcessInfo.processInfo.systemUptime)
        return (r.bitsPerSecond, r.framesPerSecond, topUps)
    }

    public func reset() {
        queue.async {
            self.layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
            self.waitingForKeyframe = true
        }
    }
}
#endif
