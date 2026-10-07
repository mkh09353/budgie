import AppKit
import SwiftUI
import XCTest
@testable import Budgie

/// Renders the popover in each state to PNGs for design review:
/// BUDGIE_RENDER_POPOVER=/some/dir swift test --filter PopoverSnapshotTests
@MainActor
final class PopoverSnapshotTests: XCTestCase {
    func testRenderPopoverStates() throws {
        guard let output = ProcessInfo.processInfo.environment["BUDGIE_RENDER_POPOVER"] else {
            throw XCTSkip("Set BUDGIE_RENDER_POPOVER to a directory to render the popover")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let meetings = [
            MeetingSummary(folder: URL(fileURLWithPath: "/tmp/a"), started: now.addingTimeInterval(-3_000),
                           duration: 2_530, preview: "Okay, let's get started. Thanks everyone for joining the weekly sync.",
                           hasTranscript: true),
            MeetingSummary(folder: URL(fileURLWithPath: "/tmp/b"), started: now.addingTimeInterval(-90_000),
                           duration: 1_810, preview: "Hi, thanks for joining. Can you hear me okay?",
                           hasTranscript: true),
            MeetingSummary(folder: URL(fileURLWithPath: "/tmp/c"), started: now.addingTimeInterval(-200_000),
                           duration: 640, preview: nil, hasTranscript: false)
        ]
        let recent = [
            Transcription(text: "Can you send me the deck before the call tomorrow?", date: now.addingTimeInterval(-120)),
            Transcription(text: "Let's push the release candidate to the twenty first.", date: now.addingTimeInterval(-900)),
            Transcription(text: "Sounds good, I'll take a look tonight.", date: now.addingTimeInterval(-86_400 - 600))
        ]
        let history: [MeetingLevels] = (0..<AppState.meetingLevelHistoryLength).map { (i: Int) -> MeetingLevels in
            let me: Float = i < 20 ? Float(abs(sin(Double(i) * 0.7))) * 0.8 : 0.02
            let them: Float = i >= 22 ? Float(abs(sin(Double(i) * 0.9))) * 0.9 : 0
            return MeetingLevels(me: me, them: them)
        }

        let states: [(String, (AppState) -> Void)] = [
            ("idle", { _ in }),
            ("recording", { s in
                s.meeting = .recording(started: now.addingTimeInterval(-754))
                s.meetingLevelHistory = history
                s.meetingProgress = MeetingLiveProgress(through: 720, lastLine: TranscriptLine(
                    speaker: .them, start: 700, end: 712,
                    text: "Okay, so if we move the launch to the twenty first, does that give design enough time to finish the onboarding pass?"
                ))
            }),
            ("recording-first-minute", { s in
                s.meeting = .recording(started: now.addingTimeInterval(-21))
                s.meetingLevelHistory = Array(history.prefix(12))
            }),
            ("processing", { s in s.meeting = .processing(.transcribingThem) }),
            ("failed", { s in
                s.meeting = .failed("Transcription failed. The recording is saved.",
                                    folder: URL(fileURLWithPath: "/tmp/c"))
            }),
            ("dictating-during-meeting", { s in
                s.meeting = .recording(started: now.addingTimeInterval(-61))
                s.meetingLevelHistory = history
                s.meetingProgress = MeetingLiveProgress(through: 60, lastLine: nil)
                s.dictation = .recording
                s.recordingStarted = now.addingTimeInterval(-4)
                s.level = 0.6
            }),
            ("empty", { s in s.meetings = []; s.recent = [] }),
            ("update-ready", { s in s.update = .ready(version: "1.6.2") }),
            ("update-during-meeting", { s in
                s.update = .ready(version: "1.6.2")
                s.meeting = .recording(started: now.addingTimeInterval(-300))
                s.meetingLevelHistory = history
            }),
            ("long-history", { s in
                s.recent = (0..<20).map { i in
                    Transcription(text: "Dictation number \(i) about the plan for the week.",
                                  date: now.addingTimeInterval(Double(-i) * 7_000))
                }
            })
        ]

        for (name, configure) in states {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let state = AppState()
                state.meetings = meetings
                state.recent = recent
                state.wordsToday = 412
                state.recordingSecondsToday = 140
                configure(state)
                let view = PopoverView(
                    state: state, prefs: UserPrefs.shared,
                    meetingActions: MeetingActions(
                        start: {}, stop: {}, transcribe: { _ in }, open: { _ in },
                        copy: { _ in }, reveal: { _ in }, openFolder: {}
                    ),
                    onOpenSettings: {}, onCheckForUpdates: {}, onInstallUpdate: {}, onQuit: {}
                )
                let suffix = appearance == .aqua ? "light" : "dark"
                try render(view, appearance: appearance,
                           to: directory.appendingPathComponent("popover-\(name)-\(suffix).png"))
            }
        }
    }

    func testRenderMenuBarIcons() throws {
        guard let output = ProcessInfo.processInfo.environment["BUDGIE_RENDER_POPOVER"] else {
            throw XCTSkip("Set BUDGIE_RENDER_POPOVER to a directory to render the icons")
        }
        let icons = HStack(spacing: 24) {
            ForEach([false, true], id: \.self) { badge in
                Image(nsImage: badge ? MenuBarIcon.idleWithBadge() : MenuBarIcon.idle())
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 72, height: 72)
            }
        }
        .padding(16)
        try render(icons, size: NSSize(width: 216, height: 104), appearance: .aqua,
                   to: URL(fileURLWithPath: output).appendingPathComponent("menu-bar-icons.png"))
    }

    func testRenderMeetingsSettings() throws {
        guard let output = ProcessInfo.processInfo.environment["BUDGIE_RENDER_POPOVER"] else {
            throw XCTSkip("Set BUDGIE_RENDER_POPOVER to a directory to render the settings tab")
        }
        // The Settings window is 480x380; its tab bar takes about 50 pt.
        try render(MeetingsTab(prefs: UserPrefs.shared), size: NSSize(width: 480, height: 330),
                   appearance: .aqua,
                   to: URL(fileURLWithPath: output).appendingPathComponent("settings-meetings.png"))
    }

    /// The popover is as tall as its content, so render at its fitting size.
    private func render(_ view: PopoverView, appearance: NSAppearance.Name, to url: URL) throws {
        let probe = NSHostingView(rootView: view)
        probe.appearance = NSAppearance(named: appearance)
        // Two passes: the timeline measures its rows, then sizes itself.
        _ = probe.fittingSize
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try render(view, size: probe.fittingSize, appearance: appearance, to: url)
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
