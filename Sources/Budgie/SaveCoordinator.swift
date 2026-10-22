import AppKit
import Combine

/// Runs one save from the gesture to the database.
///
/// The selection is read the instant the second tap lands — before focus can
/// move — but only written once the gesture is decided: a quick release
/// commits it, a hold commits it and attaches a spoken note, and a chord or
/// Esc throws it away. The capture runs asynchronously, so each save tracks
/// both halves and finishes whenever the last one arrives.
final class SaveCoordinator: ObservableObject {
    /// The note being dictated right now, shown live in the panel or the HUD.
    struct LiveNote: Equatable {
        /// The saved row the note will attach to, once the selection is read.
        var itemID: String?
        var snippet: String?
        var source: SaveSource
        var text: String
        let startedAt: Date
    }

    @Published private(set) var liveNote: LiveNote?

    let store: SaveStore
    private let prefs: UserPrefs
    /// When the panel is open the new card itself is the feedback, so the
    /// toast and HUD stay out of the way.
    var isPanelVisible: () -> Bool = { false }
    /// While the panel has keyboard focus a synthetic ⌘C would copy from the
    /// panel itself, so capture relies on accessibility alone.
    var isPanelKey: () -> Bool = { false }

    /// Reads the selection; swapped out in tests.
    var captureSelection: (_ allowCopyFallback: Bool,
                           _ completion: @escaping (CapturedSelection) -> Void) -> Void = {
        SelectionCapture.capture(allowCopyFallback: $0, completion: $1)
    }

    /// The save the current gesture is building.
    private var current: SaveTicket?
    /// The save whose note `liveNote` is showing.
    private weak var liveNoteOwner: SaveTicket?
    private let toast = ToastController()
    private lazy var noteHUD = NoteHUDController(coordinator: self)
    /// Set by the app delegate so the HUD's level meter tracks the mic.
    weak var appState: AppState?

    init(store: SaveStore, prefs: UserPrefs) {
        self.store = store
        self.prefs = prefs
    }

    // MARK: - Gesture steps

    /// Second tap went down: read the selection now, decide later.
    func beginSave() {
        let save = SaveTicket()
        current = save
        captureSelection(!isPanelKey()) { [weak self] selection in
            save.capture = selection
            self?.advance(save)
        }
    }

    /// Second tap released quickly: keep the selection, no note.
    func commitSave() {
        guard let save = current else { return }
        current = nil
        save.decision = .commit
        advance(save)
    }

    /// Second tap held: keep the selection and start the live note. Without a
    /// running microphone (another transcription still busy) it's a plain save.
    func beginNote(micRunning: Bool) {
        guard micRunning else {
            commitSave()
            return
        }
        guard let save = current else { return }
        save.decision = .note
        save.note = .recording
        liveNote = LiveNote(itemID: save.itemID,
                            snippet: save.capture?.text,
                            source: save.capture?.source ?? .none,
                            text: "",
                            startedAt: Date())
        liveNoteOwner = save
        if !isPanelVisible() {
            toast.hide()
            noteHUD.show()
        }
        advance(save)
    }

    /// Live partial transcript of the note.
    func updateLiveNote(_ text: String) {
        guard liveNote != nil else { return }
        liveNote?.text = text
    }

    /// Key released while noting: the note now belongs to its transcription,
    /// so a new gesture can start a new save while it finishes.
    func endNoteRecording() -> SaveTicket? {
        defer { current = nil }
        return current
    }

    /// The note's final transcript (nil if nothing was heard).
    func finishNote(_ save: SaveTicket?, text: String?) {
        guard let save else { return }
        save.note = .finished(text)
        advance(save)
    }

    /// A chord on the second tap, or Esc while noting: forget the save.
    func cancelSave() {
        guard let save = current else { return }
        current = nil
        save.decision = .cancelled
        if let id = save.itemID { store.delete(ids: [id]) }
        endLiveNote(for: save)
    }

    // MARK: - Resolution

    private func advance(_ save: SaveTicket) {
        guard !save.resolved, let capture = save.capture else { return }
        let text = capture.text

        switch save.decision {
        case .undecided, .cancelled:
            return

        case .commit:
            save.resolved = true
            if let text {
                store.add(text: text, kind: .capture, source: capture.source)
                announceSaved(source: capture.source)
            } else {
                announceNothingSelected()
            }

        case .note:
            // Show the selection in the list right away; the note fills in after.
            if save.itemID == nil, let text {
                let item = store.add(text: text, kind: .capture, source: capture.source)
                save.itemID = item.id
                if liveNoteOwner === save {
                    liveNote?.itemID = item.id
                    liveNote?.snippet = text
                    liveNote?.source = capture.source
                }
            }
            guard case .finished(let why) = save.note else { return }
            save.resolved = true
            endLiveNote(for: save)
            if let id = save.itemID {
                store.updateWhy(id: id, why: why)
                announceSaved(source: capture.source)
            } else if let why, !why.isEmpty {
                // Nothing was selected: the spoken note becomes the save.
                store.add(text: why, kind: .note)
                announceSaved(source: .none, title: "Saved note")
            } else {
                announceNothingSelected()
            }
        }
    }

    private func endLiveNote(for save: SaveTicket) {
        guard liveNoteOwner === save else { return }
        liveNoteOwner = nil
        liveNote = nil
        noteHUD.hide()
    }

    private func announceSaved(source: SaveSource, title: String = "Saved") {
        if prefs.playSounds { NSSound(named: "Tink")?.play() }
        guard !isPanelVisible() else { return }
        let subtitle = [source.appName, source.windowTitle]
            .compactMap { $0 }
            .joined(separator: " · ")
        toast.show(ToastContent(title: title,
                                subtitle: subtitle.isEmpty ? nil : subtitle,
                                bundleID: source.bundleID,
                                isWarning: false))
    }

    private func announceNothingSelected() {
        toast.show(ToastContent(title: "Nothing selected",
                                subtitle: "Select text first, or tap then hold to say a note.",
                                bundleID: nil,
                                isWarning: true))
    }
}

/// One save in flight: its two halves (the captured selection and the
/// gesture's decision) are filled in as they arrive. Opaque outside this file;
/// the app delegate only carries it from the note's recording to its transcript.
final class SaveTicket {
    fileprivate enum Decision { case undecided, commit, note, cancelled }
    fileprivate enum Note { case none, recording, finished(String?) }

    fileprivate var capture: CapturedSelection?
    fileprivate var decision: Decision = .undecided
    fileprivate var note: Note = .none
    /// The row written so far (notes insert early so the card can show live text).
    fileprivate var itemID: String?
    fileprivate var resolved = false
}
