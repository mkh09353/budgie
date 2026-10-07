import AVFoundation
import CoreAudio

enum SystemAudioError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status):
            return "Could not \(step) (Core Audio error \(status))."
        case .unsupportedFormat:
            return "System audio arrived in an unsupported format."
        }
    }
}

/// Captures everything the Mac plays — the other side of a call — through a
/// Core Audio process tap, with no virtual audio driver.
///
/// The tap covers every process except Budgie itself (so its own sounds stay
/// out of the recording) and is read through a private aggregate device whose
/// clock is the current output device. The first start shows macOS's "System
/// Audio Recording Only" prompt (`NSAudioCaptureUsageDescription`). If the user
/// declines, Core Audio still delivers buffers, but they are silent.
@available(macOS 14.2, *)
final class SystemAudioRecorder {
    /// Called on `queue` with each captured buffer and its host time. The
    /// buffer wraps Core Audio's memory and is only valid during the call.
    var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?

    let queue = DispatchQueue(label: "com.maxheadley.budgie.system-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    deinit { stop() }

    func start() throws {
        stop()
        do {
            try startTapAndDevice()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func startTapAndDevice() throws {
        let excluded = Self.processObject(for: getpid()).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Budgie Meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check("create the system audio tap", AudioHardwareCreateProcessTap(description, &tapID))

        var streamDescription = AudioStreamBasicDescription()
        try Self.read(tapID, kAudioTapPropertyFormat, into: &streamDescription,
                      step: "read the system audio format")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw SystemAudioError.unsupportedFormat
        }

        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        try Self.read(AudioObjectID(kAudioObjectSystemObject),
                      kAudioHardwarePropertyDefaultSystemOutputDevice,
                      into: &outputDevice, step: "find the output device")
        // Core Audio returns the UID retained (+1); take ownership of it.
        var retainedUID: Unmanaged<CFString>?
        try Self.read(outputDevice, kAudioDevicePropertyDeviceUID, into: &retainedUID,
                      step: "read the output device")
        guard let outputUID = retainedUID?.takeRetainedValue() else {
            throw SystemAudioError.coreAudio("read the output device", kAudioHardwareUnspecifiedError)
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Budgie Meeting Tap",
            kAudioAggregateDeviceUIDKey: "com.maxheadley.budgie.meeting-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID as String]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]
        try check("create the capture device",
                  AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        try check("attach to the capture device", AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, queue
        ) { [weak self] _, inputData, inputTime, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData)
            else { return }
            self.onBuffer?(buffer, inputTime.pointee.mHostTime)
        })
        try check("start the capture device", AudioDeviceStart(aggregateID, procID))
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioError.coreAudio(step, status) }
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private static func read<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        into value: inout T, step: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw SystemAudioError.coreAudio(step, status) }
    }
}
