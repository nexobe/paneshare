#if os(macOS)
import AppKit
import PaneshareCore
import PaneshareDecode

/// One native window per shared window, titled after the source app and window. Live resizes are
/// coalesced and sent to the host, which resizes the real window; the host's answer (the size the
/// app actually took) snaps this window to match. Outside a live resize the content size is kept at
/// exactly the stream's pixels ÷ the backing scale at native quality, so the picture is shown 1:1.
public final class RemoteWindowController: NSWindowController, NSWindowDelegate {
    public let remote: RemoteWindowIdentity
    public private(set) var streamID: UInt16
    public let renderer: StreamRenderer
    public let videoView: VideoView
    private weak var dock: DockPresenter?

    public var onInput: ((InputEvent) -> Void)? {
        get { videoView.onInput }
        set { videoView.onInput = newValue }
    }
    /// A size to ask the host for; `final` is false for the steps of a live resize.
    public var onResizeRequest: ((_ size: CGSize, _ final: Bool) -> Void)?
    /// The user closed the window.
    public var onClose: (() -> Void)?
    public var onFilesDropped: (([URL]) -> Void)? {
        didSet { videoView.onFilesDropped = onFilesDropped }
    }

    private var coalescer = ResizeCoalescer(interval: 0.1)
    private var resizeTimer: Timer?
    private var applyingHostSize = false
    private var closedByHost = false

    public let quality: StreamQuality
    private var hostPoints: CGSize
    /// What the host says it sends; the decoded size replaces it once frames arrive.
    private var streamPixels: PixelSize
    private var decodedPixels: PixelSize?
    /// The host's description of this stream, from `streamInfo`.
    public var streamInfo: StreamInfo? {
        didSet { if streamInfo != oldValue { logDiagnostics(reason: "stream info") } }
    }
    private var overlayTimer: Timer?
    private var overlayTicks = 0
    /// UserDefaults key (app domain) that turns the diagnostics overlay and its log lines on.
    public static let overlayKey = "debugOverlay"

    public init(remote: RemoteWindowIdentity, started: StreamStarted, quality: StreamQuality, dock: DockPresenter?) {
        self.remote = remote
        self.streamID = started.streamID
        self.renderer = StreamRenderer()
        self.videoView = VideoView(displayLayer: renderer.layer)
        self.dock = dock
        self.quality = quality
        self.hostPoints = started.pointSize.cgSize
        self.streamPixels = started.pixelSize
        let fitted = DisplayFit.contentSize(pixels: started.pixelSize, backingScale: Double(NSScreen.main?.backingScaleFactor ?? 2),
                                            quality: quality, hostPoints: started.pointSize.cgSize)
        let size = Sizing.clampRequested(fitted)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = started.window.displayTitle
        let pause: InputState.Pause? = started.inputEnabled == false ? .noAccessibility : nil
        window.subtitle = Self.subtitle(hostName: remote.hostName, pause: pause)
        self.inputPause = pause
        window.contentView = videoView
        window.contentMinSize = Sizing.minPointSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        window.center()
        let icon = started.appIconPNG.flatMap(NSImage.init(data:))
        dock?.didOpen(remote, window: window, appIcon: icon)
        renderer.onDimensions = { [weak self] d in
            MainActor.assumeIsolated { self?.decoded(PixelSize(width: Int(d.width), height: Int(d.height))) }
        }
        if UserDefaults.standard.bool(forKey: Self.overlayKey) { startOverlay() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show() {
        showWindow(nil)
        window?.makeFirstResponder(videoView)
    }

    /// The host says what size the source window really took, and the stream's new pixel size.
    public func hostResized(to pointSize: CGSize, pixelSize: PixelSize) {
        hostPoints = pointSize
        streamPixels = pixelSize
        decodedPixels = nil
        fitToStream()
    }

    private func decoded(_ pixels: PixelSize) {
        decodedPixels = pixels
        fitToStream()
        logDiagnostics(reason: "decoded size")
    }

    /// Snaps the content size to the stream (`DisplayFit`), unless the user is dragging.
    private func fitToStream() {
        guard let window, !window.inLiveResize else { return updateMapping() }
        let target = DisplayFit.contentSize(pixels: decodedPixels ?? streamPixels, backingScale: Double(window.backingScaleFactor),
                                            quality: quality, hostPoints: hostPoints)
        let current = videoView.bounds.size
        if abs(current.width - target.width) > 0.01 || abs(current.height - target.height) > 0.01 {
            applyingHostSize = true
            window.setContentSize(target)
            applyingHostSize = false
        }
        updateMapping()
    }

    private func updateMapping() {
        guard let window, let pixels = decodedPixels else { return videoView.setOneToOne(false) }
        videoView.setOneToOne(DisplayFit.isOneToOne(pixels: pixels, viewPoints: videoView.bounds.size,
                                                    backingScale: Double(window.backingScaleFactor)))
    }

    // MARK: Diagnostics

    public var diagnostics: StreamDiagnostics {
        let stats = renderer.stats()
        return StreamDiagnostics(info: streamInfo, decodedPixels: decodedPixels, viewPoints: videoView.bounds.size,
                                 backingScale: Double(window?.backingScaleFactor ?? 2),
                                 receivedBitsPerSecond: stats.bitsPerSecond, receivedFramesPerSecond: stats.framesPerSecond,
                                 topUps: stats.topUps)
    }

    private func startOverlay() {
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlayTick() }
        }
        overlayTick()
    }

