import AVFoundation
import XCTest
@testable import Budgie

final class StreamingSessionTests: XCTestCase {
    func testSpeechContinuesAcrossEndOfUtteranceWithoutReleasingKey() throws {
        guard FileManager.default.fileExists(atPath: Config.parakeetLibraryPath),
              FileManager.default.fileExists(atPath: Config.streamingModelPath) else {
            throw XCTSkip("Live model and parakeet.cpp library are required")
        }
        let library = try ParakeetLibrary(path: Config.parakeetLibraryPath)
        let context = try ParakeetContext(library: library, modelPath: Config.streamingModelPath)
        let session = try ParakeetStreamSession(context: context)
        defer { session.free() }

        // Synthetic speech: "The first number is four. The second number is one."
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "numbers", withExtension: "wav", subdirectory: "Fixtures"
        ))
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let speech = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        // Silence triggers EOU before the next phrase arrives in the same held-key session.
        let utterance = speech + Array(repeating: Float(0), count: 32_000)
        var transcript = ""
        for _ in 0..<3 {
            for start in stride(from: 0, to: utterance.count, by: 4_000) {
                transcript += try session.feed(utterance[start..<min(start + 4_000, utterance.count)])
            }
        }
        transcript += try session.finalize()
        let expected = Array(
            repeating: "the first number is four the second number is one", count: 3
        ).joined(separator: " ")
        XCTAssertEqual(transcript.trimmingCharacters(in: .whitespacesAndNewlines), expected)
    }
}
