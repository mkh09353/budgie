import AppKit
import SwiftUI

/// The Saved panel: everything you've grabbed with the double tap, plus typed
/// notes, and a Meetings tab for recording calls. Replaces the old menu bar
/// popover — dictation status lives in the header pill and the speed stat in
/// the footer.
struct SavedPanelView: View {
    @ObservedObject var model: SavedListModel
    @ObservedObject var store: SaveStore
    @ObservedObject var coordinator: SaveCoordinator
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs

    private enum Field { case search, add }
    @FocusState private var focus: Field?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            // Restarting would end a meeting, so the banner waits until it's saved.
            if let update = state.update, !state.meeting.isBusy {
                UpdateBanner(update: update, install: model.onInstallUpdate)
            }
            if case .error(let message) = state.dictation {
                errorBanner(message)
            }
            switch model.tab {
            case .saved:
                searchField
                list
                addField
            case .meetings:
                MeetingsPane(state: state, prefs: prefs, actions: model.meetingActions)
            }
            footer
        }
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .overlay(alignment: .bottom) { flashBadge }
        .onChange(of: model.focusSearchRequest) { _, _ in focus = .search }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            HStack(spacing: 2) {
                tabButton("Saved", tab: .saved, shortcut: "⌘1")
                tabButton("Meetings", tab: .meetings, shortcut: "⌘2")
            }
            // While a meeting records, REC stands in for READY.
            if state.dictation != .idle || !state.meeting.isRecording {
                StatePill(state: state.dictation)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if state.meeting.isRecording {
                Button { model.tab = .meetings } label: { RecordingBadge() }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Recording a meeting")
            }
            Button {
                prefs.panelPinned.toggle()
            } label: {
                Image(systemName: prefs.panelPinned ? "pin.fill" : "pin")
                    .rotationEffect(.degrees(prefs.panelPinned ? 0 : 45))
            }
            .buttonStyle(HeaderIconButtonStyle(active: prefs.panelPinned))
            .help(prefs.panelPinned ? "Pinned: stays open when you click away"
                                    : "Pin to keep the panel open")
            moreMenu
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func tabButton(_ title: String, tab: SavedListModel.Tab, shortcut: String) -> some View {
        let selected = model.tab == tab
        return Button { model.tab = tab } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(shortcut))")
    }

    private var moreMenu: some View {
        Menu {
            Section("Today") {
                Text(todayStats)
            }
            Button("Paste Last Dictation") { model.onPasteLastDictation() }
                .disabled(state.recent.isEmpty)
            Divider()
            Toggle("Show Done Items", isOn: $prefs.showDoneItems)
            Button("Clear Done") { store.clearDone() }
                .disabled(model.doneCount == 0)
            Button("Open Meetings Folder") { model.meetingActions.openFolder() }
            Divider()
            Button("Settings…") {
                model.closePanel()
                model.onOpenSettings()
            }
            Button("Check for Updates…") {
                model.closePanel()
                model.onCheckForUpdates()
            }
            Divider()
            Button("Quit Budgie") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

    private var todayStats: String {
        var parts: [String] = []
        if state.speedMultiplier >= 1.05 {
            parts.append(String(format: "%.1f× faster than typing", state.speedMultiplier))
        }
        parts.append("\(state.wordsToday) words")
        if state.timeSavedToday >= 60 {
            parts.append("\(AppState.durationText(state.timeSavedToday)) saved")
        }
        return parts.joined(separator: " · ")
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Permissions…") {
                model.closePanel()
                model.onOpenSettings()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search", text: $model.search)
                .textFieldStyle(.plain)
                .focused($focus, equals: .search)
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    // MARK: - List

    private var list: some View {
        let sections = model.sections
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if sections.isEmpty {
                        emptyState
                    }
                    ForEach(sections) { section in
                        SectionHeader(title: section.title)
                        ForEach(section.items) { item in
                            SavedCard(item: item,
                                      model: model,
                                      isSelected: model.isSelected(item.id),
                                      isExpanded: model.expandedID == item.id,
                                      isEditing: model.editingID == item.id,
                                      liveWhy: liveWhy(for: item))
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.cursor) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    private func liveWhy(for item: SavedItem) -> String? {
        guard let note = coordinator.liveNote, note.itemID == item.id else { return nil }
        return note.text
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.search.isEmpty {
            Text("No saves match “\(model.search)”.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
        } else {
            VStack(spacing: 10) {
                BudgieGlyph(size: 28)
                    .foregroundStyle(.tertiary)
                Text("Nothing saved yet")
                    .font(.system(size: 13, weight: .semibold))
                VStack(spacing: 6) {
                    gestureHint("Select text, then double-tap", suffix: "to save it.")
                    gestureHint("Tap, then hold", suffix: "to say why.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    private func gestureHint(_ prefix: String, suffix: String) -> some View {
        HStack(spacing: 5) {
            Text(prefix)
            Keycap(text: prefs.hotKey.keycap, size: 11)
            Text(suffix)
        }
    }

    // MARK: - Add

    private var addField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.tertiary)
            TextField("Add a note or a prompt…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focus, equals: .add)
                .onSubmit {
                    model.addNote(draft)
                    draft = ""
                }
            if focus != .add && draft.isEmpty {
                HStack(spacing: 3) {
                    Text("hold")
                    Keycap(text: prefs.hotKey.keycap, size: 9.5)
                    Text("to speak")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(focus == .add ? Color.accentColor.opacity(0.6)
                                        : Color.primary.opacity(0.08),
                          lineWidth: focus == .add ? 1.5 : 0.5))
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.engineWarm ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(state.engineWarm ? "Engine warm" : "Engine cold")
            Spacer()
            if state.speedMultiplier >= 1.05 {
                Text(String(format: "%.1f×", state.speedMultiplier))
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                Text("faster than typing today")
            } else {
                Text("\(state.wordsToday) words dictated today")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var flashBadge: some View {
        if let flash = model.flash {
            Label(flash, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .padding(.bottom, 96)
                .transition(.opacity)
        }
    }
}

// MARK: - Pieces

private struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 1)
    }
}

/// One saved item. Collapsed it shows the text, the why and its source;
/// expanded (↩ or a second click) it adds the captured context and actions.
private struct SavedCard: View {
    let item: SavedItem
    @ObservedObject var model: SavedListModel
    let isSelected: Bool
    let isExpanded: Bool
    let isEditing: Bool
    /// The note being dictated onto this item right now.
    let liveWhy: String?

    @State private var draftText = ""
    @State private var draftWhy = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.toggleDone([item])
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(item.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 0) {
                if isEditing {
                    editor
                } else {
                    Text(item.text)
                        .font(.system(size: 12))
                        .lineLimit(isExpanded ? nil : 3)
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let why = liveWhy ?? item.why {
                        WhyLine(text: why, live: liveWhy != nil)
                            .padding(.top, 5)
                    }
                    if isExpanded {
                        context
                    } else {
                        meta.padding(.top, 5)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(item.isDone ? 0.55 : 0.85)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.07),
                          lineWidth: isSelected ? 2 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture { model.click(item.id) }
        .contextMenu { contextMenu }
    }

    // MARK: Collapsed

    private var meta: some View {
        HStack(spacing: 4) {
            if item.kind == .note && item.source.isEmpty {
                Image(systemName: "square.and.pencil")
                Text("Typed")
            } else {
                AppIconView(bundleID: item.source.bundleID, size: 12)
                Text(item.source.appName ?? "Unknown app")
            }
            Text("·")
            TimelineView(.everyMinute) { context in
                Text(SaveFormatting.shortAge(item.createdAt, now: context.date))
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Expanded

    private var context: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
                .padding(.bottom, 3)
            if item.kind == .capture {
                HStack(alignment: .top, spacing: 5) {
                    AppIconView(bundleID: item.source.bundleID, size: 12)
                    Text([item.source.appName, item.source.windowTitle]
                        .compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(2)
                }
            }
            if let url = item.source.url {
                Text(url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture { model.openSource(item) }
            }
            if let path = item.source.documentPath {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let around = item.source.surroundingText {
                Text("“\(around)”")
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                Button("Copy") { model.copy([item], as: .plain) }
                    .buttonStyle(.borderedProminent)
                if model.canOpenSource(item) {
                    Button("Open") { model.openSource(item) }
                }
                Button("Edit") { model.beginEdit(item) }
            }
            .controlSize(.small)
            .padding(.top, 5)
        }
        .font(.system(size: 11))
        .padding(.top, 8)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Text", text: $draftText, axis: .vertical)
                .lineLimit(1...10)
            TextField("Why (optional)", text: $draftWhy, axis: .vertical)
                .lineLimit(1...5)
            HStack {
                Spacer()
                Button("Cancel") { model.editingID = nil }
                Button("Save") { model.saveEdit(id: item.id, text: draftText, why: draftWhy) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .onAppear {
            draftText = item.text
            draftWhy = item.why ?? ""
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        let targets = model.targets(for: item)
        let plural = targets.count > 1 ? " \(targets.count) Items" : ""
        Button("Copy\(plural)") { model.copy(targets, as: .plain) }
        Button("Copy as List") { model.copy(targets, as: .list) }
        Button("Copy with Why") { model.copy(targets, as: .withWhy) }
        Divider()
        Button(targets.contains { !$0.isDone } ? "Mark as Done" : "Mark as Not Done") {
            model.toggleDone(targets)
        }
        if targets.count == 1 {
            if model.canOpenSource(item) {
                Button("Open Source") { model.openSource(item) }
            }
            Button("Edit") { model.beginEdit(item) }
        }
        Divider()
        Button("Delete\(plural)", role: .destructive) { model.delete(targets) }
    }
}

/// The yellow-ruled "why" under a saved item.
private struct WhyLine: View {
    let text: String
    let live: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.yellow)
                .frame(width: 2)
            Group {
                if live && text.isEmpty {
                    Text("Listening…").foregroundStyle(.tertiary)
                } else {
                    Text(text).foregroundStyle(live ? .primary : .secondary)
                }
            }
            .font(.system(size: 11.5))
            .fixedSize(horizontal: false, vertical: true)
            if live {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
        }
        // Keep the rule exactly as tall as the text.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HeaderIconButtonStyle: ButtonStyle {
    var active = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(active ? Color.accentColor.opacity(0.15)
                             : (hovering ? Color.primary.opacity(0.08) : .clear)))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}
