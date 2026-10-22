import XCTest
@testable import Budgie

final class SaveStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BudgieSaveStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent("saves.sqlite") }

    func testSavesPersistAcrossLaunchesNewestFirst() {
        let source = SaveSource(appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                                windowTitle: "Compare configuration formats",
                                url: "https://claude.ai/chat/abc",
                                documentPath: nil, surroundingText: "…around…")
        let store = SaveStore(url: databaseURL)
        store.add(text: "first", kind: .capture, source: source,
                  at: Date(timeIntervalSince1970: 1_000))
        store.add(text: "second", kind: .note, why: "  because  ",
                  at: Date(timeIntervalSince1970: 2_000))

        let reopened = SaveStore(url: databaseURL)
        XCTAssertEqual(reopened.items.map(\.text), ["second", "first"])
        XCTAssertEqual(reopened.items[0].why, "because")
        XCTAssertEqual(reopened.items[0].kind, .note)
        XCTAssertEqual(reopened.items[1].source, source)
    }

    func testDoneEditAndDelete() {
        let store = SaveStore(url: databaseURL)
        let a = store.add(text: "a", kind: .note)
        let b = store.add(text: "b", kind: .note)

        store.setDone(ids: [a.id], done: true)
        XCTAssertTrue(store.item(id: a.id)?.isDone ?? false)
        store.setDone(ids: [a.id], done: false)
        XCTAssertFalse(store.item(id: a.id)?.isDone ?? true)

        store.updateText(id: b.id, text: "b2")
        store.updateWhy(id: b.id, why: "why")
        XCTAssertEqual(store.item(id: b.id)?.text, "b2")
        XCTAssertEqual(store.item(id: b.id)?.why, "why")
        store.updateWhy(id: b.id, why: "   ")
        XCTAssertNil(store.item(id: b.id)?.why)

        store.delete(ids: [a.id])
        XCTAssertNil(store.item(id: a.id))
        XCTAssertEqual(SaveStore(url: databaseURL).items.map(\.id), [b.id])
    }

    func testClearDoneOnlyRemovesDoneItems() {
        let store = SaveStore(url: databaseURL)
        let done = store.add(text: "done", kind: .note)
        let open = store.add(text: "open", kind: .note)
        store.setDone(ids: [done.id], done: true)
        store.clearDone()
        XCTAssertEqual(store.items.map(\.id), [open.id])
    }

    func testDeletesAreTombstonesForFutureSync() throws {
        let store = SaveStore(url: databaseURL)
        let item = store.add(text: "gone", kind: .note)
        store.delete(ids: [item.id])

        let db = try SQLiteDatabase(path: databaseURL.path)
        let rows = try db.query("SELECT deleted_at, updated_at FROM saves WHERE id = ?", [item.id]) {
            ($0.double(0), $0.double(1))
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].0)
        XCTAssertEqual(rows[0].0, rows[0].1)
    }

    func testUUIDv7IsVersionedAndSortsByTime() {
        let early = UUIDv7.make(at: Date(timeIntervalSince1970: 1_700_000_000))
        let late = UUIDv7.make(at: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertLessThan(early, late)
        XCTAssertEqual(Array(early)[14], "7")
        XCTAssertNotNil(UUID(uuidString: early))
    }

    func testUnopenableFileFallsBackToMemory() {
        // A directory can't be opened as a database file.
        try? FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        let store = SaveStore(url: databaseURL)
        store.add(text: "still works", kind: .note)
        XCTAssertEqual(store.items.map(\.text), ["still works"])
    }
}
