import AppKit
import CoreGraphics
import ServiceManagement

/// A modifier key that can be held to dictate. All are tracked via
/// `flagsChanged` events, so each needs both a keycode and a modifier mask.
enum HotKey: String, CaseIterable, Identifiable {
    case rightCommand, leftCommand, rightOption, rightControl

    var id: String { rawValue }

    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand:  return 55
        case .rightOption:  return 61
        case .rightControl: return 62
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightCommand, .leftCommand: return .maskCommand
        case .rightOption:                return .maskAlternate
        case .rightControl:               return .maskControl
        }
    }

    var label: String {
        switch self {
        case .rightCommand: return "Right Command"
        case .leftCommand:  return "Left Command"
        case .rightOption:  return "Right Option"
        case .rightControl: return "Right Control"
        }
    }

    /// The symbol shown on the popover's keycap.
    var keycap: String {
        switch self {
        case .rightCommand, .leftCommand: return "⌘"
        case .rightOption:                return "⌥"
        case .rightControl:               return "⌃"
        }
    }
}

/// What happens to the transcript once it's ready.
enum InsertMode: String, CaseIterable, Identifiable {
    case type, clipboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .type:      return "Type into the active app"
        case .clipboard: return "Copy to the clipboard"
        }
    }
}

/// Which transcription backend should handle the push-to-talk session.
enum TranscriptionMode: String, CaseIterable, Identifiable {
    case standard, streaming

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:  return "Punctuated"
        case .streaming: return "Live"
        }
    }
}

/// User-changeable settings, persisted to `UserDefaults`. Distinct from
/// `Config`, which holds fixed engine/model paths.
final class UserPrefs: ObservableObject {
    static let shared = UserPrefs()
    private let d = UserDefaults.standard

    @Published var hotKey: HotKey {
        didSet { d.set(hotKey.rawValue, forKey: "hotKey") }
    }
    @Published var insertMode: InsertMode {
        didSet { d.set(insertMode.rawValue, forKey: "insertMode") }
    }
    @Published var transcriptionMode: TranscriptionMode {
        didSet { d.set(transcriptionMode.rawValue, forKey: "transcriptionMode") }
    }
    @Published var playSounds: Bool {
        didSet { d.set(playSounds, forKey: "playSounds") }
    }
    @Published var showLabel: Bool {
        didSet { d.set(showLabel, forKey: "showLabel") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    private init() {
        hotKey = HotKey(rawValue: d.string(forKey: "hotKey") ?? "") ?? .rightCommand
        insertMode = InsertMode(rawValue: d.string(forKey: "insertMode") ?? "") ?? .type
        transcriptionMode = TranscriptionMode(
            rawValue: d.string(forKey: "transcriptionMode") ?? ""
        ) ?? .streaming
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        showLabel = d.bool(forKey: "showLabel")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Budgie: launch-at-login toggle failed: \(error)")
        }
    }
}
