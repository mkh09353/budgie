import AppKit
import SwiftUI

/// A floating, click-through panel that never takes focus — for feedback that
/// must not disturb the app the user is working in.
private final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sizes the panel to its SwiftUI content and centres it near the top of
    /// the screen the pointer is on.
    func present<Content: View>(_ content: Content, topInset: CGFloat) {
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setFrame(NSRect(x: visible.midX - size.width / 2,
                        y: visible.maxY - topInset - size.height,
                        width: size.width,
                        height: size.height),
                 display: true)
        invalidateShadow()
    }

    func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }
}

// MARK: - Saved toast

struct ToastContent {
    let title: String
    let subtitle: String?
    let bundleID: String?
    let isWarning: Bool
}

/// The "Saved · Claude · Compare configuration formats" pill after a tap·tap.
final class ToastController {
    private let panel = HUDPanel()
    private var hideWork: DispatchWorkItem?

    func show(_ content: ToastContent) {
        hideWork?.cancel()
        panel.present(ToastView(content: content), topInset: 10)
        panel.fadeIn()
        let work = DispatchWorkItem { [weak self] in self?.panel.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (content.isWarning ? 2.4 : 1.6),
                                      execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }
}

private struct ToastView: View {
    let content: ToastContent

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.957, blue: 0.808),
                                                  Color(red: 0.98, green: 0.863, blue: 0.478)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 28, height: 28)
                    .overlay(BudgieGlyph(size: 17).foregroundStyle(Color(white: 0.15)))
                Image(systemName: content.isWarning ? "exclamationmark.circle.fill"
                                                    : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white, content.isWarning ? Color.orange : Color.green)
                    .offset(x: 4, y: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle = content.subtitle {
                    HStack(spacing: 4) {
                        AppIconView(bundleID: content.bundleID, size: 13)
                        Text(subtitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .padding(12) // room for the window shadow
        .fixedSize()
    }
}

// MARK: - Live note HUD

/// The card shown while you hold the second tap and say why you're saving.
final class NoteHUDController {
    private let panel = HUDPanel()
    private unowned let coordinator: SaveCoordinator

    init(coordinator: SaveCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        guard let state = coordinator.appState else { return }
        panel.present(NoteHUDView(coordinator: coordinator, state: state), topInset: 10)
        panel.fadeIn()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.fadeOut()
    }
}

private struct NoteHUDView: View {
    @ObservedObject var coordinator: SaveCoordinator
    @ObservedObject var state: AppState

    var body: some View {
        let note = coordinator.liveNote
        VStack(alignment: .leading, spacing: 0) {
            if let snippet = note?.snippet {
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9)))
                if let appName = note?.source.appName {
                    HStack(spacing: 5) {
                        AppIconView(bundleID: note?.source.bundleID, size: 12)
                        Text([appName, note?.source.windowTitle].compactMap { $0 }
                            .joined(separator: " · "))
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
                    .padding(.horizontal, 2)
                }
            }

            HStack {
                Text(note?.snippet == nil ? "NOTE" : "WHY")
                    .foregroundStyle(.tertiary)
                Spacer()
                if let started = note?.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let s = max(0, Int(context.date.timeIntervalSince(started)))
                        Text(String(format: "● %d:%02d", s / 60, s % 60))
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.system(size: 10, weight: .bold))
            .padding(.top, 11)
            .padding(.bottom, 4)
            .padding(.horizontal, 2)

            Group {
                if let text = note?.text, !text.isEmpty {
                    Text(text).foregroundStyle(.primary)
                } else {
                    Text(note?.snippet == nil ? "Say your note…" : "Say why you're saving this…")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 2)

            Spacer(minLength: 0)

            LevelMeter(level: state.level, bars: 22, height: 10)
                .padding(.top, 8)
                .padding(.horizontal, 2)

            HStack {
                Text("Release to save")
                Spacer()
                Keycap(text: "esc", size: 9.5)
                Text("cancel")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.horizontal, 2)
        }
        .padding(12)
        // Fixed size: the panel is sized once, and the snippet and transcript
        // arrive after it's on screen.
        .frame(width: 320, height: 250, alignment: .top)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08),
                                                                  lineWidth: 0.5))
        .padding(12)
    }
}
