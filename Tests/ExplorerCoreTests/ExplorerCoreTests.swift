import ExplorerCore
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum ExplorerCoreTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("path boundaries", testPathContainsRespectsSegmentBoundaries),
            ("history", testHistoryDropsTheForwardStack),
            ("folders stay above files", testFoldersStayAboveFiles),
            ("size ties break by name", testEqualSizesBreakTheTieByName),
            ("symlink and package flags", testSymlinkFoldersStayOutOfTheTreeButCanBeOpened),
            ("scan one level", testScanIsOneLevelAndCanShowHiddenFiles),
            ("create and rename", testCreateFolderPicksTheNextFreeNameAndRenameRefusesCollisions),
            ("store load and new folder", testStoreLoadsAFolderAndFocusesANewOneForRename),
            ("move into a folder", testMoveRefusesToEnterItselfAndMovesAFile),
            ("copy appends a number", testCopyAppendsANumberAndRefusesItself),
            ("typed paths", testTypedPaths),
            ("hidden files start visible", testFreshStoreShowsHiddenFiles),
            ("folder size windows", testFolderSizeWindows),
            ("folder size cache", testFolderSizeCacheReusesChildrenAndKeepsDeltas),
            ("folder view memory", testFolderViewMemoryFollowsTheCountUnlessChosen),
            ("folder filter", testFolderFilterStaysInTheOpenFolder),
            ("ignore rules", testIgnoreRulesFollowTheGitignoreFormat),
        ]
        var failed = 0
        for (name, test) in tests {
            do {
                try test()
                print("ok  \(name)")
            } catch {
                failed += 1
                print("FAIL \(name): \(error)")
            }
        }
        if failed > 0 {
            print("\(failed) failed")
            exit(1)
        }
        print("\(tests.count) passed")
    }
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(description: message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(description: message) }
    return value
}

private func expectThrows(_ body: () throws -> Void, _ check: (Error) -> Bool) throws {
    do {
        try body()
    } catch let failure as TestFailure {
        throw failure
    } catch {
        if !check(error) {
            throw TestFailure(description: "unexpected error \(error)")
        }
        return
    }
    throw TestFailure(description: "expected an error")
}

private func testPathContainsRespectsSegmentBoundaries() throws {
    let home = URL(fileURLWithPath: "/Users/framay")
    try expect(Paths.contains(directory: home, url: home), "home contains itself")
    try expect(Paths.contains(directory: home, url: URL(fileURLWithPath: "/Users/framay/Desktop")), "home contains Desktop")
    try expect(!Paths.contains(directory: home, url: URL(fileURLWithPath: "/Users/framay-other")), "home does not contain a sibling prefix")
    try expect(Paths.contains(directory: URL(fileURLWithPath: "/"), url: home), "root contains home")
    try expect(Paths.parent(of: URL(fileURLWithPath: "/")) == nil, "root has no parent")
    try expectEqual(Paths.parent(of: home)?.path, "/Users", "parent of home")
}

private func testHistoryDropsTheForwardStack() throws {
    var history = NavigationHistory(startingAt: URL(fileURLWithPath: "/a"))
    history.go(URL(fileURLWithPath: "/a/b"))
    history.go(URL(fileURLWithPath: "/a/b/c"))
    try expectEqual(history.back()?.path, "/a/b", "back once")
    try expectEqual(history.back()?.path, "/a", "back twice")
    try expectEqual(history.forward()?.path, "/a/b", "forward")
    history.go(URL(fileURLWithPath: "/a/d"))
    try expect(!history.canGoForward, "forward stack was dropped")
    try expectEqual(history.current.path, "/a/d", "current after jump")
    history.go(history.current)
    try expectEqual(history.back()?.path, "/a/b", "duplicate visit was not recorded")
    try expectEqual(history.forward()?.path, "/a/d", "forward stays on the new branch")
}

private func testFoldersStayAboveFiles() throws {
    let items = [
        FileItem.sample(name: "b.txt", size: 1),
        FileItem.sample(name: "A.txt", size: 50),
        FileItem.sample(name: "folder", isDirectory: true),
    ]
    try expectEqual(
        sortFileItems(items, column: .name, ascending: true).map(\.name),
        ["folder", "A.txt", "b.txt"],
        "name sort"
    )
    try expectEqual(
        sortFileItems(items, column: .size, ascending: false).map(\.name),
        ["folder", "A.txt", "b.txt"],
        "size sort"
    )
}

