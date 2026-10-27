import Foundation

/// Names the user does not want listed, from `.explorerignore` files in the gitignore format.
///
/// `~/.explorerignore` applies everywhere. A `.explorerignore` inside a folder applies to that folder and below.
/// A later line wins over an earlier one, and a file closer to the folder wins over one further up.
public struct IgnoreRules {
    public static let fileName = ".explorerignore"

    private struct Rule {
        let regex: NSRegularExpression
        let negated: Bool
        let directoriesOnly: Bool
        let anchored: Bool
    }

    private struct RuleFile {
        let base: String
        let rules: [Rule]
    }

    private let files: [RuleFile]

    public static let none = IgnoreRules(files: [])

    /// Reads the rules that apply to the children of `directory`.
    public static func load(for directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> IgnoreRules {
        var files: [RuleFile] = []
        let homeFile = home.appendingPathComponent(fileName)
        if let file = read(homeFile, base: home.standardized.path) {
            files.append(file)
        }
        var ancestors: [URL] = []
        var current = directory.standardized
        while true {
            ancestors.append(current)
            guard let parent = Paths.parent(of: current) else { break }
            current = parent
        }
        for folder in ancestors.reversed() {
            let file = folder.appendingPathComponent(fileName)
            if file.standardized.path == homeFile.standardized.path { continue }
            if let ruleFile = read(file, base: folder.path) {
                files.append(ruleFile)
            }
        }
        return IgnoreRules(files: files)
    }

    public init(parsing text: String, base: String) {
        files = [RuleFile(base: base, rules: Self.parse(text))]
    }

    private init(files: [RuleFile]) {
        self.files = files
    }

    public var isEmpty: Bool {
        files.allSatisfy { $0.rules.isEmpty }
    }

    public func ignores(_ url: URL, isDirectory: Bool) -> Bool {
        let path = url.standardized.path
        var ignored = false
        for file in files {
            let prefix = file.base == "/" ? "/" : file.base + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            let name = (relative as NSString).lastPathComponent
            for rule in file.rules {
                if rule.directoriesOnly && !isDirectory { continue }
                let subject = rule.anchored ? relative : name
                let range = NSRange(location: 0, length: (subject as NSString).length)
                if rule.regex.firstMatch(in: subject, options: [.anchored], range: range)?.range == range {
                    ignored = !rule.negated
                }
            }
        }
        return ignored
    }

    private static func read(_ url: URL, base: String) -> RuleFile? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        let rules = parse(text)
        return rules.isEmpty ? nil : RuleFile(base: base, rules: rules)
    }

    private static func parse(_ text: String) -> [Rule] {
        text.components(separatedBy: .newlines).compactMap { rule(from: $0) }
    }

    private static func rule(from rawLine: String) -> Rule? {
        var line = rawLine
        while line.hasSuffix(" ") && !line.hasSuffix("\\ ") { line.removeLast() }
        if line.isEmpty || line.hasPrefix("#") { return nil }
        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line.removeFirst()
        }
        var directoriesOnly = false
        if line.hasSuffix("/") {
            directoriesOnly = true
            line.removeLast()
        }
        if line.isEmpty { return nil }
        var anchored = line.contains("/")
        if line.hasPrefix("/") {
            line.removeFirst()
            anchored = true
        }
        guard let regex = try? NSRegularExpression(pattern: glob(line)) else { return nil }
        return Rule(regex: regex, negated: negated, directoriesOnly: directoriesOnly, anchored: anchored)
    }

    /// Turns a gitignore glob into a regular expression over a whole name or relative path.
    private static func glob(_ pattern: String) -> String {
        let chars = Array(pattern)
        var out = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "*":
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    let atStart = index == 0 || chars[index - 1] == "/"
                    let followedBySlash = index + 2 < chars.count && chars[index + 2] == "/"
                    if atStart && followedBySlash {
                        out += "(?:.*/)?"
                        index += 3
                        continue
                    }
                    out += ".*"
                    index += 2
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "[":
                if let close = chars[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var body = String(chars[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    out += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close + 1
                    continue
                }
                out += "\\["
            case "\\":
                if index + 1 < chars.count {
                    index += 1
                    out += NSRegularExpression.escapedPattern(for: String(chars[index]))
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(char))
            }
            index += 1
        }
        return out
    }
}
