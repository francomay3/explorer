import Foundation

/// Which columns the details list shows for a folder, in order, with their widths.
/// Folders with no entry use the default columns.
public final class FolderColumnStore {
    private var layouts: [String: [ColumnSetting]] = [:]
    private let database: FolderViewDatabase?

    public init(databaseURL: URL) {
        let folder = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = FolderViewDatabase(url: databaseURL, table: "folder_columns", column: "layout")
        self.database = database
        for (path, json) in database?.loadAll() ?? [:] {
            if let data = json.data(using: .utf8), let layout = try? JSONDecoder().decode([ColumnSetting].self, from: data) {
                layouts[path] = layout
            }
        }
    }

    public func layout(for url: URL) -> [ColumnSetting]? {
        layouts[FolderSizeIndex.cacheKey(for: url)]
    }

    public func save(_ layout: [ColumnSetting], for url: URL) {
        let path = FolderSizeIndex.cacheKey(for: url)
        layouts[path] = layout
        guard let data = try? JSONEncoder().encode(layout), let json = String(data: data, encoding: .utf8) else { return }
        database?.save([(path, json)])
    }

    public func reset(_ url: URL) {
        let path = FolderSizeIndex.cacheKey(for: url)
        guard layouts.removeValue(forKey: path) != nil else { return }
        database?.delete(paths: [path])
    }

    /// Keeps a layout when a folder is renamed or moved, including layouts saved for its children.
    public func retarget(from: URL, to: URL) {
        let source = FolderSizeIndex.cacheKey(for: from)
        let destination = FolderSizeIndex.cacheKey(for: to)
        guard source != destination else { return }
        let keys = layouts.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
        guard !keys.isEmpty else { return }
        var removed: [String] = []
        for key in keys {
            guard let layout = layouts.removeValue(forKey: key) else { continue }
            let path = destination + key.dropFirst(source.count)
            layouts[path] = layout
            removed.append(key)
            if let data = try? JSONEncoder().encode(layout), let json = String(data: data, encoding: .utf8) {
                database?.save([(path, json)])
            }
        }
        database?.delete(paths: removed)
    }

    public func forget(_ url: URL) {
        let path = FolderSizeIndex.cacheKey(for: url)
        let keys = layouts.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        guard !keys.isEmpty else { return }
        for key in keys { layouts.removeValue(forKey: key) }
        database?.delete(paths: keys)
    }
}
