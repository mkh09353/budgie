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
            Transcription(text: "Let's push the release candidate to the twenty first.", date: now.addingTimeInterval(-900))
        ]

        let states: [(String, (AppState) -> Void)] = [
            ("idle", { _ in }),
            ("recording", { s in
                s.meeting = .recording(started: now.addingTimeInterval(-754))
                s.meetingMicLevel = 0.55
                s.meetingSystemLevel = 0.8
            }),
            ("processing", { s in s.meeting = .processing(.transcribingThem) }),
            ("failed", { s in
                s.meeting = .failed("Transcription failed. The recording is saved.",
                                    folder: URL(fileURLWithPath: "/tmp/c"))
            }),
            ("dictating-during-meeting", { s in
                s.meeting = .recording(started: now.addingTimeInterval(-61))
                s.meetingMicLevel = 0.7
                s.dictation = .recording
                s.recordingStarted = now.addingTimeInterval(-4)
                s.level = 0.6
            }),
            ("empty", { s in s.meetings = []; s.recent = [] })
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
                    onOpenSettings: {}, onCheckForUpdates: {}, onQuit: {}
                )
                let suffix = appearance == .aqua ? "light" : "dark"
                try render(view, appearance: appearance,
                           to: directory.appendingPathComponent("popover-\(name)-\(suffix).png"))
            }
        }
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

    private func render(_ view: PopoverView, appearance: NSAppearance.Name, to url: URL) throws {
        try render(view, size: PopoverView.size, appearance: appearance, to: url)
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
