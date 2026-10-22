import XCTest
@testable import Budgie

final class SaveFormattingTests: XCTestCase {
    private func item(_ text: String, why: String? = nil,
                      at date: Date = Date(), app: String? = nil) -> SavedItem {
        SavedItem(id: UUID().uuidString, kind: .capture, text: text, why: why,
                  source: SaveSource(appName: app), createdAt: date, updatedAt: date, doneAt: nil)
    }

    func testNumberedListIndentsContinuationLines() {
        let text = SaveFormatting.numberedList([
            item("How should migrations work?"),
            item("Three things:\n- a version field\n- a resolve command"),
        ])
        XCTAssertEqual(text, """
        1. How should migrations work?
        2. Three things:
           - a version field
           - a resolve command
        """)
    }

    func testCopyWithWhy() {
        XCTAssertEqual(SaveFormatting.withWhy([item("Keep it declarative", why: "for the RFC")]),
                       "Keep it declarative\n\nWhy: for the RFC")
        XCTAssertEqual(SaveFormatting.withWhy([item("a", why: "x"), item("b")]),
                       "1. a\n   Why: x\n2. b")
    }

    func testTextFragmentForShortSelection() {
        let url = SaveFormatting.textFragmentURL(page: "https://example.com/post",
                                                 text: "keep the core, declarative")
        XCTAssertEqual(url?.absoluteString,
                       "https://example.com/post#:~:text=keep%20the%20core%2C%20declarative")
    }

    func testTextFragmentUsesStartAndEndForLongSelections() {
        let text = "My strongest recommendation is to keep the core configuration declarative "
            + "even if you later add an optional TypeScript escape-hatch."
        let url = SaveFormatting.textFragmentURL(page: "https://claude.ai/chat/abc#top", text: text)
        XCTAssertEqual(url?.absoluteString,
                       "https://claude.ai/chat/abc#top:~:text=My%20strongest%20recommendation%20is%20to,"
                       + "add%20an%20optional%20TypeScript%20escape%2Dhatch.")
    }

    func testTextFragmentOnlyForWebPages() {
        XCTAssertNil(SaveFormatting.textFragmentURL(page: "file:///tmp/a.txt", text: "hi"))
    }

    func testDaySectionsGroupNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09 08:53 UTC
        let items = [
            item("today", at: now.addingTimeInterval(-60)),
            item("also today", at: now.addingTimeInterval(-3600)),
            item("yesterday", at: now.addingTimeInterval(-86_400)),
            item("older", at: now.addingTimeInterval(-5 * 86_400)),
        ]
        let sections = SaveFormatting.daySections(items, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title).prefix(2), ["TODAY", "YESTERDAY"])
        XCTAssertEqual(sections.map { $0.items.count }, [2, 1, 1])
    }

    func testSearchMatchesAllTermsAcrossFields() {
        let saved = item("Keep the config declarative", why: "for the RFC", app: "Claude")
        XCTAssertTrue(SaveFormatting.matches(saved, query: "claude rfc"))
        XCTAssertTrue(SaveFormatting.matches(saved, query: "  "))
        XCTAssertFalse(SaveFormatting.matches(saved, query: "claude yaml"))
    }

    func testShortAge() {
        let now = Date()
        XCTAssertEqual(SaveFormatting.shortAge(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(SaveFormatting.shortAge(now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(SaveFormatting.shortAge(now.addingTimeInterval(-7200), now: now), "2h")
    }
}
