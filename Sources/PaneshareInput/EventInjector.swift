#if os(macOS)
// Event construction (HID-state source, click state, continuous pixel scrolling with phases) follows Sill
// (Sources/SillHost/InputInjector.swift, Copyright 2026 Noah Saffer, Apache-2.0), rewritten; see THIRD_PARTY.md.
import CoreGraphics
import Foundation
import PaneshareCore

/// Posts viewer input as CGEvents at the HID tap, mapped onto the shared window's frame. The caller
/// has already applied `InputGate`, which keeps keys from going to a window that isn't frontmost.
public final class EventInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<MouseButton> = []

    public init() {}

    public func inject(_ event: InputEvent, windowFrame: CGRect) {
        let flags = CGEventFlags(rawValue: event.modifierFlags & EventCodes.modifierMask)
        switch event.kind {
        case .mouseMove, .mouseDrag, .mouseDown, .mouseUp:
            guard let position = event.position else { return }
            let point = InputMapping.globalPoint(position, windowFrame: windowFrame)
            postMouse(event, at: point, flags: flags)
        case .scroll:
            guard let position = event.position else { return }
            let point = InputMapping.globalPoint(position, windowFrame: windowFrame)
            // Scroll goes to the window under the pointer, so move there first.
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            postScroll(event, flags: flags)
        case .keyDown, .keyUp:
            guard let code = event.keyCode,
                  let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: event.kind == .keyDown)
            else { return }
            e.flags = flags
            if event.isRepeat == true { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            e.post(tap: .cghidEventTap)
        case .flagsChanged:
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(event.keyCode ?? 0), keyDown: true)
            else { return }
            e.type = .flagsChanged
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Releases any button the viewer left pressed (stream closed mid-drag).
    public func releaseAll(windowFrame: CGRect) {
        let location = CGEvent(source: nil)?.location ?? CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        for b in buttonsDown {
            let (_, up, cg) = Self.types(b)
            CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: location, mouseButton: cg)?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll()
    }

    static func types(_ b: MouseButton) -> (down: CGEventType, up: CGEventType, button: CGMouseButton) {
        switch b {
        case .left: return (.leftMouseDown, .leftMouseUp, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .right)
        case .other: return (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    private func postMouse(_ event: InputEvent, at point: CGPoint, flags: CGEventFlags) {
        let button = event.button ?? .left
        let (down, up, cg) = Self.types(button)
        let type: CGEventType
        switch event.kind {
        case .mouseDown: type = down; buttonsDown.insert(button)
        case .mouseUp: type = up; buttonsDown.remove(button)
        case .mouseDrag:
            switch button {
            case .left: type = .leftMouseDragged
            case .right: type = .rightMouseDragged
            case .other: type = .otherMouseDragged
            }
        default: type = .mouseMoved
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cg) else { return }
        e.flags = flags
        if event.kind == .mouseDown || event.kind == .mouseUp {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount ?? 1))
        }
        e.post(tap: .cghidEventTap)
    }

    private func postScroll(_ event: InputEvent, flags: CGEventFlags) {
        let dx = event.scrollDeltaX ?? 0, dy = event.scrollDeltaY ?? 0
        let pixel = (event.scrollUnit ?? .pixel) == .pixel
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: pixel ? .pixel : .line, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.flags = flags
        if pixel {
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded()))
        }
        if let phase = event.scrollPhase { e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase)) }
        if let momentum = event.momentumPhase { e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum)) }
        e.post(tap: .cghidEventTap)
    }
}
#endif
