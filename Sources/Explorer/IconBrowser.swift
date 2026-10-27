import AppKit
import ExplorerCore

final class ClickableCollectionView: NSCollectionView {
    var onOpenIndex: ((Int) -> Void)?
    var onDelete: (() -> Void)?
    var onRenameIndex: ((Int) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onFocusedIndex: ((Int) -> Void)?
    var onContextIndex: ((Int?) -> Void)?
    /// The preview strip scrolls horizontally. AppKit's own background is only as wide as the
    /// viewport and is a subview of the document, so it slides with the icons.
    var usesScrollViewBackground = false

    private var selectionAnchor: IndexPath?
    private var handledShiftSelection = false
    private let renameClick = RenameClick()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        renameClick.onRename = { [weak self] in
            guard let self, self.selectionIndexPaths.count == 1, let index = self.selectionIndexPaths.first?.item else { return }
            self.onRenameIndex?(index)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isOpaque: Bool {
        usesScrollViewBackground ? false : super.isOpaque
    }

    override func draw(_ dirtyRect: NSRect) {
        if usesScrollViewBackground { return }
        super.draw(dirtyRect)
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        guard usesScrollViewBackground else { return }
        backgroundColors = [.clear]
        backgroundView?.isHidden = true
        for subview in subviews where Self.isCollectionBackground(subview) {
            subview.isHidden = true
        }
    }

    private static func isCollectionBackground(_ view: NSView) -> Bool {
        let name = NSStringFromClass(type(of: view))
        return name.contains("Background") || name.contains("ColorView")
    }

    func syncSelectionAnchor() {
        selectionAnchor = selectionIndexPaths.min { $0.item < $1.item }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        renameClick.cancel()
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
            }
            onSelectionChange?()
            onContextIndex?(indexPath.item)
        } else {
            deselectAll(nil)
            onSelectionChange?()
            onContextIndex?(nil)
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        renameClick.cancel()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let already = indexPath.map { selectionIndexPaths == [$0] } ?? false
        if indexPath == nil, event.clickCount == 1 {
            trackMarquee(from: event)
            return
        }
        let start = event.locationInWindow
        if shift, !command, allowsMultipleSelection, let indexPath {
            selectRange(through: indexPath)
            handledShiftSelection = true
            return
        }
        handledShiftSelection = false
        if let indexPath, !command, !shift {
            selectionAnchor = indexPath
        }
        super.mouseDown(with: event)
        if let indexPath, command {
            onFocusedIndex?(indexPath.item)
            onSelectionChange?()
        }
        if selectionIndexPaths.isEmpty {
            selectionAnchor = nil
        }
        let end = window?.mouseLocationOutsideOfEventStream ?? start
        let dragged = hypot(end.x - start.x, end.y - start.y) > 4
        renameClick.arm(alreadySelected: already, clickCount: event.clickCount, modifiers: event.modifierFlags, dragged: dragged)
    }

    /// Dragging from empty space draws a box and selects the items it touches while it moves. Esc abandons it.
    private func trackMarquee(from event: NSEvent) {
        guard let window else { return }
        let start = convert(event.locationInWindow, from: nil)
        let extend = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        let original = selectionIndexPaths
        let base = extend ? original : []
        window.makeFirstResponder(self)
        if !extend, !original.isEmpty {
            selectionIndexPaths = []
            onSelectionChange?()
        }

        let box = MarqueeBox()
        addSubview(box)
        defer {
            box.removeFromSuperview()
            if selectionIndexPaths.isEmpty { selectionAnchor = nil } else { syncSelectionAnchor() }
        }

        var cancelled = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .leftMouseUp { break }
            if next.type == .keyDown {
                if next.keyCode == 53, !cancelled {
                    cancelled = true
                    box.removeFromSuperview()
                    selectionIndexPaths = original
                    onSelectionChange?()
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
            for attributes in collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
            where attributes.representedElementCategory == .item {
                if let indexPath = attributes.indexPath, attributes.frame.intersects(rect) {
                    picked.insert(indexPath)
                }
            }
            if picked != selectionIndexPaths {
                selectionIndexPaths = picked
                if let last = picked.max(by: { $0.item < $1.item }) {
                    onFocusedIndex?(last.item)
                }
                onSelectionChange?()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if handledShiftSelection {
            handledShiftSelection = false
            return
        }
        super.mouseUp(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return }
        onOpenIndex?(indexPath.item)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.isDisjoint(with: [.command, .option, .control])
        if plain, event.keyCode == 36 || event.keyCode == 76 {
            guard selectionIndexPaths.count == 1, let index = selectionIndexPaths.first?.item else { return }
            onRenameIndex?(index)
            return
        }
        if plain, event.keyCode == 51 || event.keyCode == 117 || event.keyCode == 7 {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }

    private func selectRange(through indexPath: IndexPath) {
        let count = numberOfItems(inSection: indexPath.section)
        guard count > 0, indexPath.item >= 0, indexPath.item < count else { return }
        let anchorItem = selectionAnchor.flatMap { anchor in
            anchor.section == indexPath.section && anchor.item < count ? anchor.item : nil
        } ?? selectionIndexPaths.map(\.item).filter { $0 < count }.min() ?? indexPath.item
        let lower = min(anchorItem, indexPath.item)
        let upper = max(anchorItem, indexPath.item)
        selectionIndexPaths = Set((lower...upper).map { IndexPath(item: $0, section: indexPath.section) })
        selectionAnchor = IndexPath(item: anchorItem, section: indexPath.section)
        window?.makeFirstResponder(self)
        onFocusedIndex?(indexPath.item)
        onSelectionChange?()
    }
}

final class IconBrowser: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
    let view = IconBrowserView()
    let collection = ClickableCollectionView()
    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMove: (([URL], URL) -> Void)?
    var onCommitRename: ((FileItem, String) -> Void)?
    var onContextTarget: ((FileItem?) -> Void)?

    private let scrollView = NSScrollView()
    private let messageLabel = ClickThroughLabel(labelWithString: "")
    private var items: [FileItem] = []
    private var focusedIndex: Int?
    private var ignoreSelectionChanges = false
    private var editingItem: FileItem?

    override init() {
        super.init()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 104, height: 112)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.textBackgroundColor]
        collection.dataSource = self
        collection.delegate = self
        collection.setAccessibilityIdentifier("icon-grid")
        collection.register(IconCollectionItem.self, forItemWithIdentifier: IconCollectionItem.reuseID)
        collection.onOpenIndex = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.onOpen?(self.items[index])
        }
        collection.onDelete = { [weak self] in self?.onDelete?() }
        collection.onRenameIndex = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.beginRename(url: self.items[index].url)
        }
        collection.onContextIndex = { [weak self] index in
            guard let self else { return }
            let item = index.flatMap { self.items.indices.contains($0) ? self.items[$0] : nil }
            self.onContextTarget?(item)
        }
        collection.onFocusedIndex = { [weak self] index in
            guard let self, self.collection.selectionIndexPaths.contains(IndexPath(item: index, section: 0)) else { return }
            self.focusedIndex = index
        }
        collection.onSelectionChange = { [weak self] in self?.onSelectionChange?() }
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask(.move, forLocal: false)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.documentView = collection
        view.addSubview(scrollView)

        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true
        view.addSubview(messageLabel)
        view.onLayout = { [weak self] in self?.layoutContents() }
    }

