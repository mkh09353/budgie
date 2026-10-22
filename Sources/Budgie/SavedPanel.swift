import AppKit
import Combine
import SwiftUI

/// The floating Saved panel. Non-activating, so opening it never takes focus
/// (or the text selection) away from the app you're working in; it only
/// becomes key so you can use the keyboard inside it.
final class SavedPanel: NSPanel {
    /// Sees every key press first. Returns true when it handled the event.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A text field (search, add, edit) is being typed in.
    var isEditingText: Bool { firstResponder is NSTextView }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Opens, positions and closes the panel. It always opens in the same spot,
/// under the menu bar icon.
final class SavedPanelController: NSObject, NSWindowDelegate {
    let model: SavedListModel
    private let prefs: UserPrefs
    private var panel: SavedPanel?
    private var lastAutoClose = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    init(model: SavedListModel, prefs: UserPrefs) {
        self.model = model
        self.prefs = prefs
        super.init()
        model.closePanel = { [weak self] in self?.close() }
        model.endTextEditing = { [weak self] in
            guard let panel = self?.panel else { return }
            panel.makeFirstResponder(nil)
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var isKey: Bool { panel?.isKeyWindow ?? false }

    func toggle(from button: NSStatusBarButton?) {
        if isVisible {
            close()
        } else if Date().timeIntervalSince(lastAutoClose) > 0.3 {
            // The click that closed an unpinned panel was this same button.
            show(from: button)
        }
    }

    func show(from button: NSStatusBarButton?) {
        let panel = self.panel ?? makePanel()
        position(panel, under: button)
        model.didOpen()
        panel.makeKeyAndOrderFront(nil)
        // Start on the list, not the search field, so ↑/↓ and Space work at once.
        DispatchQueue.main.async { panel.makeFirstResponder(nil) }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.didClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !prefs.panelPinned, isVisible else { return }
        lastAutoClose = Date()
        close()
    }

    private func makePanel() -> SavedPanel {
        let panel = SavedPanel()
        panel.delegate = self
        let root = SavedPanelView(model: model,
                                  store: model.store,
                                  coordinator: model.coordinator,
                                  state: model.state,
                                  prefs: prefs)
        let host = NSHostingView(rootView: root)
        panel.contentView = host
        panel.keyHandler = { [weak self, weak panel] event in
            guard let self, let panel else { return false }
            // Budgie's own synthetic keys (dictation, the capture ⌘C) may type
            // into a panel text field, but must never drive list shortcuts.
            if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                return !panel.isEditingText
            }
            return self.model.handleKey(event, editingText: panel.isEditingText)
        }
        self.panel = panel
        return panel
    }

    private func position(_ panel: SavedPanel, under button: NSStatusBarButton?) {
        let anchor = button.flatMap { button -> NSRect? in
            guard let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let screen = button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 320
        let height = min(640, visible.height - 24)
        let margin: CGFloat = 8
        var x = (anchor?.maxX ?? visible.maxX) - width + 10
        x = min(max(x, visible.minX + margin), visible.maxX - width - margin)
        let frame = NSRect(x: x, y: visible.maxY - height - 6, width: width, height: height)
        panel.setFrame(frame, display: false)
    }
}

/// Selection, keyboard and actions for the Saved panel.
final class SavedListModel: ObservableObject {
    enum CopyFormat { case plain, list, withWhy }
    enum Tab { case saved, meetings }

    @Published var tab: Tab = .saved
    @Published var search = ""
    @Published private(set) var selection: Set<String> = []
    /// The item the keyboard is on; the list scrolls to keep it visible.
    @Published private(set) var cursor: String?
    @Published var expandedID: String?
    @Published var editingID: String?
    /// A short confirmation shown at the bottom of the panel.
    @Published private(set) var flash: String?
    /// Bumped to ask the view to focus the search field.
    @Published private(set) var focusSearchRequest = 0

    let store: SaveStore
    let coordinator: SaveCoordinator
    let state: AppState
    let prefs: UserPrefs

    var closePanel: () -> Void = {}
    var endTextEditing: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    var onInstallUpdate: () -> Void = {}
    var onPasteLastDictation: () -> Void = {}
    var meetingActions = MeetingActions(
        start: {}, stop: {}, transcribe: { _ in }, open: { _ in },
        copy: { _ in }, reveal: { _ in }, openFolder: {}
    )

    private var anchor: String?
    private var flashWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(store: SaveStore, coordinator: SaveCoordinator, state: AppState, prefs: UserPrefs) {
        self.store = store
        self.coordinator = coordinator
        self.state = state
        self.prefs = prefs
        // Drop selection that no longer points at a visible item.
        store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pruneSelection() }
            .store(in: &cancellables)
        // A meeting that starts shows its live view.
        state.$meeting
            .map(\.isRecording)
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tab = .meetings }
            .store(in: &cancellables)
    }

