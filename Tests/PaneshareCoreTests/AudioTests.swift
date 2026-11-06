import Foundation
import XCTest
@testable import PaneshareCore

final class AudioJitterBufferTests: XCTestCase {
    /// 480 frames = 10 ms at 48 kHz.
    private func packet(_ value: Float, frames: Int = 480, channels: Int = 2) -> [Float] {
        [Float](repeating: value, count: frames * channels)
    }

    func testPrimesUntilTargetThenPlays() {
        var jb = AudioJitterBuffer(channels: 2, sampleRate: 48_000, target: 0.03, maximum: 0.1)
        XCTAssertEqual(jb.targetFrames, 1440)
        jb.push(packet(0.5), ptsMicros: 1_000_000)
        jb.push(packet(0.5), ptsMicros: 1_010_000)
        XCTAssertEqual(jb.pull(frames: 256), [Float](repeating: 0, count: 512), "silent while priming")
        XCTAssertEqual(jb.bufferedFrames, 960, "priming doesn't consume")
        jb.push(packet(0.5), ptsMicros: 1_020_000)
        let out = jb.pull(frames: 256)
        XCTAssertEqual(out.count, 512)
        XCTAssertTrue(out.allSatisfy { $0 == 0.5 })
        XCTAssertFalse(jb.isPriming)
        XCTAssertEqual(jb.bufferedFrames, 1440 - 256)
    }

    func testUnderrunPadsWithSilenceAndRePrimes() {
        var jb = AudioJitterBuffer(channels: 1, sampleRate: 48_000, target: 0.01, maximum: 0.1)
        jb.push(packet(1, channels: 1), ptsMicros: 0)
        let out = jb.pull(frames: 600)
        XCTAssertEqual(out.prefix(480).filter { $0 == 1 }.count, 480)
        XCTAssertTrue(out.suffix(120).allSatisfy { $0 == 0 })
        XCTAssertEqual(jb.underruns, 1)
        XCTAssertTrue(jb.isPriming)
        jb.push(packet(1, frames: 100, channels: 1), ptsMicros: 10_000)
        XCTAssertTrue(jb.pull(frames: 50).allSatisfy { $0 == 0 }, "waits for the target again")
    }

    func testOverflowDropsOldestBackToTarget() {
        var jb = AudioJitterBuffer(channels: 2, sampleRate: 48_000, target: 0.02, maximum: 0.05)
        for i in 0..<5 { jb.push(packet(Float(i)), ptsMicros: UInt64(i) * 10_000) }
        XCTAssertEqual(jb.bufferedFrames, 2400, "50 ms is at, not over, the limit")
        XCTAssertEqual(jb.overflowDrops, 0)
        jb.push(packet(5), ptsMicros: 50_000)
        XCTAssertEqual(jb.bufferedFrames, 960)
        XCTAssertEqual(jb.overflowDrops, 1)
        let out = jb.pull(frames: 960)
        XCTAssertEqual(out.first, 4, "kept the newest audio")
        XCTAssertEqual(out.last, 5)
    }

    func testShortGapIsConcealedWithSilence() {
        var jb = AudioJitterBuffer(channels: 1, sampleRate: 48_000, target: 0.001, maximum: 1)
        jb.push(packet(1, channels: 1), ptsMicros: 0)
        jb.push(packet(2, channels: 1), ptsMicros: 20_000) // one 10 ms packet lost
        XCTAssertEqual(jb.concealedFrames, 480)
        XCTAssertEqual(jb.bufferedFrames, 1440)
        let out = jb.pull(frames: 1440)
        XCTAssertTrue(out[480..<960].allSatisfy { $0 == 0 })
        XCTAssertEqual(out[960], 2)
    }

    func testSmallJitterInTimestampsIsNotAGap() {
        var jb = AudioJitterBuffer(channels: 1, sampleRate: 48_000, target: 0.001, maximum: 1)
        jb.push(packet(1, channels: 1), ptsMicros: 0)
        jb.push(packet(1, channels: 1), ptsMicros: 12_000)
        jb.push(packet(1, channels: 1), ptsMicros: 19_000)
        XCTAssertEqual(jb.concealedFrames, 0)
        XCTAssertEqual(jb.bufferedFrames, 1440)
    }

    func testOverlapKeepsOnlyNewAudioAndDuplicatesAreDropped() {
        var jb = AudioJitterBuffer(channels: 1, sampleRate: 48_000, target: 0.001, maximum: 1)
        jb.push(packet(1, channels: 1), ptsMicros: 0)
        jb.push(packet(1, channels: 1), ptsMicros: 0) // duplicate
        XCTAssertEqual(jb.bufferedFrames, 480)
        jb.push(packet(2, channels: 1), ptsMicros: 0 + 10_000 - 7_500) // overlaps 7.5 ms
        XCTAssertEqual(jb.bufferedFrames, 480 + 120)
    }

