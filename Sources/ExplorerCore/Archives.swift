import Foundation

public enum ArchiveFormat: Equatable {
    case zip
    case rar
}

/// Where the contents of an archive should land, next to the archive.
public enum ExtractPlacement: Equatable {
    /// One file or one folder. Put that item beside the archive under this name.
    case alongside(String)
    /// Several items. Put them in a new folder with this name.
    case folder(String)
}

public enum ArchiveError: LocalizedError, Equatable {
    case couldNotCompress(String)
    case couldNotDecompress(String)
    case unsafePath
    case rarUnavailable

    public var errorDescription: String? {
        switch self {
        case let .couldNotCompress(detail):
            return Self.message(NSLocalizedString("Couldn't create the ZIP archive.", comment: ""), detail)
        case let .couldNotDecompress(detail):
            return Self.message(NSLocalizedString("Couldn't decompress the archive.", comment: ""), detail)
        case .unsafePath:
            return NSLocalizedString("The archive contains an unsafe path.", comment: "")
        case .rarUnavailable:
            return NSLocalizedString(
                "Couldn't decompress the RAR archive. Install unrar or 7-Zip and try again.",
                comment: ""
            )
        }
    }

    private static func message(_ base: String, _ detail: String) -> String {
        let line = detail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return base }
        let clipped = line.count > 180 ? String(line.prefix(180)) : line
        return base + " " + clipped
    }
}

