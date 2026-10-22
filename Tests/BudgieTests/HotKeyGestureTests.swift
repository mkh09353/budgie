import XCTest
@testable import Budgie

final class HotKeyGestureTests: XCTestCase {
    private func makeGesture() -> HotKeyGesture {
        var gesture = HotKeyGesture()
        gesture.tapMax = 0.2
        gesture.doubleTapWindow = 0.3
        return gesture
    }

    func testHoldDictatesOnceThePressOutlastsATap() {
        var g = makeGesture()
        XCTAssertEqual(g.press(at: 0), [.beginDictation])
        XCTAssertEqual(g.deadline, 0.2)
        XCTAssertEqual(g.timerFired(at: 0.2), [.confirmDictation])
        XCTAssertEqual(g.release(at: 1.5), [.finishDictation])
        XCTAssertEqual(g.phase, .idle)
    }

    func testReleaseJustAfterTheTapLimitStillCountsAsAHold() {
        var g = makeGesture()
        _ = g.press(at: 0)
        // Timer hasn't run yet, but the press was long enough.
        XCTAssertEqual(g.release(at: 0.25), [.confirmDictation, .finishDictation])
    }

    func testDoubleTapSavesWithoutANote() {
        var g = makeGesture()
        _ = g.press(at: 0)
        XCTAssertEqual(g.release(at: 0.08), [.pauseDictation])
        XCTAssertEqual(g.press(at: 0.2), [.discardDictation, .beginSave])
        XCTAssertEqual(g.release(at: 0.29), [.commitSave])
        XCTAssertEqual(g.phase, .idle)
    }

    func testTapThenHoldSavesWithANote() {
        var g = makeGesture()
        _ = g.press(at: 0)
        _ = g.release(at: 0.08)
        _ = g.press(at: 0.2)
        XCTAssertEqual(g.timerFired(at: 0.4), [.beginNote])
        XCTAssertEqual(g.phase, .noting)
        XCTAssertEqual(g.release(at: 3), [.finishNote])
    }

    func testASingleTapStillDeliversItsDictation() {
        var g = makeGesture()
        _ = g.press(at: 0)
        _ = g.release(at: 0.15)
        XCTAssertEqual(g.deadline ?? 0, 0.45, accuracy: 1e-9)
        XCTAssertEqual(g.timerFired(at: 0.45), [.finishPausedDictation])
        XCTAssertEqual(g.phase, .idle)
    }

    func testCommandChordIsNeverDictationOrASave() {
        var g = makeGesture()
        // Right-⌘C …
        _ = g.press(at: 0)
        XCTAssertEqual(g.otherKey(8, at: 0.05), [.discardDictation])
        XCTAssertEqual(g.release(at: 0.1), [])
        // … then right-⌘V straight after must not read as the second tap.
        XCTAssertEqual(g.press(at: 0.2), [.beginDictation])
        XCTAssertEqual(g.otherKey(9, at: 0.25), [.discardDictation])
        XCTAssertEqual(g.release(at: 0.3), [])
        XCTAssertEqual(g.phase, .idle)
    }

    func testChordOnTheSecondPressCancelsTheSave() {
        var g = makeGesture()
        _ = g.press(at: 0)
        _ = g.release(at: 0.08)
        _ = g.press(at: 0.2)
        XCTAssertEqual(g.otherKey(9, at: 0.25), [.cancelSave])
        XCTAssertEqual(g.release(at: 0.3), [])
    }

    func testTypingBetweenTapsEndsTheWait() {
        var g = makeGesture()
        _ = g.press(at: 0)
        _ = g.release(at: 0.08)
        XCTAssertEqual(g.otherKey(4, at: 0.1), [.finishPausedDictation])
        XCTAssertEqual(g.phase, .idle)
    }

    func testEscapeCancelsANoteButOtherKeysDoNot() {
        var g = makeGesture()
        _ = g.press(at: 0)
        _ = g.release(at: 0.08)
        _ = g.press(at: 0.2)
        _ = g.timerFired(at: 0.4)
        XCTAssertEqual(g.otherKey(4, at: 0.5), [])
        XCTAssertEqual(g.otherKey(HotKeyGesture.escapeKeyCode, at: 0.6), [.cancelSave])
        XCTAssertEqual(g.release(at: 1), [])
    }

    func testEarlyTimerIsIgnored() {
        var g = makeGesture()
        _ = g.press(at: 0)
        XCTAssertEqual(g.timerFired(at: 0.1), [])
        XCTAssertEqual(g.phase, .firstDown(at: 0))
    }

    func testDisablingSavesMakesTheKeyPlainPushToTalk() {
        var g = makeGesture()
        g.savingEnabled = false
        XCTAssertEqual(g.press(at: 0), [.beginDictation, .confirmDictation])
        XCTAssertNil(g.deadline)
        XCTAssertEqual(g.release(at: 0.05), [.finishDictation])
        XCTAssertEqual(g.press(at: 0.1), [.beginDictation, .confirmDictation])
    }
}

extension HotKeyGestureTests {
    func testPressAfterTheWindowLapsedIsAFreshPress() {
        var g = HotKeyGesture()
        g.tapMax = 0.2
        g.doubleTapWindow = 0.3
        _ = g.press(at: 0)
        _ = g.release(at: 0.1)
        // The timer was late (busy main thread); the press comes 0.5 s after the tap.
        XCTAssertEqual(g.press(at: 0.6), [.finishPausedDictation, .beginDictation])
        XCTAssertEqual(g.phase, .firstDown(at: 0.6))
    }

    func testClickDuringAPressIsAChord() {
        var g = HotKeyGesture()
        _ = g.press(at: 0)
        XCTAssertEqual(g.otherKey(-1, at: 0.05), [.discardDictation])
    }
}
