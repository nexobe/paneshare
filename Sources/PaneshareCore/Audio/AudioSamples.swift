import Foundation

/// Sample layout helpers shared by capture and playback. Everything on the wire and in the jitter
/// buffer is interleaved stereo Float32; capture sources deliver planar or interleaved buffers with
/// any channel count.
public enum AudioSamples {
    /// Interleaved stereo from planar channels: mono is duplicated, extra channels are dropped.
    public static func stereo(planar channels: [UnsafeBufferPointer<Float>], frames: Int) -> [Float] {
        guard frames > 0, let left = channels.first else { return [] }
        let right = channels.count > 1 ? channels[1] : left
        let n = min(frames, left.count, right.count)
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            out[2 * i] = left[i]
            out[2 * i + 1] = right[i]
        }
        return out
    }

    /// Interleaved stereo from an interleaved buffer of `channels` channels.
    public static func stereo(interleaved samples: UnsafeBufferPointer<Float>, channels: Int, frames: Int) -> [Float] {
        guard channels > 0, frames > 0 else { return [] }
        let n = min(frames, samples.count / channels)
        if channels == 2 { return Array(samples.prefix(n * 2)) }
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            out[2 * i] = samples[i * channels]
            out[2 * i + 1] = samples[i * channels + (channels > 1 ? 1 : 0)]
        }
        return out
    }

    /// Splits interleaved stereo into `left` and `right` (each at least `frames` long), for an audio
    /// render callback that wants planar output.
    public static func deinterleave(_ interleaved: [Float], frames: Int,
                                    left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?) {
        let n = min(frames, interleaved.count / 2)
        for i in 0..<n {
            left[i] = interleaved[2 * i]
            right?[i] = interleaved[2 * i + 1]
        }
        for i in n..<max(n, frames) {
            left[i] = 0
            right?[i] = 0
        }
    }

    /// Microseconds from a host-clock time in seconds, as video and audio timestamps use.
    public static func micros(seconds: Double) -> UInt64 {
        seconds.isFinite && seconds > 0 ? UInt64(seconds * 1_000_000) : 0
    }
}
