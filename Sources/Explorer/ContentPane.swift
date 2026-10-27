import AppKit
import ExplorerCore

final class ContentPaneView: NSView {
    var panes: [NSView] = []

    override func layout() {
        super.layout()
        panes.forEach { $0.frame = bounds }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        panes.forEach { $0.frame = bounds }
    }
}

/// Details, icons, and the image preview, sharing one folder listing.
final class ContentPane: NSObject {
    let view = ContentPaneView()
    let details = FileListController()
    let icons = IconBrowser()
    let preview = ImagePreviewBrowser()
    private(set) var mode: BrowserViewMode = .details

    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onSort: ((SortColumn, Bool) -> Void)?
    var onCommitRename: ((FileItem, String) -> Void)?
    var onDelete: (() -> Void)?
    var onMove: (([URL], URL) -> Void)?
    var onContextTarget: ((FileItem?) -> Void)?

    private var items: [FileItem] = []
    /// The selection belongs to the folder, not to a view. Paths are `URL.standardized.path`.
    private var selectedPaths: Set<String> = []
    private var focusedPath: String?
    private var pushingSelection = false

    override init() {
        super.init()
        view.panes = [details.view, icons.view, preview.view]
        view.panes.forEach { view.addSubview($0) }
        details.onOpenRow = { [weak self] item in self?.onOpen?(item) }
        details.onSelectionChange = { [weak self] in self?.adoptSelection(from: .details) }
        details.onSort = { [weak self] column, ascending in self?.onSort?(column, ascending) }
        details.onCommitRename = { [weak self] item, name in self?.onCommitRename?(item, name) }
        details.onContextTarget = { [weak self] item in self?.onContextTarget?(item) }
        details.tableView.onDelete = { [weak self] in self?.onDelete?() }
        details.onMove = { [weak self] urls, folder in self?.onMove?(urls, folder) }
        icons.onMove = { [weak self] urls, folder in self?.onMove?(urls, folder) }
        preview.onMove = { [weak self] urls, folder in self?.onMove?(urls, folder) }
        icons.onOpen = { [weak self] item in self?.onOpen?(item) }
        icons.onSelectionChange = { [weak self] in self?.adoptSelection(from: .icons) }
        icons.onDelete = { [weak self] in self?.onDelete?() }
        icons.onCommitRename = { [weak self] item, name in self?.onCommitRename?(item, name) }
        icons.onContextTarget = { [weak self] item in self?.onContextTarget?(item) }
        preview.onOpen = { [weak self] item in self?.onOpen?(item) }
        preview.onSelectionChange = { [weak self] in self?.adoptSelection(from: .preview) }
        preview.onDelete = { [weak self] in self?.onDelete?() }
        preview.onCommitRename = { [weak self] item, name in self?.onCommitRename?(item, name) }
        preview.onContextTarget = { [weak self] item in self?.onContextTarget?(item) }
        details.onVisibleFoldersChange = { [weak self] in
            self?.reportVisibleFolders()
        }
        setMode(.details)
    }

    var folderSizes: FolderSizeIndex? {
        get { details.folderSizes }
        set { details.folderSizes = newValue }
    }

    func reportVisibleFolders() {
        guard mode == .details else {
            folderSizes?.noteVisible([])
            return
        }
        folderSizes?.noteVisible(details.listedDirectories(), prioritizing: details.visibleDirectories())
    }

    func reloadFolderSizes(_ paths: Set<String>) {
        guard mode == .details else { return }
        details.reloadSizeCells(paths)
    }

    var onColumnsChange: ((URL, [ColumnSetting]) -> Void)? {
        get { details.onColumnsChange }
        set { details.onColumnsChange = newValue }
    }
    var onMediaLoaded: (([String: MediaInfo]) -> Void)? {
        get { details.onMediaLoaded }
        set { details.onMediaLoaded = newValue }
    }
    var onResetColumns: ((URL) -> Void)? {
        get { details.onResetColumns }
        set { details.onResetColumns = newValue }
    }

    func applyColumns(for url: URL, layout: [ColumnSetting]?) {
        details.applyColumns(for: url, layout: layout)
    }

    var isRenaming: Bool { details.isRenaming }

    var keyView: NSView {
        switch mode {
        case .details: return details.tableView
        case .icons: return icons.collection
        case .preview: return preview.view.collection
        }
    }