    private func overlayTick() {
        let d = diagnostics
        videoView.setOverlay(d.text)
        overlayTicks += 1
        if overlayTicks % 5 == 1 { logDiagnostics(reason: "periodic", d) }
    }

    /// One log line per stage change, always; every 5 s too while the overlay is on.
    private func logDiagnostics(reason: String, _ given: StreamDiagnostics? = nil) {
        let d = given ?? diagnostics
        NSLog("paneshare viewer stream %ld (%@): %@", Int(streamID), reason, d.lines.joined(separator: " | "))
    }

    /// The same remote window on a new stream, after a reconnect.
    public func rebind(streamID: UInt16) {
        self.streamID = streamID
        renderer.reset()
    }

    /// The host can't inject input into this window. The host re-checks its permission on every
    /// event, so this is advisory and refreshed on the next `streamStarted`.
    public var isViewOnly: Bool {
        get { inputPause == .noAccessibility }
        set { inputPause = newValue ? .noAccessibility : nil }
    }

    /// Why the host is dropping input, from `streamStarted` and then `inputState` updates.
    public var inputPause: InputState.Pause? {
        didSet { window?.subtitle = Self.subtitle(hostName: remote.hostName, pause: inputPause) }
    }

    static func subtitle(hostName: String, pause: InputState.Pause?) -> String {
        switch pause {
        case nil: return "on \(hostName)"
        case .noAccessibility: return "on \(hostName) · view only (that Mac hasn't allowed Accessibility)"
        case .secureInput: return "on \(hostName) · typing paused while that Mac is entering a password"
        }
    }

    /// The host ended the stream (window closed, host stopped).
    public func closeFromHost() {
        closedByHost = true
        window?.close()
    }

    // MARK: NSWindowDelegate

    public func windowDidChangeBackingProperties(_ notification: Notification) {
        fitToStream()
    }

    public func windowDidResize(_ notification: Notification) {
        updateMapping()
        guard !applyingHostSize, let window else { return }
        let size = window.contentLayoutRect.size
        // Zoom, tiling and other one-shot resizes are final straight away.
        guard window.inLiveResize else {
            resizeTimer?.invalidate()
            _ = coalescer.finish(now: ProcessInfo.processInfo.systemUptime)
            onResizeRequest?(size, true)
            return
        }
        if let now = coalescer.offer(size, now: ProcessInfo.processInfo.systemUptime) { onResizeRequest?(now, false) }
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: coalescer.interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let later = self.coalescer.poll(now: ProcessInfo.processInfo.systemUptime) { self.onResizeRequest?(later, false) }
            }
        }
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        resizeTimer?.invalidate()
        // The final request always goes out, even if its size was already sent mid-drag: it is
        // what makes the host re-size the stream.
        let last = coalescer.finish(now: ProcessInfo.processInfo.systemUptime)
        guard let size = last ?? window?.contentLayoutRect.size else { return }
        onResizeRequest?(size, true)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        dock?.didActivate(remote)
    }

    public func windowWillClose(_ notification: Notification) {
        resizeTimer?.invalidate()
        overlayTimer?.invalidate()
        dock?.didClose(remote)
        renderer.reset()
        if !closedByHost { onClose?() }
    }
}
#endif
