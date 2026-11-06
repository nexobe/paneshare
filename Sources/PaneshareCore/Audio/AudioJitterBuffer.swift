import Foundation

/// The viewer's playout buffer for one remote app's audio (docs/ARCHITECTURE.md §7.2). Decoded
/// packets go in with the host's presentation time; the audio device pulls fixed-size chunks out.
///
/// - It starts (and restarts after running dry) only once `targetFrames` are buffered, so ordinary
///   network jitter doesn't cause clicks.
/// - It never holds more than `maxFrames`: past that the oldest audio is dropped back to the target,
///   so latency stays bounded and audio can't drift behind its window.
/// - A short gap in the host's timestamps (a lost or skipped packet) is filled with silence, so
///   later audio stays at the right time; a long gap or a jump backwards starts over.
///
/// Samples are interleaved Float32. Pure and single-threaded: the macOS player wraps it in a lock.
public struct AudioJitterBuffer: Sendable {
    public let channels: Int
    public let sampleRate: Double
    public let targetFrames: Int
    public let maxFrames: Int

    /// Gaps up to this long are concealed with silence; longer ones reset the buffer.
    public static let maxConcealedGap: TimeInterval = 0.2
    /// Timestamp jitter tolerated before a gap counts (half a typical 10.7 ms packet).
    public static let gapTolerance: TimeInterval = 0.005

    private var samples: [Float] = []
    private var readIndex = 0
    private var priming = true
    /// Host time (µs) of the sample just after the last one pushed.
    private var nextPtsMicros: UInt64?

    public private(set) var underruns = 0
    public private(set) var overflowDrops = 0
    public private(set) var concealedFrames = 0
    public private(set) var resets = 0

    /// - Parameters:
    ///   - target: buffered audio needed before playing, in seconds.
    ///   - maximum: buffered audio above which the oldest is dropped, in seconds.
    public init(channels: Int, sampleRate: Double, target: TimeInterval = 0.04, maximum: TimeInterval = 0.12) {
        self.channels = max(1, channels)
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.targetFrames = max(1, Int((target * self.sampleRate).rounded()))
        self.maxFrames = max(self.targetFrames + 1, Int((maximum * self.sampleRate).rounded()))
    }

    public var bufferedFrames: Int { (samples.count - readIndex) / channels }
    public var isPriming: Bool { priming }

    /// Host time (µs) of the next sample `pull` would return, if known.
    public var playoutPtsMicros: UInt64? {
        guard let next = nextPtsMicros else { return nil }
        let back = UInt64((Double(bufferedFrames) / sampleRate * 1_000_000).rounded())
        return next >= back ? next - back : 0
    }

    public mutating func push(_ interleaved: [Float], ptsMicros: UInt64) {
        let frames = interleaved.count / channels
        guard frames > 0 else { return }
        let duration = UInt64((Double(frames) / sampleRate * 1_000_000).rounded())
        if let expected = nextPtsMicros {
            let gap = (Double(ptsMicros) - Double(expected)) / 1_000_000
            if gap > Self.maxConcealedGap || gap < -Self.maxConcealedGap {
                reset()
            } else if gap > Self.gapTolerance {
                let silent = Int((gap * sampleRate).rounded())
                samples.append(contentsOf: repeatElement(0, count: silent * channels))
                concealedFrames += silent
            } else if gap < -Self.gapTolerance {
                // Overlaps audio already queued (a duplicate or a late packet): keep only what's new.
                let overlap = Int((-gap * sampleRate).rounded())
                guard overlap < frames else { return }
                append(Array(interleaved[(overlap * channels)...]), frames: frames - overlap)
                nextPtsMicros = ptsMicros + duration
                return
            }
        }
        append(interleaved, frames: frames)
        nextPtsMicros = ptsMicros + duration
    }

    /// Exactly `frames` frames: audio when there is enough, silence while priming or after running dry.
    public mutating func pull(frames: Int) -> [Float] {
        guard frames > 0 else { return [] }
        if priming {
            guard bufferedFrames >= targetFrames else { return [Float](repeating: 0, count: frames * channels) }
            priming = false
        }
        let available = min(bufferedFrames, frames)
        var out = Array(samples[readIndex..<(readIndex + available * channels)])
        readIndex += available * channels
        if available < frames {
            out.append(contentsOf: repeatElement(0, count: (frames - available) * channels))
            underruns += 1
            priming = true
        }
        compact()
        return out
    }

