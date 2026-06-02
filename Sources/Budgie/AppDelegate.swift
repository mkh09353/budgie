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
    private let streamingEngine = StreamingTranscriber()
    private var keyMonitor: KeyMonitor?

    private var busy = false
    private var recordingMode: TranscriptionMode?
    private var streamingSessionActive = false
    private var streamingLiveText = ""
    private let workQueue = DispatchQueue(label: "com.maxheadley.budgie.work")
    private var cancellables = Set<AnyCancellable>()

    /// Drives the three-dot transcribing animation.
    private var transcribePhase = 0
    private var transcribeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildPopover()

        engine.onWarmChange = { [weak self] warm in
            guard let self, self.prefs.transcriptionMode == .standard else { return }
            self.state.engineWarm = warm
        }
        streamingEngine.onWarmChange = { [weak self] warm in
            guard let self, self.prefs.transcriptionMode == .streaming else { return }
            self.state.engineWarm = warm
        }
        streamingEngine.onPartial = { [weak self] partial in
            self?.applyStreamingTranscript(partial)
        }
        recorder.onLevel = { [weak self] level in self?.state.level = level }

        recorder.requestMicAccess()
        Permissions.ensureAccessibility()
        restartKeyMonitor()

        // Start the selected engine now so the first dictation finds it warm.
        activateSelectedEngine(prefs.transcriptionMode)

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

        prefs.$transcriptionMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.activateSelectedEngine(mode) }
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
        streamingEngine.shutdown(wait: true)
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

    private func activateSelectedEngine(_ mode: TranscriptionMode) {
        state.engineWarm = false
        switch mode {
        case .standard:
            streamingEngine.shutdown()
            engine.warmUp()
        case .streaming:
            engine.shutdown()
            streamingEngine.warmUp()
        }
    }

    // MARK: - Dictation flow

    private func startRecording() {
        guard !busy else { return }
        let mode = prefs.transcriptionMode
        recordingMode = mode
        if mode == .streaming {
            streamingSessionActive = true
            streamingLiveText = ""
            streamingEngine.beginSession()
            recorder.onBuffer = { [weak self] buffer in
                self?.streamingEngine.append(buffer)
            }
        } else {
            recorder.onBuffer = nil
        }
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
        let mode = recordingMode ?? prefs.transcriptionMode
        recordingMode = nil
        let wav = recorder.stop(shouldWriteWav: mode == .standard)
        recorder.onBuffer = nil

        guard recordingDuration >= Config.minRecordingSeconds else {
            if mode == .streaming { streamingEngine.cancelSession() }
            streamingSessionActive = false
            streamingLiveText = ""
            state.dictation = .idle
            return
        }
        if mode == .standard, wav == nil {
            state.dictation = .idle
            return
        }

        busy = true
        state.dictation = .transcribing
        startTranscribeAnimation()
        let startedAt = Date()

        workQueue.async { [weak self] in
            guard let self else { return }
            let text: String
            let errorMessage: String?
            switch mode {
            case .standard:
                text = wav.map { self.engine.transcribe($0) } ?? ""
                errorMessage = nil
            case .streaming:
                do {
                    text = try self.streamingEngine.finish()
                    errorMessage = nil
                } catch {
                    NSLog("Budgie: streaming transcription failed: \(error)")
                    text = ""
                    errorMessage = self.streamingErrorMessage(error)
                }
            }
            if let wav { try? FileManager.default.removeItem(at: wav) }
            let latency = Date().timeIntervalSince(startedAt)

            DispatchQueue.main.async {
                self.busy = false
                self.stopTranscribeAnimation()
                if let errorMessage {
                    self.streamingSessionActive = false
                    self.state.dictation = .error(errorMessage)
                    return
                }
                self.state.dictation = .idle
                let finalText = mode == .streaming && text.isEmpty
                    ? self.streamingLiveText
                    : text
                guard !finalText.isEmpty else {
                    self.streamingSessionActive = false
                    self.streamingLiveText = ""
                    return
                }
                if mode == .streaming {
                    self.applyStreamingTranscript(finalText)
                    self.streamingSessionActive = false
                    self.streamingLiveText = ""
                } else {
                    self.deliver(finalText)
                }
                self.state.didFinish(finalText, latency: latency,
                                     recordingDuration: recordingDuration)
                if self.prefs.playSounds { NSSound(named: "Pop")?.play() }
            }
        }
    }

    private func streamingErrorMessage(_ error: Error) -> String {
        if let error = error as? StreamingTranscriberError {
            switch error {
            case .modelDirectoryMissing:
                return "Install the Streaming model in models/nemotron_coreml_560ms."
            case .notLoaded:
                break
            }
        }
        return "Streaming transcription failed."
    }

    private func applyStreamingTranscript(_ text: String) {
        guard streamingSessionActive else { return }
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }

        switch prefs.insertMode {
        case .type:
            replaceTypedStreamingText(with: transcript)
        case .clipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            streamingLiveText = transcript
        }
    }

    private func replaceTypedStreamingText(with transcript: String) {
        let sharedPrefix = commonPrefixLength(streamingLiveText, transcript)
        let oldTail = streamingLiveText.dropFirst(sharedPrefix)
        let newTail = transcript.dropFirst(sharedPrefix)

        if !oldTail.isEmpty {
            TextInserter.deleteBackward(oldTail.count)
        }
        if !newTail.isEmpty {
            TextInserter.type(String(newTail))
        }
        streamingLiveText = transcript
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
            count += 1
            left = lhs.index(after: left)
            right = rhs.index(after: right)
        }
        return count
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
