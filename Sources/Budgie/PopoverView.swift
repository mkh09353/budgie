import SwiftUI

/// The menu bar dropdown — a SwiftUI popover, not a plain `NSMenu`. It always
/// answers two questions at a glance: what the app is for, and what it's doing
/// right now.
struct PopoverView: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusCard
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            SpeedCard(multiplier: state.speedMultiplier,
                      timeSaved: state.timeSavedToday,
                      words: state.wordsToday,
                      engineWarm: state.engineWarm)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            Divider()
            recentSection
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 312, height: 420)
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
            StatePill(state: state.dictation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Status card (adapts to what the app is doing)

    @ViewBuilder
    private var statusCard: some View {
        switch state.dictation {
        case .idle:
            idleCard
        case .recording:
            recordingCard
        case .transcribing:
            transcribingCard
        case .error(let message):
            errorCard(message)
        }
    }

    private var idleCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Hold")
                    .foregroundStyle(.secondary)
                Keycap(text: prefs.hotKey.keycap)
                Text(prefs.hotKey.label.replacingOccurrences(of: " Command", with: "")
                        .replacingOccurrences(of: " Option", with: "")
                        .replacingOccurrences(of: " Control", with: ""))
                    .foregroundStyle(.secondary)
                Text("to dictate")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            Text("Release to transcribe — the text lands wherever your cursor is.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var recordingCard: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Listening", systemImage: "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                Spacer()
                if let started = state.recordingStarted {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsed(since: started))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LevelMeter(level: state.level)
        }
    }

    private var transcribingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Transcribing…")
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            Button("Open Permissions…", action: onOpenSettings)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Recent transcriptions

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if state.recent.isEmpty {
                Text("Your dictations will show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.recent.prefix(6)) { item in
                            RecentRow(item: item)
                        }
                    }
                }
                .frame(maxHeight: 196)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            FooterButton(title: "Settings…", systemImage: "gearshape", action: onOpenSettings)
            Divider().frame(height: 22)
            FooterButton(title: "Quit", systemImage: "power", action: onQuit)
        }
        .padding(4)
    }

    private func elapsed(since start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Components

/// The headline "you're faster than your keyboard" card: today's dictation
/// speed expressed as a multiple of a 40-wpm typing baseline.
private struct SpeedCard: View {
    let multiplier: Double
    let timeSaved: TimeInterval
    let words: Int
    let engineWarm: Bool

    var body: some View {
        VStack(spacing: 4) {
            if multiplier >= 1.05 {
                HStack(spacing: 5) {
                    Text("🚀").font(.system(size: 15))
                    Text(String(format: "%.1f× faster", multiplier))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.tint)
                    Text("than typing")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if timeSaved >= 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 10))
                        Text("\(AppState.durationText(timeSaved)) of typing saved today")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("🎙 Speak to outpace your keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(engineWarm ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(engineWarm ? "Engine warm" : "Engine cold")
                Spacer()
                Text("\(words) words today")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
    }
}

/// A coloured pill summarising the current state in one word.
private struct StatePill: View {
    let state: DictationState

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var text: String {
        switch state {
        case .idle:         return "READY"
        case .recording:    return "RECORDING"
        case .transcribing: return "WORKING"
        case .error:        return "ATTENTION"
        }
    }

    private var color: Color {
        switch state {
        case .idle:         return .green
        case .recording:    return .red
        case .transcribing: return .blue
        case .error:        return .orange
        }
    }
}

/// A keyboard-key styled label.
private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(minWidth: 22)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
    }
}

/// An LED-style microphone level meter.
private struct LevelMeter: View {
    let level: Float
    private let bars = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let threshold = Float(i) / Float(bars)
                RoundedRectangle(cornerRadius: 1)
                    .fill(threshold < level ? color(threshold)
                                            : Color.secondary.opacity(0.16))
                    .frame(height: 16)
            }
        }
    }

    private func color(_ t: Float) -> Color {
        t < 0.6 ? .green : (t < 0.85 ? .yellow : .red)
    }
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

/// A footer action with an icon, filling half the footer width.
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
