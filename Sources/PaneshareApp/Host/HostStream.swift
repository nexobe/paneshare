#if os(macOS)
import AppKit
import Carbon.HIToolbox
import CoreMedia
import Foundation
import PaneshareCapture
import PaneshareCore
import PaneshareEncode
import PaneshareInput
import PaneshareVirtualDisplay
import ScreenCaptureKit

/// One shared window going to one viewer: capture → encode → channel, plus that viewer's input and
/// resize requests for it. Main actor, except the frame path, which never touches the main thread.
@MainActor
final class HostStream {
    let streamID: UInt16
    private(set) var info: WindowInfo
    private let scWindow: SCWindow?
    private let scDisplay: SCDisplay?
    private let policy: WindowPolicy?
    private var excludedIDs: Set<CGWindowID>
    private var exclusionTick = 0
    private let initialExclusions: [SCWindow]
    private var isScreen: Bool { scDisplay != nil }
    private let channel: MessageChannel
    private let capturer = WindowCapturer(fps: 60)
    private let injector = EventInjector()
    private var axWindow: AXWindow?
    private var encoder: VideoEncoder?
    private var viewerScale: Double
    private(set) var pixelSize: PixelSize
    private var windowFrame: CGRect
    private var frameRefreshedAt: TimeInterval = 0
    private var accessibilityTrusted = Permissions.accessibility
    private var rebuiltEncoder = false
    private let sendState = SendState()
    var onEnded: ((CloseStream.Reason) -> Void)?
    private var holdsKeepAwake = false

    private let quality: StreamQuality
    /// Chroma formats the viewer said it can decode.
    private let chroma: [ChromaFormat]
    /// Bumped by every resize request, so a deferred reconfigure only runs if nothing newer came.
    private var resizeGeneration = 0
    private var secureInputActive = IsSecureEventInputEnabled()
    /// What the viewer was last told; `streamStarted.inputEnabled` covers the initial state.
    private var reportedPause: InputState.Pause?
    private var inputStateTimer: Timer?

    /// Who the stream is for and how big their screen is, for a virtual display (§7.3). nil for a
    /// browser guest, whose windows never move.
    private let viewer: Fingerprint?
    private let viewerDisplay: WireSize?
    /// False for browser guests, which get H.264 (§7.4).
    private let allowHEVC: Bool
    /// Set while the window sits on this viewer's virtual display; `originalOrigin` is where it came from.
    private var virtualDisplay: VirtualDisplay?
    /// nil unless the viewer asked for automatic quality. Main actor.
    private var adaptive: AdaptiveBitrate?
    /// Reads the host's setting each time, so turning it off applies at once.
    var moveAwayAllowed: () -> Bool = { false }
    private var originalOrigin: CGPoint?

    init(streamID: UInt16, entry: ShareableWindows.Entry, viewerScale: Double, quality: StreamQuality,
         chroma: [ChromaFormat], channel: MessageChannel, viewer: Fingerprint?, viewerDisplay: WireSize?,
         allowHEVC: Bool = true, policy: WindowPolicy? = nil, adaptiveQuality: Bool = false) {
        self.adaptive = adaptiveQuality ? AdaptiveBitrate() : nil
        self.streamID = streamID
        self.viewer = viewer
        self.viewerDisplay = viewerDisplay
        self.allowHEVC = allowHEVC
        self.info = entry.info
        self.scWindow = entry.window
        self.scDisplay = entry.display
        self.policy = policy
        self.initialExclusions = entry.excluding
        self.excludedIDs = Set(entry.excluding.map(\.windowID))
        self.channel = channel
        self.viewerScale = viewerScale
        self.quality = quality
        self.chroma = chroma
        self.windowFrame = entry.info.frame.cgRect
        self.pixelSize = Sizing.pixelSize(points: entry.info.frame.cgRect.size, scale: viewerScale, quality: quality)
    }

