import Foundation

/// Turns raw press / release / other-key events on the dictation key into the
/// three gestures Budgie understands:
///
///   hold          → dictate into the focused app (unchanged from before)
///   tap · tap     → save the current selection
///   tap · hold    → save the selection and dictate a "why" note onto it
///
/// The first press always starts the microphone so dictation stays instant;
/// typing is held back until the press outlasts `tapMax`, which is the only
/// moment a hold can be told apart from a tap. Pure value type with injected
/// timestamps so the timing rules are unit-testable — the owner schedules a
/// timer for `deadline` and calls `timerFired(at:)` when it elapses.
struct HotKeyGesture {
    enum Action: Equatable {
        /// First press: start recording, but don't type anything yet.
        case beginDictation
        /// The press is a hold: let the live transcript reach the app.
        case confirmDictation
        /// Release after a hold: finish and deliver the dictation.
        case finishDictation
        /// A tap: stop recording, keep the take until we know if a second tap follows.
        case pauseDictation
        /// No second tap came: deliver the paused take as an ordinary dictation.
        case finishPausedDictation
        /// Throw away the in-flight or paused take (a ⌘-chord, or the start of a save).
        case discardDictation
        /// Second press: snapshot the selection and start recording a possible note.
        case beginSave
        /// Second press released quickly: commit the save, no note.
        case commitSave
        /// Second press held: commit the save and show the live note.
        case beginNote
        /// Release while noting: finish the note and attach it.
        case finishNote
        /// Abandon the save (a chord on the second press, or Esc mid-note).
        case cancelSave
    }

    enum Phase: Equatable {
        case idle
        /// First press, not yet known to be a hold.
        case firstDown(at: TimeInterval)
        case dictating
        /// Released after a quick tap; waiting for a second press.
        case tapped(at: TimeInterval)
        /// Second press, not yet known to be a hold.
        case secondDown(at: TimeInterval)
        case noting
        /// Another key joined the press: ignore everything until release.
        case chord
    }

    /// A press shorter than this is a tap.
    var tapMax: TimeInterval = Config.gestureTapMaxSeconds
    /// How long after a tap a second press still counts as a double tap.
    var doubleTapWindow: TimeInterval = Config.gestureDoubleTapWindowSeconds
    /// With saving turned off the key is plain push-to-talk again.
    var savingEnabled = true

    private(set) var phase: Phase = .idle

    /// When the owner should call `timerFired(at:)`, if anything is pending.
    var deadline: TimeInterval? {
        switch phase {
        case .firstDown(let at):  return at + tapMax
        case .tapped(let at):     return at + doubleTapWindow
        case .secondDown(let at): return at + tapMax
        case .idle, .dictating, .noting, .chord: return nil
        }
    }

    /// Whether the key should physically be down while a deadline is pending.
    /// If the hardware disagrees when the timer fires, a key event is still
    /// queued behind a busy main thread and should be handled first.
    var expectsKeyDown: Bool? {
        switch phase {
        case .firstDown, .secondDown: return true
        case .tapped:                 return false
        case .idle, .dictating, .noting, .chord: return nil
        }
    }

    static let escapeKeyCode: Int64 = 53

    mutating func press(at time: TimeInterval) -> [Action] {
        switch phase {
        case .idle:
            if !savingEnabled {
                phase = .dictating
                return [.beginDictation, .confirmDictation]
            }
            phase = .firstDown(at: time)
            return [.beginDictation]
        case .tapped(let at):
            guard time - at <= doubleTapWindow else {
                // The window lapsed while the main thread was busy: deliver the
                // tap's take and treat this as a brand new press.
                phase = savingEnabled ? .firstDown(at: time) : .dictating
                return [.finishPausedDictation, .beginDictation]
            }
            phase = .secondDown(at: time)
            return [.discardDictation, .beginSave]
        case .firstDown, .dictating, .secondDown, .noting, .chord:
            // A press while already down means we missed a release; resync.
            return []
        }
    }

    mutating func release(at time: TimeInterval) -> [Action] {
        switch phase {
        case .firstDown(let at):
            if time - at < tapMax {
                phase = .tapped(at: time)
                return [.pauseDictation]
            }
            // The hold timer hasn't fired yet, but this was a hold.
            phase = .idle
            return [.confirmDictation, .finishDictation]
        case .dictating:
            phase = .idle
            return [.finishDictation]
        case .secondDown:
            // However long the press, the note timer hadn't fired: no note.
            phase = .idle
            return [.commitSave]
        case .noting:
            phase = .idle
            return [.finishNote]
        case .chord:
            phase = .idle
            return []
        case .idle, .tapped:
            return []
        }
    }

    /// Any non-hotkey key press. Escape cancels a note; other keys turn an
    /// undecided press into a chord (e.g. right-⌘C) so it never counts.
    mutating func otherKey(_ keyCode: Int64, at time: TimeInterval) -> [Action] {
        switch phase {
        case .firstDown:
            phase = .chord
            return [.discardDictation]
        case .tapped:
            phase = .idle
            return [.finishPausedDictation]
        case .secondDown:
            phase = .chord
            return [.cancelSave]
        case .noting:
            guard keyCode == Self.escapeKeyCode else { return [] }
            phase = .chord
            return [.cancelSave]
        case .idle, .dictating, .chord:
            return []
        }
    }

    mutating func timerFired(at time: TimeInterval) -> [Action] {
        guard let deadline, time >= deadline else { return [] }
        switch phase {
        case .firstDown:
            phase = .dictating
            return [.confirmDictation]
        case .tapped:
            phase = .idle
            return [.finishPausedDictation]
        case .secondDown:
            phase = .noting
            return [.beginNote]
        case .idle, .dictating, .noting, .chord:
            return []
        }
    }

    /// Forget everything (e.g. the hotkey changed mid-gesture).
    mutating func reset() {
        phase = .idle
    }
}
