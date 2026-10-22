import Foundation
import SQLite3

/// Where a saved selection came from — whatever accessibility could tell us at
/// the moment of the save. Every field is optional: apps expose wildly
/// different amounts, and a typed note has no source at all.
struct SaveSource: Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    /// The web page the selection was on, when the app exposes one.
    var url: String?
    /// The file the selection was in, for document-based apps.
    var documentPath: String?
    /// A little of the text around the selection.
    var surroundingText: String?

    static let none = SaveSource()

    var isEmpty: Bool { self == .none }
}

/// One entry in the Saved panel.
struct SavedItem: Identifiable, Equatable {
    enum Kind: String {
        /// Grabbed from another app with the double-tap gesture.
        case capture
        /// Typed (or dictated) straight into the panel.
        case note
    }

    let id: String
    var kind: Kind
    var text: String
    /// The dictated reason it was saved.
    var why: String?
    var source: SaveSource
    let createdAt: Date
    var updatedAt: Date
    var doneAt: Date?

    var isDone: Bool { doneAt != nil }
}

/// The saved items, persisted to a local SQLite database.
///
/// The schema is sync-ready from day one so a server copy can be added later
/// without migrating local data: ids are generated on device (UUIDv7, so they
/// sort by time), every row carries `updated_at`, and deletes are tombstones
/// (`deleted_at`) rather than removed rows. All work happens on the main
/// thread — the data set is one person's notes, and each statement is sub-ms.
final class SaveStore: ObservableObject {
    /// Live (non-deleted) items, newest first.
    @Published private(set) var items: [SavedItem] = []

    private let db: SQLiteDatabase