    func start() async throws {
        if sendState.isLive, !holdsKeepAwake {
            holdsKeepAwake = true
            KeepAwake.shared.acquire()
        }
        if !isScreen { axWindow = AXWindow.find(processID: info.processID, frame: windowFrame, title: info.title) }
        if await moveToVirtualDisplayIfNeeded(wanted: nil) {
            pixelSize = Sizing.pixelSize(points: windowFrame.size, scale: viewerScale, quality: quality)
        }
        let encoder = try VideoEncoder.make(pixelSize: pixelSize, preferHEVC: allowHEVC, chroma: chroma)
        install(encoder)
        capturer.onFrame = Self.frameHandler(encoder: currentEncoder, state: sendState)
        capturer.onStop = Self.stopHandler { [weak self] in self?.end(.windowClosed) }
        let started = StreamStarted(streamID: streamID, window: info, pointSize: WireSize(windowFrame.size),
                                    pixelSize: pixelSize, codec: encoder.codec,
                                    appIconPNG: ShareableWindows.iconPNG(processID: info.processID),
                                    inputEnabled: accessibilityTrusted)
        channel.send(try MessageCodec.frame(.streamStarted, started, streamID: streamID))
        reportedPause = accessibilityTrusted ? nil : .noAccessibility
        startInputStateTimer()
        if let scDisplay {
            try await capturer.start(display: scDisplay, excluding: initialExclusions, pixelSize: pixelSize)
        } else if let scWindow {
            try await capturer.start(window: scWindow, pixelSize: pixelSize)
        }
        sendStreamInfo()
    }

    /// Tells the viewer what is really being captured and encoded, and logs it.
    private func sendStreamInfo() {
        guard let encoder, sendState.isLive else { return }
        var info = StreamInfo(sourceScale: capturer.sourceScale, sourcePoints: WireSize(windowFrame.size),
                              capturePixels: pixelSize, captureFormat: WindowCapturer.pixelFormatName,
                              encodedPixels: encoder.pixelSize, codec: encoder.codec, chroma: encoder.chroma,
                              profile: encoder.profile, hardware: encoder.isHardware,
                              bitrate: encoder.bitrate, topUpBitrate: encoder.topUpBitrate)
        info.movable = canMoveAway
        info.movedAway = isMovedAway
        NSLog("paneshare host stream %ld: window %.0fx%.0f pt @%.1fx, viewer @%.1fx, capture %ldx%ld %@, %@ %@ %@, %ld b/s (top-up %ld)",
              Int(streamID), windowFrame.width, windowFrame.height, capturer.sourceScale ?? 0, viewerScale,
              pixelSize.width, pixelSize.height, WindowCapturer.pixelFormatName, encoder.codec == .hevc ? "HEVC" : "H.264",
              encoder.chroma.rawValue, encoder.profile, encoder.bitrate, encoder.topUpBitrate)
        if let f = try? MessageCodec.frame(.streamInfo, info, streamID: streamID) { channel.send(f) }
    }

    /// Synchronous so the timer isn't scheduled from an async context.
    /// Lowers or restores the bitrate from recent drops, if the viewer asked for that.
    private func refreshBitrate() {
        guard adaptive != nil else { return }
        let dropped = sendState.takeDropCount()
        guard let factor = adaptive?.update(dropped: dropped, now: ProcessInfo.processInfo.systemUptime) else { return }
        encoder?.setRateFactor(factor)
        NSLog("paneshare host stream %ld: bitrate factor %.2f after %ld drops", Int(streamID), factor, dropped)
        sendStreamInfo()
    }

