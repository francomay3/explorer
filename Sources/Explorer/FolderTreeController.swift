import AppKit
import ExplorerCore

final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let view: NSScrollView
    let outline: FolderOutlineView
    var onContextFolder: ((URL?) -> Void)?
    var showsHidden = true
    /// At launch the starting folder is selected in the sidebar but left collapsed.
    var startsCollapsed = true
    var onNavigate: ((URL) -> Void)?
    var onMove: (([URL], URL) -> Void)?

    private var roots: [FolderNode] = []
    private var topLevel: [Any] = []
    private var pinnedRoot: FolderNode?
    private var suppressCount = 0

    override init() {
        outline = FolderOutlineView()
        view = NSScrollView()
        super.init()
        configureOutline()
        rebuildRoots()
    }

    func setShowHidden(_ show: Bool, selecting url: URL) {
        guard show != showsHidden else { return }
        showsHidden = show
        rebuildRoots()
        performSuppressed {
            outline.reloadData()
            reveal(url)
        }
    }

    func rebuildSidebar(revealing url: URL) {
        rebuildRoots()
        performSuppressed {
            outline.reloadData()
            reveal(url)
        }
    }

    func refreshExpandedFolder(_ url: URL) {
        let nodes = loadedNodes(matching: url)
        guard !nodes.isEmpty else { return }
        performSuppressed {
            for node in nodes {
                let expanded = outline.isItemExpanded(node)
                node.invalidate()
                if expanded {
                    outline.reloadItem(node, reloadChildren: true)
                }
            }
        }
    }

    func reveal(_ url: URL) {
        guard let root = bestRoot(for: url) else { return }
        pinnedRoot = root
        let keepCollapsed = startsCollapsed && Paths.same(root.url, url)
        performSuppressed {
            if !keepCollapsed {
                outline.expandItem(root)
            }
            var node = root
            for part in relativeComponents(from: root.url, to: url) {
                guard let child = node.children().first(where: { child in
                    child.url.lastPathComponent.compare(part, options: [.caseInsensitive]) == .orderedSame
                }) else { break }
                node = child
                if !Paths.same(node.url, url) {
                    outline.expandItem(node)
                }
            }
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FolderNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is FolderNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        item is FolderNode
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let header = item as? SidebarHeader else { return outlineView.rowHeight }
        return header.drawsDivider ? 36 : 20
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let header = item as? SidebarHeader {
            let id = NSUserInterfaceItemIdentifier("sidebar-header")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarHeaderCell) ?? SidebarHeaderCell()
            cell.identifier = id
            cell.show(title: header.title, hasDivider: header.drawsDivider)
            return cell
        }
        guard let node = item as? FolderNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("folder")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NameCell) ?? NameCell()
        cell.identifier = id
        cell.show(name: node.title, icon: node.icon)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? FolderNode)?.title
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let header = item as? SidebarHeader {
            let id = NSUserInterfaceItemIdentifier("sidebar-header-row")
            let row = (outlineView.makeView(withIdentifier: id, owner: self) as? SidebarHeaderRowView) ?? SidebarHeaderRowView()
            row.identifier = id
            row.drawsDivider = header.drawsDivider
            return row
        }
        let id = NSUserInterfaceItemIdentifier("folder-row")
        let row = (outlineView.makeView(withIdentifier: id, owner: self) as? DropRowView) ?? DropRowView()
        row.identifier = id
        guard let node = item as? FolderNode else { return row }
        let folder = node.url
        row.canAccept = { FileActions.canMove(DraggedFiles.urls(from: $0), to: folder) }
        row.accept = { [weak self] info in
            let urls = DraggedFiles.urls(from: info)
            guard FileActions.canMove(urls, to: folder) else { return false }
            self?.onMove?(urls, folder)
            return true
        }
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard suppressCount == 0 else { return }
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FolderNode else { return }
        pinnedRoot = rootAncestor(of: node)
        onNavigate?(node.url)
    }

    @objc private func toggleExpanded(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if outline.isItemExpanded(item) {
            outline.collapseItem(item)
        } else {
            outline.expandItem(item)
        }
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = true
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.backgroundColor = .textBackgroundColor
        outline.setAccessibilityIdentifier("folder-tree")
        outline.dataSource = self
        outline.delegate = self
        outline.unregisterDraggedTypes()
        outline.target = self
        outline.doubleAction = #selector(toggleExpanded(_:))
        outline.onContextFolder = { [weak self] url in
            self?.onContextFolder?(url)
        }

        view.translatesAutoresizingMaskIntoConstraints = true
        view.hasVerticalScroller = true
        view.hasHorizontalScroller = true
        view.autohidesScrollers = true
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.borderType = .noBorder
        view.documentView = outline
    }

    func install(menu: NSMenu) {
        outline.menu = menu
    }

    private func rebuildRoots() {
        let fileManager = FileManager.default
        let showsHidden = { [weak self] in self?.showsHidden ?? true }
        func makeNode(_ url: URL) -> FolderNode {
            let standard = url.standardized
            return FolderNode(
                url: standard,
                title: fileManager.displayName(atPath: standard.path),
                parent: nil,
                showsHidden: showsHidden
            )
        }
        func isFolder(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        var shortcuts: [FolderNode] = []
        var seen = Set<String>()
        func appendShortcut(_ url: URL) {
            let standard = url.standardized
            guard seen.insert(standard.path).inserted, isFolder(standard) else { return }
            shortcuts.append(makeNode(standard))
        }
        appendShortcut(fileManager.homeDirectoryForCurrentUser)
        let places: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
        for place in places {
            if let url = fileManager.urls(for: place, in: .userDomainMask).first {
                appendShortcut(url)
            }
        }

        let volumes = (fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .sorted {
                fileManager.displayName(atPath: $0.path)
                    .localizedStandardCompare(fileManager.displayName(atPath: $1.path)) == .orderedAscending
            }
            .map { makeNode($0) }

        let bookmarks = BookmarkStore.shared.urls
            .filter { isFolder($0) }
            .map { makeNode($0) }

        roots = shortcuts + bookmarks + volumes
        var top: [Any] = [SidebarHeader(title: L10n.shortcuts, drawsDivider: true)]
        top.append(contentsOf: shortcuts as [Any])
        if !bookmarks.isEmpty {
            top.append(SidebarHeader(title: L10n.bookmarks, drawsDivider: true))
            top.append(contentsOf: bookmarks as [Any])
        }
        top.append(SidebarHeader(title: L10n.locations, drawsDivider: true))
        top.append(contentsOf: volumes as [Any])
        topLevel = top
        pinnedRoot = nil
        outline.reloadData()
    }

    private func children(of item: Any?) -> [Any] {
        guard let item else { return topLevel }
        guard let node = item as? FolderNode else { return [] }
        return node.children()
    }

    private func bestRoot(for url: URL) -> FolderNode? {
        if let pinnedRoot, Paths.contains(directory: pinnedRoot.url, url: url) {
            return pinnedRoot
        }
        return roots
            .filter { Paths.contains(directory: $0.url, url: url) }
            .max { $0.url.standardized.path.count < $1.url.standardized.path.count }
    }

    private func rootAncestor(of node: FolderNode) -> FolderNode {
        var current = node
        while let parent = current.parent { current = parent }
        return current
    }

    private func loadedNodes(matching url: URL) -> [FolderNode] {
        var found: [FolderNode] = []
        func walk(_ nodes: [FolderNode]) {
            for node in nodes {
                if Paths.same(node.url, url) { found.append(node) }
                walk(node.cachedChildrenOnly())
            }
        }
        walk(roots)
        return found
    }

    private func relativeComponents(from root: URL, to url: URL) -> [String] {
        let rootPath = root.standardized.path
        let target = url.standardized.path
        if target == rootPath { return [] }
        let rest: String
        if rootPath == "/" {
            rest = String(target.dropFirst())
        } else if target.hasPrefix(rootPath + "/") {
            rest = String(target.dropFirst(rootPath.count + 1))
        } else {
            return []
        }
        return rest.split(separator: "/").map(String.init)
    }

    private func performSuppressed(_ body: () -> Void) {
        suppressCount += 1
        body()
        suppressCount -= 1
    }
}

private final class SidebarHeader: NSObject {
    let title: String
    let drawsDivider: Bool

    init(title: String, drawsDivider: Bool) {
        self.title = title
        self.drawsDivider = drawsDivider
    }
}

private final class SidebarHeaderCell: NSView {
    private let label = NSTextField(labelWithString: "")
    private var bottomInset: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        bottomInset = bottom
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bottom,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, hasDivider: Bool) {
        label.stringValue = title
        bottomInset?.constant = hasDivider ? -10 : -2
    }
}