    func testLongGapOrJumpBackResets() {
        var jb = AudioJitterBuffer(channels: 1, sampleRate: 48_000, target: 0.001, maximum: 1)
        jb.push(packet(1, channels: 1), ptsMicros: 1_000_000)
        jb.push(packet(2, channels: 1), ptsMicros: 2_000_000)
        XCTAssertEqual(jb.resets, 1)
        XCTAssertEqual(jb.bufferedFrames, 480)
        jb.push(packet(3, channels: 1), ptsMicros: 500_000)
        XCTAssertEqual(jb.resets, 2)
        XCTAssertEqual(jb.pull(frames: 1).first, 3)
    }

    func testPlayoutTimestampTracksWhatIsNext() {
        var jb = AudioJitterBuffer(channels: 2, sampleRate: 48_000, target: 0.001, maximum: 1)
        XCTAssertNil(jb.playoutPtsMicros)
        jb.push(packet(1), ptsMicros: 5_000_000)
        jb.push(packet(1), ptsMicros: 5_010_000)
        XCTAssertEqual(jb.playoutPtsMicros, 5_000_000)
        _ = jb.pull(frames: 240)
        XCTAssertEqual(jb.playoutPtsMicros, 5_005_000)
    }

    func testPlanarPullMatchesInterleavedPull() {
        var a = AudioJitterBuffer(channels: 2, sampleRate: 48_000, target: 0.005, maximum: 1)
        var b = a
        let ramp = (0..<960).map { Float($0) }
        a.push(ramp, ptsMicros: 0)
        b.push(ramp, ptsMicros: 0)
        var l = [Float](repeating: 9, count: 600), r = [Float](repeating: 9, count: 600)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in b.pull(frames: 600, left: lp.baseAddress!, right: rp.baseAddress) }
        }
        let interleaved = a.pull(frames: 600)
        XCTAssertEqual(l, stride(from: 0, to: 1200, by: 2).map { interleaved[$0] })
        XCTAssertEqual(r, stride(from: 1, to: 1200, by: 2).map { interleaved[$0] })
        XCTAssertEqual(a.underruns, b.underruns)
        XCTAssertEqual(b.underruns, 1)
        XCTAssertEqual(l[479], 958)
        XCTAssertEqual(l[480], 0)
    }

    func testDegenerateInputs() {
        var jb = AudioJitterBuffer(channels: 0, sampleRate: 0)
        XCTAssertEqual(jb.channels, 1)
        XCTAssertEqual(jb.sampleRate, 48_000)
        jb.push([], ptsMicros: 0)
        XCTAssertEqual(jb.bufferedFrames, 0)
        XCTAssertEqual(jb.pull(frames: 0), [])
    }
}

final class AudioTimelineTests: XCTestCase {
    func testCountsSamplesFromTheFirstAnchor() {
        var t = AudioTimeline(sampleRate: 48_000)
        XCTAssertNil(t.pts(ofSample: 0))
        t.append(frames: 512, hostPtsMicros: 10_000_000)
        t.append(frames: 512, hostPtsMicros: 10_010_700) // ~0.03 ms jitter: no resync
        XCTAssertEqual(t.pts(ofSample: 0), 10_000_000)
        XCTAssertEqual(t.pts(ofSample: 480), 10_010_000)
        XCTAssertEqual(t.pts(ofSample: 4800), 10_100_000)
        XCTAssertEqual(t.samplesIn, 1024)
    }

    func testResyncsAfterACaptureGap() {
        var t = AudioTimeline(sampleRate: 48_000)
        t.append(frames: 480, hostPtsMicros: 1_000_000)
        t.append(frames: 480, hostPtsMicros: 1_500_000) // 490 ms late
        XCTAssertEqual(t.pts(ofSample: 0), 1_000_000, "earlier samples keep their time")
        XCTAssertEqual(t.pts(ofSample: 480), 1_500_000)
        XCTAssertEqual(t.pts(ofSample: 960), 1_510_000)
    }
}

