import Foundation

/// Keeps items in the open folder whose names match a query. It does not look in subfolders.
public struct ItemFilter: Equatable {
    public var items: [FileItem]
    public var invalidPattern: Bool

    public static func filter(_ items: [FileItem], query rawQuery: String, regex: Bool) -> ItemFilter {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return ItemFilter(items: items, invalidPattern: false)
        }
        if regex {
            guard let expression = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
                return ItemFilter(items: [], invalidPattern: true)
            }
            let matched = items.filter { item in
                let name = item.name as NSString
                let range = NSRange(location: 0, length: name.length)
                return expression.firstMatch(in: item.name, options: [], range: range) != nil
            }
            return ItemFilter(items: matched, invalidPattern: false)
        }
        let matched = items.filter { item in
            item.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || item.displayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return ItemFilter(items: matched, invalidPattern: false)
    }
}
