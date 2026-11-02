import XCTest
@testable import Budgie

final class LogTests: XCTestCase {
    private var directory: URL!
    private var originalDirectory: URL!
    private var wasVerbose = false

    override func setUpWithError() throws {
        originalDirectory = Log.directoryURL
        wasVerbose = Log.verbose
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BudgieLogTests-\(UUID().uuidString)", isDirectory: true)
        Log.redirect(to: directory)
    }

    override func tearDownWithError() throws {
        Log.redirect(to: originalDirectory)
        Log.verbose = wasVerbose
        try? FileManager.default.removeItem(at: directory)
    }

    private func logText() throws -> String {
        Log.flush()
        return try String(contentsOf: directory.appendingPathComponent("budgie.log"))
    }

    func testWarningsAlwaysReachTheFileWithLevelCategoryAndThread() throws {
        Log.verbose = false
        Log.warning(.dictation, "mic slow")
        let text = try logText()
        XCTAssertTrue(text.contains("WARN [main] dictation: mic slow"), text)
    }

    func testDebugLinesNeedDiagnosticLogging() throws {
        guard !Log.forcedByEnvironment else { throw XCTSkip("BUDGIE_DEBUG_LOG forces logging on") }
        Log.verbose = false
        Log.debug(.audio, "hidden step")
        Log.verbose = true
        Log.debug(.audio, "shown step")
        let text = try logText()
        XCTAssertFalse(text.contains("hidden step"))
        XCTAssertTrue(text.contains("DEBUG [main] audio: shown step"), text)
    }

    func testBackgroundQueueLinesNameTheirQueue() throws {
        let queue = DispatchQueue(label: "com.maxheadley.budgie.streaming")
        let logged = expectation(description: "logged")
        queue.async {
            Log.info(.engine, "model loaded")
            logged.fulfill()
        }
        wait(for: [logged], timeout: 2)
        // Run synchronously from the main thread, the work blocks main.
        queue.sync { Log.info(.engine, "session ready") }
        let text = try logText()
        XCTAssertTrue(text.contains("INFO [streaming] engine: model loaded"), text)
        XCTAssertTrue(text.contains("INFO [main/streaming] engine: session ready"), text)
    }

    func testFastStartIsNotSlow() {
        var trace = DictationStartTrace(pressed: 100, handled: 100.004, engineWarm: true)
        trace.micReady = 100.06
        trace.firstAudio = 100.15
        trace.firstText = 100.9
        XCTAssertFalse(trace.isSlow)
        XCTAssertEqual(
            trace.summary,
            "press handled after 4 ms, mic ready 60 ms, first audio 150 ms, first text 900 ms, engine warm"
        )
    }

    func testSlowMicOpenIsSlowAndSaysWhere() {
        var trace = DictationStartTrace(pressed: 100, handled: 100.01, engineWarm: false)
        trace.micReady = 101.9
        trace.mic = MicStartTiming(inputNode: 0.02, installTap: 0.01, engineStart: 1.85,
                                   device: "AirPods Pro (Bluetooth)", sampleRate: 24_000)
        XCTAssertTrue(trace.isSlow)
        XCTAssertTrue(trace.summary.contains("first audio never"))
        XCTAssertTrue(trace.summary.contains("engine COLD"))
        XCTAssertTrue(trace.summary.contains("mic AirPods Pro (Bluetooth) @ 24000 Hz"))
        XCTAssertTrue(trace.summary.contains("engine.start 1850 ms"))
    }
}
