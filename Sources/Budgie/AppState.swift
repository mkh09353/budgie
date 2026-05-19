import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid
import Combine

/// What the app is doing right now — drives both the menu bar icon and the popover.
enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
}

/// One finished dictation, kept for the popover's "Recent" list.
struct Transcription: Identifiable, Codable {
    var id = UUID()
    let text: String
    let date: Date
}

/// Observable state shared between the AppKit controller and the SwiftUI views.
/// The `AppDelegate` mutates it; `PopoverView` and `PreferencesView` observe it.
final class AppState: ObservableObject {
    @Published var dictation: DictationState = .idle
    /// Live microphone level, 0...1, while recording.
    @Published var level: Float = 0
    @Published var engineWarm = false
    @Published var recordingStarted: Date?

    @Published var recent: [Transcription] = []
    @Published var wordsToday = 0
    @Published var sessionsToday = 0
    @Published var lastLatencyMS = 0
    /// Seconds spent recording today — the denominator for dictation speed.
    @Published var recordingSecondsToday: Double = 0
    @Published var wordsAllTime = 0
    @Published var recordingSecondsAllTime: Double = 0

    /// Average typing speed we measure dictation against (words per minute).
    let typingWPM = 40.0

    /// How many times faster today's dictation was than typing the same text.
    /// Zero until there's enough data to be meaningful.
    var speedMultiplier: Double {
        guard recordingSecondsToday > 2, wordsToday > 2 else { return 0 }
        let effectiveWPM = Double(wordsToday) / (recordingSecondsToday / 60)
        return effectiveWPM / typingWPM
    }

    /// Time the day's words would have taken to type, minus the time actually
    /// spent dictating them. Clamped at zero.
    var timeSavedToday: TimeInterval {
        max(0, Double(wordsToday) / typingWPM * 60 - recordingSecondsToday)
    }

    var timeSavedAllTime: TimeInterval {
        max(0, Double(wordsAllTime) / typingWPM * 60 - recordingSecondsAllTime)
    }

    /// Human-readable duration: "47 sec", "14 min", "1h 12m".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) sec" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    // Live permission status, refreshed whenever the app becomes active.
    @Published var micGranted = false
    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false

    var allPermissionsGranted: Bool {
        micGranted && accessibilityGranted && inputMonitoringGranted
    }

    private let d = UserDefaults.standard
    private let recentLimit = 20

    init() {
        load()
        refreshPermissions()
    }

    // MARK: - Recording lifecycle

    func didFinish(_ text: String, latency: TimeInterval, recordingDuration: TimeInterval) {
        rolloverIfNeeded()
        recent.insert(Transcription(text: text, date: Date()), at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        wordsToday += words
        wordsAllTime += words
        sessionsToday += 1
        recordingSecondsToday += recordingDuration
        recordingSecondsAllTime += recordingDuration
        lastLatencyMS = Int(latency * 1000)
        save()
    }

    // MARK: - Permissions

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted =
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    // MARK: - Persistence

    private func load() {
        wordsToday = d.integer(forKey: "wordsToday")
        sessionsToday = d.integer(forKey: "sessionsToday")
        recordingSecondsToday = d.double(forKey: "recSecondsToday")
        wordsAllTime = d.integer(forKey: "wordsAllTime")
        recordingSecondsAllTime = d.double(forKey: "recSecondsAllTime")
        if let data = d.data(forKey: "recent"),
           let decoded = try? JSONDecoder().decode([Transcription].self, from: data) {
            recent = decoded
        }
        rolloverIfNeeded()
    }

    private func save() {
        d.set(wordsToday, forKey: "wordsToday")
        d.set(sessionsToday, forKey: "sessionsToday")
        d.set(recordingSecondsToday, forKey: "recSecondsToday")
        d.set(wordsAllTime, forKey: "wordsAllTime")
        d.set(recordingSecondsAllTime, forKey: "recSecondsAllTime")
        if let data = try? JSONEncoder().encode(recent) {
            d.set(data, forKey: "recent")
        }
    }

    /// Zeroes today's counters when the calendar day has rolled over.
    private func rolloverIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        if d.double(forKey: "statsDay") != today {
            wordsToday = 0
            sessionsToday = 0
            recordingSecondsToday = 0
            d.set(today, forKey: "statsDay")
            d.set(0, forKey: "wordsToday")
            d.set(0, forKey: "sessionsToday")
            d.set(0.0, forKey: "recSecondsToday")
        }
    }
}
