#if os(macOS)
// Adapted from Sill, Sources/SillHost/VirtualDisplay.swift (github.com/Saffsanity/sill, commit 41e8cb8),
// Copyright 2026 Noah Saffer, licensed under the Apache License 2.0. Changed: paneshare names and errors,
// type-encoding rules moved to PaneshareCore (`ObjCTypeEncoding`), a whole-surface availability check
// cached per process, explicit HiDPI mode selection kept, colour primaries kept optional. The private
// API's shape was first published by KhaosT/CGVirtualDisplay (Apache-2.0) and is used the same way by
// DeskPad (MIT). See THIRD_PARTY.md.
import AppKit
import CoreGraphics
import Foundation
import ObjectiveC
import PaneshareCore

/// A virtual monitor on the host, made with CoreGraphics' **private** `CGVirtualDisplay` classes.
///
/// Why: a headless Mac (a Mac mini with no screen) has nowhere to put windows, and a window larger than
/// the host's screen can't be sized past it. A virtual display sized to the viewer's screen, in HiDPI,
/// gives the shared window room and a 2× backing store, so it stays sharp (docs/ARCHITECTURE.md §7.3).
///
/// Private API:
/// - `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings` and
///   `CGVirtualDisplayMode` are in CoreGraphics.framework but in no public header. They have existed
///   since macOS 11 and shipping apps use them, but Apple can change or remove them in any release.
/// - Every class and selector is looked up by name through the Objective-C runtime, and its type
///   encoding is checked before the call, so a missing or changed API is a thrown `Failure`, never a
///   crash. Callers fall back to the real screen.
/// - **Mac App Store:** guideline 2.5.1 forbids non-public API, so a build with this code can't be
///   submitted there. Developer ID + notarization (how paneshare ships) is allowed. No entitlement, no SIP.
///
/// Lifetime: the display exists while this object holds the `CGVirtualDisplay`. `destroy()` (or deinit)
/// releases it; the window server moves any window on it back to a real display. If the process exits
/// or crashes, the display goes with it, so nothing can be left behind.
///
/// Needs the AppKit event loop (`NSApplication.run`, which the SwiftUI app has): display
/// reconfiguration reaches this process through it. Main actor only.
@MainActor
public final class VirtualDisplay {
    public enum Failure: Error, CustomStringConvertible {
        case classMissing(String)
        case selectorMissing(cls: String, selector: String)
        case signatureChanged(cls: String, selector: String, expected: String, found: String)
        case initReturnedNil(String)
        case applySettingsFailed
        case noDisplayID
        case invalidSize(String)

        public var description: String {
            switch self {
            case .classMissing(let c): return "private class \(c) not found (API removed or renamed)"
            case .selectorMissing(let c, let s): return "private class \(c) doesn't respond to \(s)"
            case .signatureChanged(let c, let s, let e, let f): return "\(c) \(s) changed: expected \(e), found \(f)"
            case .initReturnedNil(let c): return "\(c) init returned nil"
            case .applySettingsFailed: return "the virtual display rejected its mode"
            case .noDisplayID: return "the virtual display reported display ID 0"
            case .invalidSize(let why): return "invalid size: \(why)"
            }
        }
    }

    public let widthPt: Int
    public let heightPt: Int
    public let scale = 2
    /// Zero after `destroy()`.
    public private(set) var displayID: CGDirectDisplayID = 0

    /// Called on the main actor if the window server tears the display down by itself.
    public var onTerminated: (() -> Void)?

    private var object: AnyObject?
    private let queue = DispatchQueue(label: "dev.paneshare.virtualdisplay")

    /// The display in global points (top-left origin, as window frames use).
    public var bounds: CGRect { displayID == 0 ? .zero : CGDisplayBounds(displayID) }