private func testEqualSizesBreakTheTieByName() throws {
    let items = [
        FileItem.sample(name: "b.txt", size: 5),
        FileItem.sample(name: "a.txt", size: 5),
    ]
    try expectEqual(
        sortFileItems(items, column: .size, ascending: false).map(\.name),
        ["a.txt", "b.txt"],
        "tie break"
    )
}

private func testSymlinkFoldersStayOutOfTheTreeButCanBeOpened() throws {
    let link = FileItem.sample(name: "Link", isDirectory: true, isSymbolicLink: true)
    try expect(link.opensAsFolder, "symlink folder opens")
    try expect(!link.appearsInTree, "symlink folder stays out of the tree")
    let package = FileItem.sample(name: "Demo.app", isDirectory: true, isPackage: true)
    try expect(!package.opensAsFolder, "package is a file")
}

private func testScanIsOneLevelAndCanShowHiddenFiles() throws {
    let directory = try makeTemp()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("Sub/Nested"),
        withIntermediateDirectories: true
    )
    try Data("x".utf8).write(to: directory.appendingPathComponent(".secret"))
    try Data("y".utf8).write(to: directory.appendingPathComponent("visible.txt"))
    let target = directory.appendingPathComponent("Target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("Link"),
        withDestinationURL: target
    )
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("Demo.app"),
        withIntermediateDirectories: true
    )

    let visible = try DirectoryScanner.scan(url: directory, showHidden: false)
    try expect(visible.contains { $0.name == "Sub" }, "lists the child folder")
    try expect(visible.contains { $0.name == "visible.txt" }, "lists the file")
    try expect(!visible.contains { $0.name == "Nested" }, "does not recurse")
    try expect(!visible.contains { $0.name == ".secret" }, "hides dotfiles")

    let link = try unwrap(visible.first { $0.name == "Link" }, "missing link")
    try expect(link.isSymbolicLink && link.opensAsFolder && !link.appearsInTree, "link flags")

    let app = try unwrap(visible.first { $0.name == "Demo.app" }, "missing app")
    try expect(app.isPackage && !app.opensAsFolder, "app bundle is a package")

    let hidden = try DirectoryScanner.scan(url: directory, showHidden: true)
    try expect(hidden.contains { $0.name == ".secret" }, "shows dotfiles when asked")
}

private func testCreateFolderPicksTheNextFreeNameAndRenameRefusesCollisions() throws {
    let directory = try makeTemp()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try FileActions.createFolder(in: directory, baseName: "New Folder")
    let second = try FileActions.createFolder(in: directory, baseName: "New Folder")
    try expectEqual(first.lastPathComponent, "New Folder", "first folder name")
    try expectEqual(second.lastPathComponent, "New Folder (2)", "second folder name")

    let file = directory.appendingPathComponent("a.txt")
    try Data("a".utf8).write(to: file)
    try Data("b".utf8).write(to: directory.appendingPathComponent("b.txt"))
    let item = try unwrap(DirectoryScanner.scan(url: directory, showHidden: false).first { $0.name == "a.txt" }, "missing a.txt")
    try expectThrows({ _ = try FileActions.rename(item: item, to: "b.txt") }) { ($0 as? FileActionError) == .alreadyExists("b.txt") }
    try expectThrows({ _ = try FileActions.rename(item: item, to: "   ") }) { ($0 as? FileActionError) == .emptyName }
    try expectThrows({ _ = try FileActions.rename(item: item, to: "a/b") }) { ($0 as? FileActionError) == .invalidName }
    let renamed = try FileActions.rename(item: item, to: "c.txt")
    try expectEqual(renamed.lastPathComponent, "c.txt", "renamed")
    try expect(FileManager.default.fileExists(atPath: renamed.path), "renamed file exists")
}

private func testStoreLoadsAFolderAndFocusesANewOneForRename() throws {
    let directory = try makeTemp()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    let suite = "explorer.tests.\(UUID().uuidString)"
    let defaults = try unwrap(UserDefaults(suiteName: suite), "defaults suite")
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = BrowserStore(startingAt: directory, defaults: defaults)
    store.performsLoadsInline = true
    store.start()
    try expect(!store.snapshot.isLoading, "load finished")
    try expect(store.snapshot.items.contains { $0.name == "Sub" }, "lists Sub")

    let sub = directory.appendingPathComponent("Sub")
    store.open(sub)
    try expect(store.snapshot.canGoBack, "can go back")
    try expect(Paths.same(store.snapshot.url, sub), "opened Sub")
    store.back()
    try expect(Paths.same(store.snapshot.url, directory), "back at the parent")

    try store.createFolder(named: "New Folder")
    let focus = store.takePendingFocus()
    try expectEqual(focus?.startRename, true, "new folder wants a rename")
    try expectEqual(focus?.url.lastPathComponent, "New Folder", "new folder name")
    try expect(store.snapshot.items.contains { $0.name == "New Folder" }, "new folder is listed")
}

