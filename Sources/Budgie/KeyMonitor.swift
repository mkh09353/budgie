import AppKit
import CoreGraphics

/// Watches the global keyboard for the **right** Command key (keycode 54) and
/// reports press / release. Uses a listen-only `CGEventTap`, which needs the
/// Input Monitoring privacy permission.
final class KeyMonitor {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let keyCode: Int64
    private let flag: CGEventFlags

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDown = false

    init(keyCode: Int64,
         flag: CGEventFlags,
         onPress: @escaping () -> Void,
         onRelease: @escaping () -> Void) {
        self.keyCode = keyCode
        self.flag = flag
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Returns false if the event tap could not be created (permission missing).
    @discardableResult
    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

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
        guard type == .flagsChanged else { return }
        guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }

        let active = event.flags.contains(flag)
        if active && !keyDown {
            keyDown = true
            onPress()
        } else if !active && keyDown {
            keyDown = false
            onRelease()
        }
    }
}
