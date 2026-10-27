import Darwin
import Foundation

/// The folder the user is looking at: history, listing, and sort.
/// A future tab or second window should own its own store.
/// Search is not here yet: a later field can filter `snapshot.items` by name.
public final class BrowserStore {
    public private(set) var snapshot: BrowserSnapshot
    public var onChange: ((BrowserSnapshot) -> Void)?

    /// Tests set this so a load finishes before the call returns.
    public var performsLoadsInline = false

    public static let showHiddenKey = "dev.framay.explorer.showHidden"

    private var history: NavigationHistory
    private var generation = 0
    private var pendingFocus: PendingFocus?
    private let defaults: UserDefaults

    public init(
        startingAt url: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        let start = url.standardized
        history = NavigationHistory(startingAt: start)
        snapshot = BrowserSnapshot(
            url: start,
            items: [],
            sortColumn: .name,
            sortAscending: true,
            showHidden: Self.storedShowHidden(defaults),
            canGoBack: false,
            canGoForward: false,
            canGoUp: Paths.parent(of: start) != nil,
            isLoading: false,
            errorText: nil,
            permissionDenied: false
        )
    }

    public func start() {
        reload()
    }

    private static func storedShowHidden(_ defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: showHiddenKey) == nil { return true }
        return defaults.bool(forKey: showHiddenKey)
    }

    public func open(_ url: URL) {
        assertMain()
        pendingFocus = nil
        history.go(url)
        reload()
    }

    public func back() {
        assertMain()
        guard history.back() != nil else { return }
        pendingFocus = nil
        reload()
    }

    public func forward() {
        assertMain()
        guard history.forward() != nil else { return }
        pendingFocus = nil
        reload()
    }

    public func up() {
        assertMain()
        guard let parent = Paths.parent(of: history.current) else { return }
        open(parent)
    }

    public func refresh() {
        assertMain()
        reload()
    }

    public func toggleShowHidden() {
        assertMain()
        snapshot.showHidden.toggle()
        defaults.set(snapshot.showHidden, forKey: Self.showHiddenKey)
        reload()
    }

    /// Adds media details read for the open folder, keyed by standardized path, and sorts again when they decide the order.
    public func applyMedia(_ details: [String: MediaInfo]) {
        assertMain()
        guard !details.isEmpty else { return }
        snapshot.items = snapshot.items.map { item in
            details[item.url.standardized.path].map { item.withMedia($0) } ?? item
        }
        switch snapshot.sortColumn {
        case .dimensions, .taken, .duration:
            snapshot.items = sortFileItems(snapshot.items, column: snapshot.sortColumn, ascending: snapshot.sortAscending)
        default:
            break
        }
        publish()
    }

    public func applySort(column: SortColumn, ascending: Bool) {
        assertMain()
        snapshot.sortColumn = column
        snapshot.sortAscending = ascending
        snapshot.items = sortFileItems(snapshot.items, column: column, ascending: ascending)
        publish()
    }

    @discardableResult
    public func createFolder(named baseName: String) throws -> URL {
        assertMain()
        let created = try FileActions.createFolder(in: history.current, baseName: baseName)
        pendingFocus = PendingFocus(url: created, startRename: true)
        reload()
        return created
    }

    @discardableResult
    public func rename(_ item: FileItem, to newName: String) throws -> URL {
        assertMain()
        let newURL = try FileActions.rename(item: item, to: newName)
        guard newURL.lastPathComponent != item.name else { return newURL }
        pendingFocus = PendingFocus(url: newURL, startRename: false)
        reload()
        return newURL
    }

    public func trash(_ items: [FileItem]) throws {
        assertMain()
        let failure = FileActions.trash(items)
        reload()
        if let failure { throw failure }
    }

    public func takePendingFocus() -> PendingFocus? {
        defer { pendingFocus = nil }
        return pendingFocus
    }

    private func reload() {
        assertMain()
        generation += 1
        let token = generation
        let url = history.current
        let showHidden = snapshot.showHidden

        snapshot.url = url
        snapshot.canGoBack = history.canGoBack
        snapshot.canGoForward = history.canGoForward
        snapshot.canGoUp = Paths.parent(of: url) != nil
        snapshot.isLoading = true
        snapshot.errorText = nil
        snapshot.permissionDenied = false
        snapshot.items = []
        publish()

        let work = {
            let result = Result { try DirectoryScanner.scan(url: url, showHidden: showHidden) }
            let apply = {
                guard token == self.generation else { return }
                switch result {
                case let .success(items):
                    self.snapshot.items = sortFileItems(
                        items,
                        column: self.snapshot.sortColumn,
                        ascending: self.snapshot.sortAscending
                    )
                    self.snapshot.errorText = nil
                    self.snapshot.permissionDenied = false
                case let .failure(error):
                    self.snapshot.items = []
                    self.snapshot.errorText = error.localizedDescription
                    self.snapshot.permissionDenied = Self.isPermissionDenied(error)
                    self.pendingFocus = nil
                }
                self.snapshot.isLoading = false
                self.publish()
            }
            if self.performsLoadsInline {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }

        if performsLoadsInline {
            work()
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        return false
    }

    private func publish() {
        onChange?(snapshot)
    }

    private func assertMain() {
        precondition(Thread.isMainThread, "BrowserStore runs on the main thread")
    }
}

public struct BrowserSnapshot: Equatable {
    public var url: URL
    public var items: [FileItem]
    public var sortColumn: SortColumn
    public var sortAscending: Bool
    public var showHidden: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var canGoUp: Bool
    public var isLoading: Bool
    public var errorText: String?
    /// The folder itself is blocked, usually until Full Disk Access is turned on.
    public var permissionDenied: Bool
}

public struct PendingFocus: Equatable {
    public var url: URL
    public var startRename: Bool
}
