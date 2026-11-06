#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation
import PaneshareCore

/// One block of captured app audio: interleaved stereo Float32 and the host time (µs, mach host
/// clock, the same clock video timestamps use) of its first sample.
public struct CapturedAudio: Sendable {
    public var samples: [Float]
    public var frames: Int
    public var sampleRate: Double
    public var hostPtsMicros: UInt64
    public var source: AudioSource
}

public enum AudioCaptureError: Error, CustomStringConvertible {
    case unavailable(String)
    case coreAudio(String, OSStatus)

    public var description: String {
        switch self {
        case .unavailable(let why): return why
        case .coreAudio(let what, let status): return "\(what) failed (\(status))"
        }
    }
}

/// Something that captures one app's audio until stopped.
public protocol AppAudioCapture: AnyObject {
    var source: AudioSource { get }
    func start(onAudio: @escaping @Sendable (CapturedAudio) -> Void) async throws
    func stop()
}

/// Captures one app's audio with a public Core Audio process tap (macOS 14.2+): a private tap on
/// the app's audio processes, read through a private aggregate device. The app keeps playing on the
/// host as usual (`muteBehavior = .unmuted`). Needs the "System Audio Recording" permission
/// (`NSAudioCaptureUsageDescription`).
///
/// The app's helper processes count as the app: any audio process whose bundle ID is the app's or
/// starts with the app's ID plus a dot (Chrome's renderers, for example). Processes that start
/// playing later are added by updating the tap's description.
///
/// The sequence of calls follows AudioCap (BSD-2-Clause, Guilherme Rambo); see THIRD_PARTY.md.
@available(macOS 14.2, *)
public final class ProcessTapCapture: AppAudioCapture {
    public let source = AudioSource.processTap
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    public let bundleID: String
    public let processID: pid_t

    private let queue = DispatchQueue(label: "dev.paneshare.audio.tap", qos: .userInteractive)
    private var tapID = ProcessTapCapture.unknown
    private var aggregateID = ProcessTapCapture.unknown
    private var procID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var tappedProcesses: [AudioObjectID] = []
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var stopped = false

    public init(bundleID: String, processID: pid_t) {
        self.bundleID = bundleID
        self.processID = processID
    }

    // Nothing else holds the capture by now, so no queue hop (and no chance of waiting on ourselves).
    deinit { teardown() }

    public func start(onAudio: @escaping @Sendable (CapturedAudio) -> Void) async throws {
        try queue.sync { try self.startOnQueue(onAudio) }
    }

    private func startOnQueue(_ onAudio: @escaping @Sendable (CapturedAudio) -> Void) throws {
        let processes = Self.audioProcesses(matching: bundleID, processID: processID)
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "paneshare \(bundleID)"
        description.muteBehavior = CATapMuteBehavior.unmuted
        description.isPrivate = true
        description.isExclusive = false
        self.description = description
        self.tappedProcesses = processes

        var tap = ProcessTapCapture.unknown
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw AudioCaptureError.coreAudio("Creating the process tap", status) }
        tapID = tap

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "paneshare tap",
            kAudioAggregateDeviceUIDKey: "dev.paneshare.tap." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = ProcessTapCapture.unknown
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { teardown(); throw AudioCaptureError.coreAudio("Creating the aggregate device", status) }
        aggregateID = device

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else { teardown(); throw AudioCaptureError.coreAudio("Reading the tap format", status) }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0 else {
            teardown()
            throw AudioCaptureError.unavailable("The tap delivers an unexpected format.")
        }
        let channels = Int(format.mChannelsPerFrame)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let rate = format.mSampleRate

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, inputTime, _, _ in
            let captured = Self.copy(input, channels: channels, planar: planar)
            guard captured.frames > 0 else { return }
            let time = inputTime.pointee
            let micros = time.mFlags.contains(.hostTimeValid)
                ? AudioConvertHostTimeToNanos(time.mHostTime) / 1000
                : AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) / 1000
            onAudio(CapturedAudio(samples: captured.samples, frames: captured.frames, sampleRate: rate, hostPtsMicros: micros,
                                       source: .processTap))
        }
        guard status == noErr, let proc else { teardown(); throw AudioCaptureError.coreAudio("Creating the IO proc", status) }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { teardown(); throw AudioCaptureError.coreAudio("Starting the tap", status) }
        watchProcessList()
    }

    public func stop() {
        queue.sync { teardown() }
    }

    private func teardown() {
        guard !stopped else { return }
        stopped = true
        if let listener = processListListener {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            processListListener = nil
        }
        if aggregateID != ProcessTapCapture.unknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != ProcessTapCapture.unknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = ProcessTapCapture.unknown
        tapID = ProcessTapCapture.unknown
    }

    // MARK: Processes

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Adds processes of the app that start using audio after the tap was made.
    private func watchProcessList() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshProcesses() }
        var address = Self.processListAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            processListListener = listener
        }
    }

    private func refreshProcesses() {
        guard !stopped, let description, tapID != ProcessTapCapture.unknown else { return }
        let now = Self.audioProcesses(matching: bundleID, processID: processID)
        guard Set(now) != Set(tappedProcesses) else { return }
        description.processes = now
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var ref: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr { tappedProcesses = now }
    }

    /// Core Audio process objects that belong to the app.
    static func audioProcesses(matching bundleID: String, processID: pid_t) -> [AudioObjectID] {
        var address = processListAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        let prefix = bundleID + "."
        return objects.filter { object in
            if let pid = pid(of: object), pid == processID { return true }
            guard let id = Self.bundleID(of: object) else { return false }
            return id == bundleID || id.hasPrefix(prefix)
        }
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr ? pid : nil
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let id = value.takeRetainedValue() as String
        return id.isEmpty ? nil : id
    }

    static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = ProcessTapCapture.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw AudioCaptureError.coreAudio("Finding the output device", status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AudioCaptureError.coreAudio("Reading the output device UID", status) }
        return uid.takeRetainedValue() as String
    }

    // MARK: Samples

    private static func copy(_ list: UnsafePointer<AudioBufferList>, channels: Int, planar: Bool) -> (samples: [Float], frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return ([], 0) }
        if planar {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let channelPointers = buffers.prefix(2).compactMap { buffer -> UnsafeBufferPointer<Float>? in
                guard let p = buffer.mData else { return nil }
                return UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self),
                                           count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            }
            return (AudioSamples.stereo(planar: channelPointers, frames: frames), frames)
        }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frames = count / max(1, channels)
        let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        return (AudioSamples.stereo(interleaved: samples, channels: channels, frames: frames), frames)
    }
}
#endif