    var scrollOffset: NSPoint {
        keyView.enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    func restoreScrollOffset(_ origin: NSPoint) {
        guard let scroll = keyView.enclosingScrollView else { return }
        view.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let document = scroll.documentView?.frame.size ?? .zero
        let target = NSPoint(
            x: min(origin.x, max(0, document.width - clip.bounds.width)),
            y: min(origin.y, max(0, document.height - clip.bounds.height))
        )
        clip.scroll(to: target)
        scroll.reflectScrolledClipView(clip)
    }

    func install(menu: NSMenu) {
        details.tableView.menu = menu
        icons.collection.menu = menu
        preview.view.collection.menu = menu
    }

    func setMode(_ mode: BrowserViewMode) {
        let changed = self.mode != mode
        self.mode = mode
        details.view.isHidden = mode != .details
        icons.view.isHidden = mode != .icons
        preview.view.isHidden = mode != .preview
        view.needsLayout = true
        if changed {
            pushSelection(reveal: true)
        }
        reportVisibleFolders()
    }

    func show(items: [FileItem], preserveSelection: Bool) {
        self.items = items
        if preserveSelection {
            let live = Set(items.map { $0.url.standardized.path })
            selectedPaths.formIntersection(live)
            if let focusedPath, !selectedPaths.contains(focusedPath) {
                self.focusedPath = items.last { selectedPaths.contains($0.url.standardized.path) }?.url.standardized.path
            }
        } else {
            selectedPaths = []
            focusedPath = nil
        }
        pushingSelection = true
        details.show(items: items)
        icons.show(items: items)
        preview.show(items: items, preserveScroll: preserveSelection)
        pushingSelection = false
        pushSelection(reveal: false)
    }

    func setMessage(_ text: String?) {
        details.setMessage(text)
        icons.setMessage(text)
        preview.setOverlay(text)
    }

    func selectedItems() -> [FileItem] {
        items.filter { selectedPaths.contains($0.url.standardized.path) }
    }

    func select(url: URL) {
        let path = url.standardized.path
        guard items.contains(where: { $0.url.standardized.path == path }) else { return }
        selectedPaths = [path]
        focusedPath = path
        pushSelection(reveal: true)
        onSelectionChange?()
    }

    /// Selects the listed items that are still in the folder, without scrolling to them.
    func select(urls: [URL]) {
        let live = Set(items.map { $0.url.standardized.path })
        let paths = Set(urls.map { $0.standardized.path }).intersection(live)
        guard !paths.isEmpty else { return }
        selectedPaths = paths
        focusedPath = items.last { paths.contains($0.url.standardized.path) }?.url.standardized.path
        pushSelection(reveal: false)
        onSelectionChange?()
    }

    private func adoptSelection(from source: BrowserViewMode) {
        guard !pushingSelection else { return }
        let paths: Set<String>
        let reportedFocus: String?
        switch source {
        case .details:
            paths = details.selectionPaths()
            reportedFocus = details.focusedPath()
        case .icons:
            paths = icons.selectionPaths()
            reportedFocus = icons.focusedPath()
        case .preview:
            paths = preview.selectionPaths()
            reportedFocus = preview.focusedPath()
        }
        selectedPaths = paths
        if let reportedFocus, paths.contains(reportedFocus) {
            focusedPath = reportedFocus
        } else if focusedPath == nil || !paths.contains(focusedPath!) {
            focusedPath = items.last { paths.contains($0.url.standardized.path) }?.url.standardized.path
        }
        pushSelection(reveal: false, except: source)
        onSelectionChange?()
    }

    private func pushSelection(reveal: Bool, except source: BrowserViewMode? = nil) {
        pushingSelection = true
        if source != .details {
            details.applySelection(paths: selectedPaths, focused: focusedPath, reveal: reveal && mode == .details)
        }
        if source != .icons {
            icons.applySelection(paths: selectedPaths, focused: focusedPath, reveal: reveal && mode == .icons)
        }
        if source != .preview {
            preview.applySelection(paths: selectedPaths, focused: focusedPath, reveal: reveal && mode == .preview)
        }
        pushingSelection = false
    }

    @discardableResult
    func beginRename(url: URL) -> Bool {
        switch mode {
        case .details: return details.beginRename(url: url)
        case .icons: return icons.beginRename(url: url)
        case .preview: return preview.beginRename(url: url)
        }
    }

    func restoreName(of item: FileItem) {
        details.restoreName(of: item)
    }
}
