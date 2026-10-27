import Foundation

public enum DirectoryScanner {
    public static func scan(url: URL, showHidden: Bool) throws -> [FileItem] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey,
            .localizedTypeDescriptionKey,
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: options
        )
        let ignore = IgnoreRules.load(for: url)
        return children.compactMap { child in
            guard let item = item(at: child, keys: keys) else { return nil }
            return ignore.ignores(item.url, isDirectory: item.isDirectory) ? nil : item
        }
    }

    private static func item(at url: URL, keys: Set<URLResourceKey>) -> FileItem? {
        let name = url.lastPathComponent
        if name.isEmpty || name == "." || name == ".." { return nil }
        let values = try? url.resourceValues(forKeys: keys)
        let isPackage = values?.isPackage ?? false
        let isLink = values?.isSymbolicLink ?? false
        // isDirectory does not follow links, so a symlink to a folder looks like a file until we check the target.
        let isDirectory = (values?.isDirectory ?? false) || (isLink && targetIsDirectory(url))
        let size: Int64?
        if isDirectory && !isPackage {
            size = nil
        } else if let fileSize = values?.fileSize {
            size = Int64(fileSize)
        } else {
            size = nil
        }
        let kind = values?.localizedTypeDescription ?? fallbackKind(isDirectory: isDirectory, isPackage: isPackage)
        return FileItem(
            url: url.standardized,
            name: name,
            displayName: values?.localizedName ?? name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isLink,
            isHidden: values?.isHidden ?? name.hasPrefix("."),
            size: size,
            modified: values?.contentModificationDate,
            kind: kind
        )
    }

    private static func targetIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let resolved = url.resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func fallbackKind(isDirectory: Bool, isPackage: Bool) -> String {
        if isDirectory && !isPackage { return "Folder" }
        return "Document"
    }
}
