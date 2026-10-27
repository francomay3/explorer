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
        if row < 0 {
            trackMarquee(from: event)
            return
        }
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

    /// Dragging from the empty area below the rows draws a box. Rows it touches are selected while it moves.
    private func trackMarquee(from event: NSEvent) {
        guard let window else { return }
        let start = convert(event.locationInWindow, from: nil)
        let extend = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        let original = selectedRowIndexes
        let base = extend ? original : IndexSet()
        if !extend { deselectAll(nil) }
        window.makeFirstResponder(self)

        let box = MarqueeBox()
        addSubview(box)
        defer { box.removeFromSuperview() }

        var cancelled = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .leftMouseUp { break }
            if next.type == .keyDown {
                if next.keyCode == Key.escape, !cancelled {
                    cancelled = true
                    box.removeFromSuperview()
                    selectRowIndexes(original, byExtendingSelection: false)
                }
                continue
            }
            if cancelled { continue }
            autoscroll(with: next)
            let raw = convert(next.locationInWindow, from: nil)
            let current = NSPoint(x: min(max(raw.x, bounds.minX), bounds.maxX), y: min(max(raw.y, bounds.minY), bounds.maxY))
            let rect = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(start.x - current.x),
                height: abs(start.y - current.y)
            )
            box.frame = rect
            var picked = base
            let hit = rows(in: rect)
            if hit.length > 0 {
                picked.formUnion(IndexSet(integersIn: hit.location..<(hit.location + hit.length)))
            }
            if picked != selectedRowIndexes {
                selectRowIndexes(picked, byExtendingSelection: false)
            }
        }
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
    static let escape: UInt16 = 53
}

/// The translucent box drawn while dragging out a selection. Esc abandons it.
final class MarqueeBox: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
    }

    /// Gray like the box the system draws in the icon and preview views, so all three views match.
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tint: NSColor = dark ? .white : .black
        layer?.backgroundColor = tint.withAlphaComponent(dark ? 0.14 : 0.1).cgColor
        layer?.borderColor = tint.withAlphaComponent(dark ? 0.35 : 0.3).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The column headings. Right-clicking them opens the menu that adds and removes columns.
final class FileHeaderView: NSTableHeaderView {
    var menuProvider: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
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
    var onColumnsChange: ((URL, [ColumnSetting]) -> Void)?
    var onResetColumns: ((URL) -> Void)?
    /// Media details read for the whole folder so the store can sort by them. Keyed by standardized path.
    var onMediaLoaded: (([String: MediaInfo]) -> Void)?
    var folderSizes: FolderSizeIndex?
    var isRenaming: Bool { editingItem != nil }

