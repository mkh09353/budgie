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

/// The menu bar dropdown — a SwiftUI popover, not a plain `NSMenu`. A header
/// with the Record button, the live meeting while one records, one timeline of
/// meetings and dictations, and a footer for push-to-talk and the app menu.
/// It is as tall as its content; the timeline scrolls past `maxTimelineHeight`.
struct PopoverView: View {
    static let width: CGFloat = 340
    static let maxTimelineHeight: CGFloat = 380
    /// While recording, the live meeting takes the room.
    static let maxTimelineHeightWhileRecording: CGFloat = 170

    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    var meetingActions: MeetingActions
    var onOpenSettings: () -> Void
    var onCheckForUpdates: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            MeetingStatus(state: state, actions: meetingActions)
            Divider()
            Timeline(
                state: state,
                prefs: prefs,
                actions: meetingActions,
                maxHeight: state.meeting.isRecording
                    ? Self.maxTimelineHeightWhileRecording : Self.maxTimelineHeight
            )
            Divider()
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // Opaque, so the window behind the popover doesn't show through.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(nsImage: MenuBarIcon.budgie(size: NSSize(width: 16, height: 16)))
                .renderingMode(.template)
                .foregroundStyle(.tint)
            Text("Budgie")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            switch state.meeting {
            case .recording:
                RecordingBadge()
            case .processing:
                EmptyView()
            case .idle, .failed:
                RecordButton(action: meetingActions.start)
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            DictationStatus(state: state, prefs: prefs, onOpenSettings: onOpenSettings)
            Spacer(minLength: 6)
            Menu {
                Button("Open Meetings Folder", action: meetingActions.openFolder)
                Divider()
                Button("Settings…", action: onOpenSettings)
                Button("Check for Updates…", action: onCheckForUpdates)
                Divider()
                Button("Quit Budgie", action: onQuit)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings, updates and quit")
        }
        .font(.system(size: 11.5))
        .frame(minHeight: 22)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: - Header controls

/// The red "Record" capsule that starts a meeting.
private struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(.white).frame(width: 7, height: 7)
                Text("Record")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .padding(.vertical, 4)
        }
        .buttonStyle(FilledButtonStyle(color: .red, shape: .capsule))
        .disabled(!MeetingRecorder.isSupported)
        .help(MeetingRecorder.isSupported
              ? "Record a meeting: your mic and the call, transcribed on this Mac"
              : "Recording meetings needs macOS 14.2 or later")
    }
}

private struct RecordingBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 7, height: 7)
                .symbolEffectPulse()
            Text("REC")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.red)
        }
    }
}

private extension View {
    /// A slow pulse, for the recording dot.
    func symbolEffectPulse() -> some View {
        PhaseAnimator([1.0, 0.35]) { opacity in
            self.opacity(opacity)
        } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

// MARK: - Meeting status

/// The live meeting while recording, a progress line while the transcript is
/// saved, or the last failure. Nothing when idle.
private struct MeetingStatus: View {
    @ObservedObject var state: AppState
    let actions: MeetingActions

    var body: some View {
        switch state.meeting {
        case .idle:
            EmptyView()
        case .recording(let started):
            LiveMeeting(state: state, started: started, stop: actions.stop)
        case .processing(let stage):
            Banner(tint: .blue) {
                ProgressView().controlSize(.small)
                Text(stage.label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
        case .failed(let message, let folder):
            Banner(tint: .orange) {
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
        }
    }
}

private struct Banner<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.10)))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }
}

/// The meeting being recorded: a big timer, rolling Me/Them waveforms, the
/// latest transcribed line, and Stop.
private struct LiveMeeting: View {
    @ObservedObject var state: AppState
    let started: Date
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: started, by: 1)) { _ in
                Text(MeetingTranscript.timestamp(Date().timeIntervalSince(started)))
                    .font(.system(size: 34, weight: .light).monospacedDigit())
            }
            VStack(spacing: 4) {
                Waveform(label: "Me", values: state.meetingLevelHistory.map(\.me), color: .red)
                Waveform(label: "Them", values: state.meetingLevelHistory.map(\.them), color: .blue)
            }
            LiveTranscriptCard(progress: state.meetingProgress)
            Button(action: stop) {
                Label("Stop & Save Transcript", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
            }
            .buttonStyle(FilledButtonStyle(color: .red))
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }
}

/// A rolling level history drawn as bars, newest on the right.
private struct Waveform: View {
    let label: String
    let values: [Float]
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            HStack(alignment: .center, spacing: 2) {
                let padded = Array(repeating: Float(0), count: max(0, AppState.meetingLevelHistoryLength - values.count)) + values
                ForEach(Array(padded.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(color.opacity(level > 0.02 ? 0.85 : 0.3))
                        .frame(width: 3, height: 3 + CGFloat(min(max(level, 0), 1)) * 19)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .trailing)
        }
    }
}

