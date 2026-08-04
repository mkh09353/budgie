import XCTest
@testable import Budgie

final class StreamingRuntimePolicyTests: XCTestCase {
    func testPendingAudioBudgetStaysUnderOneSecondAtCommonInputRates() {
        for sampleRate in [16_000.0, 24_000.0, 44_100.0, 48_000.0] {
            let limit = StreamingRuntimePolicy.pendingBufferLimit(
                sampleRate: sampleRate,
                frameCount: StreamingRuntimePolicy.audioTapBufferFrames
            )
            let bufferedSeconds = Double(
                2 * limit
                    * StreamingRuntimePolicy.audioTapBufferFrames
            ) / sampleRate

            XCTAssertLessThan(bufferedSeconds, 1.0)
        }
    }

    func testParakeetThreadLimitLeavesCoresAvailableForInteractiveWork() {
        XCTAssertEqual(StreamingRuntimePolicy.inferenceThreadCount, 4)
    }

    func testBundledParakeetAcceptsConfiguredThreadLimit() throws {
        guard FileManager.default.fileExists(atPath: Config.parakeetLibraryPath) else {
            throw XCTSkip("parakeet.cpp shared library is not available")
        }

        let library = try ParakeetLibrary(path: Config.parakeetLibraryPath)
        XCTAssertTrue(library.threadLimitApplied)
        XCTAssertEqual(library.configuredThreadCount, 4)
    }
}
