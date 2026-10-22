import Foundation

/// Pure text helpers for the Saved panel: clipboard formats, links back to
/// the source, and day grouping.
enum SaveFormatting {
    /// Plain copy: each item's text, separated by a blank line.
    static func plain(_ items: [SavedItem]) -> String {
        items.map(\.text).joined(separator: "\n\n")
    }

    /// "1. first\n2. second" — ready to paste into a chat as a prompt list.
    /// Continuation lines are indented to sit under their item.
    static func numberedList(_ items: [SavedItem], includeWhy: Bool = false) -> String {
        items.enumerated().map { index, item in
            let marker = "\(index + 1). "
            let indent = String(repeating: " ", count: marker.count)
            var lines = item.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            if includeWhy, let why = item.why, !why.isEmpty {
                lines.append("Why: \(why)")
            }
            return lines.enumerated().map { lineIndex, line in
                (lineIndex == 0 ? marker : indent) + line
            }
            .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// Each item followed by its reason — for handing an AI the context too.
    static func withWhy(_ items: [SavedItem]) -> String {
        if items.count > 1 { return numberedList(items, includeWhy: true) }
        return items.map { item in
            guard let why = item.why, !why.isEmpty else { return item.text }
            return "\(item.text)\n\nWhy: \(why)"
        }
        .joined(separator: "\n\n")
    }

    /// The page URL with a text fragment (`#:~:text=`) so a browser scrolls to
    /// and highlights the saved passage. Long passages use the `start,end`
    /// form so the link survives small differences in the middle.
    static func textFragmentURL(page: String, text: String) -> URL? {
        guard var components = URLComponents(string: page),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return URL(string: page) }

        let directive: String
        if words.count <= 10 {
            directive = encodeFragmentPart(words.joined(separator: " "))
        } else {
            let start = words.prefix(5).joined(separator: " ")
            let end = words.suffix(5).joined(separator: " ")
            directive = encodeFragmentPart(start) + "," + encodeFragmentPart(end)
        }
        // Keep any existing fragment; text directives follow it after `:~:`.
        let existing = components.percentEncodedFragment.map {
            $0.components(separatedBy: ":~:").first ?? $0
        } ?? ""
        components.percentEncodedFragment = existing + ":~:text=" + directive
        return components.url
    }

    /// Percent-encodes a text-directive part. `-`, `,` and `&` are syntax in
    /// text fragments, so they're encoded on top of the usual set.
    static func encodeFragmentPart(_ s: String) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "-,&#:~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Day grouping

    struct DaySection: Identifiable, Equatable {
        let id: Date
        let title: String
        var items: [SavedItem]
    }

    /// Groups newest-first items into TODAY / YESTERDAY / dated sections.
    static func daySections(_ items: [SavedItem],
                            now: Date = Date(),
                            calendar: Calendar = .current) -> [DaySection] {
        var sections: [DaySection] = []
        for item in items {
            let day = calendar.startOfDay(for: item.createdAt)
            if let last = sections.indices.last, sections[last].id == day {
                sections[last].items.append(item)
            } else {
                sections.append(DaySection(id: day,
                                           title: dayTitle(day, now: now, calendar: calendar),
                                           items: [item]))
            }
        }
        return sections
    }

    static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "TODAY" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "YESTERDAY" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEdMMM" : "dMMMy")
        return formatter.string(from: day).uppercased()
    }

    /// "just now", "4m", "2h", or a time for older items.
    static func shortAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 6 * 3600 { return "\(Int(seconds / 3600))h" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Case-insensitive match against everything a user might remember.
    static func matches(_ item: SavedItem, query: String) -> Bool {
        let terms = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = [item.text, item.why, item.source.appName,
                        item.source.windowTitle, item.source.url]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}