    /// Opens (or creates) the store. Falls back to an in-memory database if the
    /// file can't be opened, so saving still works for the session.
    init(url: URL? = Config.savesDatabaseURL) {
        var opened: SQLiteDatabase?
        if let url {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                opened = try SQLiteDatabase(path: url.path)
            } catch {
                NSLog("Budgie: could not open saves database: \(error)")
            }
        }
        // `try!` is safe: an in-memory database cannot fail to open.
        db = opened ?? (try! SQLiteDatabase(path: ":memory:"))
        do {
            try migrate()
        } catch {
            NSLog("Budgie: saves database migration failed: \(error)")
        }
        reload()
    }

    // MARK: - Reads

    func item(id: String) -> SavedItem? {
        items.first { $0.id == id }
    }

    func reload() {
        do {
            items = try db.query(
                """
                SELECT id, kind, text, why, app_name, app_bundle_id, window_title,
                       url, document_path, surrounding_text,
                       created_at, updated_at, done_at
                FROM saves
                WHERE deleted_at IS NULL
                ORDER BY created_at DESC, id DESC
                """
            ) { row in
                SavedItem(
                    id: row.string(0) ?? UUID().uuidString,
                    kind: SavedItem.Kind(rawValue: row.string(1) ?? "") ?? .note,
                    text: row.string(2) ?? "",
                    why: row.string(3),
                    source: SaveSource(
                        appName: row.string(4),
                        bundleID: row.string(5),
                        windowTitle: row.string(6),
                        url: row.string(7),
                        documentPath: row.string(8),
                        surroundingText: row.string(9)
                    ),
                    createdAt: Date(timeIntervalSince1970: row.double(10) ?? 0),
                    updatedAt: Date(timeIntervalSince1970: row.double(11) ?? 0),
                    doneAt: row.double(12).map { Date(timeIntervalSince1970: $0) }
                )
            }
        } catch {
            NSLog("Budgie: could not load saves: \(error)")
        }
    }

    // MARK: - Writes

    @discardableResult
    func add(text: String,
             kind: SavedItem.Kind,
             why: String? = nil,
             source: SaveSource = .none,
             at date: Date = Date()) -> SavedItem {
        let item = SavedItem(
            id: UUIDv7.make(at: date),
            kind: kind,
            text: text,
            why: why.flatMap(Self.nonEmpty),
            source: source,
            createdAt: date,
            updatedAt: date,
            doneAt: nil
        )
        write(
            """
            INSERT INTO saves (id, kind, text, why, app_name, app_bundle_id, window_title,
                               url, document_path, surrounding_text, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [item.id, item.kind.rawValue, item.text, item.why,
             source.appName, source.bundleID, source.windowTitle,
             source.url, source.documentPath, source.surroundingText,
             date.timeIntervalSince1970, date.timeIntervalSince1970]
        )
        return item
    }

    func updateText(id: String, text: String) {
        write("UPDATE saves SET text = ?, updated_at = ? WHERE id = ?",
              [text, Self.now, id])
    }

    func updateWhy(id: String, why: String?) {
        write("UPDATE saves SET why = ?, updated_at = ? WHERE id = ?",
              [why.flatMap(Self.nonEmpty), Self.now, id])
    }

    func setDone(ids: [String], done: Bool) {
        guard !ids.isEmpty else { return }
        let now = Self.now
        transaction {
            for id in ids {
                try db.run(
                    "UPDATE saves SET done_at = ?, updated_at = ? WHERE id = ?",
                    [done ? now : nil, now, id]
                )
            }
        }
    }

    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        let now = Self.now
        transaction {
            for id in ids {
                try db.run(
                    "UPDATE saves SET deleted_at = ?, updated_at = ? WHERE id = ?",
                    [now, now, id]
                )
            }
        }
    }

    func clearDone() {
        write(
            """
            UPDATE saves SET deleted_at = ?1, updated_at = ?1
            WHERE done_at IS NOT NULL AND deleted_at IS NULL
            """,
            [Self.now]
        )
    }

    // MARK: - Internals

    private static var now: Double { Date().timeIntervalSince1970 }

    private static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func write(_ sql: String, _ values: [SQLiteValue?]) {
        do {
            try db.run(sql, values)
        } catch {
            NSLog("Budgie: saves write failed: \(error)")
        }
        reload()
    }

    private func transaction(_ body: () throws -> Void) {
        do {
            try db.exec("BEGIN")
            do {
                try body()
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        } catch {
            NSLog("Budgie: saves transaction failed: \(error)")
        }
        reload()
    }

    private func migrate() throws {
        try db.exec("PRAGMA journal_mode = WAL")
        let version = try db.query("PRAGMA user_version") { $0.int(0) ?? 0 }.first ?? 0
        if version < 1 {
            try db.exec(
                """
                CREATE TABLE IF NOT EXISTS saves (
                    id               TEXT PRIMARY KEY,
                    kind             TEXT NOT NULL,
                    text             TEXT NOT NULL,
                    why              TEXT,
                    app_name         TEXT,
                    app_bundle_id    TEXT,
                    window_title     TEXT,
                    url              TEXT,
                    document_path    TEXT,
                    surrounding_text TEXT,
                    created_at       REAL NOT NULL,
                    updated_at       REAL NOT NULL,
                    done_at          REAL,
                    deleted_at       REAL
                );
                CREATE INDEX IF NOT EXISTS saves_created_at ON saves (created_at);
                CREATE INDEX IF NOT EXISTS saves_updated_at ON saves (updated_at);
                PRAGMA user_version = 1;
                """
            )
        }
    }
}

// MARK: - UUIDv7

/// Time-ordered UUIDs (RFC 9562 version 7): a 48-bit millisecond timestamp
/// followed by random bits, so ids sort by creation time across devices.
enum UUIDv7 {
    static func make(at date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        for i in 0..<6 {
            bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70   // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                               bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11],
                               bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }
}

// MARK: - Minimal SQLite wrapper

protocol SQLiteValue {}
extension String: SQLiteValue {}
extension Double: SQLiteValue {}
extension Int: SQLiteValue {}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

/// Just enough of the C API for the saves table. Not thread-safe; the store
/// only touches it from the main thread.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Tells SQLite to copy bound strings, since Swift's buffers are temporary.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(code: rc, message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs one or more statements with no parameters.
    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw SQLiteError(code: rc, message: message)
        }
    }

    /// Runs a single statement with bound parameters.
    func run(_ sql: String, _ values: [SQLiteValue?]) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError(rc) }
    }

    func query<T>(_ sql: String,
                  _ values: [SQLiteValue?] = [],
                  map: (SQLiteRow) -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError(rc) }
            results.append(map(SQLiteRow(statement: statement)))
        }
        return results
    }

    private func prepare(_ sql: String, _ values: [SQLiteValue?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else { throw lastError(rc) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as Int:    sqlite3_bind_int64(statement, index, Int64(v))
            default:              sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func lastError(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer?

    func string(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    func double(_ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    func int(_ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }
}
