import Foundation

public struct FileItem: Equatable, Hashable {
    public let url: URL
    public let name: String
    public let displayName: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let modified: Date?
    public let kind: String

    public init(
        url: URL,
        name: String,
        displayName: String,
        isDirectory: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isHidden: Bool,
        size: Int64?,
        modified: Date?,
        kind: String
    ) {
        self.url = url
        self.name = name
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.kind = kind
    }

    public func replacingSize(_ size: Int64?) -> FileItem {
        FileItem(
            url: url,
            name: name,
            displayName: displayName,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isHidden: isHidden,
            size: size,
            modified: modified,
            kind: kind
        )
    }

    /// A folder the list can open by navigating into it. Packages stay files.
    public var opensAsFolder: Bool {
        isDirectory && !isPackage
    }

    /// Real directories, including packages. Symlinks are left alone so a link cannot be counted twice.
    public var measuresSize: Bool {
        isDirectory && !isSymbolicLink
    }

    /// Symlinks stay out of the tree so a link back to a parent cannot expand forever.
    public var appearsInTree: Bool {
        opensAsFolder && !isSymbolicLink
    }
}

public enum SortColumn: String, Equatable {
    case name
    case size
    case kind
    case modified
}
