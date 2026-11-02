import AppKit
import SwiftUI
import Combine
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: SavedPanelController!
    private var prefsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    /// Installs a downloaded update and relaunches; set once Sparkle has one.
    private var installUpdate: (() -> Void)?

    private let state = AppState()
    private let prefs = UserPrefs.shared
    private let recorder = AudioRecorder()
    private let engine = StandardTranscriber()
    private let streamingEngine = StreamingTranscriber()
    private var keyMonitor: KeyMonitor?
    private let meetingRecorder = MeetingRecorder()
    private var meetingFolder: URL?
    private var meetingTranscriber: MeetingLiveTranscriber?
    private var meetingClock: Timer?
    private let meetingQueue = DispatchQueue(label: "com.maxheadley.budgie.meeting", qos: .userInitiated)

    private let saveStore = SaveStore()
    private lazy var saveCoordinator = SaveCoordinator(store: saveStore, prefs: prefs)
    private var gesture = HotKeyGesture()
    private var gestureTimer: DispatchWorkItem?

    private var busy = false
    private var recordingMode: TranscriptionMode?
    private var streamingSessionActive = false
    private var streamingLiveText = ""
    /// Where the transcript of the current recording goes.
    private var dictationTarget: DictationTarget = .focusedApp
    /// Live text is held back until the press is known to be a hold, so a
    /// tap (the start of a double tap) never types anything.
    private var typingHeld = false
    private var heldPartial: String?
    /// A tap-length recording, kept until we know whether a second tap follows.
    private var pausedTake: Take?
    private var punctuatedPreparationID: UUID?
    private let workQueue = DispatchQueue(label: "com.maxheadley.budgie.work")
    private var cancellables = Set<AnyCancellable>()

    /// The latest dictation-key press: its event timestamp, and when the main
    /// thread handled it. Recording only ever starts from a press.
    private var lastPress: (pressed: TimeInterval, handled: TimeInterval)?
    /// Timings of the dictation being recorded, logged when it stops.
    private var startTrace: DictationStartTrace?
    private let watchdog = MainThreadWatchdog()

    /// Drives the three-dot transcribing animation.
    private var transcribePhase = 0
    private var transcribeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStarted = Log.uptime
        let info = Bundle.main.infoDictionary
        Log.info(.app, "Budgie \(info?["CFBundleShortVersionString"] as? String ?? "dev") "
            + "(\(info?["CFBundleVersion"] as? String ?? "?")) launching on macOS "
            + "\(ProcessInfo.processInfo.operatingSystemVersionString), "
            + "\(ProcessInfo.processInfo.activeProcessorCount) cores, "
            + "\(prefs.transcriptionMode.label) mode, diagnostic logging \(Log.verbose ? "on" : "off")")
        _ = updaterController
        buildStatusItem()
        buildPanel()

        engine.onWarmChange = { [weak self] warm in
            guard let self, self.prefs.transcriptionMode == .standard else { return }
            self.state.engineWarm = warm
        }
        streamingEngine.onWarmChange = { [weak self] warm in
            guard let self, self.prefs.transcriptionMode == .streaming else { return }
            self.state.engineWarm = warm
        }
        streamingEngine.onPartial = { [weak self] partial in
            guard let self else { return }
            if self.startTrace != nil, self.startTrace?.firstText == nil {
                self.startTrace?.firstText = Log.uptime
            }
            self.applyStreamingTranscript(partial)
        }
        recorder.onLevel = { [weak self] level in self?.state.level = level }
        recorder.onFirstBuffer = { [weak self] heard in
            guard let self, self.startTrace != nil, self.startTrace?.firstAudio == nil else { return }
            self.startTrace?.firstAudio = heard
        }
        meetingRecorder.onLevels = { [weak self] me, them in
            self?.state.recordMeetingLevels(me: me, them: them)
        }
        reloadMeetings()

        // Permissions are requested by the setup window — one at a time, in
        // order — instead of stacking three system dialogs here at launch.
        state.refreshPermissions()
        if state.inputMonitoringGranted {
            restartKeyMonitor()
        } else {
            // Don't try to create the tap yet: a failed attempt fires the
            // system's Input Monitoring prompt out of the setup order.
            state.dictation = .error("Finish setup to start dictating.")
        }
        refreshPunctuatedModelStatus()
        StandardTranscriber.removeLegacyModels()

        // Start the selected engine now so the first dictation finds it warm.
        if prefs.transcriptionMode == .standard && !StandardTranscriber.standardModelAvailable {
            prefs.transcriptionMode = .streaming
            activateSelectedEngine(.streaming)
            preparePunctuatedMode()
        } else {
            activateSelectedEngine(prefs.transcriptionMode)
        }

        // Redraw the menu bar icon whenever the state or live level changes.
        state.$dictation
            .combineLatest(state.$level, state.$meeting, state.$update)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.updateIcon() }
            .store(in: &cancellables)

        prefs.$meetingsFolder
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadMeetings() }
            .store(in: &cancellables)

        prefs.$saveGestureEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.gesture.savingEnabled = enabled
            }
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

        prefs.$diagnosticLogging
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.watchdog.setRunning(on || Log.forcedByEnvironment) }
            .store(in: &cancellables)

        // The menu bar label is opt-in and can be toggled live.
        prefs.$showLabel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        // Create the event tap the moment Input Monitoring is granted — the
        // setup window polls permissions while it's open, so this usually
        // fires seconds after the user flips the toggle, no relaunch needed.
        state.$inputMonitoringGranted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                guard let self, granted, self.keyMonitor == nil else { return }
                self.restartKeyMonitor()
            }
            .store(in: &cancellables)

        // First run (or any permission lost since): walk the user through it.
        if !prefs.onboardingCompleted || !state.allPermissionsGranted {
            openOnboarding()
        }
        Log.info(.app, "launched in \(Log.ms(Log.uptime - launchStarted)); "
            + "key monitor \(keyMonitor == nil ? "NOT running" : "running"), "
            + "input \(AudioRecorder.defaultInputDescription())")
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
        // Close the WAV files so the recording survives; it can be
        // transcribed from the Saved panel on the next launch.
        if state.meeting.isRecording { finishMeetingRecording() }
        engine.shutdown()
        streamingEngine.shutdown(wait: true)
    }

    // MARK: - Menu bar item & Saved panel

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
        }
        updateIcon()
    }

    private func buildPanel() {
        let model = SavedListModel(store: saveStore,
                                   coordinator: saveCoordinator,
                                   state: state,
                                   prefs: prefs)
        model.onOpenSettings = { [weak self] in self?.openPreferences() }
        model.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        model.onInstallUpdate = { [weak self] in self?.installPendingUpdate() }
        model.onPasteLastDictation = { [weak self] in self?.pasteLastDictation() }
        model.meetingActions = MeetingActions(
            start: { [weak self] in self?.startMeeting() },
            stop: { [weak self] in self?.stopMeeting() },
            transcribe: { [weak self] folder in self?.transcribeMeeting(in: folder) },
            open: { [weak self] meeting in
                self?.panelController.close()
                NSWorkspace.shared.open(meeting.transcriptURL)
            },
            copy: { meeting in
                guard let text = try? String(contentsOf: meeting.transcriptURL) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            reveal: { [weak self] meeting in
                self?.panelController.close()
                let file = meeting.hasTranscript ? meeting.transcriptURL : meeting.folder
                NSWorkspace.shared.activateFileViewerSelecting([file])
            },
            openFolder: { [weak self] in
                guard let self else { return }
                self.panelController.close()
                try? FileManager.default.createDirectory(
                    at: self.prefs.meetingsFolder, withIntermediateDirectories: true
                )
                NSWorkspace.shared.open(self.prefs.meetingsFolder)
            }
        )
        panelController = SavedPanelController(model: model, prefs: prefs)
        saveCoordinator.appState = state
        saveCoordinator.isPanelVisible = { [weak self] in
            self?.panelController.isVisible ?? false
        }
        saveCoordinator.isPanelKey = { [weak self] in
            self?.panelController.isKey ?? false
        }
    }

    @objc private func togglePanel() {
        state.refreshPermissions()
        if !state.meeting.isBusy { reloadMeetings() }
        panelController.toggle(from: statusItem.button)
    }

    /// Re-delivers the most recent dictation — for when it landed in the
    /// wrong field. The panel closes first so focus returns to that app.
    private func pasteLastDictation() {
        guard let text = state.recent.first?.text else { return }
        panelController.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.deliver(text)
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        switch state.dictation {
        case .idle:
            switch state.meeting {
            case .recording(let started):
                // Always show the timer while a meeting records, label or not:
                // it is the indicator that Budgie is capturing the call.
                button.image = MenuBarIcon.idle()
                button.contentTintColor = .systemRed
                button.title = " " + MeetingTranscript.timestamp(Date().timeIntervalSince(started))
            case .processing:
                button.image = MenuBarIcon.transcribing(phase: transcribePhase)
                button.contentTintColor = nil
                button.title = prefs.showLabel ? " Transcribing" : ""
            case .idle, .failed:
                button.image = state.update == nil ? MenuBarIcon.idle() : MenuBarIcon.idleWithBadge()
                button.contentTintColor = nil
                button.title = prefs.showLabel ? " Budgie" : ""
            }
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
        // A meeting still being transcribed keeps the animation going.
        if case .processing = state.meeting { return }
        transcribeTimer?.invalidate()
        transcribeTimer = nil
    }

    // MARK: - Meetings

    private func reloadMeetings() {
        state.meetings = MeetingLibrary.list(in: prefs.meetingsFolder)
    }

    private func startMeeting() {
        guard !state.meeting.isBusy else { return }
        guard MeetingRecorder.isSupported else {
            state.meeting = .failed("Recording meetings needs macOS 14.2 or later.", folder: nil)
            return
        }
        let started = Date()
        do {
            let folder = try MeetingLibrary.createFolder(in: prefs.meetingsFolder, started: started)
            let transcriber = MeetingLiveTranscriber(engine: engine)
            transcriber.onChunkStart = { [weak self] speaker in
                // Only shown once the meeting has stopped and its last chunks run.
                DispatchQueue.main.async {
                    guard let self, case .processing = self.state.meeting else { return }
                    self.state.meeting = .processing(speaker == .me ? .transcribingMe : .transcribingThem)
                }
            }
            transcriber.onProgress = { [weak self] progress in
                DispatchQueue.main.async {
                    guard let self, self.state.meeting.isRecording else { return }
                    self.state.meetingProgress = progress
                }
            }
            state.meetingProgress = nil
            state.meetingLevelHistory = []
            do {
                try meetingRecorder.start(in: folder, transcriber: transcriber)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            meetingFolder = folder
            meetingTranscriber = transcriber
            state.activeMeetingFolder = folder
            state.meeting = .recording(started: started)
            meetingClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateIcon()
            }
            reloadMeetings()
        } catch {
            Log.error(.meeting, "could not start meeting: \(error)")
            state.meeting = .failed("Could not start recording: \(error.localizedDescription)", folder: nil)
        }
    }

    private func stopMeeting() {
        guard state.meeting.isRecording else { return }
        let transcriber = meetingTranscriber
        guard let folder = finishMeetingRecording() else { return }
        transcribeMeeting(in: folder, live: transcriber)
    }

    /// Stops capture, closes both WAVs and records the duration. Returns the
    /// meeting's folder.
    @discardableResult
    private func finishMeetingRecording() -> URL? {
        meetingClock?.invalidate()
        meetingClock = nil
        let result = meetingRecorder.stop()
        meetingTranscriber = nil
        guard let folder = meetingFolder else { return nil }
        meetingFolder = nil
        if var info = try? MeetingLibrary.readInfo(from: folder) {
            info.duration = result.duration
            info.heardSystemAudio = result.heardSystemAudio
            info.heardMicAudio = result.heardMicAudio
            try? MeetingLibrary.writeInfo(info, to: folder)
        }
        state.meeting = .idle
        return folder
    }

    /// Saves a meeting's transcript. With `live`, only the chunks still
    /// queued are left to transcribe; without it (a retry, or if a live chunk
    /// failed) both files are transcribed from scratch.
    private func transcribeMeeting(in folder: URL, live: MeetingLiveTranscriber? = nil) {
        guard !state.meeting.isBusy else { return }
        state.meeting = .processing(.transcribingMe)
        startTranscribeAnimation()
        guard let live else {
            runMeetingJob(folder: folder) { engine, progress in
                try MeetingLibrary.transcribe(folder: folder, engine: engine, progress: progress)
            }
            return
        }
        live.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let words):
                self.runMeetingJob(folder: folder) { _, progress in
                    progress(.saving)
                    return try MeetingLibrary.save(folder: folder, me: words.me, them: words.them)
                }
            case .failure(let error):
                Log.warning(.meeting, "live meeting transcription failed, retrying from the files: \(error)")
                self.runMeetingJob(folder: folder) { engine, progress in
                    try MeetingLibrary.transcribe(folder: folder, engine: engine, progress: progress)
                }
            }
        }
    }

    private func runMeetingJob(
        folder: URL,
        _ job: @escaping (StandardTranscriber, (MeetingStage) -> Void) throws -> MeetingTranscript
    ) {
        meetingQueue.async { [weak self] in
            guard let self else { return }
            let result = Result {
                try job(self.engine) { stage in
                    DispatchQueue.main.async { self.state.meeting = .processing(stage) }
                }
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    // Only once the transcript is safely written; a failed
                    // meeting keeps its audio so it can be transcribed again.
                    if !self.prefs.keepMeetingAudio { MeetingLibrary.deleteAudio(in: folder) }
                    self.state.meeting = .idle
                    if self.prefs.playSounds { NSSound(named: "Glass")?.play() }
                case .failure(let error):
                    Log.error(.meeting, "meeting transcription failed: \(error)")
                    self.state.meeting = .failed(self.meetingErrorMessage(error), folder: folder)
                }
                self.state.activeMeetingFolder = nil
                self.state.meetingProgress = nil
                if case .transcribing = self.state.dictation {} else { self.stopTranscribeAnimation() }
                self.reloadMeetings()
            }
        }
    }

    private func meetingErrorMessage(_ error: Error) -> String {
        if case StreamingTranscriberError.modelDownloadFailed = error {
            return "Could not download the speech model. Check your connection."
        }
        if case StreamingTranscriberError.symbolMissing = error {
            return "This build's speech library is too old to transcribe meetings."
        }
        return "Transcription failed. The recording is saved."
    }

    // MARK: - Preferences window

    private func checkForUpdates() {
        panelController.close()
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    /// The Saved panel's update banner: restart into a downloaded update, or open
    /// Sparkle's window when automatic updates are off.
    private func installPendingUpdate() {
        guard !state.meeting.isBusy else { return }
        if case .ready = state.update, let installUpdate {
            panelController.close()
            installUpdate()
        } else {
            checkForUpdates()
        }
    }

    private func openPreferences() {
        if prefsWindow == nil {
            let view = PreferencesView(
                state: state,
                prefs: prefs,
                onSelectTranscriptionMode: { [weak self] mode in
                    self?.requestTranscriptionMode(mode)
                },
                onRunSetup: { [weak self] in self?.openOnboarding() },
                onCheckForUpdates: { [weak self] in
                    self?.checkForUpdates()
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
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

    // MARK: - Setup window

    private func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                state: state,
                prefs: prefs,
                onFinished: { [weak self] in
                    self?.prefs.onboardingCompleted = true
                    self?.onboardingWindow?.close()
                },
                onLater: { [weak self] in
                    self?.onboardingWindow?.close()
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 478),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Set Up Budgie"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = true
            window.delegate = self
            // The compact drag helper stays above System Settings instead.
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === onboardingWindow else { return }
        // Releasing the hosting view also cancels OnboardingView's autoconnected
        // permission timer. Keeping this closed window alive polled TCC forever.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.onboardingWindow else { return }
            window.contentView = nil
            self.onboardingWindow = nil
        }
    }

    // MARK: - Hotkey

    private func restartKeyMonitor() {
        keyMonitor?.stop()
        keyMonitor = nil
        state.keyMonitorRunning = false

        resetGesture()
        let hotKey = prefs.hotKey
        let monitor = KeyMonitor(
            keyCode: hotKey.keyCode,
            flag: hotKey.flag,
            onPress: { [weak self] time in
                guard let self else { return }
                let handled = Log.uptime
                self.lastPress = (time, handled)
                // The press waited this long for the main thread.
                if handled - time > 0.15 {
                    Log.warning(.dictation, "key press handled \(Log.ms(handled - time)) late; the main thread was busy")
                } else {
                    Log.debug(.dictation, "key down (handled after \(Log.ms(handled - time)))")
                }
                self.perform(self.gesture.press(at: time))
            },
            onRelease: { [weak self] time in
                guard let self else { return }
                Log.debug(.dictation, "key up")
                self.perform(self.gesture.release(at: time))
            },
            onOtherKey: { [weak self] keyCode, time in
                guard let self else { return }
                self.perform(self.gesture.otherKey(keyCode, at: time))
            }
        )
        if monitor.start() {
            keyMonitor = monitor
            state.keyMonitorRunning = true
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

    private func requestTranscriptionMode(_ mode: TranscriptionMode) {
        switch mode {
        case .streaming:
            punctuatedPreparationID = nil
            state.pendingTranscriptionMode = nil
            refreshPunctuatedModelStatus()
            if prefs.transcriptionMode != .streaming {
                prefs.transcriptionMode = .streaming
            }
        case .standard:
            guard prefs.transcriptionMode != .standard else { return }
            if StandardTranscriber.standardModelAvailable {
                state.punctuatedModelStatus = .ready
                state.pendingTranscriptionMode = nil
                prefs.transcriptionMode = .standard
                return
            }
            guard !state.punctuatedModelStatus.isDownloading else {
                state.pendingTranscriptionMode = .standard
                return
            }
            preparePunctuatedMode()
        }
    }

    private func preparePunctuatedMode() {
        let requestID = UUID()
        punctuatedPreparationID = requestID
        state.pendingTranscriptionMode = .standard
        state.punctuatedModelStatus = .downloading

        engine.prepareForActivation { [weak self] result in
            guard let self else { return }

            guard self.punctuatedPreparationID == requestID else {
                self.refreshPunctuatedModelStatus()
                self.engine.shutdown()
                return
            }

            self.punctuatedPreparationID = nil
            switch result {
            case .success:
                self.state.punctuatedModelStatus = .ready
                self.switchToPreparedPunctuatedModeIfPossible()
            case .failure(let error):
                self.state.punctuatedModelStatus = .failed(self.punctuatedPreparationMessage(error))
                self.state.pendingTranscriptionMode = nil
                if self.prefs.transcriptionMode != .streaming {
                    self.prefs.transcriptionMode = .streaming
                } else {
                    self.activateSelectedEngine(.streaming)
                }
            }
        }
    }

    private func refreshPunctuatedModelStatus() {
        if StandardTranscriber.standardModelAvailable {
            state.punctuatedModelStatus = .ready
        } else if !state.punctuatedModelStatus.isDownloading {
            state.punctuatedModelStatus = .unavailable
        }
    }

    private func switchToPreparedPunctuatedModeIfPossible() {
        guard state.pendingTranscriptionMode == .standard else { return }
        guard state.punctuatedModelStatus.isReady else { return }
        guard prefs.transcriptionMode != .standard else {
            state.pendingTranscriptionMode = nil
            return
        }
        guard canSwitchTranscriptionModeNow else { return }

        state.pendingTranscriptionMode = nil
        prefs.transcriptionMode = .standard
    }

    private var canSwitchTranscriptionModeNow: Bool {
        guard !busy, recordingMode == nil, !streamingSessionActive else { return false }
        if case .idle = state.dictation { return true }
        return false
    }

    // MARK: - Gesture

    /// Carries out what the gesture recognizer decided, then re-arms its timer.
    private func perform(_ actions: [HotKeyGesture.Action]) {
        if !actions.isEmpty {
            Log.debug(.dictation, "gesture: \(actions.map { "\($0)" }.joined(separator: ", "))")
        }
        for action in actions {
            switch action {
            case .beginDictation:
                startRecording(target: .focusedApp, holdTyping: true)
            case .confirmDictation:
                releaseHeldTyping()
            case .finishDictation:
                if let take = stopRecording() { transcribe(take, target: .focusedApp) }
            case .pauseDictation:
                pausedTake = stopRecording()
            case .finishPausedDictation:
                if let take = pausedTake {
                    pausedTake = nil
                    typingHeld = false
                    transcribe(take, target: .focusedApp)
                }
            case .discardDictation:
                if let take = stopRecording() { discard(take) }
                if let take = pausedTake {
                    pausedTake = nil
                    discard(take)
                }
            case .beginSave:
                saveCoordinator.beginSave()
                // Start listening now so the first words of a note aren't clipped.
                startRecording(target: .note, holdTyping: true)
            case .commitSave:
                if let take = stopRecording() { discard(take) }
                saveCoordinator.commitSave()
            case .beginNote:
                saveCoordinator.beginNote(micRunning: recordingMode != nil)
                if let partial = heldPartial { saveCoordinator.updateLiveNote(partial) }
            case .finishNote:
                let ticket = saveCoordinator.endNoteRecording()
                if let take = stopRecording() {
                    transcribe(take, target: .note, ticket: ticket)
                } else {
                    saveCoordinator.finishNote(ticket, text: nil)
                }
            case .cancelSave:
                if let take = stopRecording() { discard(take) }
                saveCoordinator.cancelSave()
            }
        }
        scheduleGestureTimer()
    }

    private func scheduleGestureTimer(retries: Int = 0) {
        gestureTimer?.cancel()
        gestureTimer = nil
        guard let deadline = gesture.deadline else { return }
        let delay = retries > 0 ? 0.015 : max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If the key's physical state disagrees with the gesture, its
            // press/release event is still queued: let it land first.
            if let expected = self.gesture.expectsKeyDown, retries < 12,
               CGEventSource.keyState(.hidSystemState,
                                      key: CGKeyCode(self.prefs.hotKey.keyCode)) != expected {
                self.scheduleGestureTimer(retries: retries + 1)
                return
            }
            self.perform(self.gesture.timerFired(at: ProcessInfo.processInfo.systemUptime))
        }
        gestureTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetGesture() {
        gestureTimer?.cancel()
        gestureTimer = nil
        gesture.reset()
        gesture.savingEnabled = prefs.saveGestureEnabled
        if let take = stopRecording() { discard(take) }
        if let take = pausedTake {
            pausedTake = nil
            discard(take)
        }
        saveCoordinator.cancelSave()
    }

    // MARK: - Dictation flow

    private enum DictationTarget {
        /// Typed into (or copied for) the focused app — ordinary dictation.
        case focusedApp
        /// The spoken "why" attached to a save.
        case note
    }

    /// A finished recording, not yet transcribed.
    private struct Take {
        let mode: TranscriptionMode
        let wav: URL?
        let duration: TimeInterval
    }

    private func startRecording(target: DictationTarget, holdTyping: Bool) {
        guard !busy, recordingMode == nil else {
            // The press does nothing, which looks like dictation not starting.
            Log.warning(.dictation, busy
                ? "press ignored: the previous dictation is still transcribing"
                : "press ignored: already recording")
            return
        }
        let press = lastPress ?? (Log.uptime, Log.uptime)
        startTrace = DictationStartTrace(pressed: press.pressed, handled: press.handled,
                                         engineWarm: state.engineWarm)
        let mode = prefs.transcriptionMode
        recordingMode = mode
        dictationTarget = target
        typingHeld = holdTyping
        heldPartial = nil
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
        startTrace?.micReady = Log.uptime
        startTrace?.mic = recorder.lastStartTiming
        state.recordingStarted = Date()
        state.dictation = .recording
    }

    /// The press turned out to be a hold: let the live transcript through.
    private func releaseHeldTyping() {
        guard typingHeld else { return }
        typingHeld = false
        if let partial = heldPartial {
            heldPartial = nil
            applyStreamingTranscript(partial)
        }
    }

    /// Stops the microphone, returning what was recorded (nil if nothing was).
    private func stopRecording() -> Take? {
        guard let mode = recordingMode else { return nil }
        let duration = state.recordingStarted.map { Date().timeIntervalSince($0) } ?? 0
        state.recordingStarted = nil
        recordingMode = nil
        let wav = recorder.stop(shouldWriteWav: mode == .standard)
        recorder.onBuffer = nil
        if let trace = startTrace {
            startTrace = nil
            let line = "dictation start (\(mode.label), held \(Log.ms(duration))): \(trace.summary)"
            if trace.isSlow {
                Log.warning(.dictation, "SLOW " + line + ", thermal state \(ProcessInfo.processInfo.thermalState.logName)"
                    + (ProcessInfo.processInfo.isLowPowerModeEnabled ? ", Low Power Mode" : ""))
            } else {
                Log.debug(.dictation, line)
            }
        }
        if case .recording = state.dictation { state.dictation = .idle }
        return Take(mode: mode, wav: wav, duration: duration)
    }

    /// Throws a recording away without transcribing it.
    private func discard(_ take: Take) {
        if take.mode == .streaming { streamingEngine.cancelSession() }
        if let wav = take.wav { try? FileManager.default.removeItem(at: wav) }
        streamingSessionActive = false
        streamingLiveText = ""
        heldPartial = nil
        switchToPreparedPunctuatedModeIfPossible()
    }

    /// `ticket` is the save a `.note` transcript belongs to.
    private func transcribe(_ take: Take, target: DictationTarget, ticket: SaveTicket? = nil) {
        guard !busy else {
            Log.warning(.dictation, "recording dropped: the previous dictation is still transcribing")
            discard(take)
            if target == .note { saveCoordinator.finishNote(ticket, text: nil) }
            return
        }
        let mode = take.mode
        let wav = take.wav
        let recordingDuration = take.duration

        guard recordingDuration >= Config.minRecordingSeconds,
              mode == .streaming || wav != nil else {
            discard(take)
            if target == .note { saveCoordinator.finishNote(ticket, text: nil) }
            return
        }

        busy = true
        dictationTarget = target
        state.dictation = .transcribing
        startTranscribeAnimation()
        let startedAt = Date()

        workQueue.async { [weak self] in
            guard let self else { return }
            var text = ""
            var errorMessage: String?
            switch mode {
            case .standard:
                do {
                    if let wav {
                        text = try self.engine.transcribe(wav)
                    }
                } catch {
                    Log.error(.dictation, "Punctuated transcription failed: \(error)")
                    errorMessage = self.standardErrorMessage(error)
                }
            case .streaming:
                do {
                    text = try self.streamingEngine.finish()
                } catch {
                    Log.error(.dictation, "Live transcription failed: \(error)")
                    errorMessage = self.streamingErrorMessage(error)
                }
            }
            if let wav { try? FileManager.default.removeItem(at: wav) }
            let latency = Date().timeIntervalSince(startedAt)
            Log.debug(.dictation, "\(mode.label) transcript ready \(Log.ms(latency)) after release"
                + (errorMessage == nil ? "" : " (failed)"))

            DispatchQueue.main.async {
                self.busy = false
                self.stopTranscribeAnimation()
                if let errorMessage {
                    self.streamingSessionActive = false
                    self.state.dictation = .error(errorMessage)
                    if target == .note { self.saveCoordinator.finishNote(ticket, text: nil) }
                    return
                }
                self.state.dictation = .idle
                // If the engine's final pass came back empty, fall back to the
                // last live text (typed, or held back while undecided).
                let liveText = self.streamingLiveText.isEmpty
                    ? (self.heldPartial ?? "")
                    : self.streamingLiveText
                let finalText = mode == .streaming && text.isEmpty ? liveText : text
                if target == .note {
                    self.streamingSessionActive = false
                    self.streamingLiveText = ""
                    self.heldPartial = nil
                    self.saveCoordinator.finishNote(ticket, text: finalText.isEmpty ? nil : finalText)
                    self.switchToPreparedPunctuatedModeIfPossible()
                    return
                }
                self.heldPartial = nil
                guard !finalText.isEmpty else {
                    self.streamingSessionActive = false
                    self.streamingLiveText = ""
                    self.switchToPreparedPunctuatedModeIfPossible()
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
                self.switchToPreparedPunctuatedModeIfPossible()
            }
        }
    }

    private func streamingErrorMessage(_ error: Error) -> String {
        if let error = error as? StreamingTranscriberError {
            switch error {
            case .libraryMissing, .libraryLoadFailed, .symbolMissing:
                return "Build parakeet.cpp in ParakeetCpp/build-shared."
            case .modelFileMissing:
                return "Install the Live model in models/realtime_eou_120m-v1-q8_0.gguf."
            case .notLoaded:
                break
            case .contextLoadFailed, .streamStartFailed, .streamFeedFailed,
                 .streamFinalizeFailed, .transcribeFailed, .resampleFailed,
                 .modelDownloadFailed, .invalidPCMBuffer:
                break
            }
        }
        return "Streaming transcription failed."
    }

    private func standardErrorMessage(_ error: Error) -> String {
        if let error = error as? StreamingTranscriberError {
            switch error {
            case .libraryMissing, .libraryLoadFailed, .symbolMissing:
                return "Build parakeet.cpp in ParakeetCpp/build-shared."
            case .modelDownloadFailed:
                return "Could not download the Punctuated model."
            case .modelFileMissing, .contextLoadFailed, .transcribeFailed:
                return "Punctuated transcription failed."
            case .notLoaded:
                break
            case .streamStartFailed, .streamFeedFailed, .streamFinalizeFailed,
                 .resampleFailed, .invalidPCMBuffer:
                break
            }
        }
        return "Punctuated transcription failed."
    }

    private func punctuatedPreparationMessage(_ error: Error) -> String {
        if let error = error as? StreamingTranscriberError {
            switch error {
            case .modelDownloadFailed:
                return "Download failed. Check your connection and try again."
            case .libraryMissing, .libraryLoadFailed, .symbolMissing:
                return "The speech library is missing from this build."
            default:
                break
            }
        }
        return "Could not prepare Punctuated mode."
    }

    private func applyStreamingTranscript(_ text: String) {
        guard streamingSessionActive else { return }
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }

        // A note's words go to the save, never into the app.
        if dictationTarget == .note {
            heldPartial = transcript
            saveCoordinator.updateLiveNote(transcript)
            return
        }
        if typingHeld {
            heldPartial = transcript
            return
        }

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

// MARK: - Updates

extension AppDelegate: SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Budgie never quits on its own, so an update installed "on quit" would
    /// wait forever. Hold it and offer Restart to Update in the Saved panel.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Log.info(.update, "update \(item.displayVersionString) downloaded, waiting for restart")
        installUpdate = immediateInstallHandler
        state.update = .ready(version: item.displayVersionString)
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if case .available = state.update { state.update = nil }
    }

    // With automatic updates off, scheduled updates show as the Saved panel's banner
    // instead of a window popping up over whatever the user is doing.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        Log.info(.update, "update \(update.displayVersionString) available")
        self.state.update = .available(version: update.displayVersionString)
    }

    func standardUserDriverWillFinishUpdateSession() {
        if case .available = state.update { state.update = nil }
    }
}

private extension ProcessInfo.ThermalState {
    var logName: String {
        switch self {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "unknown"
        }
    }
}