public enum Archives {
    public static func format(of url: URL) -> ArchiveFormat? {
        // A folder named "notes.zip" is still a folder.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nil
        }
        switch url.pathExtension.lowercased() {
        case "zip": return .zip
        case "rar": return .rar
        default: return nil
        }
    }

    public static func canDecompress(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { format(of: $0) != nil }
    }

    /// One item keeps its name (`Photos` becomes `Photos.zip`). Several items share `Archive.zip`.
    /// A name that is already there becomes `Photos (1).zip`.
    public static func zipName(for itemNames: [String], isTaken: (String) -> Bool) -> String {
        let base = itemNames.count == 1 && itemNames[0].isEmpty == false ? "\(itemNames[0]).zip" : "Archive.zip"
        return uniqueName(base, isTaken: isTaken)
    }

    /// One top-level item is placed beside the archive. Several items go into a folder named after the archive.
    /// `__MACOSX` is Finder metadata, so it does not count as a second item. `..` is refused.
    public static func extractPlacement(
        archiveName: String,
        entries: [String],
        isTaken: (String) -> Bool
    ) throws -> ExtractPlacement {
        let names = try topLevelNames(in: entries)
        if names.count == 1, let only = names.first {
            return .alongside(uniqueName(only, isTaken: isTaken))
        }
        let stem = (archiveName as NSString).deletingPathExtension
        let folder = stem.isEmpty || stem == "." ? "Archive" : stem
        return .folder(uniqueName(folder, isTaken: isTaken))
    }

    /// Writes a zip next to the items and returns it. Symlinks are stored as links.
    @discardableResult
    public static func compress(_ urls: [URL]) throws -> URL {
        guard let first = urls.first, let parent = Paths.parent(of: first) else {
            throw ArchiveError.couldNotCompress("")
        }
        for url in urls {
            guard let itemParent = Paths.parent(of: url), Paths.same(itemParent, parent), exists(url) else {
                throw ArchiveError.couldNotCompress("")
            }
        }
        let name = zipName(for: urls.map(\.lastPathComponent)) { candidate in
            FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidate).path)
        }
        let destination = parent.appendingPathComponent(name)
        // `./` keeps a file named "-q" from being read as a switch.
        let arguments = ["-r", "-y", "-q", destination.path] + urls.map { "./\($0.lastPathComponent)" }
        do {
            try run(URL(fileURLWithPath: "/usr/bin/zip"), arguments, cwd: parent)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw rethrow(error, compress: true)
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw ArchiveError.couldNotCompress("")
        }
        return destination.standardized
    }

    /// Expands one zip or rar next to itself and returns the file or folder that was created.
    @discardableResult
    public static func decompress(_ url: URL) throws -> URL {
        do {
            return try expanding(url)
        } catch {
            throw rethrow(error, compress: false)
        }
    }

    private static func expanding(_ url: URL) throws -> URL {
        guard let format = format(of: url), let parent = Paths.parent(of: url) else {
            throw ArchiveError.couldNotDecompress("")
        }
        let listed = try entries(of: url, format: format)
        let placement = try extractPlacement(archiveName: url.lastPathComponent, entries: listed) { candidate in
            FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidate).path)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try extract(url, format: format, to: temp)
        return try place(placement, from: temp, in: parent)
    }

    static func uniqueName(_ name: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(name) { return name }
        let file = name as NSString
        let ext = file.pathExtension
        let stem = file.deletingPathExtension
        var number = 1
        while number < 1000 {
            let candidate = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
        return ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
    }

    /// The first path component of each entry, in order, with `__MACOSX` left out.
    private static func topLevelNames(in entries: [String]) throws -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for raw in entries {
            let entry = raw.replacingOccurrences(of: "\\", with: "/")
            if entry.isEmpty { continue }
            if !isSafe(entry) { throw ArchiveError.unsafePath }
            let name = topLevel(of: entry)
            if name.isEmpty || name.caseInsensitiveCompare("__MACOSX") == .orderedSame { continue }
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    private static func topLevel(of entry: String) -> String {
        let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
        return String(trimmed.split(separator: "/", maxSplits: 1).first ?? "")
    }

    private static func isSafe(_ entry: String) -> Bool {
        if entry.hasPrefix("/") || entry.contains("\0") { return false }
        let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
        if trimmed.isEmpty { return false }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func entries(of url: URL, format: ArchiveFormat) throws -> [String] {
        switch format {
        case .zip:
            let output = try run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z", "-1", url.path])
            return output.split(whereSeparator: \.isNewline).map(String.init)
        case .rar:
            guard let backend = rarBackend() else { throw ArchiveError.rarUnavailable }
            switch backend {
            case let .unrar(tool):
                let output = try run(tool, ["lb", "-cfg-", "-p-", url.path])
                return output.split(whereSeparator: \.isNewline).map(String.init)
            case let .sevenZip(tool):
                let output = try run(tool, ["l", "-slt", "-bd", "-bso1", "-bsp0", url.path])
                return sevenZipEntries(output)
            }
        }
    }

    /// `7zz l -slt` prints the archive itself, then one block per file. Only the file blocks count.
    public static func sevenZipEntries(_ output: String) -> [String] {
        var entries: [String] = []
        var pastHeader = false
        var path: String?
        var isFolder = false
        func flush() {
            defer {
                path = nil
                isFolder = false
            }
            guard pastHeader, let path, !path.isEmpty else { return }
            entries.append(isFolder && !path.hasSuffix("/") ? path + "/" : path)
        }
        for lineSub in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(lineSub)
            if line.hasPrefix("----------") {
                flush()
                pastHeader = true
                continue
            }
            guard pastHeader else { continue }
            if line.hasPrefix("Path = ") {
                flush()
                path = String(line.dropFirst("Path = ".count))
            } else if line.hasPrefix("Folder = ") {
                // Folder comes after Path in the same block, so this must not flush yet.
                let value = line.dropFirst("Folder = ".count).trimmingCharacters(in: CharacterSet.whitespaces)
                isFolder = value == "+"
            }
        }
        flush()
        return entries
    }

    private static func extract(_ url: URL, format: ArchiveFormat, to temp: URL) throws {
        switch format {
        case .zip:
            try run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", url.path, temp.path])
        case .rar:
            guard let backend = rarBackend() else { throw ArchiveError.rarUnavailable }
            switch backend {
            case let .unrar(tool):
                let destination = temp.path.hasSuffix("/") ? temp.path : temp.path + "/"
                // `-p-` fails a password-protected archive instead of waiting for a prompt.
                try run(tool, ["x", "-o+", "-idq", "-y", "-cfg-", "-p-", url.path, destination])
            case let .sevenZip(tool):
                try run(tool, ["x", "-y", "-bd", "-bso0", "-bsp0", "-o\(temp.path)", url.path])
            }
        }
    }

    private static func place(_ placement: ExtractPlacement, from temp: URL, in parent: URL) throws -> URL {
        let items = try children(of: temp)
        switch placement {
        case let .alongside(name):
            guard items.count == 1, let only = items.first else {
                throw ArchiveError.couldNotDecompress("")
            }
            let destination = parent.appendingPathComponent(name)
            try FileManager.default.moveItem(at: only, to: destination)
            return destination.standardized
        case let .folder(name):
            let destination = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for item in items {
                try FileManager.default.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
            }
            return destination.standardized
        }
    }

    private static func children(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        .filter { $0.lastPathComponent.caseInsensitiveCompare("__MACOSX") != .orderedSame }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private enum RarBackend {
        case unrar(URL)
        case sevenZip(URL)
    }

    /// Finder starts the app with a PATH that does not include Homebrew, so the usual install locations are checked too.
    private static func rarBackend() -> RarBackend? {
        if let tool = executable(named: ["unrar"]) { return .unrar(tool) }
        if let tool = executable(named: ["7zz", "7z", "7za"]) { return .sevenZip(tool) }
        return nil
    }

    private static func executable(named names: [String]) -> URL? {
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for name in names {
            for directory in directories where !directory.isEmpty {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// `fileExists` follows links and misses a broken one. Compress should still accept the link itself.
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func rethrow(_ error: Error, compress: Bool) -> Error {
        if error is ArchiveError { return error }
        let detail = (error as? ToolError)?.detail ?? error.localizedDescription
        return compress ? ArchiveError.couldNotCompress(detail) : .couldNotDecompress(detail)
    }

    @discardableResult
    private static func run(_ tool: URL, _ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.qualityOfService = .userInitiated
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ToolError(detail: "")
        }
        // Read both pipes at once. Filling one while the other is unread would stall the tool.
        let outQueue = DispatchQueue(label: "explorer.archive.out")
        let errQueue = DispatchQueue(label: "explorer.archive.err")
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        outQueue.async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errQueue.async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        let errorText = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw ToolError(detail: errorText) }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

private struct ToolError: Error {
    let detail: String
}