    /// The same as `pull(frames:)`, written straight into planar output without allocating, for a
    /// real-time render callback. `right` may be nil for mono output.
    public mutating func pull(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?) {
        guard frames > 0 else { return }
        var available = 0
        if priming, bufferedFrames >= targetFrames { priming = false }
        if !priming {
            available = min(bufferedFrames, frames)
            samples.withUnsafeBufferPointer { s in
                for i in 0..<available {
                    let base = readIndex + i * channels
                    left[i] = s[base]
                    right?[i] = channels > 1 ? s[base + 1] : s[base]
                }
            }
            readIndex += available * channels
            if available < frames {
                underruns += 1
                priming = true
            }
        }
        for i in available..<frames {
            left[i] = 0
            right?[i] = 0
        }
        compact()
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        readIndex = 0
        priming = true
        nextPtsMicros = nil
        resets += 1
    }

    private mutating func append(_ interleaved: [Float], frames: Int) {
        samples.append(contentsOf: interleaved.prefix(frames * channels))
        if bufferedFrames > maxFrames {
            readIndex += (bufferedFrames - targetFrames) * channels
            overflowDrops += 1
        }
        compact()
    }

    private mutating func compact() {
        if readIndex == samples.count {
            samples.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 48_000 * channels {
            samples.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

/// Maps the host's captured sample count to host presentation time (µs), so each encoded packet
/// carries the time its first sample was captured, in the same clock as video timestamps
/// (mach host time). Capture callbacks report a time per buffer; a buffer that arrives more than
/// `resyncThreshold` away from where the count predicts (a capture gap, a device change) starts a
/// new anchor.
public struct AudioTimeline: Sendable {
    public let sampleRate: Double
    public static let resyncThreshold: TimeInterval = 0.02

    private var anchors: [(sample: Int64, ptsMicros: UInt64)] = []
    public private(set) var samplesIn: Int64 = 0

    public init(sampleRate: Double) { self.sampleRate = sampleRate > 0 ? sampleRate : 48_000 }

    /// A capture buffer of `frames` frames whose first sample was captured at `hostPtsMicros`.
    public mutating func append(frames: Int, hostPtsMicros: UInt64) {
        defer { samplesIn += Int64(max(0, frames)) }
        guard let predicted = pts(ofSample: samplesIn) else {
            anchors.append((samplesIn, hostPtsMicros))
            return
        }
        let drift = abs(Double(hostPtsMicros) - Double(predicted)) / 1_000_000
        if drift > Self.resyncThreshold {
            anchors.append((samplesIn, hostPtsMicros))
            if anchors.count > 8 { anchors.removeFirst(anchors.count - 8) }
        }
    }

    /// Host time of sample `n` (counted from the first appended), or nil before any audio.
    public func pts(ofSample n: Int64) -> UInt64? {
        guard let anchor = anchors.last(where: { $0.sample <= n }) ?? anchors.first else { return nil }
        let offset = Double(n - anchor.sample) / sampleRate * 1_000_000
        let value = Double(anchor.ptsMicros) + offset
        return value <= 0 ? 0 : UInt64(value.rounded())
    }
}

/// How far a remote app's audio is from its window, for the diagnostics overlay: positive means
/// audio plays later than the video frame shown at the same moment.
public enum AVSync {
    public static func skewMillis(videoPtsMicros: UInt64, videoShownAt: TimeInterval,
                                  audioPlayoutPtsMicros: UInt64, audioReadAt: TimeInterval,
                                  audioOutputLatency: TimeInterval) -> Double {
        // Bring both to the same local instant, then compare host timestamps.
        let videoNow = Double(videoPtsMicros) / 1000 + (audioReadAt - videoShownAt) * 1000
        let audioNow = Double(audioPlayoutPtsMicros) / 1000 - audioOutputLatency * 1000
        return videoNow - audioNow
    }

    /// ITU-R BT.1359: audio more than 45 ms early or 125 ms late is noticeable.
    public static func isAcceptable(skewMillis: Double) -> Bool { skewMillis >= -45 && skewMillis <= 125 }
}
