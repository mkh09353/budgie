import XCTest
@testable import Budgie

final class StandardTranscriptionTests: XCTestCase {
    func testPunctuatedModelTranscribesWithPunctuation() throws {
        guard FileManager.default.fileExists(atPath: Config.parakeetLibraryPath),
              FileManager.default.fileExists(atPath: Config.standardModelPath) else {
            throw XCTSkip("Punctuated model and parakeet.cpp library are required")
        }
        let library = try ParakeetLibrary(path: Config.parakeetLibraryPath)
        let context = try ParakeetContext(library: library, modelPath: Config.standardModelPath)

        // Synthetic speech: "The first number is four. The second number is one."
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "numbers", withExtension: "wav", subdirectory: "Fixtures"
        ))
        let transcript = try context.transcribe(wavPath: url.path)
        XCTAssertEqual(
            transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            "The first number is four. The second number is one."
        )
    }
}
