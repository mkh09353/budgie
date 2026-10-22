import AppKit
import CoreGraphics

/// Watches the global keyboard for the dictation key (right ⌘ by default) and
/// reports press / release, plus every other key press so a ⌘-chord can be
/// told apart from a bare tap. Uses a listen-only `CGEventTap`, which needs the
/// Input Monitoring privacy permission. Timestamps are seconds since boot
/// (the same clock as `ProcessInfo.systemUptime`).
final class KeyMonitor {
    private let onPress: (TimeInterval) -> Void
    private let onRelease: (TimeInterval) -> Void
    private let onOtherKey: (Int64, TimeInterval) -> Void
    private let keyCode: Int64
    private let flag: CGEventFlags

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDown = false
    private let ownPID = getpid()

    init(keyCode: Int64,
         flag: CGEventFlags,
         onPress: @escaping (TimeInterval) -> Void,
         onRelease: @escaping (TimeInterval) -> Void,
         onOtherKey: @escaping (Int64, TimeInterval) -> Void) {
        self.keyCode = keyCode
        self.flag = flag
        self.onPress = onPress
        self.onRelease = onRelease
        self.onOtherKey = onOtherKey
    }

    /// Returns false if the event tap could not be created (permission missing).
    @discardableResult
    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Budgie: could not create event tap — grant Input Monitoring and relaunch")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Tears the tap down so a fresh monitor can be created for a new hotkey.
    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        tap = nil
        keyDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap if its callback is too slow; just re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Budgie's own synthetic typing and ⌘C must never read as a chord.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ownPID) { return }
        // The event's own timestamp, not "now": the main thread can be busy
        // (starting the microphone) and a tap must still measure as a tap.
        let now = NSEvent(cgEvent: event)?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // A ⌘-click is a chord too — two quick ⌘-clicks must not save.
            onOtherKey(-1, now)
            return
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onOtherKey(code, now)
            }
            return
        }
        guard type == .flagsChanged else { return }
        guard code == keyCode else {
            // Another modifier going down (e.g. ⇧ while holding ⌘) is a chord too.
            onOtherKey(code, now)
            return
        }

        let active = event.flags.contains(flag)
        if active && !keyDown {
            keyDown = true
            onPress(now)
        } else if !active && keyDown {
            keyDown = false
            onRelease(now)
        }
    }
}
