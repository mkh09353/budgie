import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid

/// Wraps the three privacy permissions Budgie needs. The status checks are
/// cheap and safe to poll; the request calls surface the matching system
/// prompt (and register Budgie in the System Settings list, so the user has
/// something to toggle). Requests are driven one at a time by the setup
/// window instead of all at once at launch, so the dialogs never stack.
enum Permissions {
    // MARK: - Microphone

    enum MicStatus { case granted, denied, undetermined }

    static var micStatus: MicStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .notDetermined: return .undetermined
        default:             return .denied
        }
    }

    /// Shows the system microphone prompt (only does anything while the
    /// permission is undetermined; once denied, only System Settings helps).
    static func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: - Accessibility

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Prompts for Accessibility access (needed to post synthetic keystrokes)
    /// and registers Budgie in the Accessibility list.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Input Monitoring

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system Input Monitoring prompt and registers Budgie in the
    /// Input Monitoring list.
    static func requestInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - System Settings deep links

    enum SettingsPane: String {
        case microphone      = "Privacy_Microphone"
        case accessibility   = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func openSettings(_ pane: SettingsPane) {
        let str = "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        if let url = URL(string: str) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Relaunch

    /// Relaunches Budgie. Input Monitoring occasionally only takes effect in a
    /// fresh process; the new instance starts before this one terminates and
    /// the setup window resumes from persisted permission state.
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
