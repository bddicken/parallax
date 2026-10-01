import AVFoundation
import CoreAudio
import Foundation
import ParallaxCore

/// Captures what Parallax's own web views play (the Suno window's player)
/// with a Core Audio process tap.
///
/// WebKit plays a page's audio from helper processes (WebKit.GPU, and
/// WebContent for some Web Audio), which macOS attributes to the app that
/// launched them. The tap includes only Parallax's helpers, never Parallax
/// itself (its headphone monitor would feed back) or other apps' audio. It
/// mutes them while tapped, so the page isn't also heard straight from the
/// speakers; you hear it through the monitor like the rest of the mix.
final class WebAudioNode: AudioInputNode, @unchecked Sendable {
    /// Setup and teardown.
    private let queue = DispatchQueue(label: "parallax.audio-web", qos: .userInitiated)
    /// Captured audio; separate so stopping the device never waits on itself.
    private let ioQueue = DispatchQueue(label: "parallax.audio-web-io", qos: .userInteractive)
    private let normalizer = PCMNormalizer()
    private let onBuffer: AudioBufferHandler
    private let onError: SourceErrorHandler

    // Only touched on `queue`.
    private var running = false
    private var tapped: Set<AudioObjectID> = []
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var reportedWaiting = false
    /// Not repeated while it keeps failing the same way.
    private var lastFailure: String?

    init(onBuffer: @escaping AudioBufferHandler, onError: @escaping SourceErrorHandler) {
        self.onBuffer = onBuffer
        self.onError = onError
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            // Rebuild when WebKit's helpers come and go, or the output device
            // (the tap's clock) changes.
            for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
                var address = tapAddress(selector)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh(force: selector != kAudioHardwarePropertyProcessObjectList) }
                if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                    listeners.append((address, block))
                }
            }
            refresh(force: true)
        }
    }

    func stop() {
        queue.sync { [self] in
            running = false
            for (address, block) in listeners {
                var address = address
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
            listeners = []
            tearDown()
        }
    }

    private func refresh(force: Bool = false) {
        guard running else { return }
        let processes = Self.webKitProcesses()
        guard force || processes != tapped else { return }
        tearDown()
        guard !processes.isEmpty else {
            // Nothing has played in the Suno window yet; WebKit's audio
            // process shows up the first time something does.
            if !reportedWaiting {
                reportedWaiting = true
                onError(.waiting("Play a song in the Suno window."))
            }
            return
        }
        do {
            try build(processes)
            tapped = processes
            if reportedWaiting || lastFailure != nil {
                reportedWaiting = false
                lastFailure = nil
                onError(.recovered)
            }
        } catch {
            tearDown()
            let message = error.localizedDescription
            if message != lastFailure {
                lastFailure = message
                onError(.failed(message))
            }
        }
    }

    private func build(_ processes: Set<AudioObjectID>) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
        description.name = "Parallax Suno Player"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(0)
        try check(AudioHardwareCreateProcessTap(description, &tapID),
                  "Parallax couldn't capture the Suno window. Allow Parallax under System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only).")
        tap = tapID

        var streamFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = tapAddress(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamFormat), "Couldn't read the Suno window's audio format.")
        guard let format = AVAudioFormat(streamDescription: &streamFormat) else { throw MediaError("The Suno window's audio format isn't supported.") }
        self.format = format

        guard let outputUID = Self.defaultOutputUID() else { throw MediaError("No audio output device to time the capture against.") }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Parallax Suno Player",
            kAudioAggregateDeviceUIDKey: "parallax.suno-player.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var deviceID = AudioObjectID(0)
        try check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &deviceID), "Couldn't set up capture of the Suno window.")
        aggregate = deviceID

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }, "Couldn't start capturing the Suno window.")
        ioProc = procID
        try check(AudioDeviceStart(deviceID, procID), "Couldn't start capturing the Suno window.")
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0, let pcm = normalizer.convert(buffer) else { return }
        onBuffer(pcm)
    }

    private func tearDown() {
        if aggregate != 0 {
            if let ioProc {
                AudioDeviceStop(aggregate, ioProc)
                AudioDeviceDestroyIOProcID(aggregate, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        aggregate = 0
        tap = 0
        tapped = []
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw MediaError("\(message) (error \(status))") }
    }

    // MARK: Finding WebKit's processes

    /// Core Audio's objects for the WebKit helpers this app launched.
    static func webKitProcesses() -> Set<AudioObjectID> {
        let me = getpid()
        var address = tapAddress(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Set(objects.filter { object in
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = tapAddress(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != me, responsiblePID(for: pid) == me else { return false }
            return true
        })
    }

    /// The app macOS holds responsible for `pid`: for an XPC helper like
    /// WebKit's, the app that launched it. Uses libsystem's
    /// `responsibility_get_pid_responsible_for_pid` (not in the public
    /// headers, but what Activity Monitor and others rely on).
    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        responsibleFunction.map { $0(pid) }
    }

    private static func defaultOutputUID() -> String? {
        var address = tapAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uidAddress = tapAddress(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

private func tapAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
