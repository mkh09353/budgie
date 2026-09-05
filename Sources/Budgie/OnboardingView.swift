import SwiftUI
import Combine

/// First-run setup: walks the three privacy permissions one at a time, in an
/// order that saves Input Monitoring's possible relaunch for last — so if
/// macOS quits and reopens Budgie, the only thing left is the "all set"
/// screen. The view polls permission state while visible, so each checkmark
/// flips the moment the user toggles Budgie on in System Settings.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: UserPrefs
    var onFinished: () -> Void
    var onLater: () -> Void

    private let poll = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    private enum Step: Equatable { case microphone, accessibility, inputMonitoring }

    /// The first permission still missing — the row whose action is shown.
    private var activeStep: Step? {
        if !state.micGranted { return .microphone }
        if !state.accessibilityGranted { return .accessibility }
        if !state.inputMonitoringGranted || !state.keyMonitorRunning { return .inputMonitoring }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                micRow
                accessibilityRow
                inputMonitoringRow
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 14)
            footer
        }
        .padding(.bottom, 18)
        .frame(width: 440, height: 478)
        .animation(.easeInOut(duration: 0.2), value: activeStep)
        .onAppear { state.refreshPermissions() }
        .onReceive(poll) { _ in state.refreshPermissions() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 7) {
            // The real (yellow) app icon — not the template silhouette, which
            // would take the system accent color.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Welcome to Budgie")
                .font(.system(size: 19, weight: .semibold))
            Text("Grant three macOS permissions and you're dictating.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var micRow: some View {
        let denied = state.micDenied
        return StepRow(
            index: 1,
            title: "Microphone",
            caption: denied
                ? "Microphone access was turned off. Switch Budgie on in the list, then come back."
                : "Budgie records you only while the push-to-talk key is held.",
            status: status(for: .microphone),
            buttonTitle: denied ? "Open System Settings" : "Allow Microphone",
            buttonAction: {
                if denied {
                    Permissions.openSettings(.microphone)
                } else {
                    Permissions.requestMicrophone()
                }
            })
    }

    private var accessibilityRow: some View {
        StepRow(
            index: 2,
            title: "Accessibility",
            caption: "Lets Budgie type the transcript at your cursor. "
                + "Drag Budgie into the Accessibility list, then switch it on.",
            status: status(for: .accessibility),
            buttonTitle: "Grant Access",
            buttonAction: { Permissions.openSettings(.accessibility) })
    }

    private var inputMonitoringRow: some View {
        let needsRelaunch = state.inputMonitoringGranted && !state.keyMonitorRunning
        return StepRow(
            index: 3,
            title: "Input Monitoring",
            caption: needsRelaunch
                ? "Almost done — macOS needs Budgie to relaunch to finish turning this on."
                : "Lets Budgie see the push-to-talk key — and nothing else you type. "
                    + "If macOS offers “Quit & Reopen”, click it: setup resumes by itself.",
            status: status(for: .inputMonitoring),
            buttonTitle: needsRelaunch ? "Relaunch Budgie" : "Grant Input Monitoring",
            buttonAction: {
                if needsRelaunch {
                    Permissions.relaunch()
                } else {
                    Permissions.openSettings(.inputMonitoring)
                }
            },
            linkTitle: needsRelaunch ? nil : "Open System Settings",
            linkAction: { Permissions.openSettings(.inputMonitoring) })
    }

    @ViewBuilder
    private var footer: some View {
        if activeStep == nil {
            VStack(spacing: 11) {
                Text("You're all set!")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 7) {
                    Text("Hold").foregroundStyle(.secondary)
                    Text(prefs.hotKey.keycap)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .frame(minWidth: 34, minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Color.secondary.opacity(0.16)))
                    Text("and speak — release to finish.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                Button("Start Dictating") { onFinished() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            Button("Set up later") { onLater() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Row state

    private func status(for step: Step) -> StepRow.Status {
        let granted: Bool
        switch step {
        case .microphone:      granted = state.micGranted
        case .accessibility:   granted = state.accessibilityGranted
        case .inputMonitoring: granted = state.inputMonitoringGranted && state.keyMonitorRunning
        }
        if granted { return .done }
        return activeStep == step ? .active : .pending
    }
}

// MARK: - Row

private struct StepRow: View {
    enum Status { case done, active, pending }

    let index: Int
    let title: String
    let caption: String
    let status: Status
    var buttonTitle: String?
    var buttonAction: () -> Void = {}
    var linkTitle: String?
    var linkAction: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if status == .active {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if let buttonTitle {
                            Button(buttonTitle, action: buttonAction)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        if let linkTitle {
                            Button(linkTitle, action: linkAction)
                                .buttonStyle(.link)
                                .controlSize(.small)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(status == .active
                ? Color.accentColor.opacity(0.08)
                : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(status == .active ? Color.accentColor.opacity(0.45) : .clear,
                          lineWidth: 1))
        .opacity(status == .pending ? 0.55 : 1)
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(.green)
        case .active, .pending:
            ZStack {
                Circle()
                    .fill(status == .active
                        ? Color.accentColor.opacity(0.18)
                        : Color.secondary.opacity(0.14))
                Text("\(index)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(status == .active ? Color.accentColor : .secondary)
            }
            .frame(width: 21, height: 21)
        }
    }
}
