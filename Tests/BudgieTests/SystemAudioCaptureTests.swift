import AVFoundation
import XCTest
@testable import Budgie

/// Records real system audio, so it needs the host's "System Audio Recording"
/// permission and plays a sound: opt in with BUDGIE_SYSTEM_AUDIO_TEST=1.
final class SystemAudioCaptureTests: XCTestCase {
    func testTapCapturesAnotherProcessPlayingAudio() throws {
        guard ProcessInfo.processInfo.environment["BUDGIE_SYSTEM_AUDIO_TEST"] == "1" else {
            throw XCTSkip("Set BUDGIE_SYSTEM_AUDIO_TEST=1 to record system audio")
        }
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps need macOS 14.2") }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budgie-tap-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PCMFileWriter(url: url)
        let recorder = SystemAudioRecorder()
        var peak: Float = 0
        recorder.onBuffer = { buffer, _ in
            peak = max(peak, AudioLevel.normalized(buffer))
            try? writer.append(buffer)
        }
        try recorder.start()

        // Play from another process: the tap excludes Budgie's own audio.
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try player.run()
        player.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)

        recorder.stop()
        recorder.queue.sync {}
        writer.finish()

        XCTAssertGreaterThan(writer.secondsWritten, 0.5, "the tap delivered no audio")
        XCTAssertGreaterThan(peak, 0.2, "the tap delivered only silence; is System Audio Recording allowed?")
    }

    /// A whole meeting through the real devices: another process speaks
    /// through the speakers, so "Them" hears it directly and the mic hears it
    /// as echo, which must not come back as "Me". Transcribed live in 5 s
    /// chunks, so the second sentence lands in a later chunk than the first.
    func testRecordsAndTranscribesALiveMeeting() throws {
        guard ProcessInfo.processInfo.environment["BUDGIE_SYSTEM_AUDIO_TEST"] == "1" else {
            throw XCTSkip("Set BUDGIE_SYSTEM_AUDIO_TEST=1 to record a live meeting")
        }
        guard FileManager.default.fileExists(atPath: Config.standardModelPath) else {
            throw XCTSkip("Punctuated model and parakeet.cpp library are required")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budgie-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try MeetingLibrary.createFolder(in: root, started: Date())
        let recorder = MeetingRecorder()
        recorder.chunkSeconds = 5
        let live = MeetingLiveTranscriber(engine: StandardTranscriber())
        try recorder.start(in: folder, transcriber: live)

        for (index, sentence) in ["The quarterly budget review moves to Thursday afternoon.",
                                  "Please bring the hiring numbers."].enumerated() {
            if index > 0 { RunLoop.current.run(until: Date().addingTimeInterval(2)) }
            let speaker = Process()
            speaker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            speaker.arguments = [sentence]
            try speaker.run()
            speaker.waitUntilExit()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let result = recorder.stop()
        let stopped = Date()
        var info = try MeetingLibrary.readInfo(from: folder)
        info.duration = result.duration
        info.heardSystemAudio = result.heardSystemAudio
        info.heardMicAudio = result.heardMicAudio
        try MeetingLibrary.writeInfo(info, to: folder)
        XCTAssertTrue(result.heardSystemAudio)

        let done = expectation(description: "live transcription finished")
        var words: Result<(me: [TranscriptWord], them: [TranscriptWord]), Error>?
        live.finish {
            words = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        let finished = try XCTUnwrap(words).get()
        let transcript = try MeetingLibrary.save(folder: folder, me: finished.me, them: finished.them)
        print(transcript.markdown())
        print(String(format: "transcript ready %.2fs after stop", Date().timeIntervalSince(stopped)))
        if let keep = ProcessInfo.processInfo.environment["BUDGIE_KEEP_MEETING"] {
            try? FileManager.default.copyItem(at: folder, to: URL(fileURLWithPath: keep))
        }
        let theirs = transcript.lines.filter { $0.speaker == .them }.map(\.text).joined(separator: " ")
        XCTAssertTrue(theirs.lowercased().contains("budget review"), "Them: \(theirs)")
        XCTAssertTrue(theirs.lowercased().contains("hiring numbers"), "Them: \(theirs)")
        // The echo check means something only if the mic heard the speakers:
        // a test host without microphone permission records silence.
        guard result.heardMicAudio else {
            print("note: the mic recorded silence (no permission for this host, or headphones); echo check skipped")
            return
        }
        let mine = transcript.lines.filter { $0.speaker == .me }.map(\.text).joined(separator: " ")
        XCTAssertFalse(mine.lowercased().contains("budget review"), "echo leaked into Me: \(mine)")
    }
}
