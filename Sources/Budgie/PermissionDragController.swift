import AppKit
import SwiftUI

/// A nonactivating companion to System Settings. The payload is the running
/// app's file URL, just like dragging Budgie from Finder, never a promised file.
final class PermissionDragController {
    static let shared = PermissionDragController()

    private var panel: NSPanel?
    private var timer: Timer?
    private var pane: Permissions.SettingsPane?
    private var presentation: PermissionDragPresentation?
    private var settingsFrame: NSRect?
    private var completedAt: Date?

    func show(for pane: Permissions.SettingsPane) {
        dismiss(animated: false)
        guard pane != .microphone else { return }
        self.pane = pane
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.title = "Budgie permission helper"
        panel.appearance = NSAppearance(named: .vibrantDark)
        let presentation = PermissionDragPresentation(
            title: pane == .accessibility ? "Accessibility" : "Input Monitoring",
            appURL: Self.draggableApplicationURL(Bundle.main.bundleURL))
        self.presentation = presentation
        panel.contentView = NSHostingView(rootView: PermissionDragView(
            presentation: presentation, onClose: { [weak self] in self?.dismiss() }))
        self.panel = panel
        positionPanel(animated: false)
        let destination = panel.frame.origin
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion { panel.setFrameOrigin(NSPoint(x: destination.x, y: destination.y - 6)) }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.22
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(destination)
        }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // A command-line build is not an app users can add to a privacy list.
    static func draggableApplicationURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
        else { return nil }
        return url
    }

    func dismiss(animated: Bool = true) {
        timer?.invalidate()
        timer = nil
        let closingPanel = panel
        panel = nil
        pane = nil
        presentation = nil
        completedAt = nil
        settingsFrame = nil
        guard let closingPanel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0
            closingPanel.animator().alphaValue = 0
        } completionHandler: {
            closingPanel.close()
        }
    }

    private func refresh() {
        guard let pane, let presentation, presentation.phase != .dragging else { return }
        positionPanel(animated: true)
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").isEmpty {
            dismiss()
            return
        }
        if let completedAt {
            if Date().timeIntervalSince(completedAt) > 1.4 { dismiss() }
            return
        }
        let granted = pane == .accessibility
            ? Permissions.accessibilityGranted : Permissions.inputMonitoringGranted
        if granted {
            completedAt = Date()
            presentation.phase = .granted
        }
    }

    private func positionPanel(animated: Bool) {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 24)
        // Window bounds are available without reading screen pixels or asking
        // for Accessibility. Fall back to the screen edge when unavailable.
        if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let window = windows.first(where: {
               guard ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                     ($0[kCGWindowLayer as String] as? Int) == 0,
                     let bounds = $0[kCGWindowBounds as String] as? NSDictionary,
                     let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
               return frame.width >= 500 && frame.height >= 400
           }),
           let bounds = window[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: bounds),
           let primary = NSScreen.screens.first {
            let appKitRect = NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
            let target = NSScreen.screens.first(where: { $0.frame.intersects(appKitRect) }) ?? screen
            let area = target.visibleFrame
            guard settingsFrame != appKitRect else { return }
            settingsFrame = appKitRect
            origin.x = min(max(appKitRect.maxX - panel.frame.width - 18, area.minX + 12),
                           area.maxX - panel.frame.width - 12)
            origin.y = min(max(appKitRect.minY + 14, area.minY + 12),
                           area.maxY - panel.frame.height - 12)
        } else if panel.isVisible {
            return
        }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().setFrameOrigin(origin)
            }
        } else {
            panel.setFrameOrigin(origin)
        }
    }
}

final class PermissionDragPresentation: ObservableObject {
    enum Phase { case ready, dragging, waiting, granted }
    let title: String
    let appURL: URL?
    @Published var phase: Phase = .ready

    init(title: String, appURL: URL?) {
        self.title = title
        self.appURL = appURL
    }

    func dragEnded(_ operation: NSDragOperation) {
        phase = operation.isEmpty ? .ready : .waiting
    }
}

private struct PermissionDragView: View {
    @ObservedObject var presentation: PermissionDragPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let onClose: () -> Void

    private var granted: Bool { presentation.phase == .granted }
    private var heading: String {
        if granted { return "\(presentation.title) enabled" }
        if presentation.phase == .waiting { return "Switch Budgie on in the list above" }
        return "Drag Budgie into the \(presentation.title) list"
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: granted ? "checkmark.circle.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(granted ? Color.green : .white.opacity(0.85))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                Text(heading)
                    .font(.system(size: 11, weight: .medium))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss permission helper")
                .help("Dismiss")
            }
            if let appURL = presentation.appURL {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable().frame(width: 24, height: 24)
                    Text("Budgie").font(.system(size: 12, weight: .medium))
                    Spacer()
                    if granted {
                        Text("All set").font(.system(size: 11)).foregroundStyle(.green)
                    } else {
                        Image(systemName: "line.2.horizontal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.4))
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 36)
                .background(.white.opacity(hovering && !granted ? 0.14 : 0.07),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(hovering && !granted ? 0.18 : 0.06)))
                .overlay {
                    if !granted {
                        AppDragSource(appURL: appURL,
                            onDragChanged: { if $0 { presentation.phase = .dragging } },
                            onDragEnded: { presentation.dragEnded($0) })
                    }
                }
                .opacity(presentation.phase == .dragging ? 0.5 : 1)
                .onHover { hovering = $0 }
                .help("Drag Budgie into the list, then enable its switch. If already listed, just switch it on.")
            } else {
                Text("Use + in System Settings to choose Budgie.app.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 380, height: 88)
        .background(PermissionHelperMaterial().overlay(.black.opacity(0.22)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: presentation.phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

private struct PermissionHelperMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.appearance = NSAppearance(named: .vibrantDark)
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct AppDragSource: NSViewRepresentable {
    let appURL: URL
    let onDragChanged: (Bool) -> Void
    let onDragEnded: (NSDragOperation) -> Void

    func makeNSView(context: Context) -> AppDragSourceView { AppDragSourceView() }
    func updateNSView(_ view: AppDragSourceView, context: Context) {
        view.appURL = appURL
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("Budgie application. Drag into the permission list in System Settings.")
    }
}

final class AppDragSourceView: NSView, NSDraggingSource {
    var appURL: URL?
    var onDragChanged: (Bool) -> Void = { _ in }
    var onDragEnded: (NSDragOperation) -> Void = { _ in }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let item = makeDraggingItem(at: point) else { return }
        onDragChanged(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func makeDraggingItem(at point: NSPoint) -> NSDraggingItem? {
        guard let appURL else { return nil }
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                              contents: NSWorkspace.shared.icon(forFile: appURL.path))
        return item
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragChanged(false)
        onDragEnded(operation)
        // A successful drop is not proof of permission. Only TCC checks above
        // can advance setup, including when the user cancels authentication.
    }
}
