#if os(macOS)
import Foundation
import PaneshareCore

/// Host side of one app's audio for one viewer: capture → AAC-ELD → channel. `audioStarted` goes
/// out before the first packet and again if the capture format changes (a new output device), so
/// the viewer rebuilds its decoder; packets follow on the same stream ID.
public final class HostAudioStream: @unchecked Sendable {
    public let streamID: UInt16
    public let bundleID: String
    public let appName: String
    private let processID: pid_t
    private let channel: MessageChannel
    private var capture: AppAudioCapture?
    private let lock = NSLock()
    private var stopped = false

    public init(streamID: UInt16, bundleID: String, appName: String, processID: pid_t, channel: MessageChannel) {
        self.streamID = streamID
        self.bundleID = bundleID
        self.appName = appName
        self.processID = processID
        self.channel = channel
    }

    public func start() async throws {
        let pipeline = Pipeline(stream: self)
        let capture = try await AppAudioCapturer.start(bundleID: bundleID, processID: processID) { audio in
            pipeline.consume(audio)
        }
        lock.lock()
        let late = stopped
        if !late { self.capture = capture }
        lock.unlock()
        if late { capture.stop() }
    }

    /// Stops capture and tells the viewer why. Safe to call more than once.
    public func stop(_ reason: AudioStopped.Reason, notify: Bool = true) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let capture = self.capture
        self.capture = nil
        lock.unlock()
        capture?.stop()
        if notify, let f = try? MessageCodec.frame(.audioStopped, AudioStopped(bundleID: bundleID, reason: reason), streamID: streamID) {
            channel.send(f)
        }
    }

    fileprivate var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Encoder state, touched only from the capture's serial callback queue.
    private final class Pipeline: @unchecked Sendable {
        private weak var stream: HostAudioStream?
        private var encoder: AACELDEncoder?
        private var failedRate: Double?
        private var announced = false

        init(stream: HostAudioStream) { self.stream = stream }

        func consume(_ audio: CapturedAudio) {
            guard let stream, !stream.isStopped else { return }
            if encoder?.inputRate != audio.sampleRate {
                guard failedRate != audio.sampleRate else { return }
                do {
                    encoder = try AACELDEncoder(inputRate: audio.sampleRate)
                    announced = false
                } catch {
                    failedRate = audio.sampleRate
                    NSLog("paneshare audio: %@", "\(error)")
                    return
                }
            }
            guard let encoder else { return }
            let packets = encoder.encode(audio)
            guard !packets.isEmpty else { return }
            // After the first packet, so the encoder's magic cookie is certain to exist.
            if !announced {
                announced = true
                announce(encoder, source: audio.source, on: stream)
            }
            for packet in packets {
                stream.channel.send(Frame(kind: .audioFrame, streamID: stream.streamID, payload: packet.encoded()))
            }
        }

        private func announce(_ encoder: AACELDEncoder, source: AudioSource, on stream: HostAudioStream) {
            let started = AudioStarted(bundleID: stream.bundleID, appName: stream.appName, sampleRate: AACELD.sampleRate,
                                       channels: Int(AACELD.channels), framesPerPacket: AACELD.framesPerPacket,
                                       magicCookie: encoder.magicCookie, source: source,
                                       bitrate: AACELD.bitrate)
            if let f = try? MessageCodec.frame(.audioStarted, started, streamID: stream.streamID) { stream.channel.send(f) }
        }
    }
}

/// Viewer side of one remote app's audio: packets arrive on the network queue, are decoded on a
/// serial queue of their own, and land in the output's jitter buffer.
public final class RemoteAudioStream: @unchecked Sendable {
    public let streamID: UInt16
    /// Main actor.
    public private(set) var started: AudioStarted
    public let output: RemoteAudioOutput
    private let queue = DispatchQueue(label: "dev.paneshare.audio.decode", qos: .userInteractive)
    private var decoder: AACELDDecoder

    @MainActor
    public init(streamID: UInt16, started: AudioStarted) throws {
        self.streamID = streamID
        self.started = started
        self.decoder = try AACELDDecoder(started)
        self.output = try AudioPlayback.shared.makeOutput(sampleRate: started.sampleRate)
    }

    /// A repeated `audioStarted` on the same stream: new format or cookie.
    @MainActor
    public func restart(_ started: AudioStarted) throws {
        guard started.sampleRate == self.started.sampleRate else { throw AudioCodecError.setup("sample rate changed") }
        let decoder = try AACELDDecoder(started)
        self.started = started
        queue.async {
            self.decoder = decoder
            self.output.reset()
        }
    }

    /// Network queue.
    public func receive(_ payload: AudioFramePayload) {
        queue.async {
            let pcm = self.decoder.decode(payload.packet)
            if !pcm.isEmpty { self.output.push(pcm, ptsMicros: payload.ptsMicros) }
        }
    }

    @MainActor
    public func stop() {
        AudioPlayback.shared.remove(output)
    }
}
#endif