    private func startInputStateTimer() {
        inputStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshInputState()
                self?.refreshExclusions()
                self?.refreshBitrate()
            }
        }
        refreshInputState()
    }

    /// Every two seconds, leaves out windows of rejected apps that opened after the stream started.
    private func refreshExclusions() {
        exclusionTick += 1
        guard let scDisplay, let policy, exclusionTick.isMultiple(of: 4), sendState.isLive else { return }
        let capturer = self.capturer
        Task { [weak self] in
            guard let windows = try? await ShareableWindows.excludedWindows(policy: policy) else { return }
            let ids = Set(windows.map(\.windowID))
            guard let self, ids != self.excludedIDs, self.sendState.isLive else { return }
            self.excludedIDs = ids
            try? await capturer.update(display: scDisplay, excluding: windows)
        }
    }

    /// Re-reads secure keyboard entry and Accessibility trust and tells the viewer when the pause
    /// state changes, so its window can say why typing does nothing.
    private func refreshInputState() {
        guard sendState.isLive else { return }
        secureInputActive = IsSecureEventInputEnabled()
        accessibilityTrusted = Permissions.accessibility
        let pause = InputGate.pause(accessibilityTrusted: accessibilityTrusted, secureInputActive: secureInputActive)
        guard pause != reportedPause,
              let f = try? MessageCodec.frame(.inputState, InputState(paused: pause), streamID: streamID) else { return }
        reportedPause = pause
        channel.send(f)
    }

    /// The encoder the capture queue feeds, swapped on resize.
    private let currentEncoder = Locked<VideoEncoder?>(nil)

    private func install(_ encoder: VideoEncoder) {
        encoder.onEncoded = Self.encodedHandler(channel: channel, streamID: streamID, state: sendState,
                                                encoder: encoder, current: currentEncoder)
        encoder.onFailed = Self.failureHandler { [weak self, weak encoder] in
            guard let encoder else { return }
            self?.encoderFailed(encoder)
        }
        self.encoder = encoder
        if let factor = adaptive?.factor, factor < 1 { encoder.setRateFactor(factor) }
        currentEncoder.withLock { $0 = encoder }
    }

    // The frame path runs on capture and VideoToolbox threads. These closures are built outside the
    // main actor and touch only lock-protected state.

    nonisolated private static func frameHandler(encoder: Locked<VideoEncoder?>, state: SendState) -> @Sendable (CVPixelBuffer, CMTime) -> Void {
        { buffer, pts in
            guard state.isLive else { return }
            encoder.withLock { $0?.encode(buffer, pts: pts) }
        }
    }

    nonisolated private static func stopHandler(_ body: @escaping @MainActor @Sendable () -> Void) -> @Sendable (Error?) -> Void {
        { _ in onMain(body) }
    }

    nonisolated private static func encodedHandler(channel: MessageChannel, streamID: UInt16, state: SendState,
                                                   encoder: VideoEncoder, current: Locked<VideoEncoder?>) -> @Sendable (EncodedFrame) -> Void {
        { [weak encoder] frame in
            // A replaced encoder's late output would reach the viewer after the new keyframe.
            guard state.isLive, let encoder, current.withLock({ $0 === encoder }) else { return }
            // The viewer would drop the connection over a frame past its limit; resync instead.
            guard frame.payload.accessUnit.count + 64 < Int(FrameDecoder.hostToViewerLimit) else {
                state.dropped()
                encoder.requestKeyframe()
                return
            }
            if frame.isKeyframe {
                if let sets = frame.parameterSets {
                    channel.send(Frame(kind: .parameterSets, streamID: streamID, payload: sets.encoded()))
                }
                channel.send(Frame(kind: .videoFrame, flags: .keyframe, streamID: streamID, payload: frame.payload.encoded()))
                state.keyframeSent()
                return
            }
            // After a dropped delta, the following deltas are useless until the next keyframe.
            guard !state.awaitingKeyframe else { return }
            let flags: FrameFlags = frame.isTopUp ? .topUp : []
            if !channel.sendDroppable(Frame(kind: .videoFrame, flags: flags, streamID: streamID, payload: frame.payload.encoded())) {
                state.dropped()
                encoder.requestKeyframe()
            }
        }
    }

    nonisolated private static func failureHandler(_ body: @escaping @MainActor @Sendable () -> Void) -> @Sendable () -> Void {
        { onMain(body) }
    }

    /// One rebuild, preferring H.264 (whose fallback list ends in the software encoder); a second
    /// failure ends the stream.
    private func encoderFailed(_ failed: VideoEncoder) {
        guard sendState.isLive, failed === encoder else { return }
        // 4:2:0 too: a rich-chroma profile the hardware accepted but can't run is a likely cause.
        guard !rebuiltEncoder, let replacement = try? VideoEncoder.make(pixelSize: pixelSize, preferHEVC: false) else {
            return end(.error)
        }
        rebuiltEncoder = true
        install(replacement)
        replacement.requestKeyframe()
        sendStreamInfo()
    }

    func requestKeyframe() { encoder?.requestKeyframe() }

    /// The window's frame in global top-left coordinates, as of the last refresh (at most 250 ms old).
    var currentFrame: CGRect {
        refreshFrame(force: false)
        return windowFrame
    }

    // MARK: Input

    func handle(_ event: InputEvent) {
        refreshFrame(force: event.kind == .mouseDown)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if event.kind == .keyDown { secureInputActive = IsSecureEventInputEnabled() }
        // On a whole screen the viewer can't see a rejected app's windows, so it can't type into them.
        if isScreen, event.kind == .keyDown, let policy, let front = NSWorkspace.shared.frontmostApplication,
           policy.appRejection(bundleID: front.bundleIdentifier ?? "", processID: front.processIdentifier) != nil {
            return
        }
        let decision = InputGate.decide(event, streamOwned: true, accessibilityTrusted: accessibilityTrusted,
                                        secureInputActive: secureInputActive,
                                        frontmostPID: frontPID, targetPID: isScreen ? (frontPID ?? 0) : info.processID)
        switch decision {
        case .drop:
            // A key typed while another app is in front would go to that app; raise on the next click.
            return
        case .raiseThenInject:
            axWindow?.raise()
        case .inject:
            break
        }
        injector.inject(event, windowFrame: windowFrame)
    }

    /// Re-reads the window's frame from AX at most every 250 ms (or now), so input lands on a window
    /// the host user moved.
    private func refreshFrame(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - frameRefreshedAt > 0.25 else { return }
        frameRefreshedAt = now
        accessibilityTrusted = Permissions.accessibility
        guard !isScreen else { return }
        if axWindow == nil { axWindow = AXWindow.find(processID: info.processID, frame: windowFrame, title: info.title) }
        if let f = axWindow?.frame { windowFrame = f }
    }

    // MARK: Resize

    /// Resizes the real window. While `final` is false (a live drag on the viewer) the stream keeps
    /// its pixel size and the window content is scaled into it; the capture and encoder are rebuilt
    /// once, for the final size, or one second after the last request if no final one arrives.
    func resize(to requested: WireSize, final: Bool) async {
        guard !isScreen else { return sendResized(final: final) }
        resizeGeneration += 1
        let generation = resizeGeneration
        let target = Sizing.clampRequested(requested.cgSize)
        guard Permissions.accessibility, let ax = axWindow ?? AXWindow.find(processID: info.processID, frame: windowFrame, title: info.title)
        else { return sendResized(final: final) }
        axWindow = ax
        if final { await moveToVirtualDisplayIfNeeded(wanted: WireSize(target)) }
        _ = ax.resize(to: target)
        // Apps apply AX sizes asynchronously; give it a moment before reading back.
        try? await Task.sleep(nanoseconds: 50_000_000)
        refreshFrame(force: true)
        if final {
            await reconfigureIfNeeded()
        } else {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.resizeGeneration == generation, self.sendState.isLive else { return }
                await self.reconfigureIfNeeded()
                self.sendResized(final: true)
            }
        }
        sendResized(final: final)
    }

    private func reconfigureIfNeeded() async {
        let newPixels = Sizing.pixelSize(points: windowFrame.size, scale: viewerScale, quality: quality)
        guard sendState.isLive, Sizing.shouldReconfigure(final: true, current: pixelSize, next: newPixels) else { return }
        pixelSize = newPixels
        do {
            let encoder = try VideoEncoder.make(pixelSize: newPixels, preferHEVC: allowHEVC && self.encoder?.codec != .h264,
                                                chroma: rebuiltEncoder ? [.yuv420] : chroma)
            install(encoder)
            try await capturer.update(pixelSize: newPixels)
            encoder.requestKeyframe()
            sendStreamInfo()
        } catch {
            end(.error)
        }
    }

    private func sendResized(final: Bool) {
        let msg = Resized(pointSize: WireSize(windowFrame.size), pixelSize: pixelSize, final: final)
        if let f = try? MessageCodec.frame(.resized, msg, streamID: streamID) { channel.send(f) }
    }

    // MARK: Virtual display

    /// Moves the window onto the viewer's virtual display when the setting and the planner say so.
    /// True if it moved. Needs Accessibility; without it the window stays where it is.
    @discardableResult
    private func moveToVirtualDisplayIfNeeded(wanted: WireSize?) async -> Bool {
        guard !isScreen else { return false }
        guard case .useVirtual(let size) = VirtualDisplayManager.shared.plan(window: WireSize(windowFrame.size), wanted: wanted,
                                                                             viewerDisplay: viewerDisplay) else { return false }
        return await moveToVirtualDisplay(size: size)
    }

    private var isMovedAway: Bool { virtualDisplay != nil }

    private var canMoveAway: Bool {
        VirtualDisplayPlanner.canMoveAway(settingOn: moveAwayAllowed(), isScreen: isScreen,
                                          apiProblem: VirtualDisplayManager.shared.apiProblem, accessibility: Permissions.accessibility)
    }

    /// The viewer's request. Every check runs here too, because the viewer can ask anyway.
    func setPlacement(away: Bool) async {
        if away {
            if canMoveAway, !isMovedAway {
                let need = WireSize(windowFrame.size)
                await moveToVirtualDisplay(size: VirtualDisplayPlanner.displaySize(viewer: viewerDisplay, need: need))
            }
        } else {
            bringBack()
            try? await Task.sleep(nanoseconds: 50_000_000)
            refreshFrame(force: true)
        }
        sendStreamInfo()
    }

    /// Also the host user's own control, so it needs no setting.
    func bringBack() { leaveVirtualDisplay() }

    func refreshInfo() { sendStreamInfo() }

    var movedAwayTitle: String? { isMovedAway ? info.displayTitle : nil }

    @discardableResult
    private func moveToVirtualDisplay(size: WireSize) async -> Bool {
        guard let viewer, virtualDisplay == nil, Permissions.accessibility, let ax = axWindow else { return false }
        let manager = VirtualDisplayManager.shared
        guard let display = await manager.acquire(viewer: viewer, size: size) else { return false }
        guard sendState.isLive else { manager.release(viewer: viewer); return false }
        let origin = windowFrame.origin
        let target = VirtualDisplayPlanner.placement(window: WireSize(windowFrame.size), visible: WireRect(display.visibleFrame))
        ax.move(to: CGPoint(x: target.x, y: target.y))
        try? await Task.sleep(nanoseconds: 50_000_000)
        refreshFrame(force: true)
        virtualDisplay = display
        originalOrigin = origin
        NSLog("paneshare host stream %ld: moved to a %ldx%ld pt virtual display (%ldx%ld px)", Int(streamID),
              display.widthPt, display.heightPt, display.pixelSize.width, display.pixelSize.height)
        return true
    }

    /// Puts the window back where it was and lets the display go.
    private func leaveVirtualDisplay() {
        guard virtualDisplay != nil else { return }
        virtualDisplay = nil
        if let origin = originalOrigin, Permissions.accessibility { axWindow?.move(to: origin) }
        originalOrigin = nil
        if let viewer { VirtualDisplayManager.shared.release(viewer: viewer) }
    }

    // MARK: End

    func end(_ reason: CloseStream.Reason, notify: Bool = true) {
        guard sendState.isLive else { return }
        sendState.stop()
        if holdsKeepAwake {
            holdsKeepAwake = false
            KeepAwake.shared.release()
        }
        inputStateTimer?.invalidate()
        inputStateTimer = nil
        injector.releaseAll(windowFrame: windowFrame)
        leaveVirtualDisplay()
        currentEncoder.withLock { $0 = nil }
        encoder = nil
        let capturer = self.capturer
        Task { await capturer.stop() }
        if notify, let f = try? MessageCodec.frame(.closeStream, CloseStream(reason: reason), streamID: streamID) {
            channel.send(f)
        }
        onEnded?(reason)
    }
}

/// Send-side flags shared by the encoder thread and the main actor.
final class SendState: @unchecked Sendable {
    private let lock = NSLock()
    private var live = true
    private var waitingForKey = false
    private var dropCount = 0

    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return live }
    var awaitingKeyframe: Bool { lock.lock(); defer { lock.unlock() }; return waitingForKey }
    func dropped() { lock.lock(); waitingForKey = true; dropCount += 1; lock.unlock() }
    func takeDropCount() -> Int { lock.lock(); defer { dropCount = 0; lock.unlock() }; return dropCount }
    func keyframeSent() { lock.lock(); waitingForKey = false; lock.unlock() }
    func stop() { lock.lock(); live = false; lock.unlock() }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
#endif