private func testMoveRefusesToEnterItselfAndMovesAFile() throws {
    let root = try makeTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Dest", isDirectory: true)
    let nested = folder.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("note.txt")
    try Data("hola".utf8).write(to: file)

    try expect(!FileActions.canMove([folder], to: folder), "a folder cannot move into itself")
    try expect(!FileActions.canMove([folder], to: nested), "a folder cannot move into its child")
    try expect(!FileActions.canMove([file], to: root), "an item already in the folder stays")
    try expect(FileActions.canMove([file], to: folder), "a file can move into another folder")
    try expectThrows({ try FileActions.move([folder], to: nested) }) { ($0 as? FileActionError) == .couldNotMove }

    try FileActions.move([file], to: folder)
    let arrived = folder.appendingPathComponent("note.txt")
    try expect(!FileManager.default.fileExists(atPath: file.path), "the source is gone")
    try expect(FileManager.default.fileExists(atPath: arrived.path), "the file arrived")

    let other = root.appendingPathComponent("other.txt")
    try Data("x".utf8).write(to: other)
    try Data("y".utf8).write(to: folder.appendingPathComponent("other.txt"))
    try expectThrows({ try FileActions.move([other], to: folder) }) { ($0 as? FileActionError) == .alreadyExists("other.txt") }
    try expect(FileManager.default.fileExists(atPath: other.path), "a collision leaves the original in place")
}

private func testCopyAppendsANumberAndRefusesItself() throws {
    let root = try makeTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let dest = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("note.txt")
    try Data("hola".utf8).write(to: file)

    try FileActions.duplicate([file], to: dest)
    try expect(FileManager.default.fileExists(atPath: file.path), "copy leaves the original")
    try expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("note.txt").path), "copy keeps the name")

    try FileActions.duplicate([file], to: root)
    let firstCopy = root.appendingPathComponent("note.txt (1)")
    try expect(FileManager.default.fileExists(atPath: firstCopy.path), "the first extra copy is (1)")
    try FileActions.duplicate([file], to: root)
    try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("note.txt (2)").path), "the next copy is (2)")

    try expectThrows({ try FileActions.duplicate([dest], to: dest) }) { ($0 as? FileActionError) == .couldNotCopy }
}

