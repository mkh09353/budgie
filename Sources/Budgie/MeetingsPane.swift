import SwiftUI

/// What the Meetings tab can ask the app to do with meetings.
struct MeetingActions {
    var start: () -> Void
    var stop: () -> Void
    var transcribe: (URL) -> Void
    var open: (MeetingSummary) -> Void
    var copy: (MeetingSummary) -> Void
    var reveal: (MeetingSummary) -> Void
    var openFolder: () -> Void
}

/// The Saved panel's Meetings tab: Record Meeting, the live meeting while
/// one records, and past meetings by day.
struct MeetingsPane: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    let actions: MeetingActions

    var body: some View {
        VStack(spacing: 0) {
            if !state.meeting.isBusy {
                RecordButton(action: actions.start)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
            MeetingStatus(state: state, actions: actions)
            MeetingList(state: state, prefs: prefs, actions: actions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Header controls

/// The red "Record" capsule that starts a meeting.
struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // "Meeting" in the label: a bare "Record" reads as the way to
            // dictate, which is the hold-to-talk key, not this button.
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10))
                Text("Record Meeting")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.leading, 10)
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

struct RecordingBadge: View {
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

// MARK: - Update banner

/// Shown while an update waits, so it isn't stuck until Budgie next quits.
struct UpdateBanner: View {
    let update: UpdateStatus
    let install: () -> Void

    var body: some View {
        Banner(tint: .accentColor) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Button(action: install) {
                Text(buttonTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
            }
            .buttonStyle(FilledButtonStyle(color: .accentColor, shape: .capsule))
            .fixedSize()
        }
    }

    private var title: String {
        switch update {
        case .ready(let version):     return "Budgie \(version) is ready"
        case .available(let version): return "Budgie \(version) is available"
        }
    }

    private var buttonTitle: String {
        if case .ready = update { return "Restart to Update" }
        return "Update…"
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

// MARK: - Meeting list

/// Past meetings, newest first, grouped by day.
private struct MeetingList: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    let actions: MeetingActions

    var body: some View {
        if groups.isEmpty {
            VStack {
                Text("Your meetings show up here.\nTranscripts are saved to \(prefs.meetingsFolder.abbreviatedPath).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
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
                        ForEach(group.meetings, id: \.folder) { meeting in
                            MeetingRow(meeting: meeting, isBusy: state.meeting.isBusy, actions: actions)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var groups: [(title: String, meetings: [MeetingSummary])] {
        let meetings = state.meetings
            .filter { $0.folder != state.activeMeetingFolder }
            .sorted { $0.started > $1.started }
        var groups: [(title: String, meetings: [MeetingSummary])] = []
        for meeting in meetings {
            let title = SaveFormatting.dayTitle(meeting.started)
            if groups.last?.title == title {
                groups[groups.count - 1].meetings.append(meeting)
            } else {
                groups.append((title, [meeting]))
            }
        }
        return groups
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

/// A solid button that keeps its colour whether or not the panel is the key
/// window (`.borderedProminent` greys out in an inactive window).
struct FilledButtonStyle: ButtonStyle {
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
struct HoverRowStyle: ButtonStyle {
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
