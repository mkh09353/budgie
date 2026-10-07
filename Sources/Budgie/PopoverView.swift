import SwiftUI

/// What the popover can ask the app to do with meetings.
struct MeetingActions {
    var start: () -> Void
    var stop: () -> Void
    var transcribe: (URL) -> Void
    var open: (MeetingSummary) -> Void
    var copy: (MeetingSummary) -> Void
    var reveal: (MeetingSummary) -> Void
    var openFolder: () -> Void
}

/// The menu bar dropdown — a SwiftUI popover, not a plain `NSMenu`. Top to
/// bottom: the meeting recorder (the one big action), push-to-talk dictation
/// (always on, so just a status strip), then history.
struct PopoverView: View {
    static let size = NSSize(width: 340, height: 540)

    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    var meetingActions: MeetingActions
    var onOpenSettings: () -> Void
    var onCheckForUpdates: () -> Void
    var onQuit: () -> Void

    @AppStorage("popoverHistoryTab") private var historyTab: HistoryTab = .meetings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MeetingCard(state: state, actions: meetingActions)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            DictationStrip(state: state, prefs: prefs, onOpenSettings: onOpenSettings)
                .padding(12)
            Divider()
            history
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.budgie(size: NSSize(width: 16, height: 16)))
                .renderingMode(.template)
                .foregroundStyle(.tint)
            Text("Budgie")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            StatePill(dictation: state.dictation, meeting: state.meeting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - History

    private var history: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $historyTab) {
                    ForEach(HistoryTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(action: meetingActions.openFolder) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open the meetings folder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    switch historyTab {
                    case .meetings:
                        if state.meetings.isEmpty {
                            EmptyHistory(text: "Meetings you record show up here, saved as Markdown in \(prefs.meetingsFolder.abbreviatedPath).")
                        }
                        ForEach(state.meetings) { meeting in
                            MeetingRow(
                                meeting: meeting,
                                isBusy: state.meeting.isBusy,
                                actions: meetingActions
                            )
                        }
                    case .dictations:
                        if state.recent.isEmpty {
                            EmptyHistory(text: "Your dictations show up here. Click one to copy it.")
                        }
                        ForEach(state.recent.prefix(20)) { RecentRow(item: $0) }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            FooterButton(title: "Settings", systemImage: "gearshape", action: onOpenSettings)
            FooterButton(title: "Updates", systemImage: "arrow.triangle.2.circlepath",
                         action: onCheckForUpdates)
            FooterButton(title: "Quit", systemImage: "power", action: onQuit)
        }
        .padding(4)
    }
}

enum HistoryTab: String, CaseIterable, Identifiable {
    case meetings, dictations
    var id: String { rawValue }
    var title: String {
        switch self {
        case .meetings:   return "Meetings"
        case .dictations: return "Dictations"
        }
    }
}

// MARK: - Meeting card

/// The meeting recorder: a start button, a live card while recording, a
/// progress line while transcribing.
private struct MeetingCard: View {
    @ObservedObject var state: AppState
    let actions: MeetingActions

    var body: some View {
        Group {
            switch state.meeting {
            case .idle:
                startButton
            case .failed(let message, let folder):
                VStack(spacing: 10) {
                    failure(message, folder: folder)
                    startButton
                }
            case .recording(let started):
                recording(since: started)
            case .processing(let stage):
                processing(stage)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var startButton: some View {
        VStack(spacing: 7) {
            Button(action: actions.start) {
                Label("Record Meeting", systemImage: "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(FilledButtonStyle(color: .red))
            .disabled(!MeetingRecorder.isSupported)

            Text(MeetingRecorder.isSupported
                 ? "Your mic and the call, transcribed on this Mac."
                 : "Recording meetings needs macOS 14.2 or later.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func recording(since started: Date) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Recording")
                    .font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: started, by: 1)) { _ in
                    Text(MeetingTranscript.timestamp(Date().timeIntervalSince(started)))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: actions.stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(FilledButtonStyle(color: .red))
            }
            ChannelMeter(label: "Me", level: state.meetingMicLevel)
            ChannelMeter(label: "Them", level: state.meetingSystemLevel)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.25)))
    }

    private func processing(_ stage: MeetingStage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage.label)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            Text("Dictation keeps working in the meantime.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func failure(_ message: String, folder: URL?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let folder {
                Button("Try Again") { actions.transcribe(folder) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }
}

/// A labelled level meter for one meeting channel.
private struct ChannelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            LevelMeter(level: level, height: 8)
        }
    }
}

// MARK: - Dictation strip

