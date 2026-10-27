import AppKit
import ExplorerCore

/// Every file in a horizontal line, with a preview of the selection above it.
final class ImagePreviewBrowser: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
    let view = PreviewContainer(frame: .zero)
    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMove: (([URL], URL) -> Void)?
    var onCommitRename: ((FileItem, String) -> Void)?
    var onContextTarget: ((FileItem?) -> Void)?

    private var items: [FileItem] = []
    private var stageToken = 0
    private var focusedIndex: Int?
    private var heldScrollX: CGFloat?
    private var restoringScroll = false
    private var ignoreSelectionChanges = false
    private var editingItem: FileItem?

    override init() {
        super.init()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 112, height: 100)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view.collection.collectionViewLayout = layout
        view.collection.isSelectable = true
        view.collection.allowsMultipleSelection = true
        view.collection.backgroundColors = [.clear]
        view.collection.usesScrollViewBackground = true
        view.collection.setDraggingSourceOperationMask(.move, forLocal: true)
        view.collection.setDraggingSourceOperationMask(.move, forLocal: false)
        view.scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stripScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: view.scroll.contentView
        )
        view.collection.dataSource = self
        view.collection.delegate = self
        view.collection.setAccessibilityIdentifier("image-strip")
        view.collection.register(StripCollectionItem.self, forItemWithIdentifier: StripCollectionItem.reuseID)
        view.collection.onOpenIndex = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.onOpen?(self.items[index])
        }
        view.collection.onDelete = { [weak self] in self?.onDelete?() }
        view.collection.onRenameIndex = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.beginRename(url: self.items[index].url)
        }
        view.collection.onContextIndex = { [weak self] index in
            guard let self else { return }
            let item = index.flatMap { self.items.indices.contains($0) ? self.items[$0] : nil }
            self.onContextTarget?(item)
        }
        view.collection.onFocusedIndex = { [weak self] index in
            guard let self, self.view.collection.selectionIndexPaths.contains(IndexPath(item: index, section: 0)) else { return }
            self.focusedIndex = index
        }
        view.collection.onSelectionChange = { [weak self] in
            self?.loadStage()
            self?.onSelectionChange?()
        }
        view.onLayout = { [weak self] in self?.fitStrip() }
        let click = NSClickGestureRecognizer(target: self, action: #selector(openStage(_:)))
        click.numberOfClicksRequired = 2
        view.stage.addGestureRecognizer(click)
    }

    func show(items: [FileItem], preserveScroll: Bool) {
        heldScrollX = preserveScroll ? view.scroll.contentView.bounds.origin.x : 0
        self.items = items
        stageToken += 1
        clearStage()
        ignoreSelectionChanges = true
        view.collection.reloadData()
        ignoreSelectionChanges = false
        fitStrip()
        view.needsLayout = true
    }

    func applySelection(paths: Set<String>, focused: String?, reveal: Bool) {
        var indexPaths = Set<IndexPath>()
        var focus: Int?
        for (index, item) in items.enumerated() where paths.contains(item.url.standardized.path) {
            indexPaths.insert(IndexPath(item: index, section: 0))
            if item.url.standardized.path == focused {
                focus = index
            }
        }
        ignoreSelectionChanges = true
        view.collection.selectionIndexPaths = indexPaths
        focusedIndex = focus ?? indexPaths.map(\.item).max()
        view.collection.syncSelectionAnchor()
        ignoreSelectionChanges = false
        if reveal, let focusedIndex {
            view.collection.scrollToItems(
                at: [IndexPath(item: focusedIndex, section: 0)],
                scrollPosition: .nearestHorizontalEdge
            )
        }
        loadStage()
    }

    @discardableResult
    func beginRename(url: URL) -> Bool {
        guard let index = items.firstIndex(where: { Paths.same($0.url, url) }) else { return false }
        let indexPath = IndexPath(item: index, section: 0)
        let item = items[index]
        view.collection.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        view.collection.layoutSubtreeIfNeeded()
        guard let strip = view.collection.item(at: indexPath) as? StripCollectionItem else { return false }
        editingItem = item
        strip.beginEditing(text: item.name, delegate: self, selectsAll: item.opensAsFolder)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let item = editingItem, let field = obj.object as? NSTextField else { return }
        let cancelled = NameEditing.movement(in: obj) == NSTextMovement.cancel.rawValue || (field as? RenameField)?.cancelled == true
        let typed = field.stringValue
        editingItem = nil
        (field as? RenameField)?.close()
        if let index = items.firstIndex(where: { Paths.same($0.url, item.url) }),
           let strip = view.collection.item(at: IndexPath(item: index, section: 0)) as? StripCollectionItem {
            strip.finishEditing()
            if cancelled { strip.show(item) }
        } else {
            NameEditing.finish(field, bezeled: true)
        }
        if !cancelled { onCommitRename?(item, typed) }
    }

    func selectionPaths() -> Set<String> {
        Set(selectedItems().map { $0.url.standardized.path })
    }

    func focusedPath() -> String? {
        guard let focusedIndex,
              items.indices.contains(focusedIndex),
              view.collection.selectionIndexPaths.contains(IndexPath(item: focusedIndex, section: 0)) else { return nil }
        return items[focusedIndex].url.standardized.path
    }

    @objc private func stripScrolled(_ notification: Notification) {
        if restoringScroll { return }
        heldScrollX = nil
    }

    func setOverlay(_ text: String?) {
        if let text {
            view.overlayLabel.stringValue = text
            view.overlayLabel.isHidden = false
            view.itemMessage.isHidden = true
            view.stage.isHidden = true
            view.textScroll.isHidden = true
            view.stage.image = nil
            view.textView.string = ""
            view.nameLabel.stringValue = ""
        } else {
            view.overlayLabel.isHidden = true
        }
        view.needsLayout = true
    }

    func selectedItems() -> [FileItem] {
        view.collection.selectionIndexPaths.compactMap { indexPath in
            items.indices.contains(indexPath.item) ? items[indexPath.item] : nil
        }
    }

    private func focusedItem() -> FileItem? {
        if let focusedIndex,
           items.indices.contains(focusedIndex),
           view.collection.selectionIndexPaths.contains(IndexPath(item: focusedIndex, section: 0)) {
            return items[focusedIndex]
        }
        guard let index = view.collection.selectionIndexPaths.map(\.item).sorted().last,
              items.indices.contains(index) else { return nil }
        return items[index]
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: StripCollectionItem.reuseID, for: indexPath)
        if let strip = item as? StripCollectionItem {
            strip.onMove = { [weak self] urls, folder in self?.onMove?(urls, folder) }
            strip.show(items[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard items.indices.contains(indexPath.item) else { return nil }
        return items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !ignoreSelectionChanges else { return }
        if indexPaths.count == 1, let index = indexPaths.first?.item {
            focusedIndex = index
        }
        loadStage()
        onSelectionChange?()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !ignoreSelectionChanges else { return }
        if let focusedIndex, indexPaths.contains(IndexPath(item: focusedIndex, section: 0)) {
            self.focusedIndex = collectionView.selectionIndexPaths.map(\.item).max()
        }
        loadStage()
        onSelectionChange?()
    }

    private func loadStage() {
        guard view.overlayLabel.isHidden else { return }
        guard let item = focusedItem() else {
            clearStage()
            return
        }
        view.nameLabel.stringValue = item.displayName
        stageToken += 1
        let token = stageToken
        let path = item.url.path
        guard let provider = FilePreviews.provider(for: item) else {
            showUnavailable()
            return
        }
        provider.loadPreview(item) { [weak self] preview in
            guard let self, token == self.stageToken, self.focusedItem()?.url.path == path else { return }
            guard self.view.overlayLabel.isHidden else { return }
            switch preview {
            case let .image(image):
                self.showImage(image)
            case let .text(text):
                self.showText(text)
            case .unavailable:
                self.showUnavailable()
            }
        }
    }

    private func clearStage() {
        view.stage.image = nil
        view.stage.isHidden = true
        view.textView.string = ""
        view.textScroll.isHidden = true
        view.itemMessage.isHidden = true
        view.nameLabel.stringValue = ""
    }

    private func showImage(_ image: NSImage) {
        view.stage.image = image
        view.stage.isHidden = false
        view.textScroll.isHidden = true
        view.textView.string = ""
        view.itemMessage.isHidden = true
    }

    private func showText(_ text: String) {
        view.stage.image = nil
        view.stage.isHidden = true
        view.itemMessage.isHidden = true
        view.textView.string = text
        view.textScroll.isHidden = false
        view.needsLayout = true
    }

    private func showUnavailable() {
        view.stage.image = nil
        view.stage.isHidden = true
        view.textScroll.isHidden = true
        view.textView.string = ""
        view.itemMessage.stringValue = L10n.previewUnavailable
        view.itemMessage.isHidden = false
        view.needsLayout = true
    }

    private func fitStrip() {
        let width = max(view.scroll.contentView.bounds.width, 1)
        let height = max(view.scroll.contentView.bounds.height, 1)
        view.collection.collectionViewLayout?.invalidateLayout()
        let contentWidth = view.collection.collectionViewLayout?.collectionViewContentSize.width ?? width
        let size = NSSize(width: max(width, contentWidth), height: height)
        if abs(view.collection.frame.width - size.width) > 1 || abs(view.collection.frame.height - size.height) > 1 {
            view.collection.setFrameSize(size)
        }
        guard let heldScrollX else { return }
        let clip = view.scroll.contentView
        let maxX = max(0, view.collection.frame.width - clip.bounds.width)
        let x = min(max(0, heldScrollX), maxX)
        guard abs(clip.bounds.origin.x - x) > 0.5 else { return }
        restoringScroll = true
        clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        view.scroll.reflectScrolledClipView(clip)
        restoringScroll = false
    }

    @objc private func openStage(_ sender: Any?) {
        guard let item = focusedItem() else { return }
        onOpen?(item)
    }
}

final class PreviewContainer: NSView {
    let stage = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let scroll = NSScrollView()
    let collection = ClickableCollectionView()
    let overlayLabel = ClickThroughLabel(labelWithString: "")
    let itemMessage = ClickThroughLabel(labelWithString: "")
    let textScroll = NSScrollView()
    let textView = NSTextView()
    let separator = NSBox()
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stage.imageScaling = .scaleProportionallyUpOrDown
        stage.imageAlignment = .alignCenter
        stage.animates = true
        stage.setAccessibilityIdentifier("image-preview")
        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        for label in [overlayLabel, itemMessage] {
            label.alignment = .center
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.isHidden = true
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .noBorder
        textScroll.documentView = textView
        textScroll.isHidden = true
        separator.boxType = .separator
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = .windowBackgroundColor
        scroll.borderType = .noBorder
        scroll.documentView = collection
        addSubview(stage)
        addSubview(textScroll)
        addSubview(nameLabel)
        addSubview(itemMessage)
        addSubview(overlayLabel)
        addSubview(separator)
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        place()
    }

    private func place() {
        let strip: CGFloat = 128
        let width = bounds.width
        let height = bounds.height
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: min(strip, height))
        separator.frame = NSRect(x: 0, y: scroll.frame.maxY, width: width, height: 1)
        nameLabel.frame = NSRect(x: 12, y: separator.frame.maxY + 6, width: max(0, width - 24), height: 16)
        let stageY = nameLabel.frame.maxY + 4
        let stageFrame = NSRect(x: 16, y: stageY, width: max(0, width - 32), height: max(0, height - stageY - 12))
        stage.frame = stageFrame
        textScroll.frame = stageFrame
        let textWidth = max(textScroll.contentSize.width, 1)
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(stageFrame.height, textView.frame.height))
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        center(overlayLabel, in: stageFrame, width: width)
        center(itemMessage, in: stageFrame, width: width)
        onLayout?()
    }

    private func center(_ label: NSTextField, in stageFrame: NSRect, width: CGFloat) {
        label.sizeToFit()
        label.frame = NSRect(
            x: 12,
            y: stageFrame.midY - label.frame.height / 2,
            width: max(0, width - 24),
            height: label.frame.height
        )
    }
}

final class StripCollectionItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("StripItem")

    var onMove: (([URL], URL) -> Void)?
    private let iconView = DragForwardingImageView()
    private let nameField = NSTextField(labelWithString: "")
    private var representedPath: String?

    override func loadView() {
        let container = IconDropView(frame: NSRect(x: 0, y: 0, width: 112, height: 100))
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        iconView.unregisterDraggedTypes()
        nameField.unregisterDraggedTypes()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.alignment = .center
        nameField.maximumNumberOfLines = 2
        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = .systemFont(ofSize: 11)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)
        container.addSubview(nameField)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
            nameField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
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
        iconView.image = Icons.file(item.url, pointSize: 56)
        iconView.toolTip = item.displayName
        iconView.unregisterDraggedTypes()
        nameField.unregisterDraggedTypes()
        guard let provider = FilePreviews.provider(for: item) else { return }
        let path = item.url.path
        provider.loadThumbnail(item, maxPixel: 240) { [weak self] image in
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