private func testTypedPaths() throws {
    let root = try makeTemp()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("Child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

    let absolute = try unwrap(PathInput.resolve(child.path, relativeTo: root), "absolute path")
    try expect(Paths.same(absolute, child), "absolute path resolves")
    let relative = try unwrap(PathInput.resolve("Child", relativeTo: root), "relative path")
    try expect(Paths.same(relative, child), "relative path resolves")
    let parent = try unwrap(PathInput.resolve("..", relativeTo: child), "parent path")
    try expect(Paths.same(parent, root), "dotdot resolves")
    let home = FileManager.default.homeDirectoryForCurrentUser.standardized
    let tilde = try unwrap(PathInput.resolve("~", relativeTo: root), "tilde")
    try expect(Paths.same(tilde, home), "tilde is the home folder")
    try expect(PathInput.resolve("Does Not Exist", relativeTo: root) == nil, "missing path")
    try expect(PathInput.resolve("   ", relativeTo: root) == nil, "blank path")
}

private func testFreshStoreShowsHiddenFiles() throws {
    let name = "dev.framay.explorer.tests.\(UUID().uuidString)"
    let defaults = try unwrap(UserDefaults(suiteName: name), "defaults suite")
    defer { defaults.removePersistentDomain(forName: name) }
    let store = BrowserStore(startingAt: URL(fileURLWithPath: "/tmp"), defaults: defaults)
    try expect(store.snapshot.showHidden, "hidden files are visible until turned off")
    defaults.set(false, forKey: BrowserStore.showHiddenKey)
    let hiddenOff = BrowserStore(startingAt: URL(fileURLWithPath: "/tmp"), defaults: defaults)
    try expect(!hiddenOff.snapshot.showHidden, "an explicit off stays off")
}

private func testFolderFilterStaysInTheOpenFolder() throws {
    let png = FileItem.sample(name: "photo.PNG")
    let text = FileItem.sample(name: "notes.txt")
    let items = [png, text]

    let everything = ItemFilter.filter(items, query: "  ", regex: false)
    try expectEqual(everything.items.map(\.name), ["photo.PNG", "notes.txt"], "a blank query keeps the folder")
    try expect(!everything.invalidPattern, "a blank query is valid")

    let plain = ItemFilter.filter(items, query: "png", regex: false)
    try expectEqual(plain.items.map(\.name), ["photo.PNG"], "plain search matches the name")

    let photos = ItemFilter.filter(items, query: #"\.png$"#, regex: true)
    try expectEqual(photos.items.map(\.name), ["photo.PNG"], "regex matches the extension")
    try expect(ItemFilter.filter(items, query: #"\.png$"#, regex: true).items.allSatisfy { $0.name != "notes.txt" }, "regex does not keep other files")

    let broken = ItemFilter.filter(items, query: "(", regex: true)
    try expect(broken.items.isEmpty, "an invalid pattern matches nothing")
    try expect(broken.invalidPattern, "an invalid pattern is reported")
}

private func testFolderViewMemoryFollowsTheCountUnlessChosen() throws {
    try expectEqual(FolderViewStore.automaticView(itemCount: 0), "icons", "an empty folder opens as icons")
    try expectEqual(FolderViewStore.automaticView(itemCount: 15), "icons", "15 items still open as icons")
    try expectEqual(FolderViewStore.automaticView(itemCount: 16), "details", "16 items open as details")

    let root = try makeTemp()
    let database = root.appendingPathComponent("views.sqlite")
    var memory: FolderViewStore? = FolderViewStore(databaseURL: database)
    let views = try unwrap(memory, "view store")
    defer {
        memory = nil
        try? FileManager.default.removeItem(at: root)
    }

    let folder = root.appendingPathComponent("Projects", isDirectory: true)
    let child = folder.appendingPathComponent("App", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try expect(views.view(for: folder) == nil, "a new folder has no saved view")
    views.remember(folder, view: "preview")
    views.remember(child, view: "details")
    try expectEqual(views.view(for: folder), "preview", "the chosen view is kept")

    let renamed = root.appendingPathComponent("Code", isDirectory: true)
    views.retarget(from: folder, to: renamed)
    try expect(views.view(for: folder) == nil, "rename drops the old path")
    try expectEqual(views.view(for: renamed), "preview", "rename keeps the view")
    try expectEqual(views.view(for: renamed.appendingPathComponent("App")), "details", "a child view follows the rename")

    views.forget(renamed)
    try expect(views.view(for: renamed) == nil, "forgetting a folder drops it")
    try expect(views.view(for: renamed.appendingPathComponent("App")) == nil, "forgetting a folder drops its children")

    views.remember(folder, view: "icons")
    memory = nil
    let reopened = FolderViewStore(databaseURL: database)
    try expectEqual(reopened.view(for: folder), "icons", "the chosen view survives a relaunch")
}

private func testFolderSizeWindows() throws {
    try expectEqual(FolderSizePolicy.phase(age: FolderSizePolicy.fresh - 1), .fresh, "just inside fresh")
    try expectEqual(FolderSizePolicy.phase(age: FolderSizePolicy.fresh), .revalidating, "fresh ends at 15 minutes")
    try expectEqual(FolderSizePolicy.phase(age: FolderSizePolicy.staleAfter - 1), .revalidating, "inside the revalidate window")
    try expectEqual(FolderSizePolicy.phase(age: FolderSizePolicy.staleAfter), .stale, "stale after 7 days")
}

private func testFolderSizeCacheReusesChildrenAndKeepsDeltas() throws {
    let root = try makeTemp()
    let database = root.appendingPathComponent("sizes.sqlite")
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var index: FolderSizeIndex? = FolderSizeIndex(databaseURL: database)
    let sizes = try unwrap(index, "index")
    sizes.performsWorkInline = true
    sizes.now = { clock }
    defer {
        index = nil
        try? FileManager.default.removeItem(at: root)
    }

    let parent = root.appendingPathComponent("parent", isDirectory: true)
    let child = parent.appendingPathComponent("child", isDirectory: true)
    let sibling = parent.appendingPathComponent("sibling", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    try Data(count: 10).write(to: child.appendingPathComponent("file.bin"))
    try Data(count: 4).write(to: sibling.appendingPathComponent("file.bin"))
    let bulk = root.appendingPathComponent("bulk", isDirectory: true)
    let linked = bulk.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    try Data(count: 10).write(to: linked.appendingPathComponent("file.bin"))
    try FileManager.default.createSymbolicLink(
        at: bulk.appendingPathComponent("link"),
        withDestinationURL: linked
    )
    try Data(count: 5).write(to: bulk.appendingPathComponent(".secret"))
    let package = bulk.appendingPathComponent("Foo.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data(count: 9).write(to: package.appendingPathComponent("data.bin"))

    sizes.noteVisible([child, sibling, parent])
    try expectEqual(sizes.record(for: child)?.bytes, 10, "child folder")
    try expectEqual(sizes.record(for: sibling)?.bytes, 4, "sibling folder")
    try expectEqual(sizes.record(for: parent)?.bytes, 14, "parent sums cached children")
    let siblingStamp = try unwrap(sizes.record(for: sibling)?.computedAt, "sibling stamp")

    let file = child.appendingPathComponent("file.bin")
    let removal = sizes.planRemoval(of: [file])
    try FileManager.default.removeItem(at: file)
    sizes.finishRemoval(removal, succeeded: [file])
    try expectEqual(sizes.record(for: child)?.bytes, 0, "deleted file leaves the child")
    try expectEqual(sizes.record(for: parent)?.bytes, 4, "deleted file leaves the parent")
    try expectEqual(sizes.record(for: sibling)?.bytes, 4, "sibling bytes stay")
    try expectEqual(sizes.record(for: sibling)?.computedAt, siblingStamp, "sibling is not walked again")

    let folderRemoval = sizes.planRemoval(of: [sibling])
    try FileManager.default.removeItem(at: sibling)
    sizes.finishRemoval(folderRemoval, succeeded: [sibling])
    try expect(sizes.record(for: sibling) == nil, "deleted folder drops its row")
    try expectEqual(sizes.record(for: parent)?.bytes, 0, "deleted folder leaves the parent")
    try expectEqual(sizes.record(for: child)?.bytes, 0, "the other child stays")

    let origin = root.appendingPathComponent("origin", isDirectory: true)
    let other = root.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let moving = origin.appendingPathComponent("note.bin")
    try Data(count: 6).write(to: moving)
    sizes.noteVisible([origin, other])
    try expectEqual(sizes.record(for: origin)?.bytes, 6, "origin before the move")
    try expectEqual(sizes.record(for: other)?.bytes, 0, "destination before the move")
    let move = sizes.planMove(of: [moving], to: other)
    try FileManager.default.moveItem(at: moving, to: other.appendingPathComponent("note.bin"))
    sizes.finishMove(move)
    try expectEqual(sizes.record(for: origin)?.bytes, 0, "move subtracts from the old folder")
    try expectEqual(sizes.record(for: other)?.bytes, 6, "move adds to the new folder")

    let renamed = root.appendingPathComponent("other-renamed", isDirectory: true)
    sizes.noteRenamed(from: other, to: renamed)
    try FileManager.default.moveItem(at: other, to: renamed)
    try expect(sizes.record(for: other) == nil, "rename drops the old path")
    try expectEqual(sizes.record(for: renamed)?.bytes, 6, "rename keeps the size")

    let source = root.appendingPathComponent("source", isDirectory: true)
    let copies = root.appendingPathComponent("copies", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
    let original = source.appendingPathComponent("note.bin")
    try Data(count: 4).write(to: original)
    sizes.noteVisible([source, copies])
    let created = try FileActions.duplicate([original], to: copies)
    sizes.noteCopied(from: [original], to: created)
    try expectEqual(sizes.record(for: source)?.bytes, 4, "copy keeps the original folder")
    try expectEqual(sizes.record(for: copies)?.bytes, 4, "copy adds to the destination")

    sizes.noteVisible([bulk])
    let bulkBytes = try unwrap(sizes.record(for: bulk)?.bytes, "bulk size")
    let linkSize = try unwrap(
        (try? bulk.appendingPathComponent("link").resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
        "symlink size"
    )
    try expectEqual(bulkBytes, 10 + linkSize + 5 + 9, "hidden files and packages count, symlinks are not walked")
    try expectEqual(sizes.record(for: bulk.appendingPathComponent("Foo.app"))?.bytes, 9, "a package keeps its own total")

    let freshFolder = root.appendingPathComponent("fresh", isDirectory: true)
    try FileManager.default.createDirectory(at: freshFolder, withIntermediateDirectories: true)
    let freshFile = freshFolder.appendingPathComponent("file.bin")
    try Data(count: 3).write(to: freshFile)
    sizes.noteVisible([freshFolder])
    let freshStamp = try unwrap(sizes.record(for: freshFolder)?.computedAt, "fresh stamp")
    try Data(count: 9).write(to: freshFile)
    clock = clock.addingTimeInterval(5 * 60)
    sizes.noteVisible([freshFolder])
    try expectEqual(sizes.record(for: freshFolder)?.bytes, 3, "a fresh size is not walked again")
    try expectEqual(sizes.record(for: freshFolder)?.computedAt, freshStamp, "a fresh stamp stays")

    let held = root.appendingPathComponent("held", isDirectory: true)
    let nested = held.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(count: 3).write(to: nested.appendingPathComponent("file.bin"))
    try Data(count: 4).write(to: held.appendingPathComponent("loose.bin"))
    sizes.remember(url: nested, bytes: 5000, computedAt: clock.addingTimeInterval(-8 * 24 * 60 * 60))
    sizes.remember(url: held, bytes: 1, computedAt: clock.addingTimeInterval(-60 * 60))
    sizes.noteVisible([held])
    try expectEqual(sizes.record(for: nested)?.bytes, 5000, "a revalidate reuses the child")
    try expectEqual(sizes.record(for: held)?.bytes, 5004, "a revalidate sums the cached child")

    let old = root.appendingPathComponent("old", isDirectory: true)
    let oldChild = old.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: oldChild, withIntermediateDirectories: true)
    try Data(count: 3).write(to: oldChild.appendingPathComponent("file.bin"))
    try Data(count: 4).write(to: old.appendingPathComponent("loose.bin"))
    sizes.remember(url: oldChild, bytes: 5000, computedAt: clock.addingTimeInterval(-8 * 24 * 60 * 60))
    sizes.remember(url: old, bytes: 1, computedAt: clock.addingTimeInterval(-8 * 24 * 60 * 60))
    sizes.noteVisible([old])
    try expectEqual(sizes.record(for: oldChild)?.bytes, 3, "a stale child is walked")
    try expectEqual(sizes.record(for: old)?.bytes, 7, "a stale parent picks up the walked child")

    sizes.remember(url: root, bytes: 42, computedAt: clock)
    index = nil
    let reopened = FolderSizeIndex(databaseURL: database)
    try expectEqual(reopened.record(for: root)?.bytes, 42, "the size survives a relaunch")
}

private func makeTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("explorer-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private extension FileItem {
    static func sample(
        name: String,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        isSymbolicLink: Bool = false,
        size: Int64? = nil
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            displayName: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isHidden: false,
            size: size,
            modified: nil,
            kind: isDirectory ? "Folder" : "Document"
        )
    }
}

extension ExplorerCoreTests {
    static func testIgnoreRulesFollowTheGitignoreFormat() throws {
        let rules = IgnoreRules(parsing: """
        # comment
        .DS_Store
        *.log
        build/
        /top.txt
        docs/*.tmp
        !keep.log
        **/cache
        """, base: "/base")
        func url(_ path: String) -> URL { URL(fileURLWithPath: "/base/" + path) }
        let cases: [(String, Bool, Bool)] = [
            (".DS_Store", false, true),
            ("a/.DS_Store", false, true),
            ("x.log", false, true),
            ("keep.log", false, false),
            ("build", true, true),
            ("build", false, false),
            ("top.txt", false, true),
            ("sub/top.txt", false, false),
            ("docs/a.tmp", false, true),
            ("other/a.tmp", false, false),
            ("deep/er/cache", true, true),
            ("readme.md", false, false),
        ]
        for (path, isDirectory, expected) in cases {
            let actual = rules.ignores(url(path), isDirectory: isDirectory)
            if actual != expected {
                throw TestFailure(description: "\(path) dir=\(isDirectory): expected \(expected), got \(actual)")
            }
        }
        if rules.ignores(URL(fileURLWithPath: "/elsewhere/.DS_Store"), isDirectory: false) {
            throw TestFailure(description: "rules leaked outside their base")
        }
    }
}