final class AVSyncTests: XCTestCase {
    func testSkewAndTolerance() {
        // Video frame 1.000 s shown at local 10.0; at local 10.05 audio's next sample is 1.010 s with
        // 20 ms of output latency, so it's heard at 0.990 s while the picture shows 1.050 s.
        let skew = AVSync.skewMillis(videoPtsMicros: 1_000_000, videoShownAt: 10.0,
                                     audioPlayoutPtsMicros: 1_010_000, audioReadAt: 10.05, audioOutputLatency: 0.02)
        XCTAssertEqual(skew, 60, accuracy: 0.001)
        XCTAssertTrue(AVSync.isAcceptable(skewMillis: skew))
        XCTAssertFalse(AVSync.isAcceptable(skewMillis: 130))
        XCTAssertFalse(AVSync.isAcceptable(skewMillis: -50))
    }
}

final class AudioPolicyTests: XCTestCase {
    let policy = WindowPolicy(ownProcessID: 99, ownBundleID: "dev.paneshare.app")

    func testNormalAppsAreOnByDefault() {
        XCTAssertEqual(AudioPolicy(windowPolicy: policy).decision(bundleID: "com.spotify.client", processID: 10), .allowed)
    }

    func testExcludedAppsAreAlwaysOff() {
        let audio = AudioPolicy(windowPolicy: policy, enabled: true)
        XCTAssertEqual(audio.decision(bundleID: "com.apple.SecurityAgent", processID: 10), .excludedApp(.systemAuthPrompt))
        XCTAssertEqual(audio.decision(bundleID: "com.1password.1password", processID: 10), .excludedApp(.deniedApp))
        XCTAssertEqual(audio.decision(bundleID: "dev.paneshare.app", processID: 10), .excludedApp(.ownProcess))
        XCTAssertEqual(audio.decision(bundleID: "x", processID: 99), .excludedApp(.ownProcess))
        var extra = policy
        extra.extraDeniedBundleIDs = ["com.example.secret"]
        XCTAssertFalse(AudioPolicy(windowPolicy: extra).allows(bundleID: "com.example.secret", processID: 10))
    }

    func testHostSwitches() {
        XCTAssertEqual(AudioPolicy(windowPolicy: policy, enabled: false).decision(bundleID: "com.spotify.client", processID: 10), .turnedOff)
        let perApp = AudioPolicy(windowPolicy: policy, mutedBundleIDs: AudioPolicy.mutedList(from: ["com.spotify.client"]))
        XCTAssertEqual(perApp.decision(bundleID: "com.spotify.client", processID: 10), .turnedOffForApp)
        XCTAssertTrue(perApp.allows(bundleID: "com.apple.Music", processID: 11))
        XCTAssertEqual(AudioPolicy(windowPolicy: policy, enabled: false).decision(bundleID: "com.apple.SecurityAgent", processID: 10),
                       .excludedApp(.systemAuthPrompt), "exclusion wins over every switch")
    }

    func testWindowPolicyStillUsesTheAppRules() {
        let w = WindowInfo(windowID: 1, title: "", appName: "1Password", bundleID: "com.1password.1password", processID: 5,
                           frame: WireRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(policy.rejection(for: w), .deniedApp)
    }
}

final class AudioMixSettingsTests: XCTestCase {
    let host = Fingerprint(bytes: [UInt8](repeating: 0xAB, count: 32))!
    let other = Fingerprint(bytes: [UInt8](repeating: 0x01, count: 32))!

    func testDefaultsClampingAndPersistence() {
        var s = AudioMixSettings()
        XCTAssertEqual(s.mix(host: host, bundleID: "com.spotify.client"), .default)
        s.set(AudioMix(muted: false, volume: 1.7), host: host, bundleID: "a")
        XCTAssertEqual(s.mix(host: host, bundleID: "a").volume, 1)
        XCTAssertEqual(s.count, 0, "a clamped default isn't stored")
        s.set(AudioMix(muted: true, volume: 0.25), host: host, bundleID: "a")
        s.set(AudioMix(volume: -3), host: other, bundleID: "a")
        XCTAssertEqual(s.mix(host: other, bundleID: "a").volume, 0)
        XCTAssertEqual(s.mix(host: host, bundleID: "b"), .default)

        let restored = AudioMixSettings(data: s.encoded())
        XCTAssertEqual(restored, s)
        XCTAssertEqual(restored.mix(host: host, bundleID: "a"), AudioMix(muted: true, volume: 0.25))
        XCTAssertEqual(restored.mix(host: host, bundleID: "a").effectiveGain, 0)
        XCTAssertEqual(AudioMix(volume: 0.5).effectiveGain, 0.5)
        XCTAssertEqual(AudioMix(volume: .nan).volume, 1)

        s.forget(host: host)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(AudioMixSettings(data: Data("junk".utf8)).count, 0)
        XCTAssertEqual(AudioMixSettings(data: nil).count, 0)
    }

