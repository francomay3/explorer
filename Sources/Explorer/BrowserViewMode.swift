import Foundation

enum BrowserViewMode: String, CaseIterable {
    case details
    case icons
    case preview

    var title: String {
        switch self {
        case .details: return L10n.details
        case .icons: return L10n.icons
        case .preview: return L10n.preview
        }
    }

    var symbolName: String {
        switch self {
        case .details: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .preview: return "rectangle.split.2x1"
        }
    }
}
