import XCTest
@testable import Budgie

final class MeetingTranscriptTests: XCTestCase {
    private func word(_ w: String, _ start: Double, _ end: Double? = nil) -> TranscriptWord {
        TranscriptWord(w: w, start: start, end: end ?? start + 0.3)
    }

    func testPausesSplitLines() {
        let words = [word("Hello", 0), word("there.", 0.4), word("Next", 3), word("topic.", 3.4)]
        let lines = MeetingTranscript.lines(from: words, speaker: .me)
        XCTAssertEqual(lines.map(\.text), ["Hello there.", "Next topic."])
        XCTAssertEqual(lines.first?.start, 0)
        XCTAssertEqual(lines.last?.start, 3)
    }

    func testEchoRunIsRemovedButReplyIsKept() {
        // The mic hears "can you hear me" from the call, then the user replies.
        let them = [word("Can", 1.0), word("you", 1.3), word("hear", 1.6), word("me?", 1.9)]
        let me = [word("can", 1.1), word("you", 1.4), word("hear", 1.7), word("me", 2.0),
                  word("Yes,", 2.8), word("I", 3.1), word("can.", 3.3)]
        let kept = MeetingTranscript.removingEcho(from: me, heardIn: them)
        XCTAssertEqual(kept.map(\.w), ["Yes,", "I", "can."])
    }

    func testLoneMatchingWordIsNotEcho() {
        let them = [word("Okay,", 5.0), word("so", 5.3), word("next", 5.6)]
        let me = [word("okay.", 5.2)]
        XCTAssertEqual(MeetingTranscript.removingEcho(from: me, heardIn: them).map(\.w), ["okay."])
    }

    func testSameWordsAtDifferentTimesAreNotEcho() {
        let them = [word("the", 1), word("launch", 1.3), word("plan", 1.6)]
        let me = [word("the", 20), word("launch", 20.3), word("plan", 20.6)]
        XCTAssertEqual(MeetingTranscript.removingEcho(from: me, heardIn: them).count, 3)
    }

    func testMergeOrdersBothChannelsByTime() {
        let transcript = MeetingTranscript.merge(
            me: [word("Fine,", 4), word("thanks.", 4.3)],
            them: [word("How", 1), word("are", 1.3), word("you?", 1.6), word("Great.", 8)],
            started: Date(timeIntervalSince1970: 0), duration: 10, heardSystemAudio: true
        )
        XCTAssertEqual(transcript.lines.map(\.speaker), [.them, .me, .them])
        XCTAssertEqual(transcript.lines.map(\.text), ["How are you?", "Fine, thanks.", "Great."])
    }

    func testTimestamps() {
        XCTAssertEqual(MeetingTranscript.timestamp(5), "0:05")
        XCTAssertEqual(MeetingTranscript.timestamp(605), "10:05")
        XCTAssertEqual(MeetingTranscript.timestamp(3_729), "1:02:09")
    }

    func testMarkdownWarnsWhenSystemAudioWasSilent() {
        let transcript = MeetingTranscript(
            started: Date(), duration: 60, heardSystemAudio: false, heardMicAudio: true,
            lines: [TranscriptLine(speaker: .me, start: 2, end: 3, text: "Hello?")]
        )
        let markdown = transcript.markdown()
        XCTAssertTrue(markdown.contains("No system audio was captured"))
        XCTAssertTrue(markdown.contains("**[0:02] Me:** Hello?"))
    }

    /// Runs the real pipeline: redux through parakeet.cpp on a synthetic call
    /// whose mic track also carries a quiet echo of the other side.
    func testTranscribesRecordedMeetingFolder() throws {
        guard FileManager.default.fileExists(atPath: Config.parakeetLibraryPath),
              FileManager.default.fileExists(atPath: Config.standardModelPath) else {
            throw XCTSkip("Punctuated model and parakeet.cpp library are required")
        }
        let fixtures = try XCTUnwrap(Bundle.module.url(
            forResource: "meeting", withExtension: nil, subdirectory: "Fixtures"
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budgie-meetings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try MeetingLibrary.createFolder(in: root, started: started)
        for name in [MeetingRecorder.meFileName, MeetingRecorder.themFileName] {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name), to: folder.appendingPathComponent(name)
            )
        }

        var stages: [MeetingStage] = []
        let transcript = try MeetingLibrary.transcribe(folder: folder, engine: StandardTranscriber()) {
            stages.append($0)
        }

        XCTAssertEqual(stages.suffix(3), [.transcribingMe, .transcribingThem, .saving])
        XCTAssertEqual(transcript.lines.map(\.speaker), [.them, .me, .them])
        XCTAssertEqual(transcript.lines.map(\.text), [
            "Hi, thanks for joining. Can you hear me okay?",
            "Yes, I can hear you fine.",
            "Great, let's talk about the launch plan."
        ])
        let markdown = try String(contentsOf: folder.appendingPathComponent(MeetingLibrary.transcriptFileName))
        XCTAssertTrue(markdown.contains("**[0:04] Me:** Yes, I can hear you fine."))

        let listed = MeetingLibrary.list(in: root)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.preview, "Hi, thanks for joining. Can you hear me okay?")
        XCTAssertEqual(listed.first?.hasTranscript, true)
    }
}
