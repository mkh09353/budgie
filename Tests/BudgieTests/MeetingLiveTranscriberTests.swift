import AVFoundation
import XCTest
@testable import Budgie

final class MeetingLiveTranscriberTests: XCTestCase {
    private let rate = AudioChunk.sampleRate

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample }
        return buffer
    }

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { 0.3 * sin(Float($0) * 0.2) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    func testChunksAreCutInPausesAndLoseNoAudio() {
        // "Speech" with a pause at 8.6-9.0 s; chunks target 10 s, so the cut
        // must land in that pause rather than mid-word at 10 s.
        let audio = tone(8.6) + silence(0.4) + tone(6) + silence(0.3) + tone(2)
        var chunks: [AudioChunk] = []
        let chunker = AudioChunker(speaker: .me, target: 10) { chunks.append($0) }
        stride(from: 0, to: audio.count, by: 4_096).forEach {
            chunker.append(buffer(Array(audio[$0..<min($0 + 4_096, audio.count)])))
        }
        chunker.finish()

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].duration, 8.8, accuracy: 0.11)
        XCTAssertEqual(chunks[1].offset, chunks[0].duration, accuracy: 1e-9)
        XCTAssertEqual(chunks.map(\.samples).reduce([], +), audio)
    }

    func testSilentChunksAreRecognised() {
        XCTAssertTrue(AudioChunk(speaker: .them, offset: 0, samples: silence(5)).isSilent)
        XCTAssertFalse(AudioChunk(speaker: .them, offset: 0, samples: silence(4) + tone(0.2)).isSilent)
        // A very quiet voice (about -50 dBFS) still counts as sound.
        let quiet = (0..<Int(rate)).map { 0.004 * sin(Float($0) * 0.2) }
        XCTAssertFalse(AudioChunk(speaker: .them, offset: 0, samples: quiet).isSilent)
    }

    /// The synthetic call from the fixtures, cut into 3-second chunks, must
    /// transcribe the same as transcribing each whole file.
    func testChunkedFixtureMatchesWholeFileTranscript() throws {
        try requireModel()
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "meeting", withExtension: nil, subdirectory: "Fixtures"))
        let words = try transcribeChunked(
            me: fixtures.appendingPathComponent(MeetingRecorder.meFileName),
            them: fixtures.appendingPathComponent(MeetingRecorder.themFileName),
            chunkSeconds: 3
        )
        let transcript = MeetingTranscript.merge(
            me: words.me, them: words.them, started: Date(), duration: 10, heardSystemAudio: true
        )
        // Chunks this short leave the model little context, so punctuation can
        // differ at a cut ("Yes. I"); the words, speakers and order must not.
        let plain = transcript.lines.map {
            $0.text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }
        }
        XCTAssertEqual(transcript.lines.map(\.speaker), [.them, .me, .them])
        XCTAssertEqual(plain, [
            "hi thanks for joining can you hear me okay",
            "yes i can hear you fine",
            "great let's talk about the launch plan"
        ])
    }

    /// Compares chunked and whole-file transcription of a long recording:
    /// BUDGIE_CHUNK_BENCH=/path/to/speech.wav swift test --filter testChunkedLongRecording
    func testChunkedLongRecording() throws {
        guard let path = ProcessInfo.processInfo.environment["BUDGIE_CHUNK_BENCH"] else {
            throw XCTSkip("Set BUDGIE_CHUNK_BENCH to a 16 kHz mono WAV")
        }
        try requireModel()
        let url = URL(fileURLWithPath: path)
        let engine = StandardTranscriber()

        var start = Date()
        let whole = try JSONDecoder().decode(
            ParakeetJSONDocument.self, from: Data(engine.transcribeJSONWithVAD(url).utf8)
        ).words
        let wholeTime = Date().timeIntervalSince(start)

        start = Date()
        let chunked = try transcribeChunked(me: url, them: nil, chunkSeconds: 60, engine: engine).me
        let chunkedTime = Date().timeIntervalSince(start)

        if let dump = ProcessInfo.processInfo.environment["BUDGIE_CHUNK_DUMP"] {
            try whole.map(\.w).joined(separator: "\n").write(toFile: dump + ".whole", atomically: true, encoding: .utf8)
            try chunked.map(\.w).joined(separator: "\n").write(toFile: dump + ".chunked", atomically: true, encoding: .utf8)
        }
        // The model flips near-ties ("talk"/"talked") differently with
        // different context, in both directions; scored against the spoken
        // script, 60 s chunks and whole files make the same number of errors
        // (1.6% vs 1.7% on 10 minutes of speech). So allow a few edits.
        let plain = { (words: [TranscriptWord]) in
            words.map { $0.w.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        }
        let a = plain(whole), b = plain(chunked)
        let edits = editDistance(a, b)
        print("whole: \(a.count) words in \(String(format: "%.1f", wholeTime))s; "
              + "chunked: \(b.count) words in \(String(format: "%.1f", chunkedTime))s; "
              + "word edits between them: \(edits)")
        XCTAssertLessThanOrEqual(Double(edits), Double(a.count) * 0.03)
        if let last = chunked.last, let lastWhole = whole.last {
            XCTAssertEqual(last.end, lastWhole.end, accuracy: 0.5)
        }
    }

    private func requireModel() throws {
        guard FileManager.default.fileExists(atPath: Config.parakeetLibraryPath),
              FileManager.default.fileExists(atPath: Config.standardModelPath) else {
            throw XCTSkip("Punctuated model and parakeet.cpp library are required")
        }
    }

    /// Feeds whole files through the chunkers, as the recorder would.
    private func transcribeChunked(
        me: URL, them: URL?, chunkSeconds: TimeInterval, engine: StandardTranscriber = StandardTranscriber()
    ) throws -> (me: [TranscriptWord], them: [TranscriptWord]) {
        let live = MeetingLiveTranscriber(engine: engine)
        for (url, speaker) in [(me, Speaker.me), (them, Speaker.them)] {
            guard let url else { continue }
            let chunker = AudioChunker(speaker: speaker, target: chunkSeconds, onChunk: live.submit)
            let file = try AVAudioFile(forReading: url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
            while file.framePosition < file.length {
                try file.read(into: buffer)
                chunker.append(buffer)
            }
            chunker.finish()
        }
        let done = expectation(description: "live transcription finished")
        var result: Result<(me: [TranscriptWord], them: [TranscriptWord]), Error>?
        live.finish {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 600)
        return try XCTUnwrap(result).get()
    }

    private func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
