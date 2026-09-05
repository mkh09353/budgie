import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid

/// Live status for Budgie's three privacy permissions. Setup requests the
/// microphone through macOS and guides users through the other two lists
/// with an app-file drag helper, one permission at a time.
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

    // MARK: - Input Monitoring

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    // MARK: - System Settings deep links

    enum SettingsPane: String {
        case microphone      = "Privacy_Microphone"
        case accessibility   = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func openSettings(_ pane: SettingsPane) {
        PermissionDragController.shared.dismiss()
        let str = "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        if let url = URL(string: str), NSWorkspace.shared.open(url), pane != .microphone {
            PermissionDragController.shared.show(for: pane)
        }
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
