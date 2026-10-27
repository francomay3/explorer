import Foundation

public enum Paths {
    public static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardized.path == rhs.standardized.path
    }

    /// True when `url` is `directory` or a descendant. `/Users/framay` does not contain `/Users/framay-other`.
    public static func contains(directory: URL, url: URL) -> Bool {
        let root = directory.standardized.path
        let path = url.standardized.path
        if root == path { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }

    public static func parent(of url: URL) -> URL? {
        let standard = url.standardized
        if standard.path == "/" { return nil }
        let parent = standard.deletingLastPathComponent().standardized
        if parent.path == standard.path { return nil }
        return parent
    }
}