private final class SidebarHeaderRowView: NSTableRowView {
    var drawsDivider = false

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard drawsDivider else { return }
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        let y = bounds.height - 5
        line.move(to: NSPoint(x: 8, y: y))
        line.line(to: NSPoint(x: max(8, bounds.maxX - 8), y: y))
        line.lineWidth = 1
        line.stroke()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}

final class FolderOutlineView: NSOutlineView {
    var onContextFolder: ((URL?) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let node = row >= 0 ? item(atRow: row) as? FolderNode : nil
        onContextFolder?(node?.url)
        return menu
    }
}

private final class FolderNode {
    let url: URL
    let title: String
    var icon: NSImage { Icons.file(url) }
    weak var parent: FolderNode?
    private let showsHidden: () -> Bool
    private var cachedChildren: [FolderNode]?

    init(url: URL, title: String, parent: FolderNode?, showsHidden: @escaping () -> Bool) {
        self.url = url
        self.title = title
        self.parent = parent
        self.showsHidden = showsHidden
    }

    func children() -> [FolderNode] {
        if let cachedChildren { return cachedChildren }
        let loaded = Self.load(parent: self, showsHidden: showsHidden)
        cachedChildren = loaded
        return loaded
    }

    func cachedChildrenOnly() -> [FolderNode] { cachedChildren ?? [] }

    func invalidate() { cachedChildren = nil }

    private static func load(parent: FolderNode, showsHidden: @escaping () -> Bool) -> [FolderNode] {
        guard let items = try? DirectoryScanner.scan(url: parent.url, showHidden: showsHidden()) else { return [] }
        return items
            .filter(\.appearsInTree)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { item in
                FolderNode(url: item.url, title: item.displayName, parent: parent, showsHidden: showsHidden)
            }
    }
}
