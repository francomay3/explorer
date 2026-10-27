import Foundation

/// Folders the user pinned to the sidebar. Kept as plain paths in UserDefaults.
public final class BookmarkStore {
    public static let shared = BookmarkStore()
    public static let didChange = Notification.Name("dev.framay.explorer.bookmarksDidChange")

    private static let key = "dev.framay.explorer.bookmarks"
    private let defaults: UserDefaults
    private var paths: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paths = defaults.stringArray(forKey: Self.key) ?? []
    }

    public var urls: [URL] {
        paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func contains(_ url: URL) -> Bool {
        paths.contains(Self.key(for: url))
    }

    public func add(_ url: URL) {
        let path = Self.key(for: url)
        guard !paths.contains(path) else { return }
        paths.append(path)
        save()
    }

    public func remove(_ url: URL) {
        let path = Self.key(for: url)
        guard paths.contains(path) else { return }
        paths.removeAll { $0 == path }
        save()
    }

    /// Keeps bookmarks pointing at a folder that was renamed or moved, and at bookmarked folders inside it.
    public func retarget(from: URL, to: URL) {
        let source = Self.key(for: from)
        let destination = Self.key(for: to)
        guard source != destination else { return }
        var changed = false
        paths = paths.map { path in
            guard path == source || path.hasPrefix(source + "/") else { return path }
            changed = true
            return destination + path.dropFirst(source.count)
        }
        if changed { save() }
    }

    /// Drops bookmarks for a folder that was deleted, and for bookmarked folders inside it.
    public func forget(_ url: URL) {
        let path = Self.key(for: url)
        let before = paths.count
        paths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        if paths.count != before { save() }
    }

    private static func key(for url: URL) -> String {
        url.standardized.path
    }

    private func save() {
        defaults.set(paths, forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
