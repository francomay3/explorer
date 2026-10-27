import AppKit
import ExplorerCore

final class FileTableView: NSTableView {
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onContextRow: ((Int) -> Void)?
    private let renameClick = RenameClick()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        renameClick.onRename = { [weak self] in self?.onRename?() }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        renameClick.onRename = { [weak self] in self?.onRename?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        renameClick.cancel()
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        onContextRow?(row)
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        renameClick.cancel()
        let row = row(at: convert(event.locationInWindow, from: nil))
        let already = row >= 0 && selectedRowIndexes == IndexSet(integer: row)
        let start = event.locationInWindow
        super.mouseDown(with: event)
        let end = window?.mouseLocationOutsideOfEventStream ?? start
        let dragged = hypot(end.x - start.x, end.y - start.y) > 4
        renameClick.arm(
            alreadySelected: already,
            clickCount: event.clickCount,
            modifiers: event.modifierFlags,
            dragged: dragged
        )
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.isDisjoint(with: [.command, .option, .control])
        if plain, event.keyCode == Key.return || event.keyCode == Key.keypadEnter {
            onRename?()
            return
        }
        if plain, event.keyCode == Key.delete || event.keyCode == Key.forwardDelete || event.keyCode == Key.x {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

private enum Key {
    static let `return`: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let x: UInt16 = 7
}

final class FileListContainer: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }
}

final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let view: FileListContainer
    let tableView: FileTableView
    var onCommitRename: ((FileItem, String) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onSort: ((SortColumn, Bool) -> Void)?
    var onOpenRow: ((FileItem) -> Void)?
    var onMove: (([URL], URL) -> Void)?
    var onContextTarget: ((FileItem?) -> Void)?
    var onVisibleFoldersChange: (() -> Void)?
    var folderSizes: FolderSizeIndex?
    var isRenaming: Bool { editingItem != nil }

    private let messageLabel = ClickThroughLabel(labelWithString: "")
    private let scrollView = NSScrollView()
    private var items: [FileItem] = []
    private var editingItem: FileItem?
    private var isReloading = false
    private var ignoreSelectionChanges = false

    override init() {
        tableView = FileTableView()
        view = FileListContainer()
        super.init()
        configureTable()
        configureMessage()
        view.onLayout = { [weak self] in
            self?.layoutContents()
            self?.onVisibleFoldersChange?()
        }
        tableView.onContextRow = { [weak self] row in
            guard let self else { return }
            let item = self.items.indices.contains(row) ? self.items[row] : nil
            self.onContextTarget?(item)
        }
        tableView.onRename = { [weak self] in
            guard let self, let item = self.selectedItems().first, self.selectedItems().count == 1 else { return }
            self.beginRename(url: item.url)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleRowsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(items: [FileItem]) {
        self.items = items
        isReloading = true
        ignoreSelectionChanges = true
        tableView.reloadData()
        ignoreSelectionChanges = false
        isReloading = false
        onVisibleFoldersChange?()
    }

    /// Every directory in this folder, in listing order. Packages included; symlinks left out.
    func listedDirectories() -> [URL] {
        items.compactMap { $0.measuresSize ? $0.url : nil }
    }

    /// Directories on screen, top to bottom.
    func visibleDirectories() -> [URL] {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return [] }
        var urls: [URL] = []
        let last = range.location + range.length
        for row in range.location..<last {
            guard items.indices.contains(row) else { continue }
            let item = items[row]
            guard item.measuresSize else { continue }
            urls.append(item.url)
        }
        return urls
    }

    func reloadSizeCells(_ paths: Set<String>) {
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(SortColumn.size.rawValue))
        guard column >= 0 else { return }
        var rows = IndexSet()
        for (index, item) in items.enumerated() where paths.contains(FolderSizeIndex.cacheKey(for: item.url)) {
            rows.insert(index)
        }
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: column))
    }

    func applySelection(paths: Set<String>, focused: String?, reveal: Bool) {
        var indexes = IndexSet()
        var focusedRow: Int?
        for (index, item) in items.enumerated() where paths.contains(item.url.standardized.path) {
            indexes.insert(index)
            if item.url.standardized.path == focused {
                focusedRow = index
            }
        }
        ignoreSelectionChanges = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        ignoreSelectionChanges = false
        if reveal, let row = focusedRow ?? indexes.max() {
            tableView.scrollRowToVisible(row)
        }
    }

    func selectionPaths() -> Set<String> {
        Set(selectedItems().map { $0.url.standardized.path })
    }

    func focusedPath() -> String? {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return nil }
        return items[row].url.standardized.path
    }

    func setMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil || !items.isEmpty
        layoutContents()
    }

    func selectedItems() -> [FileItem] {
        tableView.selectedRowIndexes.compactMap { index in
            items.indices.contains(index) ? items[index] : nil
        }
    }


    @discardableResult
    func beginRename(url: URL) -> Bool {
        guard let row = items.firstIndex(where: { Paths.same($0.url, url) }) else { return false }
        let item = items[row]
        tableView.scrollRowToVisible(row)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.layoutSubtreeIfNeeded()
        guard let cell = nameCell(at: row) else { return false }
        editingItem = item
        cell.beginEditing(text: item.name, delegate: self, selectsAll: item.opensAsFolder)
        return true
    }

    func restoreName(of item: FileItem) {
        guard let row = items.firstIndex(where: { Paths.same($0.url, item.url) }),
              let cell = nameCell(at: row) else { return }
        cell.show(name: item.displayName, icon: Icons.file(item.url))
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = SortColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = items[row]
        switch column {
        case .name:
            let cell = reuseNameCell(id: tableColumn.identifier, in: tableView)
            cell.show(name: item.displayName, icon: Icons.file(item.url))
            return cell
        case .size:
            let cell = reuseSizeCell(id: tableColumn.identifier, in: tableView)
            if item.measuresSize {
                cell.showDirectory(folderSizes?.reading(for: item.url) ?? .loading)
            } else {
                cell.showFile(bytes: item.size)
            }
            return cell
        case .kind:
            let cell = reuseTextCell(id: tableColumn.identifier, in: tableView)
            cell.show(item.kind, alignment: .left)
            return cell
        case .modified:
            let cell = reuseTextCell(id: tableColumn.identifier, in: tableView)
            let text = item.modified.map { Format.date.string(from: $0) } ?? ""
            cell.show(text, alignment: .left)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = SortColumn(rawValue: key) else { return }
        onSort?(column, descriptor.ascending)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !ignoreSelectionChanges else { return }
        onSelectionChange?()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        items[row].displayName
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard items.indices.contains(row) else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("file-row")
        let rowView = (tableView.makeView(withIdentifier: id, owner: self) as? DropRowView) ?? DropRowView()
        rowView.identifier = id
        guard items.indices.contains(row) else { return rowView }
        let item = items[row]
        if item.opensAsFolder {
            let folder = item.url
            rowView.canAccept = { FileActions.canMove(DraggedFiles.urls(from: $0), to: folder) }
            rowView.accept = { [weak self] info in
                let urls = DraggedFiles.urls(from: info)
                guard FileActions.canMove(urls, to: folder) else { return false }
                self?.onMove?(urls, folder)
                return true
            }
        } else {
            rowView.canAccept = nil
            rowView.accept = nil
        }
        return rowView
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isReloading, let item = editingItem, let field = obj.object as? NSTextField else { return }
        let cancelled = NameEditing.movement(in: obj) == NSTextMovement.cancel.rawValue || (field as? RenameField)?.cancelled == true
        let typed = field.stringValue
        editingItem = nil
        (field.superview as? NameCell)?.finishEditing()
        (field as? RenameField)?.close()
        if cancelled {
            field.stringValue = item.displayName
            return
        }
        onCommitRename?(item, typed)
    }

    @objc private func openRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        onOpenRow?(items[row])
    }

    private func configureTable() {
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 3, height: 2)
        tableView.backgroundColor = .textBackgroundColor
        tableView.setAccessibilityIdentifier("file-list")
        tableView.doubleAction = #selector(openRow(_:))
        tableView.target = self
        tableView.dataSource = self
        addColumn(.name, title: L10n.name, width: 320, min: 140, alignment: .left)
        addColumn(.size, title: L10n.size, width: 108, min: 80, alignment: .right)
        addColumn(.kind, title: L10n.type, width: 140, min: 80, alignment: .left)
        addColumn(.modified, title: L10n.dateModified, width: 170, min: 120, alignment: .left)
        tableView.sortDescriptors = [NSSortDescriptor(key: SortColumn.name.rawValue, ascending: true)]
        tableView.delegate = self
        tableView.unregisterDraggedTypes()
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask(.move, forLocal: false)
        tableView.autosaveName = "FileList"
        tableView.autosaveTableColumns = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView
        view.addSubview(scrollView)
    }

    private func layoutContents() {
        scrollView.frame = view.bounds
        let width = max(0, view.bounds.width - 40)
        messageLabel.preferredMaxLayoutWidth = width
        messageLabel.frame = NSRect(x: 20, y: 0, width: width, height: 200)
        messageLabel.sizeToFit()
        var frame = messageLabel.frame
        frame.origin.x = 20
        frame.size.width = width
        frame.origin.y = max(0, (view.bounds.height - frame.height) / 2)
        messageLabel.frame = frame
    }

    private func configureMessage() {
        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true
        view.addSubview(messageLabel)
    }

    private func addColumn(_ column: SortColumn, title: String, width: CGFloat, min: CGFloat, alignment: NSTextAlignment) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = min
        tableColumn.headerCell.alignment = alignment
        tableColumn.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
        tableView.addTableColumn(tableColumn)
    }

    private func reuseNameCell(id: NSUserInterfaceItemIdentifier, in table: NSTableView) -> NameCell {
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? NameCell { return cell }
        let cell = NameCell()
        cell.identifier = id
        return cell
    }

    @objc private func visibleRowsChanged() {
        onVisibleFoldersChange?()
    }

    private func reuseSizeCell(id: NSUserInterfaceItemIdentifier, in table: NSTableView) -> SizeCell {
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? SizeCell { return cell }
        let cell = SizeCell()
        cell.identifier = id
        return cell
    }

    private func reuseTextCell(id: NSUserInterfaceItemIdentifier, in table: NSTableView) -> TextCell {
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? TextCell { return cell }
        let cell = TextCell()
        cell.identifier = id
        return cell
    }

    private func nameCell(at row: Int) -> NameCell? {
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(SortColumn.name.rawValue))
        guard column >= 0 else { return nil }
        return tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCell
    }

}
