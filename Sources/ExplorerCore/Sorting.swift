import Foundation

/// Folders stay above files. Equal values fall back to the name, A to Z.
public func sortFileItems(_ items: [FileItem], column: SortColumn, ascending: Bool) -> [FileItem] {
    items.sorted { lhs, rhs in
        if lhs.opensAsFolder != rhs.opensAsFolder {
            return lhs.opensAsFolder
        }
        switch column {
        case .name:
            return textOrder(lhs.displayName, rhs.displayName, ascending: ascending)
                ?? textOrder(lhs.name, rhs.name, ascending: true)
                ?? false
        case .kind:
            return textOrder(lhs.kind, rhs.kind, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .size:
            return valueOrder(lhs.size, rhs.size, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .modified:
            return valueOrder(lhs.modified, rhs.modified, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .created:
            return valueOrder(lhs.created, rhs.created, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .accessed:
            return valueOrder(lhs.accessed, rhs.accessed, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .ext:
            return textOrder(lhs.fileExtension, rhs.fileExtension, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .permissions:
            return valueOrder(lhs.permissions, rhs.permissions, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .dimensions:
            return valueOrder(lhs.media?.pixels, rhs.media?.pixels, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .taken:
            return valueOrder(lhs.media?.isMedia == true ? lhs.media?.taken : nil, rhs.media?.isMedia == true ? rhs.media?.taken : nil, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .duration:
            return valueOrder(lhs.media?.duration, rhs.media?.duration, ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        case .owner:
            return textOrder(lhs.owner ?? "", rhs.owner ?? "", ascending: ascending)
                ?? textOrder(lhs.displayName, rhs.displayName, ascending: true)
                ?? false
        }
    }
}

/// nil means the strings are equal, so the caller can break the tie.
private func textOrder(_ lhs: String, _ rhs: String, ascending: Bool) -> Bool? {
    let order = lhs.localizedStandardCompare(rhs)
    if order == .orderedSame { return nil }
    let isAscending = order == .orderedAscending
    return ascending ? isAscending : !isAscending
}

/// nil means the values are equal. Missing values always sort last.
private func valueOrder<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> Bool? {
    switch (lhs, rhs) {
    case let (left?, right?):
        if left == right { return nil }
        return ascending ? left < right : right < left
    case (nil, nil):
        return nil
    case (nil, _):
        return false
    case (_, nil):
        return true
    }
}
