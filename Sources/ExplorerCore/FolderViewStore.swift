import Foundation
import SQLite3

/// The view the user picked for a folder. Folders with no row use the item-count default.
public final class FolderViewStore {
    /// 0...15 items open as icons. More than that opens as details.
    public static let iconLimit = 15

    public static func automaticView(itemCount: Int) -> String {
        itemCount <= iconLimit ? "icons" : "details"
    }

    private var views: [String: String] = [:]
    private let database: FolderViewDatabase?

    public init(databaseURL: URL) {
        let folder = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = FolderViewDatabase(url: databaseURL)
        self.database = database
        views = database?.loadAll() ?? [:]
    }

    public func view(for url: URL) -> String? {
        views[FolderSizeIndex.cacheKey(for: url)]
    }

    public func remember(_ url: URL, view: String) {
        let path = FolderSizeIndex.cacheKey(for: url)
        views[path] = view
        database?.save([(path, view)])
    }

    /// Keeps a saved view when a folder is renamed or moved, including views saved for its children.
    public func retarget(from: URL, to: URL) {
        let source = FolderSizeIndex.cacheKey(for: from)
        let destination = FolderSizeIndex.cacheKey(for: to)
        guard source != destination else { return }
        let keys = views.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
        guard !keys.isEmpty else { return }
        var removed: [String] = []
        var saved: [(String, String)] = []
        for key in keys {
            guard let view = views.removeValue(forKey: key) else { continue }
            let path = destination + key.dropFirst(source.count)
            views[path] = view
            removed.append(key)
            saved.append((path, view))
        }
        database?.delete(paths: removed)
        database?.save(saved)
    }

    public func forget(_ url: URL) {
        let path = FolderSizeIndex.cacheKey(for: url)
        let keys = views.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        guard !keys.isEmpty else { return }
        for key in keys {
            views.removeValue(forKey: key)
        }
        database?.delete(paths: keys)
    }
}

/// One text value per folder path in a SQLite table. Folder views and column layouts each use one.
final class FolderViewDatabase {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "dev.framay.explorer.folder-views")
    private let table: String
    private let column: String

    init?(url: URL, table: String = "folder_view", column: String = "mode") {
        self.table = table
        self.column = column
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
                CREATE TABLE IF NOT EXISTS \(table) (
                    path TEXT PRIMARY KEY NOT NULL,
                    \(column) TEXT NOT NULL
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

    func loadAll() -> [String: String] {
        queue.sync {
            var rows: [String: String] = [:]
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT path, \(column) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return rows }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pathC = sqlite3_column_text(statement, 0),
                      let modeC = sqlite3_column_text(statement, 1) else { continue }
                rows[String(cString: pathC)] = String(cString: modeC)
            }
            return rows
        }
    }

    func save(_ rows: [(String, String)]) {
        guard !rows.isEmpty else { return }
        queue.sync {
            guard execute("BEGIN") else { return }
            var statement: OpaquePointer?
            let sql = "INSERT INTO \(table) (path, \(column)) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET \(column) = excluded.\(column)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                _ = execute("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(statement) }
            for (path, mode) in rows {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, path)
                bind(statement, 2, mode)
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
            guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE path = ?", -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                _ = execute("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(statement) }
            for path in paths {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, path)
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

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}