    func show(items: [FileItem]) {
        self.items = items
        ignoreSelectionChanges = true
        collection.reloadData()
        ignoreSelectionChanges = false
        layoutContents()
    }

    func applySelection(paths: Set<String>, focused: String?, reveal: Bool) {
        var indexPaths = Set<IndexPath>()
        var focus: Int?
        for (index, item) in items.enumerated() where paths.contains(item.url.standardized.path) {
            let indexPath = IndexPath(item: index, section: 0)
            indexPaths.insert(indexPath)
            if item.url.standardized.path == focused {
                focus = index
            }
        }
        focusedIndex = focus ?? indexPaths.map(\.item).max()
        ignoreSelectionChanges = true
        collection.selectionIndexPaths = indexPaths
        collection.syncSelectionAnchor()
        ignoreSelectionChanges = false
        if reveal, let focusedIndex {
            collection.scrollToItems(at: [IndexPath(item: focusedIndex, section: 0)], scrollPosition: .centeredVertically)
        }
    }

    func selectionPaths() -> Set<String> {
        Set(selectedItems().map { $0.url.standardized.path })
    }

    func focusedPath() -> String? {
        guard let focusedIndex,
              items.indices.contains(focusedIndex),
              collection.selectionIndexPaths.contains(IndexPath(item: focusedIndex, section: 0)) else { return nil }
        return items[focusedIndex].url.standardized.path
    }