    private let messageLabel = ClickThroughLabel(labelWithString: "")
    private let scrollView = NSScrollView()
    private var items: [FileItem] = []
    private var editingItem: FileItem?
    private var isReloading = false
    private var ignoreSelectionChanges = false
    private var columnsFolder: URL?
    private var applyingColumns = false
    private var pendingSave: DispatchWorkItem?
    private let media = MediaMetadataCache()
    private var loadingMediaForSort = false

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
        loadMediaForSort()
    }

    /// Sorting by a media column needs the values for every file, not only the rows on screen.
    private func loadMediaForSort() {
        guard let key = tableView.sortDescriptors.first?.key, DetailColumn(rawValue: key)?.isMedia == true else { return }
        let pending = items.filter { $0.media == nil && !$0.isDirectory }
        guard !pending.isEmpty, !loadingMediaForSort else { return }
        loadingMediaForSort = true
        media.loadAll(pending.map(\.url)) { [weak self] in
            guard let self else { return }
            self.loadingMediaForSort = false
            var details: [String: MediaInfo] = [:]
            for item in pending {
                details[item.url.standardized.path] = self.media.cached(item.url) ?? MediaInfo()
            }
            self.onMediaLoaded?(details)
            // The folder may have changed while this ran.
            self.loadMediaForSort()
        }
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
        guard let tableColumn, let column = DetailColumn(rawValue: tableColumn.identifier.rawValue),
              items.indices.contains(row) else { return nil }
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
        default:
            let cell = reuseTextCell(id: tableColumn.identifier, in: tableView)
            cell.show(text(for: column, of: item), alignment: .left)
            return cell
        }
    }

    private func text(for column: DetailColumn, of item: FileItem) -> String {
        switch column {
        case .name, .size: return ""
        case .kind: return item.kind
        case .modified: return item.modified.map { Format.date.string(from: $0) } ?? ""
        case .created: return item.created.map { Format.date.string(from: $0) } ?? ""
        case .accessed: return item.accessed.map { Format.date.string(from: $0) } ?? ""
        case .ext: return item.fileExtension
        case .permissions: return Format.permissions(item.permissions)
        case .owner: return item.owner ?? ""
        case .dimensions, .taken, .duration: return mediaText(column, of: item)
        }
    }

    private func mediaText(_ column: DetailColumn, of item: FileItem) -> String {
        guard !item.isDirectory else { return "" }
        guard let info = item.media ?? media.cached(item.url) else {
            media.load(item.url) { [weak self] in self?.reloadMediaCells(for: item.url) }
            return ""
        }
        guard info.isMedia else { return "" }
        switch column {
        case .dimensions:
            guard let width = info.width, let height = info.height else { return "" }
            return "\(width) × \(height)"
        case .taken:
            return info.taken.map { Format.date.string(from: $0) } ?? ""
        case .duration:
            return info.duration.map { Format.duration($0) } ?? ""
        default:
            return ""
        }
    }

    private func reloadMediaCells(for url: URL) {
        guard let row = items.firstIndex(where: { Paths.same($0.url, url) }) else { return }
        var columns = IndexSet()
        for (index, tableColumn) in tableView.tableColumns.enumerated() {
            if DetailColumn(rawValue: tableColumn.identifier.rawValue)?.isMedia == true { columns.insert(index) }
        }
        guard !columns.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: columns)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = SortColumn(rawValue: key) else { return }
        onSort?(column, descriptor.ascending)
        loadMediaForSort()
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
        let header = FileHeaderView()
        header.menuProvider = { [weak self] in self?.columnsMenu() ?? NSMenu() }
        tableView.headerView = header
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
        applyingColumns = true
        for column in DetailColumn.defaults {
            tableView.addTableColumn(makeColumn(column, width: nil))
        }
        applyingColumns = false
        tableView.sortDescriptors = [NSSortDescriptor(key: SortColumn.name.rawValue, ascending: true)]
        tableView.delegate = self
        tableView.unregisterDraggedTypes()
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask(.move, forLocal: false)

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

    private struct ColumnSpec {
        let title: String
        let width: CGFloat
        let min: CGFloat
        let alignment: NSTextAlignment
    }

    private func spec(_ column: DetailColumn) -> ColumnSpec {
        switch column {
        case .name: return ColumnSpec(title: L10n.name, width: 320, min: 140, alignment: .left)
        case .size: return ColumnSpec(title: L10n.size, width: 108, min: 80, alignment: .right)
        case .kind: return ColumnSpec(title: L10n.type, width: 140, min: 80, alignment: .left)
        case .modified: return ColumnSpec(title: L10n.dateModified, width: 170, min: 120, alignment: .left)
        case .created: return ColumnSpec(title: L10n.dateCreated, width: 170, min: 120, alignment: .left)
        case .accessed: return ColumnSpec(title: L10n.dateLastOpened, width: 170, min: 120, alignment: .left)
        case .ext: return ColumnSpec(title: L10n.fileExtension, width: 90, min: 60, alignment: .left)
        case .permissions: return ColumnSpec(title: L10n.permissions, width: 110, min: 80, alignment: .left)
        case .owner: return ColumnSpec(title: L10n.owner, width: 110, min: 70, alignment: .left)
        case .dimensions: return ColumnSpec(title: L10n.dimensions, width: 110, min: 80, alignment: .left)
        case .taken: return ColumnSpec(title: L10n.dateTaken, width: 170, min: 120, alignment: .left)
        case .duration: return ColumnSpec(title: L10n.duration, width: 90, min: 60, alignment: .left)
        }
    }

    private func makeColumn(_ column: DetailColumn, width: CGFloat?) -> NSTableColumn {
        let spec = spec(column)
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = spec.title
        tableColumn.width = width ?? spec.width
        tableColumn.minWidth = spec.min
        tableColumn.headerCell.alignment = spec.alignment
        tableColumn.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
        if let sortColumn = column.sortColumn {
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: sortColumn.rawValue, ascending: true)
        }
        return tableColumn
    }

    // MARK: Column layout per folder

    /// Shows the columns saved for `url`, or the default ones when nothing is saved.
    func applyColumns(for url: URL, layout: [ColumnSetting]?) {
        columnsFolder = url
        pendingSave?.cancel()
        media.reset()
        let wanted = layout ?? DetailColumn.defaults.map { ColumnSetting(id: $0.rawValue, width: Double(spec($0).width)) }
        setColumns(wanted)
    }

    private func setColumns(_ layout: [ColumnSetting]) {
        applyingColumns = true
        defer { applyingColumns = false }
        var wanted = layout.filter { DetailColumn(rawValue: $0.id) != nil }
        if !wanted.contains(where: { $0.id == DetailColumn.name.rawValue }) {
            wanted.insert(ColumnSetting(id: DetailColumn.name.rawValue, width: Double(spec(.name).width)), at: 0)
        }
        let ids = Set(wanted.map(\.id))
        for tableColumn in tableView.tableColumns where !ids.contains(tableColumn.identifier.rawValue) {
            tableView.removeTableColumn(tableColumn)
        }
        for setting in wanted where tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(setting.id)) < 0 {
            if let column = DetailColumn(rawValue: setting.id) {
                tableView.addTableColumn(makeColumn(column, width: CGFloat(setting.width)))
            }
        }
        for (index, setting) in wanted.enumerated() {
            let current = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(setting.id))
            guard current >= 0 else { continue }
            if current != index { tableView.moveColumn(current, toColumn: index) }
            tableView.tableColumns[index].width = CGFloat(setting.width)
        }
        // A hidden column cannot be the sort key, so fall back to the name.
        if let key = tableView.sortDescriptors.first?.key,
           tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(key)) < 0 {
            tableView.sortDescriptors = [NSSortDescriptor(key: SortColumn.name.rawValue, ascending: true)]
        }
    }

    private func currentLayout() -> [ColumnSetting] {
        tableView.tableColumns.map { ColumnSetting(id: $0.identifier.rawValue, width: Double($0.width)) }
    }

    private func saveNow() {
        pendingSave?.cancel()
        guard let url = columnsFolder else { return }
        onColumnsChange?(url, currentLayout())
    }

    /// Resizing fires many times while dragging, so the layout is saved once the drag settles.
    private func saveSoon() {
        pendingSave?.cancel()
        guard let url = columnsFolder else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.columnsFolder, Paths.same(current, url) else { return }
            self.onColumnsChange?(url, self.currentLayout())
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !applyingColumns, (tableView.headerView?.resizedColumn ?? -1) >= 0 else { return }
        saveSoon()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !applyingColumns else { return }
        saveSoon()
    }

    private func columnsMenu() -> NSMenu {
        let menu = NSMenu()
        let groups: [[DetailColumn]] = [
            [.name, .size, .kind, .modified, .created, .accessed, .ext, .permissions, .owner],
            [.dimensions, .taken, .duration],
        ]
        for group in groups {
            for column in group {
                let item = NSMenuItem(title: spec(column).title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                let visible = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)) >= 0
                item.state = visible ? .on : .off
                item.isEnabled = !column.isRequired
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let reset = NSMenuItem(title: L10n.resetColumns, action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = DetailColumn(rawValue: raw),
              !column.isRequired else { return }
        var layout = currentLayout()
        if let index = layout.firstIndex(where: { $0.id == raw }) {
            layout.remove(at: index)
        } else {
            layout.append(ColumnSetting(id: raw, width: Double(spec(column).width)))
        }
        setColumns(layout)
        saveNow()
    }

    @objc private func resetColumns(_ sender: Any?) {
        guard let url = columnsFolder else { return }
        applyColumns(for: url, layout: nil)
        onResetColumns?(url)
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
