import SwiftUI

/// The Settings window — replaces the two raw "open System Settings" menu
/// items with a real, sectioned preferences UI.
struct PreferencesView: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    var onSelectTranscriptionMode: (TranscriptionMode) -> Void
    var onRunSetup: () -> Void
    var onCheckForUpdates: () -> Void

    var body: some View {
        TabView {
            GeneralTab(
                state: state,
                prefs: prefs,
                onSelectTranscriptionMode: onSelectTranscriptionMode
            )
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeyTab(prefs: prefs)
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            MeetingsTab(prefs: prefs)
                .tabItem { Label("Meetings", systemImage: "record.circle") }
            PermissionsTab(state: state, onRunSetup: onRunSetup)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutTab(state: state, onCheckForUpdates: onCheckForUpdates)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    var onSelectTranscriptionMode: (TranscriptionMode) -> Void

    private var selectedMode: Binding<TranscriptionMode> {
        Binding(
            get: { state.pendingTranscriptionMode ?? prefs.transcriptionMode },
            set: { onSelectTranscriptionMode($0) }
        )
    }

    private var requestedMode: TranscriptionMode {
        state.pendingTranscriptionMode ?? prefs.transcriptionMode
    }

    var body: some View {
        Form {
            Picker("When dictation finishes:", selection: $prefs.insertMode) {
                ForEach(InsertMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Picker("Dictation style:", selection: selectedMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(modeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                punctuatedModelStatus
            }

            Divider().padding(.vertical, 4)

            Toggle("Play a sound when text is ready", isOn: $prefs.playSounds)
            Toggle("Show a text label in the menu bar", isOn: $prefs.showLabel)
            Toggle("Launch Budgie at login", isOn: $prefs.launchAtLogin)
        }
        .padding(20)
    }

    private var modeDescription: String {
        switch requestedMode {
        case .streaming:
            return "Streams text while you speak. This is Budgie's default mode."
        case .standard:
            if state.pendingTranscriptionMode == .standard {
                return "Live mode stays active until the Punctuated model is ready."
            }
            return "Waits until you release the key, then returns text with punctuation."
        }
    }

    @ViewBuilder
    private var punctuatedModelStatus: some View {
        switch state.punctuatedModelStatus {
        case .unavailable:
            Text("Punctuated mode downloads a larger model the first time; it can take a few minutes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading the Punctuated model. You can keep using Live mode.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ready:
            if requestedMode == .standard {
                Label("Punctuated model ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Meetings

struct MeetingsTab: View {
    @ObservedObject var prefs: UserPrefs

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save meetings in:")
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(prefs.meetingsFolder.abbreviatedPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                    Button("Show") {
                        try? FileManager.default.createDirectory(
                            at: prefs.meetingsFolder, withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(prefs.meetingsFolder)
                    }
                }
                Text("Each meeting is a folder holding transcript.md, ready to paste into Claude or Codex, plus transcript.json and the two recordings (me.wav and them.wav).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("How it works")
                    .font(.system(size: 12, weight: .semibold))
                Text("\u{201C}Me\u{201D} is your microphone and \u{201C}Them\u{201D} is everything this Mac plays, so any call app works and no bot joins. When you stop, Budgie transcribes both on this Mac and merges them into one timeline. If you use speakers instead of headphones, words your mic picks up from the call are removed from \u{201C}Me\u{201D}.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("The first meeting asks to record system audio. If \u{201C}Them\u{201D} comes out empty, allow Budgie under Screen & System Audio Recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = prefs.meetingsFolder
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            prefs.meetingsFolder = url
        }
    }
}

// MARK: - Hotkey

private struct HotkeyTab: View {
    @ObservedObject var prefs: UserPrefs

    var body: some View {
        VStack(spacing: 18) {
            Picker("Push-to-talk key:", selection: $prefs.hotKey) {
                ForEach(HotKey.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Hold").foregroundStyle(.secondary)
                    Text(prefs.hotKey.keycap)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .frame(minWidth: 44, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(Color.secondary.opacity(0.16)))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                    Text("to record, release to transcribe")
                        .foregroundStyle(.secondary)
                }
                Text("The key keeps its normal behaviour on a quick tap — "
                     + "it only records while held.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.07)))

            Spacer()
        }
        .padding(20)
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @ObservedObject var state: AppState
    var onRunSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Budgie needs three macOS permissions to work.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            PermissionRow(
                title: "Microphone",
                detail: "Record your voice.",
                granted: state.micGranted,
                pane: .microphone)
            PermissionRow(
                title: "Input Monitoring",
                detail: "Detect the push-to-talk key. Relaunch after granting.",
                granted: state.inputMonitoringGranted,
                pane: .inputMonitoring)
            PermissionRow(
                title: "Accessibility",
                detail: "Type the transcript at your cursor.",
                granted: state.accessibilityGranted,
                pane: .accessibility)

            Spacer()
            HStack {
                Button("Open Setup Assistant…") { onRunSetup() }
                Spacer()
                Button("Re-check") { state.refreshPermissions() }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { state.refreshPermissions() }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let pane: Permissions.SettingsPane

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") {
                    Permissions.openSettings(pane)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }
}

// MARK: - About

private struct AboutTab: View {
    @ObservedObject var state: AppState
    var onCheckForUpdates: () -> Void

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Version \(v)"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text("Budgie").font(.system(size: 18, weight: .semibold))
            Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Push-to-talk dictation that runs fully offline\non local Parakeet speech engines.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Button("Check for Updates…", action: onCheckForUpdates)
                .padding(.top, 4)

            HStack(spacing: 24) {
                lifetimeStat("\(state.wordsAllTime)", "words spoken")
                lifetimeStat(AppState.durationText(state.timeSavedAllTime), "of typing avoided")
            }
            .padding(.top, 10)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lifetimeStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
