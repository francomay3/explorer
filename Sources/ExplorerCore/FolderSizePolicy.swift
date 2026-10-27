import Foundation

/// How long a stored folder size can be shown, and when it has to be walked again.
public enum FolderSizePolicy {
    /// Show the number and leave it alone.
    public static let fresh: TimeInterval = 15 * 60
    /// Show the number and recompute from cached children. After this, the next look walks stale branches.
    public static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    public enum Phase: Equatable {
        case fresh
        case revalidating
        case stale
    }

    public static func phase(age: TimeInterval) -> Phase {
        if age < fresh { return .fresh }
        if age < staleAfter { return .revalidating }
        return .stale
    }
}

public struct FolderSizeRecord: Equatable {
    public let bytes: Int64
    public let computedAt: Date

    public init(bytes: Int64, computedAt: Date) {
        self.bytes = bytes
        self.computedAt = computedAt
    }
}

/// What the size column draws for one directory.
public enum FolderSizeReading: Equatable {
    /// Nothing stored yet. The cell shows a spinner.
    case loading
    /// The walk failed and there is nothing to show.
    case unavailable
    case fresh(Int64)
    /// A stored number that is being checked again. The cell keeps the number and marks it.
    case revalidating(Int64)
}
