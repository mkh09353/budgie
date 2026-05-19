import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var prefsWindow: NSWindow?

    private let state = AppState()
    private let prefs = UserPrefs.shared
    private let recorder = AudioRecorder()
    private let engine = EngineServer()
    private var keyMonitor: KeyMonitor?

    private var busy = false
    private let workQueue = DispatchQueue(label: "com.maxheadley.budgie.work")
    private var cancellables = Set<AnyCancellable>()

    /// Drives the three-dot transcribing animation.
    private var transcribePhase = 0
    private var transcribeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildPopover()

        engine.onWarmChange = { [weak self] warm in self?.state.engineWarm = warm }
        recorder.onLevel = { [weak self] level in self?.state.level = level }

        recorder.requestMicAccess()
        Permissions.ensureAccessibility()
        restartKeyMonitor()

        // Start the engine now so the first dictation finds it already warm.
        engine.warmUp()

        // Redraw the menu bar icon whenever the state or live level changes.
        state.$dictation
            .combineLatest(state.$level)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateIcon() }
            .store(in: &cancellables)

        // Rebind the push-to-talk key when the user picks a different one.
        prefs.$hotKey
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartKeyMonitor() }
            .store(in: &cancellables)

        // The menu bar label is opt-in and can be toggled live.
        prefs.$showLabel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        state.refreshPermissions()
        // The Input Monitoring tap can only be created once the permission is
        // granted — retry here so a relaunch isn't strictly required.
        if keyMonitor == nil, state.inputMonitoringGranted {
            restartKeyMonitor()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    // MARK: - Menu bar item & popover

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        updateIcon()
    }

    private func buildPopover() {
        popover.behavior = .transient
        popover.animates = true
        let root = PopoverView(
            state: state,
            prefs: prefs,
            onOpenSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openPreferences()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        let host = NSHostingController(rootView: root)
        // Pin the size so the popover opens flush under the menu bar instead of
        // being repositioned while SwiftUI settles its fitting size.
        host.view.frame = NSRect(x: 0, y: 0, width: 312, height: 420)
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 312, height: 420)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refreshPermissions()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        switch state.dictation {
        case .idle:
            button.image = MenuBarIcon.idle()
            button.contentTintColor = nil
            button.title = prefs.showLabel ? " Budgie" : ""
        case .recording:
            button.image = MenuBarIcon.recording(level: state.level)
            button.contentTintColor = .systemRed
            button.title = prefs.showLabel ? " Listening" : ""
        case .transcribing:
            button.image = MenuBarIcon.transcribing(phase: transcribePhase)
            button.contentTintColor = nil
            button.title = prefs.showLabel ? " Working" : ""
        case .error:
            button.image = MenuBarIcon.error()
            button.contentTintColor = .systemOrange
            button.title = ""
        }
    }

    private func startTranscribeAnimation() {
        transcribeTimer?.invalidate()
        transcribeTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            self.transcribePhase += 1
            self.updateIcon()
        }
    }

    private func stopTranscribeAnimation() {
        transcribeTimer?.invalidate()
        transcribeTimer = nil
    }

    // MARK: - Preferences window

    private func openPreferences() {
        if prefsWindow == nil {
            let view = PreferencesView(state: state, prefs: prefs)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Budgie Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            prefsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Hotkey

    private func restartKeyMonitor() {
        keyMonitor?.stop()
        keyMonitor = nil

        let hotKey = prefs.hotKey
        let monitor = KeyMonitor(
            keyCode: hotKey.keyCode,
            flag: hotKey.flag,
            onPress: { [weak self] in self?.startRecording() },
            onRelease: { [weak self] in self?.stopAndTranscribe() }
        )
        if monitor.start() {
            keyMonitor = monitor
            if case .error = state.dictation { state.dictation = .idle }
        } else {
            state.dictation = .error("Grant Input Monitoring, then relaunch Budgie.")
        }
    }

    // MARK: - Dictation flow

    private func startRecording() {
        guard !busy else { return }
        recorder.start()
        state.recordingStarted = Date()
        state.dictation = .recording
    }

    private func stopAndTranscribe() {
        guard !busy, case .recording = state.dictation else {
            state.dictation = .idle
            return
        }
        let recordingDuration = state.recordingStarted
            .map { Date().timeIntervalSince($0) } ?? 0
        state.recordingStarted = nil
        guard let wav = recorder.stop() else {
            state.dictation = .idle
            return
        }

        busy = true
        state.dictation = .transcribing
        startTranscribeAnimation()
        let startedAt = Date()

        workQueue.async { [weak self] in
            guard let self else { return }
            let text = self.engine.transcribe(wav)
            try? FileManager.default.removeItem(at: wav)
            let latency = Date().timeIntervalSince(startedAt)

            DispatchQueue.main.async {
                self.busy = false
                self.stopTranscribeAnimation()
                self.state.dictation = .idle
                guard !text.isEmpty else { return }
                self.deliver(text)
                self.state.didFinish(text, latency: latency,
                                     recordingDuration: recordingDuration)
                if self.prefs.playSounds { NSSound(named: "Pop")?.play() }
            }
        }
    }

    /// Routes the finished transcript according to the user's chosen mode.
    private func deliver(_ text: String) {
        switch prefs.insertMode {
        case .type:
            TextInserter.type(text)
        case .clipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
