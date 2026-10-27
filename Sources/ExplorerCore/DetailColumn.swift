import Foundation

/// A field the details list can show.
public enum DetailColumn: String, CaseIterable, Codable {
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

    /// The fields on until the user changes a folder.
    public static let defaults: [DetailColumn] = [.name, .size, .kind, .modified]

    /// Media fields come from Spotlight. They are read when a cell is shown, and for the whole folder when sorting by one.
    public var isMedia: Bool {
        switch self {
        case .dimensions, .taken, .duration: return true
        default: return false
        }
    }

    public var sortColumn: SortColumn? {
        SortColumn(rawValue: rawValue)
    }

    public var isRequired: Bool { self == .name }
}

public struct ColumnSetting: Codable, Equatable {
    public var id: String
    public var width: Double

    public init(id: String, width: Double) {
        self.id = id
        self.width = width
    }
}
