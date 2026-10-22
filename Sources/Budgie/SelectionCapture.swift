import AppKit
import ApplicationServices

/// What was selected at the moment of a save, plus whatever accessibility
/// could say about where it came from.
struct CapturedSelection {
    /// Nil when nothing was selected.
    var text: String?
    var source: SaveSource
}

/// Reads the current selection in the frontmost app.
///
/// Accessibility is tried first: it doesn't touch the clipboard and also yields
/// the window title, page URL, file and surrounding text. Apps that don't
/// expose their selection (terminals, canvas-drawn apps, some web views) fall
/// back to a synthetic ⌘C, with the user's clipboard restored afterwards.
enum SelectionCapture {
    private static let axQueue = DispatchQueue(label: "com.maxheadley.budgie.capture")
    /// Electron apps only build their accessibility tree once asked to; we ask
    /// once per process.
    private static var manualAccessibilityPIDs = Set<pid_t>()
    private static let surroundingRadius = 240

    /// Bounds every accessibility call (not just the app element's), so a
    /// hung app can't stall captures. Setting it on the system-wide element
    /// applies process-wide.
    private static let messagingTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }()

    /// Calls `completion` on the main thread. `allowCopyFallback` is off when
    /// a synthetic ⌘C would land in Budgie's own panel.
    static func capture(allowCopyFallback: Bool = true,
                        completion: @escaping (CapturedSelection) -> Void) {
        _ = messagingTimeout
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else {
            completion(CapturedSelection(text: nil, source: .none))
            return
        }
        let pid = app.processIdentifier
        let wantsManualAccessibility = !manualAccessibilityPIDs.contains(pid)
        manualAccessibilityPIDs.insert(pid)
        var base = SaveSource()
        base.appName = app.localizedName
        base.bundleID = app.bundleIdentifier

        axQueue.async {
            let found = readAccessibility(pid: pid,
                                          enableManualAccessibility: wantsManualAccessibility,
                                          base: base)
            DispatchQueue.main.async {
                if let text = found.text, !text.isEmpty {
                    completion(found)
                } else if !allowCopyFallback {
                    completion(found)
                } else {
                    copySelection { copied in
                        completion(CapturedSelection(text: copied, source: found.source))
                    }
                }
            }
        }
    }

    // MARK: - Accessibility

    private static func readAccessibility(pid: pid_t,
                                          enableManualAccessibility: Bool,
                                          base: SaveSource) -> CapturedSelection {
        let appElement = AXUIElementCreateApplication(pid)
        if enableManualAccessibility {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString,
                                         kCFBooleanTrue)
        }

        var source = base
        if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) {
            source.windowTitle = nonEmpty(attribute(window, kAXTitleAttribute) as String?)
            if let document: String = attribute(window, kAXDocumentAttribute),
               let url = URL(string: document), url.isFileURL {
                source.documentPath = url.path
            }
        }

        guard let focused: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) else {
            return CapturedSelection(text: nil, source: source)
        }
        let selected = nonEmpty(attribute(focused, kAXSelectedTextAttribute) as String?)
        source.url = webURL(around: focused)
        source.surroundingText = surroundingText(of: focused, selected: selected)
        return CapturedSelection(text: selected, source: source)
    }

    /// Walks up from the focused element to the enclosing web area, if any.
    private static func webURL(around element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if (attribute(node, kAXRoleAttribute) as String?) == "AXWebArea" {
                if let url: URL = attribute(node, kAXURLAttribute) { return url.absoluteString }
                if let url: String = attribute(node, kAXURLAttribute) { return url }
                return nil
            }
            current = attribute(node, kAXParentAttribute)
        }
        return nil
    }

    /// A window of the field's text around the selection — for text views
    /// and editors that expose their full value.
    private static func surroundingText(of element: AXUIElement, selected: String?) -> String? {
        guard let selected,
              let value: String = attribute(element, kAXValueAttribute),
              value.utf16.count < 500_000,
              value != selected else { return nil }
        let utf16 = value.utf16
        var location: Int?
        if let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) { location = range.location }
        }
        if location == nil, let found = value.range(of: selected) {
            location = utf16.distance(from: utf16.startIndex, to: found.lowerBound)
        }
        guard let start = location else { return nil }
        let length = selected.utf16.count
        let lower = max(0, start - surroundingRadius)
        let upper = min(utf16.count, start + length + surroundingRadius)
        guard lower < upper,
              let from = utf16.index(utf16.startIndex, offsetBy: lower, limitedBy: utf16.endIndex),
              let to = utf16.index(utf16.startIndex, offsetBy: upper, limitedBy: utf16.endIndex),
              let slice = String(utf16[from..<to]) else { return nil }
        let text = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > selected.count ? text : nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - ⌘C fallback

    /// Copies the selection with a synthetic ⌘C, reads it, then puts the
    /// user's clipboard back exactly as it was.
    private static func copySelection(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        postCommandC()

        let deadline = Date().addingTimeInterval(0.35)
        // A slow app may still copy after we've given up; keep watching a
        // little longer so its copy never replaces the user's clipboard.
        let restoreDeadline = deadline.addingTimeInterval(1.0)
        var answered = false
        func poll() {
            if pasteboard.changeCount != before {
                let concealed = pasteboard.types?.contains(
                    NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false
                let text = concealed ? nil : nonEmpty(pasteboard.string(forType: .string))
                restore(saved, to: pasteboard)
                if !answered { completion(text) }
            } else if Date() >= restoreDeadline {
                return
            } else {
                if !answered && Date() >= deadline {
                    answered = true
                    completion(nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cKey: CGKeyCode = 8
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ saved: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