    public var pixelSize: (width: Int, height: Int) {
        guard displayID != 0, let mode = CGDisplayCopyDisplayMode(displayID) else { return (0, 0) }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    /// The display's area below the menu bar, in global top-left points, once AppKit knows the screen.
    public var visibleFrame: CGRect {
        guard displayID != 0,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
              }),
              let primary = NSScreen.screens.first else { return bounds }
        // AppKit is bottom-left from the primary screen; window frames are top-left.
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height)
    }

    public var isAlive: Bool { object != nil }

    public var hasRequestedMode: Bool {
        let b = bounds, px = pixelSize
        return Int(b.width) == widthPt && Int(b.height) == heightPt && px.width == widthPt * scale
    }

    /// - Parameters:
    ///   - widthPt, heightPt: the size windows see, in points (backing store is twice that).
    ///   - serial: keep stable per viewer (`VirtualDisplayPlanner.serial`), so macOS remembers where the
    ///     display goes instead of adding a new one to System Settings each time.
    public init(name: String, widthPt: Int, heightPt: Int, serial: UInt32, refreshHz: Double = 60) throws {
        guard widthPt >= 320, heightPt >= 240, widthPt <= 8192, heightPt <= 8192 else {
            throw Failure.invalidSize("\(widthPt)×\(heightPt) pt is outside 320×240…8192×8192")
        }
        self.widthPt = widthPt
        self.heightPt = heightPt
        let pxW = widthPt * scale, pxH = heightPt * scale

        let descriptor = try Runtime.newObject("CGVirtualDisplayDescriptor")
        try Runtime.setObject(descriptor, "setName:", name as NSString)
        try Runtime.setUInt32(descriptor, "setMaxPixelsWide:", UInt32(pxW))
        try Runtime.setUInt32(descriptor, "setMaxPixelsHigh:", UInt32(pxH))
        // About 110 pt per inch, like Apple's Retina panels, so macOS's default "looks like" is sensible.
        let mm = CGSize(width: Double(widthPt) / 110 * 25.4, height: Double(heightPt) / 110 * 25.4)
        try Runtime.setSize(descriptor, "setSizeInMillimeters:", mm)
        try Runtime.setUInt32(descriptor, "setVendorID:", 0x5057)   // "PW"
        try Runtime.setUInt32(descriptor, "setProductID:", 0x0001)
        try Runtime.setUInt32(descriptor, "setSerialNum:", serial)
        // sRGB-like primaries; without them some macOS versions build a degenerate colour profile.
        try? Runtime.setPoint(descriptor, "setRedPrimary:", CGPoint(x: 0.6797, y: 0.3203))
        try? Runtime.setPoint(descriptor, "setGreenPrimary:", CGPoint(x: 0.2559, y: 0.6983))
        try? Runtime.setPoint(descriptor, "setBluePrimary:", CGPoint(x: 0.1494, y: 0.0557))
        try? Runtime.setPoint(descriptor, "setWhitePoint:", CGPoint(x: 0.3125, y: 0.3291))
        do {
            try Runtime.setObject(descriptor, "setQueue:", queue)
        } catch {
            try Runtime.setObject(descriptor, "setDispatchQueue:", queue)
        }
        // Arguments taken as raw pointers, so a different arity can't cause a bad retain.
        let terminated: @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminatedByServer() } }
        }
        try Runtime.setBlock(descriptor, "setTerminationHandler:", terminated)

        let display = try Runtime.allocInit("CGVirtualDisplay", "initWithDescriptor:", descriptor)

        // One mode, in points. With hiDPI = 1 macOS derives a 1× and a 2× mode from it (hence maxPixels
        // at 2×); `waitUntilOnline` selects the 2× one with public API.
        let mode = try Runtime.newMode(width: UInt32(widthPt), height: UInt32(heightPt), refreshRate: refreshHz)
        let settings = try Runtime.newObject("CGVirtualDisplaySettings")
        try Runtime.setUInt32(settings, "setHiDPI:", 1)
        try Runtime.setObject(settings, "setModes:", [mode] as NSArray)
        guard try Self.applySettings(settings, to: display) else { throw Failure.applySettingsFailed }

        let id = try Runtime.getUInt32(display, "displayID")
        guard id != 0 else { throw Failure.noDisplayID }
        self.object = display
        self.displayID = id
    }

    /// Waits until the display is online at the requested HiDPI mode, selecting it with public
    /// CoreGraphics calls if macOS chose another. False on timeout (the display may still work).
    @discardableResult
    public func waitUntilOnline(timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var nextSelect = Date()
        while Date() < deadline {
            if hasRequestedMode { return true }
            if bounds.width > 0, Date() >= nextSelect {
                selectRequestedMode()
                nextSelect = Date().addingTimeInterval(0.5)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return hasRequestedMode
    }

    @discardableResult
    public func selectRequestedMode() -> Bool {
        guard displayID != 0 else { return false }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let want = modes.first(where: { $0.width == widthPt && $0.height == heightPt && $0.pixelWidth == widthPt * scale })
        else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, displayID, want, nil)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// Releases the display; it disappears. Safe to call twice.
    public func destroy() {
        object = nil
        displayID = 0
    }

    private func terminatedByServer() {
        guard object != nil else { return }
        destroy()
        onTerminated?()
    }

    // MARK: Availability

    /// Every private class, selector and type encoding this file calls.
    nonisolated static let privateAPISurface: [(cls: String, selector: String, encoding: String)] = [
        ("CGVirtualDisplayDescriptor", "init", "@@:"),
        ("CGVirtualDisplayDescriptor", "setName:", "v@:@"),
        ("CGVirtualDisplayDescriptor", "setMaxPixelsWide:", "v@:I"),
        ("CGVirtualDisplayDescriptor", "setMaxPixelsHigh:", "v@:I"),
        ("CGVirtualDisplayDescriptor", "setSizeInMillimeters:", "v@:{CGSize=dd}"),
        ("CGVirtualDisplayDescriptor", "setVendorID:", "v@:I"),
        ("CGVirtualDisplayDescriptor", "setProductID:", "v@:I"),
        ("CGVirtualDisplayDescriptor", "setSerialNum:", "v@:I"),
        ("CGVirtualDisplayDescriptor", "setQueue:", "v@:@"),
        ("CGVirtualDisplayDescriptor", "setTerminationHandler:", "v@:@?"),
        ("CGVirtualDisplay", "initWithDescriptor:", "@@:@"),
        ("CGVirtualDisplay", "applySettings:", "B@:@"),
        ("CGVirtualDisplay", "displayID", "I@:"),
        ("CGVirtualDisplayMode", "initWithWidth:height:refreshRate:", "@@:IId"),
        ("CGVirtualDisplaySettings", "init", "@@:"),
        ("CGVirtualDisplaySettings", "setHiDPI:", "v@:I"),
        ("CGVirtualDisplaySettings", "setModes:", "v@:@"),
    ]

    /// nil when the whole private surface is present with the expected signatures, otherwise the
    /// first problem. Creates nothing; checked once per process.
    public nonisolated static let apiProblem: String? = {
        for entry in privateAPISurface {
            var problem = methodProblem(cls: entry.cls, selector: entry.selector, encoding: entry.encoding)
            if problem != nil, entry.selector == "setQueue:" {
                problem = methodProblem(cls: entry.cls, selector: "setDispatchQueue:", encoding: entry.encoding)
            }
            if let problem { return problem }
        }
        return nil
    }()

    nonisolated static func methodProblem(cls: String, selector: String, encoding: String) -> String? {
        do {
            _ = try Runtime.method(Runtime.cls(cls), selector, encoding)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// `[display applySettings:settings]`. A `BOOL` return is one byte, read as `ObjCBool` (C99 `bool`
    /// on arm64, `signed char` on x86_64, where any non-zero byte is YES).
    static func applySettings(_ settings: AnyObject, to display: AnyObject) throws -> Bool {
        let (fn, sel) = try Runtime.imp(display, "applySettings:", "B@:@", as: Runtime.ApplyFn.self)
        return fn(display, sel, settings).boolValue
    }

    /// Real (non-virtual) screens' visible sizes in points; empty on a headless Mac. Public API.
    public static func physicalScreenSizes(excluding virtual: Set<CGDirectDisplayID>) -> [WireSize] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  !virtual.contains(id) else { return nil }
            return WireSize(screen.visibleFrame.size)
        }
    }
}

// MARK: - Objective-C runtime access

/// Looks up private classes and methods by name and checks each method's type encoding before
/// calling its IMP. Anything unexpected throws instead of sending a message with the wrong ABI.
private enum Runtime {
    static func cls(_ name: String) throws -> AnyClass {
        guard let c = NSClassFromString(name) else { throw VirtualDisplay.Failure.classMissing(name) }
        return c
    }

    static func method(_ c: AnyClass, _ selector: String, _ encoding: String) throws -> (IMP, Selector) {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(c, sel) else {
            throw VirtualDisplay.Failure.selectorMissing(cls: NSStringFromClass(c), selector: selector)
        }
        let found = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
        guard ObjCTypeEncoding.matches(found: found, expected: encoding) else {
            throw VirtualDisplay.Failure.signatureChanged(cls: NSStringFromClass(c), selector: selector,
                                                         expected: ObjCTypeEncoding.accepted(encoding).joined(separator: " or "),
                                                         found: ObjCTypeEncoding.normalized(found))
        }
        return (method_getImplementation(method), sel)
    }

    static func imp<F>(_ target: AnyObject, _ selector: String, _ encoding: String, as: F.Type) throws -> (F, Selector) {
        guard let c = object_getClass(target) else { throw VirtualDisplay.Failure.classMissing("\(target)") }
        let (imp, sel) = try method(c, selector, encoding)
        return (unsafeBitCast(imp, to: F.self), sel)
    }

    /// `[[Class alloc] init]`.
    static func newObject(_ className: String) throws -> NSObject {
        guard let type = try cls(className) as? NSObject.Type else {
            throw VirtualDisplay.Failure.classMissing("\(className) (not an NSObject)")
        }
        return type.init()
    }

    typealias AllocFn = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
    typealias InitObjFn = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> UnsafeMutableRawPointer?
    typealias InitModeFn = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeMutableRawPointer?

    /// `[[Class alloc] <initSelector>:arg]`. alloc returns +1; init consumes it and returns +1, which
    /// `takeRetainedValue` adopts.
    static func allocInit(_ className: String, _ initSelector: String, _ arg: AnyObject) throws -> AnyObject {
        let c: AnyClass = try cls(className)
        let (initFn, sel) = try initIMP(c, initSelector, "@@:@", as: InitObjFn.self)
        let raw = try alloc(c)
        guard let obj = initFn(raw, sel, arg) else { throw VirtualDisplay.Failure.initReturnedNil(className) }
        return Unmanaged<AnyObject>.fromOpaque(obj).takeRetainedValue()
    }

    static func newMode(width: UInt32, height: UInt32, refreshRate: Double) throws -> AnyObject {
        let name = "CGVirtualDisplayMode"
        let c: AnyClass = try cls(name)
        let (initFn, sel) = try initIMP(c, "initWithWidth:height:refreshRate:", "@@:IId", as: InitModeFn.self)
        let raw = try alloc(c)
        guard let obj = initFn(raw, sel, width, height, refreshRate) else { throw VirtualDisplay.Failure.initReturnedNil(name) }
        return Unmanaged<AnyObject>.fromOpaque(obj).takeRetainedValue()
    }

    private static func alloc(_ c: AnyClass) throws -> UnsafeMutableRawPointer {
        let sel = NSSelectorFromString("alloc")
        guard let method = class_getClassMethod(c, sel) else {
            throw VirtualDisplay.Failure.selectorMissing(cls: NSStringFromClass(c), selector: "+alloc")
        }
        let fn = unsafeBitCast(method_getImplementation(method), to: AllocFn.self)
        guard let raw = fn(c, sel) else { throw VirtualDisplay.Failure.initReturnedNil(NSStringFromClass(c)) }
        return raw
    }

    private static func initIMP<F>(_ c: AnyClass, _ selector: String, _ encoding: String, as: F.Type) throws -> (F, Selector) {
        let (imp, sel) = try method(c, selector, encoding)
        return (unsafeBitCast(imp, to: F.self), sel)
    }

    typealias SetObjFn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    typealias SetUIntFn = @convention(c) (AnyObject, Selector, UInt32) -> Void
    typealias SetSizeFn = @convention(c) (AnyObject, Selector, CGSize) -> Void
    typealias SetPointFn = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    typealias SetBlockFn = @convention(c) (AnyObject, Selector, @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void) -> Void
    typealias GetUIntFn = @convention(c) (AnyObject, Selector) -> UInt32
    typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool

    static func setObject(_ target: AnyObject, _ selector: String, _ value: AnyObject) throws {
        let (fn, sel) = try imp(target, selector, "v@:@", as: SetObjFn.self)
        fn(target, sel, value)
    }

    static func setUInt32(_ target: AnyObject, _ selector: String, _ value: UInt32) throws {
        let (fn, sel) = try imp(target, selector, "v@:I", as: SetUIntFn.self)
        fn(target, sel, value)
    }

    static func setSize(_ target: AnyObject, _ selector: String, _ value: CGSize) throws {
        let (fn, sel) = try imp(target, selector, "v@:{CGSize=dd}", as: SetSizeFn.self)
        fn(target, sel, value)
    }

    static func setPoint(_ target: AnyObject, _ selector: String, _ value: CGPoint) throws {
        let (fn, sel) = try imp(target, selector, "v@:{CGPoint=dd}", as: SetPointFn.self)
        fn(target, sel, value)
    }

    static func setBlock(_ target: AnyObject, _ selector: String,
                         _ block: @escaping @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void) throws {
        let (fn, sel) = try imp(target, selector, "v@:@?", as: SetBlockFn.self)
        fn(target, sel, block)
    }

    static func getUInt32(_ target: AnyObject, _ selector: String) throws -> UInt32 {
        let (fn, sel) = try imp(target, selector, "I@:", as: GetUIntFn.self)
        return fn(target, sel)
    }
}
#endif
