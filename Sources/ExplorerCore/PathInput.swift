import Foundation

public enum PathInput {
    /// The existing file or folder named by `text`. `~` is the home folder.
    /// A relative string is resolved from `current`.
    public static func resolve(_ text: String, relativeTo current: URL) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = (current.standardized.path as NSString).appendingPathComponent(expanded)
        }
        let url = URL(fileURLWithPath: absolute).standardized
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
