import Foundation

/// Photo and video details. Missing values stay nil.
public struct MediaInfo: Equatable, Hashable {
    public var width: Int?
    public var height: Int?
    public var taken: Date?
    public var duration: Double?

    public init(width: Int? = nil, height: Int? = nil, taken: Date? = nil, duration: Double? = nil) {
        self.width = width
        self.height = height
        self.taken = taken
        self.duration = duration
    }

    /// Plain files carry none of these values, so a capture date alone does not make a file media.
    public var isMedia: Bool { width != nil || duration != nil }

    public var pixels: Int? {
        guard let width, let height else { return nil }
        return width * height
    }
}

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
    public let created: Date?
    public let accessed: Date?
    /// The permission bits, such as 0o644.
    public let permissions: Int?
    public let owner: String?
    /// nil until the details have been read. Only the media columns ask for them.
    public let media: MediaInfo?

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
        kind: String,
        created: Date? = nil,
        accessed: Date? = nil,
        permissions: Int? = nil,
        owner: String? = nil,
        media: MediaInfo? = nil
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
        self.created = created
        self.accessed = accessed
        self.permissions = permissions
        self.owner = owner
        self.media = media
    }

    public var fileExtension: String {
        isDirectory && !isPackage ? "" : (name as NSString).pathExtension.lowercased()
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
            kind: kind,
            created: created,
            accessed: accessed,
            permissions: permissions,
            owner: owner,
            media: media
        )
    }

    public func withMedia(_ media: MediaInfo) -> FileItem {
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
            kind: kind,
            created: created,
            accessed: accessed,
            permissions: permissions,
            owner: owner,
            media: media
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
    case created
    case accessed
    case ext
    case permissions
    case owner
    case dimensions
    case taken
    case duration
}