    func setMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil || !items.isEmpty
        layoutContents()
    }

    func selectedItems() -> [FileItem] {
        collection.selectionIndexPaths.compactMap { indexPath in
            items.indices.contains(indexPath.item) ? items[indexPath.item] : nil
        }
    }

    @discardableResult
    func beginRename(url: URL) -> Bool {
        guard let index = items.firstIndex(where: { Paths.same($0.url, url) }) else { return false }
        let indexPath = IndexPath(item: index, section: 0)
        let item = items[index]
        collection.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
        collection.layoutSubtreeIfNeeded()
        guard let icon = collection.item(at: indexPath) as? IconCollectionItem else { return false }
        editingItem = item
        icon.beginEditing(text: item.name, delegate: self, selectsAll: item.opensAsFolder)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let item = editingItem, let field = obj.object as? NSTextField else { return }
        let cancelled = NameEditing.movement(in: obj) == NSTextMovement.cancel.rawValue || (field as? RenameField)?.cancelled == true
        let typed = field.stringValue
        editingItem = nil
        (field as? RenameField)?.close()
        if let index = items.firstIndex(where: { Paths.same($0.url, item.url) }),
           let icon = collection.item(at: IndexPath(item: index, section: 0)) as? IconCollectionItem {
            icon.finishEditing()
            if cancelled { icon.show(item) }
        } else {
            NameEditing.finish(field, bezeled: true)
        }
        if !cancelled { onCommitRename?(item, typed) }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconCollectionItem.reuseID, for: indexPath)
        if let icon = item as? IconCollectionItem {
            icon.onMove = { [weak self] urls, folder in self?.onMove?(urls, folder) }
            icon.show(items[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !ignoreSelectionChanges else { return }
        if indexPaths.count == 1, let index = indexPaths.first?.item {
            focusedIndex = index
        }
        onSelectionChange?()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !ignoreSelectionChanges else { return }
        if let focusedIndex, indexPaths.contains(IndexPath(item: focusedIndex, section: 0)) {
            self.focusedIndex = collectionView.selectionIndexPaths.map(\.item).max()
        }
        onSelectionChange?()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard items.indices.contains(indexPath.item) else { return nil }
        return items[indexPath.item].url as NSURL
    }

    private func layoutContents() {
        scrollView.frame = view.bounds
        let width = max(scrollView.contentView.bounds.width, 1)
        collection.collectionViewLayout?.invalidateLayout()
        let contentHeight = collection.collectionViewLayout?.collectionViewContentSize.height ?? 0
        let height = max(scrollView.contentView.bounds.height, contentHeight)
        if abs(collection.frame.width - width) > 1 || abs(collection.frame.height - height) > 1 {
            collection.setFrameSize(NSSize(width: width, height: height))
        }
        messageLabel.sizeToFit()
        messageLabel.frame = NSRect(
            x: 20,
            y: max(0, (view.bounds.height - messageLabel.frame.height) / 2),
            width: max(0, view.bounds.width - 40),
            height: messageLabel.frame.height
        )
    }
}

final class IconBrowserView: NSView {
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

/// The whole icon, name included, is the drop target.
final class IconDropView: NSView {
    var canAccept: ((NSDraggingInfo) -> Bool)?
    var accept: ((NSDraggingInfo) -> Bool)?
    private var targeted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        return accept?(sender) ?? false
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = canAccept?(sender) == true
        setTargeted(ok)
        return ok ? .move : []
    }

    private func setTargeted(_ on: Bool) {
        guard targeted != on else { return }
        targeted = on
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

final class IconCollectionItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("IconItem")

    var onMove: (([URL], URL) -> Void)?
    private let iconView = DragForwardingImageView()
    private let nameField = NSTextField(labelWithString: "")
    private var representedPath: String?

    override func loadView() {
        let container = IconDropView(frame: NSRect(x: 0, y: 0, width: 104, height: 112))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.alignment = .center
        nameField.maximumNumberOfLines = 2
        nameField.lineBreakMode = .byWordWrapping
        nameField.font = .systemFont(ofSize: 11)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        iconView.unregisterDraggedTypes()
        nameField.unregisterDraggedTypes()
        container.addSubview(iconView)
        container.addSubview(nameField)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            nameField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ])
        view = container
        applySelection()
    }

    override var isSelected: Bool {
        didSet {
            guard isViewLoaded else { return }
            applySelection()
        }
    }

    /// While a marquee is dragged AppKit marks items as about to be selected or deselected.
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            guard isViewLoaded else { return }
            applySelection()
        }
    }

    func beginEditing(text: String, delegate: NSTextFieldDelegate, selectsAll: Bool) {
        NameEditing.begin(nameField, text: text, delegate: delegate, selectsAll: selectsAll, bezeled: true)
    }

    func finishEditing() {
        NameEditing.finish(nameField, bezeled: true)
    }

    func show(_ item: FileItem) {
        representedPath = item.url.path
        nameField.stringValue = item.displayName
        nameField.toolTip = item.displayName
        let drop = view as? IconDropView
        if item.opensAsFolder {
            let folder = item.url
            drop?.canAccept = { FileActions.canMove(DraggedFiles.urls(from: $0), to: folder) }
            drop?.accept = { [weak self] info in
                let urls = DraggedFiles.urls(from: info)
                guard FileActions.canMove(urls, to: folder) else { return false }
                self?.onMove?(urls, folder)
                return true
            }
        } else {
            drop?.canAccept = nil
            drop?.accept = nil
        }
        iconView.image = Icons.file(item.url, pointSize: 64)
        iconView.unregisterDraggedTypes()
        nameField.unregisterDraggedTypes()
        guard let provider = FilePreviews.provider(for: item) else { return }
        let path = item.url.path
        provider.loadThumbnail(item, maxPixel: 128) { [weak self] image in
            guard let self, self.representedPath == path, let image else { return }
            self.iconView.image = image
        }
    }

    private func applySelection() {
        let selected: Bool
        switch highlightState {
        case .forSelection: selected = true
        case .forDeselection: selected = false
        default: selected = isSelected
        }
        let previewing = highlightState == .forSelection && !isSelected
        view.layer?.backgroundColor = selected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(previewing ? 0.2 : 0.35).cgColor
            : NSColor.clear.cgColor
    }
}