    // MARK: - What's shown

    var visibleItems: [SavedItem] {
        store.items.filter { item in
            (prefs.showDoneItems || !item.isDone) && SaveFormatting.matches(item, query: search)
        }
    }

    var sections: [SaveFormatting.DaySection] {
        SaveFormatting.daySections(visibleItems)
    }

    var doneCount: Int { store.items.filter(\.isDone).count }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    /// The items an action applies to: the selection when `item` is part of it
    /// (or no item given), otherwise just `item`. Always in list order.
    func targets(for item: SavedItem? = nil) -> [SavedItem] {
        if let item, !selection.contains(item.id) { return [item] }
        return visibleItems.filter { selection.contains($0.id) }
    }

    // MARK: - Lifecycle

    func didOpen() {
        pruneSelection()
        if cursor == nil, let first = visibleItems.first {
            select(first.id)
        }
    }

    func didClose() {
        editingID = nil
        expandedID = nil
    }

    // MARK: - Selection

    func click(_ id: String) {
        endTextEditing()
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            cursor = id
            anchor = id
        } else if flags.contains(.shift), let anchor {
            selectRange(from: anchor, to: id)
        } else if selection == [id] {
            expandedID = expandedID == id ? nil : id
        } else {
            select(id)
        }
    }

    func select(_ id: String) {
        selection = [id]
        cursor = id
        anchor = id
        if expandedID != id { expandedID = nil }
    }

    private func selectRange(from: String, to: String) {
        let ids = visibleItems.map(\.id)
        guard let a = ids.firstIndex(of: from), let b = ids.firstIndex(of: to) else {
            select(to)
            return
        }
        selection = Set(ids[min(a, b)...max(a, b)])
        cursor = to
    }

    func move(_ delta: Int, extend: Bool) {
        let ids = visibleItems.map(\.id)
        guard !ids.isEmpty else { return }
        let index = cursor.flatMap { ids.firstIndex(of: $0) }
        let next = index.map { min(max($0 + delta, 0), ids.count - 1) }
            ?? (delta > 0 ? 0 : ids.count - 1)
        if extend, let anchor {
            selectRange(from: anchor, to: ids[next])
        } else {
            select(ids[next])
        }
    }

    func selectAll() {
        selection = Set(visibleItems.map(\.id))
    }

    private func pruneSelection() {
        let visible = Set(visibleItems.map(\.id))
        selection = selection.intersection(visible)
        if let cursor, !visible.contains(cursor) { self.cursor = selection.first }
        if let expandedID, !visible.contains(expandedID) { self.expandedID = nil }
    }

    // MARK: - Actions

    func toggleDone(_ items: [SavedItem]) {
        guard !items.isEmpty else { return }
        let markDone = items.contains { !$0.isDone }
        store.setDone(ids: items.map(\.id), done: markDone)
    }

    func copy(_ items: [SavedItem], as format: CopyFormat) {
        guard !items.isEmpty else { return }
        let text: String
        switch format {
        case .plain:   text = SaveFormatting.plain(items)
        case .list:    text = SaveFormatting.numberedList(items)
        case .withWhy: text = SaveFormatting.withWhy(items)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if format == .list {
            // Like ticking prompts off a queue as you send them.
            store.setDone(ids: items.map(\.id), done: true)
            show(flash: items.count == 1 ? "Copied as list" : "Copied \(items.count) as list")
        } else {
            show(flash: items.count == 1 ? "Copied" : "Copied \(items.count)")
        }
    }

    func delete(_ items: [SavedItem]) {
        guard !items.isEmpty else { return }
        let visible = visibleItems.map(\.id)
        let removed = Set(items.map(\.id))
        // Move the cursor to the next survivor so the keyboard keeps going.
        let next = cursor.flatMap { visible.firstIndex(of: $0) }.flatMap { index in
            visible[index...].first { !removed.contains($0) }
                ?? visible[..<index].last { !removed.contains($0) }
        }
        store.delete(ids: Array(removed))
        if let next { select(next) } else { selection = []; cursor = nil }
    }

    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = store.add(text: trimmed, kind: .note)
        search = ""
        select(item.id)
    }

