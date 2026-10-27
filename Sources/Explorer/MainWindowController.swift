import AppKit
import ExplorerCore

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSplitViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let store: BrowserStore
    private let folderSizes: FolderSizeIndex
    private let folderViews: FolderViewStore
    private let content = ContentPane()
    private let tree = FolderTreeController()
    private let split = NSSplitView()
    private let pathField = NSTextField()
    private let searchField = NSSearchField()
    private let regexCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var accessSheet = false
    private var declinedAccess = false
    private var viewItem: NSMenuToolbarItem?
    private let viewMenu = NSMenu()
    private let statusField = NSTextField(labelWithString: "")
    private var itemMenu: NSMenu?
    private var heldFiles: HeldFiles?
    private var contextURLs: [URL]?
    private var contextPasteURL: URL?
    private var contextDisablesPaste = false
    private var mouseMonitor: Any?
    private var lastCompletedURL: URL?
    private var pendingTreeURL: URL?
    private var displayedURL: URL?
    private var committingPath = false
    private var selectAfterLoad: URL?
    private var searchFolder: URL?
    private let launchURL: URL
    private var savedStates: [String: BrowseState] = [:]
    private var restoreOnArrival = false
    private var scrollToRestore: NSPoint?
    private var selectionToRestore: [URL] = []

    init(startingAt url: URL? = nil) {
        let databaseURL = FolderSizeIndex.defaultDatabaseURL()
        folderSizes = FolderSizeIndex(databaseURL: databaseURL)
        folderViews = FolderViewStore(databaseURL: databaseURL)
        launchURL = url ?? FileManager.default.homeDirectoryForCurrentUser
        store = BrowserStore(startingAt: launchURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Explorer"
        window.minSize = NSSize(width: 680, height: 420)
        window.toolbarStyle = .expanded
        window.titlebarSeparatorStyle = .line
        super.init(window: window)
        buildInterface()
        buildToolbar()
        installMouseNavigation()
        NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.tree.rebuildSidebar(revealing: self.store.snapshot.url)
            self.store.refresh()
        }
        // Drives plugged in or ejected while the app is open.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.tree.rebuildSidebar(revealing: self.store.snapshot.url)
            }
        }
        wire()
        let frameName = "ExplorerMainWindow"
        window.center()
        _ = window.setFrameUsingName(frameName)
        window.setFrameAutosaveName(frameName)
        store.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !UserDefaults.standard.bool(forKey: Self.didPlaceSplitKey) {
            split.setPosition(220, ofDividerAt: 0)
            UserDefaults.standard.set(true, forKey: Self.didPlaceSplitKey)
        }
        tree.reveal(store.snapshot.url)
        window?.makeFirstResponder(content.keyView)
        window?.toolbar?.validateVisibleItems()
        DispatchQueue.main.async { [weak self] in
            self?.offerFullDiskAccess()
        }
    }

    // Back and Forward return to the page as it was left. Up and opening a folder start clean.
    @objc func goBack(_ sender: Any?) {
        restoreOnArrival = store.snapshot.canGoBack
        store.back()
    }

    @objc func goForward(_ sender: Any?) {
        restoreOnArrival = store.snapshot.canGoForward
        store.forward()
    }

    @objc func goUp(_ sender: Any?) { store.up() }
    @objc func refresh(_ sender: Any?) { store.refresh() }

    @objc func toggleHidden(_ sender: Any?) { store.toggleShowHidden() }

    @objc func newFolder(_ sender: Any?) {
        do {
            let created = try store.createFolder(named: L10n.newFolder)
            folderSizes.noteCreatedFolder(created)
        } catch {
            present(error)
        }
    }

    @objc func openSelection(_ sender: Any?) {
        open(actedURLs())
    }

    @objc func renameSelection(_ sender: Any?) {
        let urls = actedURLs()
        guard urls.count == 1, let url = urls.first else { return }
        if content.beginRename(url: url) { return }
        promptRename(url: url)
    }

    @objc func chooseViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = BrowserViewMode(rawValue: raw) else { return }
        setViewMode(mode, remember: true)
    }

    @objc func cut(_ sender: Any?) {
        let urls = actedURLs()
        guard !urls.isEmpty else { return }
        heldFiles = HeldFiles(operation: .cut, urls: urls)
    }

    @objc func copy(_ sender: Any?) {
        let urls = actedURLs()
        guard !urls.isEmpty else { return }
        heldFiles = HeldFiles(operation: .copy, urls: urls)
    }

    @objc func paste(_ sender: Any?) {
        guard let heldFiles, let destination = pasteDestination() else { return }
        let parents = Set(heldFiles.urls.compactMap { Paths.parent(of: $0) })
        do {
            switch heldFiles.operation {
            case .copy:
                let copies = try FileActions.duplicate(heldFiles.urls, to: destination)
                folderSizes.noteCopied(from: heldFiles.urls, to: copies)
            case .cut:
                let moving = heldFiles.urls.filter { url in
                    guard let parent = Paths.parent(of: url) else { return true }
                    return !Paths.same(parent, destination)
                }
                if !moving.isEmpty {
                    let plan = folderSizes.planMove(of: moving, to: destination)
                    do {
                        try FileActions.move(moving, to: destination)
                        folderSizes.finishMove(plan)
                        retargetFolderViews(moving, to: destination)
                    } catch {
                        folderSizes.finishMove(plan)
                        retargetFolderViews(moving, to: destination)
                        throw error
                    }
                }
                self.heldFiles = nil
            }
            store.refresh()
            tree.refreshExpandedFolder(destination)
            for parent in parents {
                tree.refreshExpandedFolder(parent)
            }
        } catch {
            folderSizes.markRevalidating([destination])
            present(error)
        }
    }

    @objc func trashSelection(_ sender: Any?) {
        let urls = actedURLs()
        guard !urls.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? String(format: L10n.confirmTrashOne, urls[0].lastPathComponent)
            : String(format: L10n.confirmTrashMany, urls.count)
        alert.alertStyle = .warning
        let confirm = alert.addButton(withTitle: L10n.moveToTrash)
        confirm.keyEquivalent = "\r"
        alert.addButton(withTitle: L10n.cancel).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.trash(urls)
        }
    }

    @objc func toggleBookmark(_ sender: Any?) {
        let urls = actedURLs()
        guard urls.count == 1, let url = urls.first, isNavigableFolder(url) else { return }
        if BookmarkStore.shared.contains(url) {
            BookmarkStore.shared.remove(url)
        } else {
            BookmarkStore.shared.add(url)
        }
    }

    @objc func openShell(_ sender: Any?) {
        let urls = actedURLs()
        let target: URL
        if urls.count == 1, let url = urls.first, isNavigableFolder(url) {
            target = url
        } else {
            target = store.snapshot.url
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([target], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private func trash(_ urls: [URL]) {
        let parents = Set(urls.compactMap { Paths.parent(of: $0) })
        let plan = folderSizes.planRemoval(of: urls)
        var first: Error?
        var succeeded: [URL] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                succeeded.append(url)
            } catch {
                if first == nil { first = error }
            }
        }
        folderSizes.finishRemoval(plan, succeeded: succeeded)
        for url in succeeded {
            folderViews.forget(url)
            BookmarkStore.shared.forget(url)
        }
        store.refresh()
        for parent in parents {
            tree.refreshExpandedFolder(parent)
        }
        if let first { present(first) }
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = actedURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let snapshot = store.snapshot
        let urls = actedURLs()
        switch item.action {
        case #selector(goBack(_:)):
            return snapshot.canGoBack
        case #selector(goForward(_:)):
            return snapshot.canGoForward
        case #selector(goUp(_:)):
            return snapshot.canGoUp
        case #selector(openSelection(_:)):
            return !urls.isEmpty
        case #selector(renameSelection(_:)):
            return urls.count == 1
        case #selector(cut(_:)), #selector(copy(_:)):
            return !urls.isEmpty
        case #selector(paste(_:)):
            return heldFiles != nil && pasteDestination() != nil
        case #selector(trashSelection(_:)):
            return !urls.isEmpty
        case #selector(showInFinder(_:)):
            return !urls.isEmpty
        case #selector(openWithApp(_:)), #selector(openWithOther(_:)):
            return true
        case #selector(toggleHidden(_:)):
            (item as? NSMenuItem)?.state = snapshot.showHidden ? .on : .off
            return true
        case #selector(chooseViewMode(_:)):
            let raw = (item as? NSMenuItem)?.representedObject as? String
            (item as? NSMenuItem)?.state = raw == content.mode.rawValue ? .on : .off
            return true
        default:
            return true
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward, .up, .viewMode, .flexibleSpace, .openShell, .newFolder]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .forward, .up, .viewMode, .flexibleSpace, .openShell, .newFolder]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == .viewMode {
            let menuItem = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            menuItem.label = L10n.view
            menuItem.paletteLabel = L10n.view
            menuItem.toolTip = L10n.view
            menuItem.showsIndicator = true
            menuItem.isBordered = true
            menuItem.menu = viewMenu
            viewItem = menuItem
            refreshViewControl()
            return menuItem
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .back:
            configure(item, label: L10n.back, symbol: "chevron.backward", action: #selector(goBack(_:)), navigational: true)
        case .forward:
            configure(item, label: L10n.forward, symbol: "chevron.forward", action: #selector(goForward(_:)), navigational: true)
        case .up:
            configure(item, label: L10n.up, symbol: "arrow.up", action: #selector(goUp(_:)), navigational: false)
        case .openShell:
            configure(item, label: L10n.openShell, symbol: "terminal", action: #selector(openShell(_:)), navigational: false)
        case .newFolder:
            configure(item, label: L10n.newFolder, symbol: "folder.badge.plus", action: #selector(newFolder(_:)), navigational: false)
        default:
            return nil
        }
        return item
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        160
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(160, splitView.bounds.width - 280)
    }

    private func buildInterface() {
        guard let root = window?.contentView else { return }

        let pathBar = NSView()
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        let address = NSTextField(labelWithString: L10n.address)
        address.font = .systemFont(ofSize: 13)
        address.textColor = .labelColor
        address.translatesAutoresizingMaskIntoConstraints = false
        address.setContentHuggingPriority(.required, for: .horizontal)
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.isEditable = true
        pathField.isSelectable = true
        pathField.isBezeled = true
        pathField.bezelStyle = .roundedBezel
        pathField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        pathField.focusRingType = .none
        pathField.delegate = self
        pathField.setAccessibilityIdentifier("address-bar")
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setContentHuggingPriority(.required, for: .vertical)
        pathField.cell?.lineBreakMode = .byTruncatingHead
        pathField.cell?.usesSingleLineMode = true
        pathField.cell?.isScrollable = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L10n.search
                searchField.font = .systemFont(ofSize: 13)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("folder-search")
        regexCheck.translatesAutoresizingMaskIntoConstraints = false
        regexCheck.controlSize = .small
        regexCheck.font = .systemFont(ofSize: 12)
        regexCheck.setButtonType(.switch)
        regexCheck.title = L10n.regex
        regexCheck.target = self
        regexCheck.action = #selector(regexChanged(_:))
        regexCheck.setAccessibilityIdentifier("folder-search-regex")
        pathBar.addSubview(address)
        pathBar.addSubview(pathField)
        pathBar.addSubview(searchField)
        pathBar.addSubview(regexCheck)

        let pathLine = NSBox()
        pathLine.boxType = .separator
        pathLine.translatesAutoresizingMaskIntoConstraints = false

        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addSubview(tree.view)
        split.addSubview(self.content.view)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.autosaveName = "MainSplit"

        let statusLine = NSBox()
        statusLine.boxType = .separator
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail

        root.addSubview(pathBar)
        root.addSubview(pathLine)
        root.addSubview(split)
        root.addSubview(statusLine)
        root.addSubview(statusField)

        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 36),

            address.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: 12),
            address.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            pathField.leadingAnchor.constraint(equalTo: address.trailingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),

            searchField.trailingAnchor.constraint(equalTo: regexCheck.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 200),
            searchField.heightAnchor.constraint(equalTo: pathField.heightAnchor),
            regexCheck.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor, constant: -10),
            regexCheck.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),

            pathLine.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            pathLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathLine.heightAnchor.constraint(equalToConstant: 1),

            statusField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            statusField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            statusField.heightAnchor.constraint(equalToConstant: 16),

            statusLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: statusField.topAnchor, constant: -4),
            statusLine.heightAnchor.constraint(equalToConstant: 1),

            split.topAnchor.constraint(equalTo: pathLine.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
        ])

        let menu = contextMenu()
        itemMenu = menu
        menu.delegate = self
        content.install(menu: menu)
        tree.install(menu: menu)
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ExplorerToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = true
        toolbar.delegate = self
        window?.toolbar = toolbar
    }

    private func refreshViewControl() {
        viewMenu.removeAllItems()
        // The toolbar item swallows the first entry of its menu, so a hidden one goes there.
        let placeholder = NSMenuItem()
        placeholder.isHidden = true
        viewMenu.addItem(placeholder)
        for mode in BrowserViewMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(chooseViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == content.mode ? .on : .off
            let image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title) ?? NSImage()
            image.isTemplate = true
            item.image = image
            viewMenu.addItem(item)
        }
        viewItem?.image = Icons.symbol(content.mode.symbolName, label: L10n.view)
    }

    private func wire() {
        content.folderSizes = folderSizes
        folderSizes.onUpdate = { [weak self] paths in
            self?.folderSizesChanged(paths)
        }
        content.onCommitRename = { [weak self] item, name in
            guard let self else { return }
            do {
                let renamed = try self.store.rename(item, to: name)
                self.folderSizes.noteRenamed(from: item.url, to: renamed)
                self.folderViews.retarget(from: item.url, to: renamed)
                BookmarkStore.shared.retarget(from: item.url, to: renamed)
            } catch {
                self.content.restoreName(of: item)
                self.present(error)
            }
        }
        content.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.updateStatus(self.store.snapshot)
        }
        content.onSort = { [weak self] column, ascending in
            self?.store.applySort(column: column, ascending: ascending)
        }
        content.onOpen = { [weak self] item in
            self?.open([item.url])
        }
        content.onContextTarget = { [weak self] item in
            self?.prepareContext(item)
        }
        tree.onContextFolder = { [weak self] url in
            self?.prepareTreeContext(url)
        }
        content.onDelete = { [weak self] in
            self?.trashSelection(nil)
        }
        content.onMove = { [weak self] urls, folder in
            self?.moveItems(urls, to: folder)
        }
        tree.onMove = { [weak self] urls, folder in
            self?.moveItems(urls, to: folder)
        }
        tree.onNavigate = { [weak self] url in
            guard let self else { return }
            self.tree.startsCollapsed = false
            if Paths.same(url, self.store.snapshot.url), !self.store.snapshot.isLoading { return }
            self.pendingTreeURL = url
            self.store.open(url)
        }
        store.onChange = { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: BrowserSnapshot) {
        // The filter and scroll position belong to the folder they were set in.
        if let previous = searchFolder, !Paths.same(previous, snapshot.url) {
            savedStates[previous.standardized.path] = BrowseState(
                search: searchField.stringValue,
                regex: regexCheck.state == .on,
                scroll: content.scrollOffset,
                selection: content.selectedItems().map(\.url)
            )
            if restoreOnArrival, let saved = savedStates[snapshot.url.standardized.path] {
                searchField.stringValue = saved.search
                regexCheck.state = saved.regex ? .on : .off
                scrollToRestore = saved.scroll
                selectionToRestore = saved.selection
            } else {
                searchField.stringValue = ""
                scrollToRestore = nil
                selectionToRestore = []
            }
            restoreOnArrival = false
        }
        searchFolder = snapshot.url
        if tree.startsCollapsed, !Paths.same(snapshot.url, launchURL) {
            tree.startsCollapsed = false
        }
        updatePathField(snapshot.url)
        window?.title = FileManager.default.displayName(atPath: snapshot.url.path)
        window?.representedURL = snapshot.url
        window?.toolbar?.validateVisibleItems()

        if snapshot.showHidden != tree.showsHidden {
            tree.setShowHidden(snapshot.showHidden, selecting: snapshot.url)
        }

        let fromTree = pendingTreeURL.map { Paths.same($0, snapshot.url) } ?? false
        updateStatus(snapshot)

        guard !snapshot.isLoading else {
            if !fromTree {
                tree.reveal(snapshot.url)
            }
            if lastCompletedURL == nil || !Paths.same(lastCompletedURL!, snapshot.url) {
                content.show(items: [], preserveSelection: false)
                content.setMessage(nil)
            }
            return
        }

        tree.refreshExpandedFolder(snapshot.url)
        if !fromTree {
            tree.reveal(snapshot.url)
        }
        pendingTreeURL = nil

        let sameFolder = lastCompletedURL.map { Paths.same($0, snapshot.url) } ?? false
        applyStoredView(snapshot)
        let listing = listing(for: snapshot)
        content.show(items: listing.items, preserveSelection: sameFolder)
        lastCompletedURL = snapshot.url
        content.setMessage(listing.message)
        if !selectionToRestore.isEmpty {
            content.select(urls: selectionToRestore)
            selectionToRestore = []
        }
        if let origin = scrollToRestore {
            scrollToRestore = nil
            content.restoreScrollOffset(origin)
        }

        if snapshot.errorText == nil, let focus = store.takePendingFocus() {
            content.select(url: focus.url)
            if focus.startRename {
                if !content.beginRename(url: focus.url) {
                    promptRename(url: focus.url)
                }
            }
        } else {
            _ = store.takePendingFocus()
        }
        if let url = selectAfterLoad {
            selectAfterLoad = nil
            content.select(url: url)
        }
        updateStatus(snapshot)
        if snapshot.permissionDenied {
            offerFullDiskAccess(becauseBlocked: true)
        }
    }

    private func updateStatus(_ snapshot: BrowserSnapshot) {
        if snapshot.isLoading {
            statusField.stringValue = L10n.loading
            statusField.textColor = .secondaryLabelColor
            return
        }
        if let error = snapshot.errorText {
            statusField.stringValue = error
            statusField.textColor = .systemRed
            return
        }
        statusField.textColor = .secondaryLabelColor
        let filtered = ItemFilter.filter(
            snapshot.items,
            query: searchField.stringValue,
            regex: regexCheck.state == .on
        )
        if filtered.invalidPattern {
            statusField.stringValue = L10n.invalidRegex
            statusField.textColor = .systemRed
            return
        }
        let selected = content.selectedItems()
        if selected.isEmpty {
            let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                statusField.stringValue = L10n.itemsMatching(filtered.items.count, of: snapshot.items.count)
            } else {
                statusField.stringValue = L10n.items(snapshot.items.count)
            }
            return
        }
        let sizes = selected.compactMap { item -> Int64? in
            if item.measuresSize {
                return folderSizes.cachedBytes(for: item.url)
            }
            return item.size
        }
        if sizes.isEmpty {
            statusField.stringValue = L10n.itemsSelected(selected.count)
        } else {
            let total = sizes.reduce(0, +)
            statusField.stringValue = L10n.itemsSelected(selected.count, size: Format.size(total))
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === pathField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitPath()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            pathField.stringValue = store.snapshot.url.path
            window?.makeFirstResponder(content.keyView)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        refreshFilteredListing()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField, !committingPath else { return }
        pathField.stringValue = store.snapshot.url.path
    }

    private func updatePathField(_ url: URL) {
        let editing = pathField.currentEditor() != nil && window?.firstResponder === pathField.currentEditor()
        let urlChanged = displayedURL.map { !Paths.same($0, url) } ?? true
        if editing && urlChanged {
            window?.makeFirstResponder(content.keyView)
        }
        if !editing || urlChanged {
            pathField.stringValue = url.path
        }
        displayedURL = url
    }

    private func commitPath() {
        guard let url = PathInput.resolve(pathField.stringValue, relativeTo: store.snapshot.url) else {
            presentMessage(L10n.pathMissing)
            return
        }
        committingPath = true
        window?.makeFirstResponder(content.keyView)
        committingPath = false
        pathField.stringValue = url.path
        if isNavigableFolder(url) {
            store.open(url)
        } else if let parent = Paths.parent(of: url) {
            selectAfterLoad = url
            store.open(parent)
        }
    }

    private func isNavigableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let values = try? url.resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage != true
    }

    /// A view the user picked is kept for this folder. Otherwise a short listing opens as icons.
    private func applyStoredView(_ snapshot: BrowserSnapshot) {
        let raw: String
        if let saved = folderViews.view(for: snapshot.url) {
            raw = saved
        } else if snapshot.errorText != nil {
            return
        } else {
            raw = FolderViewStore.automaticView(itemCount: snapshot.items.count)
        }
        guard let mode = BrowserViewMode(rawValue: raw), content.mode != mode else { return }
        content.setMode(mode)
        refreshViewControl()
        if window?.isVisible == true {
            window?.makeFirstResponder(content.keyView)
        }
    }

    private func setViewMode(_ mode: BrowserViewMode, remember: Bool) {
        content.setMode(mode)
        refreshViewControl()
        if remember {
            folderViews.remember(store.snapshot.url, view: mode.rawValue)
        }
        if window?.isVisible == true {
            window?.makeFirstResponder(content.keyView)
        }
        updateStatus(store.snapshot)
    }

    private func retargetFolderViews(_ urls: [URL], to folder: URL) {
        for url in urls {
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            let sourceGone = !FileManager.default.fileExists(atPath: url.path)
            let arrived = FileManager.default.fileExists(atPath: destination.path)
            if sourceGone && arrived {
                folderViews.retarget(from: url, to: destination)
                BookmarkStore.shared.retarget(from: url, to: destination)
            }
        }
    }

    private func promptRename(url: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.rename
        alert.addButton(withTitle: L10n.rename)
        alert.addButton(withTitle: L10n.cancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = url.lastPathComponent
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let renamed = try FileActions.rename(url: url, to: field.stringValue)
                self.folderSizes.noteRenamed(from: url, to: renamed)
                self.folderViews.retarget(from: url, to: renamed)
                BookmarkStore.shared.retarget(from: url, to: renamed)
                self.store.refresh()
                if let parent = Paths.parent(of: url) {
                    self.tree.refreshExpandedFolder(parent)
                }
                self.tree.refreshExpandedFolder(renamed)
            } catch {
                self.present(error)
            }
        }
        window.makeFirstResponder(field)
    }

    private func presentMessage(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.couldntComplete
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    private func orderedItems(_ items: [FileItem], in snapshot: BrowserSnapshot) -> [FileItem] {
        guard snapshot.sortColumn == .size else { return items }
        let measured = items.map { item -> FileItem in
            guard item.measuresSize, let bytes = folderSizes.cachedBytes(for: item.url) else { return item }
            return item.replacingSize(bytes)
        }
        return sortFileItems(measured, column: .size, ascending: snapshot.sortAscending)
    }

    private func listing(for snapshot: BrowserSnapshot) -> (items: [FileItem], message: String?) {
        if let error = snapshot.errorText {
            return ([], error)
        }
        let filtered = ItemFilter.filter(
            snapshot.items,
            query: searchField.stringValue,
            regex: regexCheck.state == .on
        )
        if filtered.invalidPattern {
            return ([], L10n.invalidRegex)
        }
        let items = orderedItems(filtered.items, in: snapshot)
        if snapshot.items.isEmpty {
            return (items, L10n.emptyFolder)
        }
        if items.isEmpty {
            return ([], L10n.noMatches)
        }
        return (items, nil)
    }

    private func refreshFilteredListing() {
        let snapshot = store.snapshot
        guard !snapshot.isLoading else { return }
        let listing = listing(for: snapshot)
        content.show(items: listing.items, preserveSelection: true)
        content.setMessage(listing.message)
        updateStatus(snapshot)
    }

    @objc private func regexChanged(_ sender: Any?) {
        refreshFilteredListing()
    }

    private func offerFullDiskAccess(becauseBlocked: Bool = false) {
        guard let window, !accessSheet, !FullDiskAccess.isGranted() else { return }
        if !becauseBlocked, declinedAccess { return }
        accessSheet = true
        let alert = NSAlert()
        alert.messageText = L10n.fullDiskAccess
        alert.informativeText = L10n.fullDiskAccessHelp
        alert.addButton(withTitle: L10n.openSystemSettings)
        alert.addButton(withTitle: L10n.notNow)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.accessSheet = false
            if response == .alertFirstButtonReturn {
                FullDiskAccess.openSettings()
            } else {
                self.declinedAccess = true
            }
        }
    }

    private func folderSizesChanged(_ paths: Set<String>) {
        let snapshot = store.snapshot
        if snapshot.sortColumn == .size, !content.isRenaming {
            let listing = listing(for: snapshot)
            content.show(items: listing.items, preserveSelection: true)
            content.setMessage(listing.message)
        } else {
            content.reloadFolderSizes(paths)
        }
        updateStatus(snapshot)
    }

    private func moveItems(_ urls: [URL], to folder: URL) {
        let plan = folderSizes.planMove(of: urls, to: folder)
        do {
            try FileActions.move(urls, to: folder)
            folderSizes.finishMove(plan)
            retargetFolderViews(urls, to: folder)
            let parents = Set(urls.compactMap { Paths.parent(of: $0)?.standardized.path })
            store.refresh()
            tree.refreshExpandedFolder(folder)
            for path in parents {
                tree.refreshExpandedFolder(URL(fileURLWithPath: path))
            }
        } catch {
            folderSizes.finishMove(plan)
            retargetFolderViews(urls, to: folder)
            store.refresh()
            present(error)
        }
    }

    private func open(_ urls: [URL]) {
        if urls.count == 1, let url = urls.first, isNavigableFolder(url) {
            store.open(url)
            return
        }
        for url in urls where !isNavigableFolder(url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func actedURLs() -> [URL] {
        contextURLs ?? content.selectedItems().map(\.url)
    }

    private func pasteDestination() -> URL? {
        if contextDisablesPaste { return nil }
        let url = contextPasteURL ?? store.snapshot.url
        return isNavigableFolder(url) ? url : nil
    }

    private func prepareContext(_ item: FileItem?) {
        contextURLs = content.selectedItems().map(\.url)
        if let item, item.opensAsFolder {
            contextPasteURL = item.url
            contextDisablesPaste = false
        } else if item == nil {
            contextPasteURL = store.snapshot.url
            contextDisablesPaste = false
        } else {
            contextPasteURL = nil
            contextDisablesPaste = true
        }
    }

    private func prepareTreeContext(_ url: URL?) {
        if let url {
            contextURLs = [url]
            contextPasteURL = url
            contextDisablesPaste = false
        } else {
            contextURLs = []
            contextPasteURL = store.snapshot.url
            contextDisablesPaste = false
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === itemMenu else { return }
        // AppKit reports the close before it sends the chosen action, so the context has to outlive this call.
        DispatchQueue.main.async { [weak self] in
            self?.contextURLs = nil
            self?.contextPasteURL = nil
            self?.contextDisablesPaste = false
        }
    }

    private func present(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.couldntComplete
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        fillContextMenu(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === itemMenu else { return }
        fillContextMenu(menu)
    }

    private func fillContextMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let onItems = !(contextURLs ?? []).isEmpty
        if onItems {
            menu.addItem(contextItem(L10n.open, #selector(openSelection(_:)), ""))
            if let openWith = openWithItem(for: contextURLs ?? []) {
                menu.addItem(openWith)
            }
            menu.addItem(contextItem(L10n.rename, #selector(renameSelection(_:)), ""))
            menu.addItem(.separator())
            menu.addItem(contextItem(L10n.cut, #selector(cut(_:)), ""))
            menu.addItem(contextItem(L10n.copy, #selector(copy(_:)), ""))
            if contextPasteURL != nil {
                menu.addItem(contextItem(L10n.paste, #selector(paste(_:)), ""))
            }
            menu.addItem(.separator())
            if let urls = contextURLs, urls.count == 1, isNavigableFolder(urls[0]) {
                menu.addItem(contextItem(L10n.openShell, #selector(openShell(_:)), ""))
            }
            if let urls = contextURLs, urls.count == 1, isNavigableFolder(urls[0]) {
                let marked = BookmarkStore.shared.contains(urls[0])
                menu.addItem(contextItem(marked ? L10n.removeBookmark : L10n.addBookmark, #selector(toggleBookmark(_:)), ""))
            }
            menu.addItem(contextItem(L10n.getInfo, #selector(getInfo(_:)), ""))
            menu.addItem(contextItem(L10n.showInFinder, #selector(showInFinder(_:)), ""))
            menu.addItem(.separator())
            menu.addItem(contextItem(L10n.moveToTrash, #selector(trashSelection(_:)), ""))
        } else {
            menu.addItem(contextItem(L10n.newFolder, #selector(newFolder(_:)), ""))
            menu.addItem(contextItem(L10n.paste, #selector(paste(_:)), ""))
            menu.addItem(.separator())
            menu.addItem(contextItem(L10n.openShell, #selector(openShell(_:)), ""))
            menu.addItem(contextItem(L10n.getInfo, #selector(getInfo(_:)), ""))
        }
    }

    /// The apps that can open every item, the default one first.
    private func openWithItem(for urls: [URL]) -> NSMenuItem? {
        guard let first = urls.first else { return nil }
        let workspace = NSWorkspace.shared
        var apps = workspace.urlsForApplications(toOpen: first)
        for url in urls.dropFirst() {
            let others = Set(workspace.urlsForApplications(toOpen: url).map(\.path))
            apps.removeAll { !others.contains($0.path) }
        }
        let defaultApp = workspace.urlForApplication(toOpen: first)
        var seen = Set<String>()
        apps = apps.filter { seen.insert($0.path).inserted }
        func name(_ app: URL) -> String { FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "") }
        apps.sort { lhs, rhs in
            if lhs.path == defaultApp?.path { return true }
            if rhs.path == defaultApp?.path { return false }
            return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
        }

        let submenu = NSMenu()
        for app in apps {
            let isDefault = app.path == defaultApp?.path
            let title = isDefault ? String(format: L10n.defaultApp, name(app)) : name(app)
            let item = contextItem(title, #selector(openWithApp(_:)), "")
            item.representedObject = OpenWithTarget(app: app, urls: urls)
            let icon = (workspace.icon(forFile: app.path).copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
            if isDefault, apps.count > 1 { submenu.addItem(.separator()) }
        }
        if !apps.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(contextItem(L10n.otherApp, #selector(openWithOther(_:)), ""))

        let other = submenu.items.last
        other?.representedObject = OpenWithTarget(app: nil, urls: urls)

        let parent = NSMenuItem(title: L10n.openWith, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        // The items were captured when the menu opened. By the time the action runs the context is already gone.
        guard let target = sender.representedObject as? OpenWithTarget else { return }
        openWith(target.app, urls: target.urls)
    }

    @objc func openWithOther(_ sender: NSMenuItem) {
        guard let urls = (sender.representedObject as? OpenWithTarget)?.urls, !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.open
        guard panel.runModal() == .OK, let app = panel.url else { return }
        openWith(app, urls: urls)
    }

    private func openWith(_ app: URL, urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async { self?.present(error) }
        }
    }

    /// Finder owns the info window, so Explorer asks it through Apple Events.
    @objc func getInfo(_ sender: Any?) {
        var urls = actedURLs()
        if urls.isEmpty { urls = [store.snapshot.url] }
        for url in urls {
            let path = url.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(path)" as alias)
            end tell
            """
            var failure: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&failure)
            if let failure {
                let code = failure[NSAppleScript.errorNumber] as? Int
                let message = code == -1743
                    ? L10n.infoNeedsPermission
                    : (failure[NSAppleScript.errorMessage] as? String ?? L10n.couldntComplete)
                presentMessage(message)
                return
            }
        }
    }

    private func contextItem(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = self
        return item
    }

    private func configure(
        _ item: NSToolbarItem,
        label: String,
        symbol: String,
        action: Selector,
        navigational: Bool
    ) {
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = Icons.symbol(symbol, label: label)
        item.action = action
        item.target = self
        item.isNavigational = navigational
        item.isBordered = true
    }

    private func installMouseNavigation() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Side buttons on most mice: 3 back, 4 forward.
            if event.buttonNumber == 3 {
                self.goBack(nil)
                return nil
            }
            if event.buttonNumber == 4 {
                self.goForward(nil)
                return nil
            }
            return event
        }
    }
}

private extension MainWindowController {
    static let didPlaceSplitKey = "dev.framay.explorer.didPlaceSplit"
}

private final class OpenWithTarget: NSObject {
    let app: URL!
    let urls: [URL]

    init(app: URL?, urls: [URL]) {
        self.app = app
        self.urls = urls
    }
}

private struct BrowseState {
    let search: String
    let regex: Bool
    let scroll: NSPoint
    let selection: [URL]
}

private struct HeldFiles {
    enum Operation {
        case copy
        case cut
    }

    var operation: Operation
    var urls: [URL]
}

private extension NSToolbarItem.Identifier {
    static let back = NSToolbarItem.Identifier("explorer.back")
    static let forward = NSToolbarItem.Identifier("explorer.forward")
    static let up = NSToolbarItem.Identifier("explorer.up")
    static let viewMode = NSToolbarItem.Identifier("explorer.viewMode")
    static let openShell = NSToolbarItem.Identifier("explorer.openShell")
    static let newFolder = NSToolbarItem.Identifier("explorer.newFolder")
}
