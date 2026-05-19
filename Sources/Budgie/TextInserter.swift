import CoreGraphics

/// Types text into whatever app currently has focus by synthesising keyboard
/// events. Needs the Accessibility privacy permission.
enum TextInserter {
    /// `keyboardSetUnicodeString` is only reliable for short strings, so the
    /// transcript is posted in small chunks.
    private static let chunkSize = 20

    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)

        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + chunkSize, units.count)])
            post(chunk, source: source)
            index += chunkSize
            usleep(1_500) // let the focused app keep up
        }
    }

    private static func post(_ chunk: [UniChar], source: CGEventSource?) {
        var chars = chunk
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