    func saveEdit(id: String, text: String, why: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, store.item(id: id)?.text != trimmed {
            store.updateText(id: id, text: trimmed)
        }
        if store.item(id: id)?.why ?? "" != why.trimmingCharacters(in: .whitespacesAndNewlines) {
            store.updateWhy(id: id, why: why)
        }
        editingID = nil
    }

    func beginEdit(_ item: SavedItem) {
        select(item.id)
        expandedID = item.id
        editingID = item.id
    }

    func canOpenSource(_ item: SavedItem) -> Bool {
        item.source.url != nil || item.source.documentPath != nil || item.source.bundleID != nil
    }

    /// Back to where it came from: the exact passage on a web page, the file,
    /// or at least the app.
    func openSource(_ item: SavedItem) {
        let source = item.source
        let workspace = NSWorkspace.shared
        let sourceApp = source.bundleID.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }

        if let page = source.url,
           let url = SaveFormatting.textFragmentURL(page: page, text: item.text) ?? URL(string: page) {
            // Reopen in the same browser when it can open web links; apps that
            // merely host a web view (chat apps) hand off to the default browser.
            if let sourceApp, workspace.urlsForApplications(toOpen: url).contains(sourceApp) {
                workspace.open([url], withApplicationAt: sourceApp,
                               configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open(url)
            }
        } else if let path = source.documentPath, FileManager.default.fileExists(atPath: path) {
            let file = URL(fileURLWithPath: path)
            if let sourceApp {
                workspace.open([file], withApplicationAt: sourceApp,
                               configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open(file)
            }
        } else if let sourceApp {
            workspace.openApplication(at: sourceApp, configuration: NSWorkspace.OpenConfiguration())
        }
        if !prefs.panelPinned { closePanel() }
    }

    func requestSearchFocus() {
        focusSearchRequest += 1
    }

    private func show(flash message: String) {
        flashWork?.cancel()
        flash = message
        let work = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    // MARK: - Keyboard

    /// Returns true when the key was handled.
    func handleKey(_ event: NSEvent, editingText: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if editingText {
            // Budgie has no Edit menu (it's a menu-bar app), so standard
            // editing shortcuts must be routed to the text field by hand.
            if command {
                let action: String?
                switch key {
                case "x": action = "cut:"
                case "c": action = "copy:"
                case "v": action = "paste:"
                case "a": action = "selectAll:"
                case "z": action = flags.contains(.shift) ? "redo:" : "undo:"
                default:  action = nil
                }
                if let action {
                    return NSApp.sendAction(Selector(action), to: nil, from: nil)
                }
            }
            if event.keyCode == 53 { // esc
                if !search.isEmpty && editingID == nil { search = "" }
                editingID = nil
                endTextEditing()
                return true
            }
            return false
        }

        if command, key == "1" || key == "2" {
            tab = key == "1" ? .saved : .meetings
            return true
        }
        if tab == .meetings {
            switch event.keyCode {
            case 53: closePanel(); return true                                     // esc
            default: break
            }
            guard command else { return false }
            switch key {
            case "w": closePanel(); return true
            case ",": closePanel(); onOpenSettings(); return true
            default: return false
            }
        }

        let targets = self.targets()
        switch event.keyCode {
        case 125: move(1, extend: flags.contains(.shift)); return true            // ↓
        case 126: move(-1, extend: flags.contains(.shift)); return true           // ↑
        case 36, 76:                                                              // ↩
            if let cursor { expandedID = expandedID == cursor ? nil : cursor }
            return true
        case 49: toggleDone(targets); return true                                 // space
        case 51, 117: delete(targets); return true                                // ⌫ ⌦
        case 53:                                                                  // esc
            if expandedID != nil {
                expandedID = nil
            } else if !prefs.panelPinned || selection.isEmpty {
                closePanel()
            } else {
                selection = []
            }
            return true
        default:
            break
        }

        guard command else { return false }
        switch key {
        case "c":
            if flags.contains(.shift) { copy(targets, as: .list) }
            else if flags.contains(.option) { copy(targets, as: .withWhy) }
            else { copy(targets, as: .plain) }
            return true
        case "a": selectAll(); return true
        case "f": requestSearchFocus(); return true
        case "w": closePanel(); return true
        case ",": closePanel(); onOpenSettings(); return true
        default: return false
        }
    }
}
