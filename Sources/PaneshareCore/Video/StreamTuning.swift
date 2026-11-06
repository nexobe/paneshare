import Foundation

/// Chroma subsampling of an encoded stream. 4:2:0 halves colour resolution both ways, which smears
/// coloured text and thin coloured lines; 4:4:4 keeps colour at full resolution.
public enum ChromaFormat: String, Codable, CaseIterable, Sendable, Comparable {
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"
    case yuv444 = "4:4:4"

    var rank: Int {
        switch self {
        case .yuv420: return 0
        case .yuv422: return 1
        case .yuv444: return 2
        }
    }

    public static func < (a: ChromaFormat, b: ChromaFormat) -> Bool { a.rank < b.rank }

    /// What a viewer accepts by default: everything, best first. It drops back to `[.yuv420]` for a
    /// window whose 4:2:2 or 4:4:4 stream it fails to decode.
    public static let viewerDefault: [ChromaFormat] = [.yuv444, .yuv422, .yuv420]

    /// The viewer's hidden `chroma` setting: absent or "auto" accepts everything; "4:2:0", "4:2:2" or
    /// "4:4:4" (or "420", "422", "444") caps it at that format, with 4:2:0 always allowed.
    public static func accepted(setting: String?) -> [ChromaFormat] {
        guard let raw = setting?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "auto" else { return viewerDefault }
        let digits = raw.filter(\.isNumber)
        guard let cap = allCases.first(where: { $0.rawValue.filter(\.isNumber) == digits }) else { return viewerDefault }
        return viewerDefault.filter { $0 <= cap }
    }
}

/// Encoder settings that don't need VideoToolbox, so they are unit-tested (docs/ARCHITECTURE.md §7.1).
public enum StreamTuning {
    /// Bits per pixel per frame during motion. Text at Retina density needs more than video does.
    public static let bitsPerPixel = 0.1
    public static let minBitrate = 2_000_000
    public static let maxBitrate = 50_000_000

    /// Steady-state target: `bitsPerPixel` × pixels × fps, scaled up for richer chroma, clamped.
    public static func bitrate(for size: PixelSize, fps: Int, chroma: ChromaFormat = .yuv420) -> Int {
        let factor: Double
        switch chroma {
        case .yuv420: factor = 1
        case .yuv422: factor = 1.25
        case .yuv444: factor = 1.5
        }
        let bps = Double(size.width) * Double(size.height) * Double(max(fps, 1)) * bitsPerPixel * factor
        return Int(min(Double(maxBitrate) * factor, max(Double(minBitrate), bps)))
    }

    /// The window stopped changing for this long: send a quality top-up.
    public static let topUpIdleDelay: TimeInterval = 0.15
    /// Top-up passes per still period. Each re-encodes the last frame as a P-frame at
    /// `topUpBitrate`, so the residual left by the motion-rate frame is coded at a low quantiser and
    /// text converges to near-lossless without a keyframe.
    public static let topUpPasses = 2
    public static let maxTopUpBitrate = 400_000_000

    public static func topUpBitrate(normal: Int) -> Int { min(maxTopUpBitrate, max(normal * 8, 40_000_000)) }

    /// Picks the richest chroma the encoder supports and the viewer accepts, from the profile names the
    /// encoder reports (VideoToolbox's `kVTCompressionPropertyKey_ProfileLevel` supported values).
    /// Matching names rather than constants keeps this working on SDKs that lack a constant.
    /// Returns nil for the codec's default 4:2:0 profile.
    public static func profile(supported: [String], codec: VideoCodec, accepted: [ChromaFormat]) -> (name: String, chroma: ChromaFormat)? {
        let prefix = codec == .hevc ? "HEVC_" : "H264_"
        let names = supported.filter { $0.hasPrefix(prefix) }
        func find(_ token: String) -> String? {
            let matching = names.filter { $0.contains(token) }
            // 8-bit before 10-bit (half the bits for the same text), AutoLevel before a fixed level.
            return matching.sorted { score($0) < score($1) }.first
        }
        func score(_ name: String) -> Int {
            (name.contains("10") ? 2 : 0) + (name.contains("AutoLevel") ? 0 : 1)
        }
        if accepted.contains(.yuv444), let name = find("444") { return (name, .yuv444) }
        if accepted.contains(.yuv422), let name = find("422") { return (name, .yuv422) }
        return nil
    }
}
