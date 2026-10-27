import Foundation
import SQLite3

/// One row per directory the explorer has measured. The in-memory index is the live copy.
final class FolderSizeDatabase {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "dev.framay.explorer.folder-sizes")

    init?(url: URL) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        db = handle
        sqlite3_busy_timeout(handle, 1000)
        guard execute("PRAGMA journal_mode=WAL"),
              execute("PRAGMA synchronous=NORMAL"),
              execute(
                """
                CREATE TABLE IF NOT EXISTS folder_size (
                    path TEXT PRIMARY KEY NOT NULL,
                    bytes INTEGER NOT NULL,
                    computed_at REAL NOT NULL
                )
                """
              )
        else {
            sqlite3_close(handle)
            db = nil
            return nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func loadAll() -> [String: FolderSizeRecord] {
        queue.sync {
            var rows: [String: FolderSizeRecord] = [:]
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT path, bytes, computed_at FROM folder_size", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return rows }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cString = sqlite3_column_text(statement, 0) else { continue }
                let path = String(cString: cString)
                let bytes = sqlite3_column_int64(statement, 1)
                let stamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                rows[path] = FolderSizeRecord(bytes: bytes, computedAt: stamp)
            }
            return rows
        }
    }

    func save(_ rows: [(path: String, record: FolderSizeRecord)]) {
        guard !rows.isEmpty else { return }
        queue.sync {
            guard execute("BEGIN") else { return }
            var statement: OpaquePointer?
            let sql = "INSERT INTO folder_size (path, bytes, computed_at) VALUES (?, ?, ?) ON CONFLICT(path) DO UPDATE SET bytes = excluded.bytes, computed_at = excluded.computed_at"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                _ = execute("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(statement) }
            for row in rows {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, index: 1, text: row.path)
                sqlite3_bind_int64(statement, 2, row.record.bytes)
                sqlite3_bind_double(statement, 3, row.record.computedAt.timeIntervalSince1970)
                if sqlite3_step(statement) != SQLITE_DONE {
                    _ = execute("ROLLBACK")
                    return
                }
            }
            _ = execute("COMMIT")
        }
    }

    func delete(paths: [String]) {
        guard !paths.isEmpty else { return }
        queue.sync {
            guard execute("BEGIN") else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM folder_size WHERE path = ?", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                _ = execute("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(statement) }
            for path in paths {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, index: 1, text: path)
                if sqlite3_step(statement) != SQLITE_DONE {
                    _ = execute("ROLLBACK")
                    return
                }
            }
            _ = execute("COMMIT")
        }
    }

    private func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bind(_ statement: OpaquePointer, index: Int32, text: String) {
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}