private struct LiveTranscriptCard: View {
    let progress: MeetingLiveProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            text
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
    }

    private var title: String {
        guard let progress, progress.through >= 1 else { return "Transcribing as you go" }
        return "Transcribed through \(MeetingTranscript.timestamp(progress.through))"
    }

    private var text: Text {
        if let line = progress?.lastLine {
            return Text("\(line.speaker.rawValue): ").bold().foregroundColor(.primary)
                + Text(Self.tail(of: line.text))
        }
        if progress == nil { return Text("The latest line shows up here every minute or so.") }
        return Text("No speech yet.")
    }

    /// The end of a long line, cut at a word.
    static func tail(of text: String, limit: Int = 140) -> String {
        guard text.count > limit else { return text }
        let suffix = text.suffix(limit)
        let start = suffix.firstIndex(of: " ").map { suffix.index(after: $0) } ?? suffix.startIndex
        return "…" + suffix[start...]
    }
}

// MARK: - Timeline

/// Meetings and dictations in one list, newest first, grouped by day.
private struct Timeline: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    let actions: MeetingActions
    let maxHeight: CGFloat

    static let itemLimit = 40

    var body: some View {
        if groups.isEmpty {
            Text("Your meetings and dictations show up here.\nTranscripts are saved to \(prefs.meetingsFolder.abbreviatedPath).")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 14)
                            .padding(.top, 9)
                            .padding(.bottom, 2)
                        ForEach(group.items) { item in
                            switch item {
                            case .meeting(let meeting):
                                MeetingRow(meeting: meeting, isBusy: state.meeting.isBusy, actions: actions)
                            case .dictation(let dictation):
                                DictationRow(item: dictation)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxHeight)
        }
    }

    private var groups: [TimelineGroup] {
        let meetings = state.meetings
            .filter { $0.folder != state.activeMeetingFolder }
            .map(TimelineItem.meeting)
        let items = (meetings + state.recent.map(TimelineItem.dictation))
            .sorted { $0.date > $1.date }
            .prefix(Self.itemLimit)
        var groups: [TimelineGroup] = []
        for item in items {
            let title = Self.dayTitle(item.date)
            if groups.last?.title == title {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(TimelineGroup(title: title, items: [item]))
            }
        }
        return groups
    }

    static func dayTitle(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEEE" : "MMMd")
        return formatter.string(from: date)
    }
}

private struct TimelineGroup {
    let title: String
    var items: [TimelineItem]
}

private enum TimelineItem: Identifiable {
    case meeting(MeetingSummary)
    case dictation(Transcription)

    var id: String {
        switch self {
        case .meeting(let meeting): return "m:" + meeting.folder.path
        case .dictation(let item):  return "d:" + item.id.uuidString
        }
    }

    var date: Date {
        switch self {
        case .meeting(let meeting): return meeting.started
        case .dictation(let item):  return item.date
        }
    }
}

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: meeting.hasTranscript ? "doc.text" : "waveform")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Meeting")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                        trailing
                    }
                    .frame(height: 20)
                    Text(meeting.preview ?? "Not transcribed yet")
                        .font(.system(size: 12))
                        .foregroundStyle(meeting.hasTranscript ? .secondary : .tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .onHover { hovering = $0 }
        .help(meeting.hasTranscript ? "Open the transcript" : "Show the recording in Finder")
    }

    private var subtitle: String {
        let time = timeFormatter.string(from: meeting.started)
        guard let duration = meeting.duration else { return time }
        return "\(time) · \(AppState.durationText(duration))"
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
                Button {
                    actions.copy(meeting)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Text("Copy for Claude")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
                .buttonStyle(FilledButtonStyle(color: .accentColor, shape: .capsule))
                .help("Copy the whole transcript as Markdown")
                RowIconButton(systemImage: "folder", help: "Show in Finder") {
                    actions.reveal(meeting)
                }
            }
        }
    }
}

/// One dictation — click to copy it back to the clipboard.
private struct DictationRow: View {
    let item: Transcription
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text(item.text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text(timeFormatter.string(from: item.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help("Click to copy")
    }
}

// MARK: - Footer

/// Push-to-talk is always armed, so dictation gets a status line.
private struct DictationStatus: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            switch state.dictation {
            case .idle:
                Text("Hold").foregroundStyle(.secondary)
                Keycap(text: prefs.hotKey.keycap)
                Text("to dictate").foregroundStyle(.secondary)
                if state.speedMultiplier >= 1.05 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(format: "%.1f× typing", state.speedMultiplier))
                        .fontWeight(.semibold)
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
                LevelMeter(level: state.level, height: 7)
                    .frame(width: 90)
            case .transcribing:
                ProgressView().controlSize(.mini)
                Text("Transcribing…").fontWeight(.medium)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Fix…", action: onOpenSettings)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Components

/// A keyboard-key styled label.
private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(minWidth: 18)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
    }
}

/// An LED-style level meter.
private struct LevelMeter: View {
    let level: Float
    var height: CGFloat = 16
    private let bars = 18

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
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help(help)
    }
}

/// A solid button that keeps its colour whether or not the popover is the key
/// window (`.borderedProminent` greys out in an inactive window).
private struct FilledButtonStyle: ButtonStyle {
    enum Shape { case rounded, capsule }

    let color: Color
    var shape: Shape = .rounded
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(background
                .foregroundStyle(isEnabled ? color : Color.secondary.opacity(0.5))
                .brightness(configuration.isPressed ? -0.12 : (hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var background: some View {
        switch shape {
        case .rounded: RoundedRectangle(cornerRadius: 8, style: .continuous)
        case .capsule: Capsule()
        }
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
