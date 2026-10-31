import XCTest
@testable import Budgie

final class MeetingAudioCleanupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BudgieMeetingAudioTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A meeting folder with 100-byte WAVs and, optionally, a transcript.
    private func makeMeeting(started: Date, transcribed: Bool) throws -> URL {
        let folder = try MeetingLibrary.createFolder(in: root, started: started)
        for name in MeetingLibrary.audioFileNames {
            try Data(count: 100).write(to: folder.appendingPathComponent(name))
        }
        if transcribed {
            try Data("# Meeting".utf8).write(to: folder.appendingPathComponent(MeetingLibrary.transcriptFileName))
        }
        return folder
    }

    private func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func testDeleteAudioKeepsTranscriptAndInfo() throws {
        let folder = try makeMeeting(started: Date(), transcribed: true)

        XCTAssertEqual(MeetingLibrary.deleteAudio(in: folder), 200)
        XCTAssertFalse(exists(MeetingRecorder.meFileName, in: folder))
        XCTAssertFalse(exists(MeetingRecorder.themFileName, in: folder))
        XCTAssertTrue(exists(MeetingLibrary.transcriptFileName, in: folder))
        XCTAssertTrue(exists(MeetingLibrary.infoFileName, in: folder))
        XCTAssertEqual(MeetingLibrary.list(in: root).first?.hasTranscript, true)
        XCTAssertEqual(MeetingLibrary.deleteAudio(in: folder), 0)
    }

    func testOldAudioCleanupSkipsUntranscribedMeetings() throws {
        let done = try makeMeeting(started: Date(timeIntervalSince1970: 1_000), transcribed: true)
        let pending = try makeMeeting(started: Date(timeIntervalSince1970: 2_000), transcribed: false)

        XCTAssertEqual(MeetingLibrary.transcribedAudioSize(in: root), 200)
        XCTAssertEqual(MeetingLibrary.deleteTranscribedAudio(in: root), 200)
        XCTAssertFalse(exists(MeetingRecorder.meFileName, in: done))
        XCTAssertTrue(exists(MeetingRecorder.meFileName, in: pending))
        XCTAssertTrue(exists(MeetingRecorder.themFileName, in: pending))
        XCTAssertEqual(MeetingLibrary.transcribedAudioSize(in: root), 0)
    }

    func testMissingFolderHasNoAudio() {
        XCTAssertEqual(MeetingLibrary.transcribedAudioSize(in: root), 0)
        XCTAssertEqual(MeetingLibrary.deleteTranscribedAudio(in: root), 0)
    }
}