/// Push-to-talk is always armed, so dictation gets a status line, not a card.
private struct DictationStrip: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private var content: some View {
        switch state.dictation {
        case .idle:
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
            Text("Hold").foregroundStyle(.secondary)
            Keycap(text: prefs.hotKey.keycap)
            Text("to dictate").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if state.speedMultiplier >= 1.05 {
                Text(String(format: "%.1f× typing", state.speedMultiplier))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
                    .help("\(AppState.durationText(state.timeSavedToday)) of typing saved today · \(state.wordsToday) words")
            }
        case .recording:
            Image(systemName: "mic.fill").foregroundStyle(.red)
            Text("Listening").fontWeight(.medium)
            if let started = state.recordingStarted {
                TimelineView(.periodic(from: started, by: 1)) { _ in
                    Text(MeetingTranscript.timestamp(Date().timeIntervalSince(started)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            LevelMeter(level: state.level, height: 8)
        case .transcribing:
            ProgressView().controlSize(.mini)
            Text("Transcribing…").fontWeight(.medium)
            Spacer()
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Fix…", action: onOpenSettings)
                .controlSize(.small)
        }
    }
}

// MARK: - History rows

private struct MeetingRow: View {
    let meeting: MeetingSummary
    let isBusy: Bool
    let actions: MeetingActions
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            if meeting.hasTranscript { actions.open(meeting) } else { actions.reveal(meeting) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: meeting.hasTranscript ? "doc.text" : "waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(Self.dateFormatter.string(from: meeting.started))
                            .font(.system(size: 12, weight: .medium))
                        if let duration = meeting.duration {
                            Text("· \(AppState.durationText(duration))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(meeting.preview ?? "Not transcribed yet")
                        .font(.system(size: 11))
                        .foregroundStyle(meeting.hasTranscript ? .secondary : .tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .onHover { hovering = $0 }
        .help(meeting.hasTranscript ? "Open the transcript" : "Show the recording in Finder")
    }

    @ViewBuilder
    private var trailing: some View {
        if !meeting.hasTranscript {
            Button("Transcribe") { actions.transcribe(meeting.folder) }
                .controlSize(.small)
                .disabled(isBusy)
        } else if copied {
            Label("Copied", systemImage: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        } else if hovering {
            HStack(spacing: 2) {
                RowIconButton(systemImage: "doc.on.doc", help: "Copy the transcript") {
                    actions.copy(meeting)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                RowIconButton(systemImage: "folder", help: "Show in Finder") {
                    actions.reveal(meeting)
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// One recent transcription — click to copy it back to the clipboard.
private struct RecentRow: View {
    let item: Transcription
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(item.text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text(item.date, format: .relative(presentation: .numeric))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help("Click to copy")
    }
}

private struct EmptyHistory: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
    }
}

// MARK: - Components

/// A coloured pill summarising the current state in one word. Dictation wins
/// while it's active; otherwise the meeting recorder's state shows.
private struct StatePill: View {
    let dictation: DictationState
    let meeting: MeetingState

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var text: String {
        switch dictation {
        case .recording:    return "LISTENING"
        case .transcribing: return "WORKING"
        case .error:        return "ATTENTION"
        case .idle:
            switch meeting {
            case .recording:  return "RECORDING"
            case .processing: return "WORKING"
            case .failed:     return "ATTENTION"
            case .idle:       return "READY"
            }
        }
    }

    private var color: Color {
        switch dictation {
        case .recording:    return .red
        case .transcribing: return .blue
        case .error:        return .orange
        case .idle:
            switch meeting {
            case .recording:  return .red
            case .processing: return .blue
            case .failed:     return .orange
            case .idle:       return .green
            }
        }
    }
}

/// A keyboard-key styled label.
private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(minWidth: 20)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
    }
}

/// An LED-style level meter.
private struct LevelMeter: View {
    let level: Float
    var height: CGFloat = 16
    private let bars = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let threshold = Float(i) / Float(bars)
                RoundedRectangle(cornerRadius: 1)
                    .fill(threshold < level ? color(threshold)
                                            : Color.secondary.opacity(0.16))
                    .frame(height: height)
            }
        }
    }

    private func color(_ t: Float) -> Color {
        t < 0.6 ? .green : (t < 0.85 ? .yellow : .red)
    }
}

private struct RowIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help(help)
    }
}

/// A footer action with an icon, filling the available width.
private struct FooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// A solid button that keeps its colour whether or not the popover is the key
/// window (`.borderedProminent` greys out in an inactive window).
private struct FilledButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isEnabled ? color : Color.secondary.opacity(0.5))
                .brightness(configuration.isPressed ? -0.12 : (hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
    }
}

/// A borderless button that highlights its whole row on hover.
private struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}

extension URL {
    /// The path with the home directory shown as `~`.
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
