import Foundation

public enum FileActionError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case alreadyExists(String)
    case couldNotCreateFolder
    case couldNotMove
    case couldNotCopy

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return NSLocalizedString("The name can't be empty.", comment: "")
        case .invalidName:
            return NSLocalizedString("The name can't include / or :.", comment: "")
        case let .alreadyExists(name):
            return String(
                format: NSLocalizedString("An item named %@ already exists.", comment: ""),
                name
            )
        case .couldNotCreateFolder:
            return NSLocalizedString("Couldn't create the folder.", comment: "")
        case .couldNotMove:
            return NSLocalizedString("Couldn't move the items.", comment: "")
        case .couldNotCopy:
            return NSLocalizedString("Couldn't copy the items.", comment: "")
        }
    }
}

public enum FileActions {
    public static func createFolder(in directory: URL, baseName: String) throws -> URL {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw FileActionError.emptyName }
        let fileManager = FileManager.default
        var attempt = 1
        while attempt < 1000 {
            let name = attempt == 1 ? trimmed : "\(trimmed) (\(attempt))"
            let url = directory.appendingPathComponent(name, isDirectory: true)
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                return url.standardized
            }
            attempt += 1
        }
        throw FileActionError.couldNotCreateFolder
    }

    public static func rename(item: FileItem, to rawName: String) throws -> URL {
        try rename(url: item.url, to: rawName)
    }

    public static func rename(url: URL, to rawName: String) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw FileActionError.emptyName }
        if name == "." || name == ".." || name.contains("/") || name.contains(":") || name.contains("\n") {
            throw FileActionError.invalidName
        }
        if name == url.lastPathComponent { return url.standardized }

        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        let sameFileDifferentCase =
            destination.path.compare(url.path, options: [.caseInsensitive]) == .orderedSame
            && destination.path != url.path
        if FileManager.default.fileExists(atPath: destination.path), !sameFileDifferentCase {
            throw FileActionError.alreadyExists(name)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination.standardized
    }

    /// Copies into `directory`. A name that is already there becomes `name (1)`, then `name (2)`.
    /// The returned URLs are the copies, in the same order as `urls`.
    @discardableResult
    public static func duplicate(_ urls: [URL], to directory: URL) throws -> [URL] {
        let destination = directory.resolvingSymlinksInPath().standardized
        guard isWritableFolder(destination) else { throw FileActionError.couldNotCopy }
        guard !urls.isEmpty else { return [] }
        for url in urls {
            let item = url.resolvingSymlinksInPath().standardized
            if Paths.same(item, destination) || Paths.contains(directory: item, url: destination) {
                throw FileActionError.couldNotCopy
            }
        }
        var reserved = Set<String>()
        var plan: [(URL, URL)] = []
        for url in urls {
            let name = availableName(url.lastPathComponent, in: destination, reserved: reserved)
            reserved.insert(name)
            plan.append((url, destination.appendingPathComponent(name)))
        }
        var created: [URL] = []
        for (source, dest) in plan {
            try FileManager.default.copyItem(at: source, to: dest)
            created.append(dest)
        }
        return created
    }

    /// `note.txt` stays `note.txt` when the folder is free, otherwise `note.txt (1)`.
    static func availableName(_ original: String, in directory: URL, reserved: Set<String>) -> String {
        func taken(_ name: String) -> Bool {
            reserved.contains(name) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        if !taken(original) { return original }
        var number = 1
        while number < 1000 {
            let candidate = "\(original) (\(number))"
            if !taken(candidate) { return candidate }
            number += 1
        }
        return "\(original) (\(number))"
    }

    private static func isWritableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    /// False when a drop would land on itself, on a child, or in the folder that already holds the item.
    public static func canMove(_ urls: [URL], to directory: URL) -> Bool {
        let destination = directory.resolvingSymlinksInPath().standardized
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        if (try? destination.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return false }
        guard !urls.isEmpty else { return false }
        for url in urls {
            let item = url.resolvingSymlinksInPath().standardized
            if Paths.same(item, destination) { return false }
            if Paths.contains(directory: item, url: destination) { return false }
            if let parent = Paths.parent(of: item), Paths.same(parent, destination) { return false }
        }
        return true
    }

    public static func move(_ urls: [URL], to directory: URL) throws {
        let destination = directory.standardized
        guard canMove(urls, to: destination) else { throw FileActionError.couldNotMove }
        let fileManager = FileManager.default
        for url in urls {
            let name = url.lastPathComponent
            if fileManager.fileExists(atPath: destination.appendingPathComponent(name).path) {
                throw FileActionError.alreadyExists(name)
            }
        }
        for url in urls {
            try fileManager.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        }
    }

    /// Trashes every item it can. Returns the first failure after the rest have been tried.
    public static func trash(_ items: [FileItem]) -> Error? {
        var first: Error?
        for item in items {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                if first == nil { first = error }
            }
        }
        return first
    }
}
