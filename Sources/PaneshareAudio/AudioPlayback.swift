#if os(macOS)
import AVFoundation
import Foundation
import os
import PaneshareCore

/// The viewer's audio output: one AVAudioEngine for the process, one source node per remote app
/// mixed into it. Each node pulls from its own jitter buffer on the render thread.
@MainActor
public final class AudioPlayback {
    public static let shared = AudioPlayback()

    private let engine = AVAudioEngine()
    private var outputs: [ObjectIdentifier: RemoteAudioOutput] = [:]

    private init() {}

    /// A new output for one remote app at `sampleRate`, starting the engine if needed.
    public func makeOutput(sampleRate: Double) throws -> RemoteAudioOutput {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw AudioCodecError.setup("output format")
        }
        let output = RemoteAudioOutput(format: format)
        engine.attach(output.node)
        engine.connect(output.node, to: engine.mainMixerNode, format: format)
        outputs[ObjectIdentifier(output)] = output
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        return output
    }

    public func remove(_ output: RemoteAudioOutput) {
        guard outputs.removeValue(forKey: ObjectIdentifier(output)) != nil else { return }
        engine.disconnectNodeOutput(output.node)
        engine.detach(output.node)
        if outputs.isEmpty { engine.stop() }
    }

    /// How long a sample spends between the render callback and the speaker.
    public var outputLatency: TimeInterval {
        engine.outputNode.presentationLatency
    }
}

/// One remote app's audio on the viewer: packets are pushed from the decode queue, and the render
/// thread pulls exactly what the device asks for. The jitter buffer sits behind an unfair lock held
/// only for copies.
public final class RemoteAudioOutput: @unchecked Sendable {
    public struct Stats: Sendable {
        public var bufferedMillis: Double
        public var underruns: Int
        public var overflowDrops: Int
        public var concealedMillis: Double
        public var playoutPtsMicros: UInt64?
    }

    let node: AVAudioSourceNode
    private let state: OSAllocatedUnfairLock<AudioJitterBuffer>
    private let sampleRate: Double

    init(format: AVAudioFormat) {
        let sampleRate = format.sampleRate
        self.sampleRate = sampleRate
        let state = OSAllocatedUnfairLock(initialState: AudioJitterBuffer(channels: 2, sampleRate: sampleRate))
        self.state = state
        node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, outputData in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let left = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            let frames = Int(frameCount)
            let silent = state.withLockUnchecked { jb -> Bool in
                let idle = jb.isPriming && jb.bufferedFrames < jb.targetFrames
                jb.pull(frames: frames, left: left, right: right)
                return idle
            }
            isSilence.pointee = ObjCBool(silent)
            return noErr
        }
    }

    /// 0…1; 0 when muted.
    public var volume: Float {
        get { node.volume }
        set { node.volume = max(0, min(1, newValue)) }
    }

    public func push(_ samples: [Float], ptsMicros: UInt64) {
        state.withLock { $0.push(samples, ptsMicros: ptsMicros) }
    }

    public func reset() {
        state.withLock { $0.reset() }
    }

    public var stats: Stats {
        state.withLock { jb in
            Stats(bufferedMillis: Double(jb.bufferedFrames) / sampleRate * 1000, underruns: jb.underruns,
                  overflowDrops: jb.overflowDrops, concealedMillis: Double(jb.concealedFrames) / sampleRate * 1000,
                  playoutPtsMicros: jb.playoutPtsMicros)
        }
    }
}
#endif
