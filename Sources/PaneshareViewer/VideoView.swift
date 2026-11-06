#if os(macOS)
import AppKit
import AVFoundation
import PaneshareCore

/// Shows a stream's display layer and turns local events into normalized `InputEvent`s.
/// The view is flipped, so (0, 0) is its top-left corner, as on the wire.
public final class VideoView: NSView {
    public var onInput: ((InputEvent) -> Void)?
    /// Files dropped on this view. Nil refuses drops.
    public var onFilesDropped: (([URL]) -> Void)? {
        didSet {
            if onFilesDropped == nil { unregisterDraggedTypes() } else { registerForDraggedTypes([.fileURL]) }
        }
    }
    private let displayLayer: AVSampleBufferDisplayLayer
    private var tracking: NSTrackingArea?
    private var overlay: OverlayLabel?

    private var borderLayer: CALayer?

    /// Outlines the picture. It's only drawn on top, so it changes neither the video nor input mapping.
    public func setBorder(_ color: CGColor?) {
        guard let color else {
            borderLayer?.removeFromSuperlayer()
            borderLayer = nil
            return
        }
        let border = borderLayer ?? CALayer()
        border.frame = bounds
        border.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        border.borderWidth = 3
        border.borderColor = color
        border.zPosition = 10
        if borderLayer == nil { layer?.addSublayer(border) }
        borderLayer = border
    }

    public init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFilesDropped != nil && !droppedFiles(sender).isEmpty ? .copy : []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard let onFilesDropped, !urls.isEmpty else { return false }
        onFilesDropped(urls)
        return true
    }

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackingScale()
    }

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        displayLayer.contentsScale = scale
    }

    /// At exactly one stream pixel per screen pixel, sample without interpolation, so nothing can
    /// soften the picture; when the picture is scaled (mid-resize, reduced quality), filter it.
    public func setOneToOne(_ exact: Bool) {
        let filter: CALayerContentsFilter = exact ? .nearest : .linear
        guard displayLayer.magnificationFilter != filter || displayLayer.minificationFilter != filter else { return }
        displayLayer.magnificationFilter = filter
        displayLayer.minificationFilter = filter
    }

    /// The diagnostics overlay (hidden `debugOverlay` setting); nil hides it.
    public func setOverlay(_ text: String?) {
        guard let text else {
            overlay?.removeFromSuperview()
            overlay = nil
            return
        }
        let label: OverlayLabel
        if let existing = overlay {
            label = existing
        } else {
            label = OverlayLabel(labelWithString: "")
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .white
            label.drawsBackground = true
            label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
            label.maximumNumberOfLines = 0
            addSubview(label)
            overlay = label
        }
        label.stringValue = text
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 6, y: 6))
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Pointer

    private func position(_ event: NSEvent) -> NormalizedPoint {
        InputMapping.normalize(flippedPoint: convert(event.locationInWindow, from: nil), viewSize: bounds.size)
    }

    private func modifiers(_ event: NSEvent) -> UInt64 { UInt64(event.modifierFlags.rawValue) & EventCodes.modifierMask }

    private func pointer(_ kind: InputEvent.Kind, _ event: NSEvent, _ button: MouseButton? = nil) {
        onInput?(InputEvent(kind: kind, position: position(event), button: button,
                            clickCount: (kind == .mouseDown || kind == .mouseUp) ? max(1, min(3, event.clickCount)) : nil,
                            modifierFlags: modifiers(event)))
    }

    public override func mouseMoved(with event: NSEvent) { pointer(.mouseMove, event) }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(.mouseDown, event, .left) }
    public override func mouseUp(with event: NSEvent) { pointer(.mouseUp, event, .left) }
    public override func mouseDragged(with event: NSEvent) { pointer(.mouseDrag, event, .left) }
    public override func rightMouseDown(with event: NSEvent) { pointer(.mouseDown, event, .right) }
    public override func rightMouseUp(with event: NSEvent) { pointer(.mouseUp, event, .right) }
    public override func rightMouseDragged(with event: NSEvent) { pointer(.mouseDrag, event, .right) }
    public override func otherMouseDown(with event: NSEvent) { pointer(.mouseDown, event, .other) }
    public override func otherMouseUp(with event: NSEvent) { pointer(.mouseUp, event, .other) }
    public override func otherMouseDragged(with event: NSEvent) { pointer(.mouseDrag, event, .other) }

    public override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        onInput?(InputEvent(kind: .scroll, position: position(event),
                            scrollDeltaX: Double(event.scrollingDeltaX), scrollDeltaY: Double(event.scrollingDeltaY),
                            scrollUnit: precise ? .pixel : .line,
                            scrollPhase: EventCodes.scrollPhase(fromNSPhase: event.phase.rawValue),
                            momentumPhase: EventCodes.momentumPhase(fromNSPhase: event.momentumPhase.rawValue),
                            modifierFlags: modifiers(event)))
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) { key(.keyDown, event) }
    public override func keyUp(with event: NSEvent) { key(.keyUp, event) }
    public override func flagsChanged(with event: NSEvent) {
        onInput?(InputEvent(kind: .flagsChanged, keyCode: event.keyCode, modifierFlags: modifiers(event)))
    }

    /// Command shortcuts go to the remote app too, except Command-Q, which quits this app.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if flags == .command, event.charactersIgnoringModifiers == "q" { return super.performKeyEquivalent(with: event) }
        key(.keyDown, event)
        // AppKit doesn't deliver keyUp for a Command chord it consumed, so send it now.
        key(.keyUp, event)
        return true
    }

    private func key(_ kind: InputEvent.Kind, _ event: NSEvent) {
        guard event.keyCode < 0x80 else { return }
        onInput?(InputEvent(kind: kind, keyCode: event.keyCode, modifierFlags: modifiers(event),
                            isRepeat: kind == .keyDown ? event.isARepeat : nil))
    }
}

/// Never takes a click, so the overlay doesn't block input to the remote window.
private final class OverlayLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
