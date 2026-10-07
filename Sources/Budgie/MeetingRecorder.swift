import AVFoundation
import CoreAudio

/// Records a meeting as two files in its folder: `me.wav` from the microphone
/// and `them.wav` from everything the Mac plays. Both are 16 kHz mono and start
/// at the same instant: a stream whose first buffer arrives late is padded with
/// silence, so a word at 0:42 in one file happened at 0:42 in the other.
///
/// Unlike Live dictation, nothing is ever dropped: every buffer is written.
/// The mic runs on its own `AVAudioEngine`, so push-to-talk keeps working
/// during a meeting.
final class MeetingRecorder {
    static let meFileName = "me.wav"
    static let themFileName = "them.wav"

    /// Called on the main thread with the latest mic / system levels (0...1).
    var onLevels: ((Float, Float) -> Void)?

    struct Result {
        let duration: TimeInterval
        /// False when the system audio was silent the whole time, which is
        /// what Core Audio delivers if System Audio Recording was declined.
        let heardSystemAudio: Bool
        /// False when the mic was silent the whole time (permission revoked,
        /// muted or wrong input device).
        let heardMicAudio: Bool
    }

    private let micEngine = AVAudioEngine()
    private let micQueue = DispatchQueue(label: "com.maxheadley.budgie.meeting-mic", qos: .userInitiated)
    private var systemRecorder: AnyObject?
    private var meWriter: MeetingStreamWriter?
    private var themWriter: MeetingStreamWriter?
    private var startHostTime: UInt64 = 0
    private var levels: (me: Float, them: Float) = (0, 0)
    private var levelTimer: Timer?
    private let levelLock = NSLock()

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func start(in folder: URL) throws {
        guard #available(macOS 14.2, *) else {
            throw SystemAudioError.coreAudio("record system audio before macOS 14.2", kAudioHardwareUnsupportedOperationError)
        }
        startHostTime = mach_absolute_time()
        let me = MeetingStreamWriter(
            writer: try PCMFileWriter(url: folder.appendingPathComponent(Self.meFileName)),
            startHostTime: startHostTime
        )
        let them = MeetingStreamWriter(
            writer: try PCMFileWriter(url: folder.appendingPathComponent(Self.themFileName)),
            startHostTime: startHostTime
        )
        meWriter = me
        themWriter = them

        let system = SystemAudioRecorder()
        system.onBuffer = { [weak self] buffer, hostTime in
            them.append(buffer, hostTime: hostTime)
            self?.setLevel(them: AudioLevel.normalized(buffer))
        }
        do {
            try system.start()
            systemRecorder = system
            try startMic(writer: me)
        } catch {
            system.stop()
            systemRecorder = nil
            micEngine.inputNode.removeTap(onBus: 0)
            micEngine.stop()
            meWriter = nil
            themWriter = nil
            throw error
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = self.takeLevels()
            self.onLevels?(current.me, current.them)
        }
    }

    /// Stops both streams and closes the files.
    func stop() -> Result {
        levelTimer?.invalidate()
        levelTimer = nil
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        micQueue.sync {}
        if #available(macOS 14.2, *), let system = systemRecorder as? SystemAudioRecorder {
            system.stop()
            system.queue.sync {}
        }
        systemRecorder = nil

        let duration = Double(mach_absolute_time() - startHostTime) * Self.hostTicksToSeconds
        // Pad the shorter file so both cover the whole meeting.
        meWriter?.finish(padTo: duration)
        themWriter?.finish(padTo: duration)
        let result = Result(
            duration: duration,
            heardSystemAudio: themWriter?.heardSound ?? false,
            heardMicAudio: meWriter?.heardSound ?? false
        )
        meWriter = nil
        themWriter = nil
        onLevels?(0, 0)
        return result
    }

    private func startMic(writer: MeetingStreamWriter) throws {
        let input = micEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw SystemAudioError.coreAudio("open the microphone", kAudioHardwareNotRunningError)
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, when in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            self.setLevel(me: AudioLevel.normalized(buffer))
            self.micQueue.async { writer.append(copy, hostTime: hostTime) }
        }
        micEngine.prepare()
        try micEngine.start()
    }

    private func setLevel(me: Float? = nil, them: Float? = nil) {
        levelLock.lock()
        if let me { levels.me = max(levels.me, me) }
        if let them { levels.them = max(levels.them, them) }
        levelLock.unlock()
    }

    /// Peak levels since the last read, so the meters don't miss short sounds.
    private func takeLevels() -> (me: Float, them: Float) {
        levelLock.lock()
        defer { levels = (0, 0); levelLock.unlock() }
        return levels
    }

    static let hostTicksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
}

/// One stream of a meeting: aligns its first buffer to the meeting start, then
/// appends everything. Called from a single queue per stream.
private final class MeetingStreamWriter {
    private let writer: PCMFileWriter
    private let startHostTime: UInt64
    private var started = false
    private(set) var heardSound = false

    init(writer: PCMFileWriter, startHostTime: UInt64) {
        self.writer = writer
        self.startHostTime = startHostTime
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        do {
            if !started {
                started = true
                if hostTime > startHostTime {
                    let lead = Double(hostTime - startHostTime) * MeetingRecorder.hostTicksToSeconds
                    try writer.appendSilence(seconds: lead)
                }
            }
            if !heardSound, AudioLevel.normalized(buffer) > 0 { heardSound = true }
            try writer.append(buffer)
        } catch {
            NSLog("Budgie: meeting audio write failed for \(writer.url.lastPathComponent): \(error)")
        }
    }

    func finish(padTo duration: TimeInterval) {
        let missing = duration - writer.secondsWritten
        if missing > 0.05 { try? writer.appendSilence(seconds: missing) }
        writer.finish()
    }
}
