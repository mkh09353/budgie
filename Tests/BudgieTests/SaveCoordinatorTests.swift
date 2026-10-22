import XCTest
@testable import Budgie

final class SaveCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var store: SaveStore!
    private var coordinator: SaveCoordinator!
    /// Captures waiting to be answered, in the order they were requested.
    private var pendingCaptures: [(CapturedSelection) -> Void] = []
    private var savedPlaySounds = true

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BudgieSaveCoordinatorTests-\(UUID().uuidString)")
        store = SaveStore(url: directory.appendingPathComponent("s.sqlite"))
        savedPlaySounds = UserPrefs.shared.playSounds
        UserPrefs.shared.playSounds = false
        coordinator = SaveCoordinator(store: store, prefs: .shared)
        // Pretend the panel is open so no toast or HUD windows appear.
        coordinator.isPanelVisible = { true }
        coordinator.captureSelection = { [unowned self] _, completion in
            self.pendingCaptures.append(completion)
        }
    }

    override func tearDownWithError() throws {
        UserPrefs.shared.playSounds = savedPlaySounds
        try? FileManager.default.removeItem(at: directory)
    }

    private func answerCapture(_ text: String?, app: String = "Safari") {
        let completion = pendingCaptures.removeFirst()
        completion(CapturedSelection(text: text, source: SaveSource(appName: app)))
    }

    func testCommitWaitsForTheCapture() {
        coordinator.beginSave()
        coordinator.commitSave()
        XCTAssertTrue(store.items.isEmpty)
        answerCapture("keep this")
        XCTAssertEqual(store.items.map(\.text), ["keep this"])
        XCTAssertEqual(store.items.first?.source.appName, "Safari")
    }

    func testCaptureBeforeCommitIsHeldUntilDecided() {
        coordinator.beginSave()
        answerCapture("keep this")
        XCTAssertTrue(store.items.isEmpty)
        coordinator.commitSave()
        XCTAssertEqual(store.items.map(\.text), ["keep this"])
    }

    func testNoteAttachesToItsSelection() {
        coordinator.beginSave()
        answerCapture("the selection")
        coordinator.beginNote(micRunning: true)
        // The card appears right away so the note can stream into it.
        XCTAssertEqual(store.items.map(\.text), ["the selection"])
        XCTAssertEqual(coordinator.liveNote?.itemID, store.items.first?.id)
        coordinator.updateLiveNote("because")
        XCTAssertEqual(coordinator.liveNote?.text, "because")

        let ticket = coordinator.endNoteRecording()
        coordinator.finishNote(ticket, text: "because it matters")
        XCTAssertEqual(store.items.first?.why, "because it matters")
        XCTAssertNil(coordinator.liveNote)
    }

    func testNoteFinishingBeforeTheCaptureStillLands() {
        coordinator.beginSave()
        coordinator.beginNote(micRunning: true)
        let ticket = coordinator.endNoteRecording()
        coordinator.finishNote(ticket, text: "why")
        XCTAssertTrue(store.items.isEmpty)
        answerCapture("late selection")
        XCTAssertEqual(store.items.map(\.text), ["late selection"])
        XCTAssertEqual(store.items.first?.why, "why")
    }

    func testCancelRemovesTheEarlyCard() {
        coordinator.beginSave()
        answerCapture("oops")
        coordinator.beginNote(micRunning: true)
        XCTAssertEqual(store.items.count, 1)
        coordinator.cancelSave()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(coordinator.liveNote)
    }

    func testCancelBeforeCaptureSavesNothing() {
        coordinator.beginSave()
        coordinator.cancelSave()
        answerCapture("never")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testSpokenNoteWithNothingSelectedBecomesTheSave() {
        coordinator.beginSave()
        answerCapture(nil)
        coordinator.beginNote(micRunning: true)
        coordinator.finishNote(coordinator.endNoteRecording(), text: "call the bank")
        XCTAssertEqual(store.items.map(\.text), ["call the bank"])
        XCTAssertEqual(store.items.first?.kind, .note)
    }

    func testWithoutAMicTheHoldIsAPlainSave() {
        coordinator.beginSave()
        answerCapture("selection")
        coordinator.beginNote(micRunning: false)
        XCTAssertNil(coordinator.liveNote)
        XCTAssertEqual(store.items.map(\.text), ["selection"])
        XCTAssertNil(coordinator.endNoteRecording())
    }

    func testANewSaveWhileANoteTranscribesKeepsNotesApart() {
        // Save A: tap·hold, released — its note is still transcribing.
        coordinator.beginSave()
        answerCapture("A")
        coordinator.beginNote(micRunning: true)
        let ticketA = coordinator.endNoteRecording()

        // Save B: tap·hold straight away.
        coordinator.beginSave()
        answerCapture("B")
        coordinator.beginNote(micRunning: true)
        let liveB = coordinator.liveNote

        // A's transcript lands on A, and B's live note is untouched.
        coordinator.finishNote(ticketA, text: "why A")
        XCTAssertEqual(coordinator.liveNote, liveB)
        coordinator.finishNote(coordinator.endNoteRecording(), text: "why B")

        let byText = Dictionary(uniqueKeysWithValues: store.items.map { ($0.text, $0.why) })
        XCTAssertEqual(byText["A"], "why A")
        XCTAssertEqual(byText["B"], "why B")
        XCTAssertNil(coordinator.liveNote)
    }
}