    func testStoredValuesAreClampedOnLoad() {
        let tampered = Data(#"{"x/y":{"muted":false,"volume":9}}"#.utf8)
        XCTAssertEqual(AudioMixSettings(data: tampered).count, 1)
    }
}

final class AudioSamplesTests: XCTestCase {
    func testPlanarToStereo() {
        let l: [Float] = [1, 2, 3], r: [Float] = [-1, -2, -3]
        l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                XCTAssertEqual(AudioSamples.stereo(planar: [lp, rp], frames: 3), [1, -1, 2, -2, 3, -3])
                XCTAssertEqual(AudioSamples.stereo(planar: [lp], frames: 2), [1, 1, 2, 2], "mono is duplicated")
                XCTAssertEqual(AudioSamples.stereo(planar: [lp, rp], frames: 9).count, 6, "never reads past the buffer")
            }
        }
        XCTAssertEqual(AudioSamples.stereo(planar: [], frames: 3), [])
    }

    func testInterleavedToStereo() {
        let quad: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        quad.withUnsafeBufferPointer {
            XCTAssertEqual(AudioSamples.stereo(interleaved: $0, channels: 4, frames: 2), [1, 2, 5, 6])
            XCTAssertEqual(AudioSamples.stereo(interleaved: $0, channels: 1, frames: 2), [1, 1, 2, 2])
            XCTAssertEqual(AudioSamples.stereo(interleaved: $0, channels: 2, frames: 3), [1, 2, 3, 4, 5, 6])
            XCTAssertEqual(AudioSamples.stereo(interleaved: $0, channels: 0, frames: 3), [])
        }
    }

    func testDeinterleavePadsWithSilence() {
        var l = [Float](repeating: 9, count: 3), r = [Float](repeating: 9, count: 3)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                AudioSamples.deinterleave([1, -1, 2, -2], frames: 3, left: lp.baseAddress!, right: rp.baseAddress)
            }
        }
        XCTAssertEqual(l, [1, 2, 0])
        XCTAssertEqual(r, [-1, -2, 0])
        XCTAssertEqual(AudioSamples.micros(seconds: 1.5), 1_500_000)
        XCTAssertEqual(AudioSamples.micros(seconds: .nan), 0)
    }
}

final class AudioMessageTests: XCTestCase {
    func testMessagesRoundTrip() throws {
        let started = AudioStarted(bundleID: "com.spotify.client", appName: "Spotify", sampleRate: 48_000, channels: 2,
                                   framesPerPacket: 512, magicCookie: Data([0xF8, 0xE8, 0x50, 0x00]), source: .processTap, bitrate: 96_000)
        let f = try MessageCodec.frame(.audioStarted, started, streamID: 7)
        XCTAssertEqual(f.kind, .audioStarted)
        XCTAssertEqual(try MessageCodec.decode(AudioStarted.self, from: f), started)
        let stop = AudioStopped(bundleID: "a", reason: .viewerMuted)
        XCTAssertEqual(try MessageCodec.decode(AudioStopped.self, from: try MessageCodec.frame(.audioStopped, stop)), stop)
        let control = AudioControl(bundleID: "a", enabled: false)
        XCTAssertEqual(try MessageCodec.decode(AudioControl.self, from: try MessageCodec.frame(.audioControl, control)), control)
        XCTAssertEqual(MessageKind(rawValue: 0x18), .audioFrame)
        XCTAssertEqual(MessageKind(rawValue: 0x1A), .audioControl)
    }

    func testAudioFramePayload() throws {
        let p = AudioFramePayload(ptsMicros: 0x0102_0304_0506_0708, packet: Data([9, 10, 11]))
        let d = p.encoded()
        XCTAssertEqual(Array(d.prefix(8)), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(try AudioFramePayload(decoding: d), p)
        XCTAssertEqual(try AudioFramePayload(decoding: d.dropFirst(0)), p)
        XCTAssertThrowsError(try AudioFramePayload(decoding: Data(count: 8)))
    }

    func testOpenWindowAudioIsOptional() throws {
        let old = try MessageCodec.decode(OpenWindow.self, from: Frame(kind: .openWindow, payload: Data(#"{"windowID":5,"viewerBackingScale":2}"#.utf8)))
        XCTAssertNil(old.audio)
        let new = OpenWindow(windowID: 5, viewerBackingScale: 2, audio: true)
        XCTAssertEqual(try MessageCodec.decode(OpenWindow.self, from: try MessageCodec.frame(.openWindow, new)).audio, true)
    }
}
