import AppKit
import ExplorerCore

enum L10n {
    static let back = NSLocalizedString("Back", comment: "Toolbar and menu")
    static let forward = NSLocalizedString("Forward", comment: "")
    static let up = NSLocalizedString("Up", comment: "")
    static let newFolder = NSLocalizedString("New Folder", comment: "")
    static let open = NSLocalizedString("Open", comment: "")
    static let rename = NSLocalizedString("Rename", comment: "")
    static let moveToTrash = NSLocalizedString("Move to Trash", comment: "")
    static let openWith = NSLocalizedString("Open With", comment: "")
    static let otherApp = NSLocalizedString("Other…", comment: "")
    static let defaultApp = NSLocalizedString("%@ (default)", comment: "")
    static let getInfo = NSLocalizedString("Get Info", comment: "")
    static let infoNeedsPermission = NSLocalizedString(
        "Explorer needs permission to control Finder. Allow it in System Settings > Privacy & Security > Automation.",
        comment: ""
    )
    static let openShell = NSLocalizedString("Open Shell", comment: "")
    static let confirmTrashOne = NSLocalizedString("Move “%@” to the Trash?", comment: "")
    static let confirmTrashMany = NSLocalizedString("Move %d items to the Trash?", comment: "")
    static let showInFinder = NSLocalizedString("Show in Finder", comment: "")
    static let refresh = NSLocalizedString("Refresh", comment: "")
    static let showHidden = NSLocalizedString("Show Hidden Files", comment: "")
    static let file = NSLocalizedString("File", comment: "Menu title")
    static let edit = NSLocalizedString("Edit", comment: "Menu title")
    static let view = NSLocalizedString("View", comment: "Menu title")
    static let window = NSLocalizedString("Window", comment: "Menu title")
    static let undo = NSLocalizedString("Undo", comment: "")
    static let redo = NSLocalizedString("Redo", comment: "")
    static let cut = NSLocalizedString("Cut", comment: "")
    static let copy = NSLocalizedString("Copy", comment: "")
    static let paste = NSLocalizedString("Paste", comment: "")
    static let selectAll = NSLocalizedString("Select All", comment: "")
    static let close = NSLocalizedString("Close", comment: "")
    static let minimize = NSLocalizedString("Minimize", comment: "")
    static let zoom = NSLocalizedString("Zoom", comment: "")
    static let hide = NSLocalizedString("Hide Explorer", comment: "")
    static let hideOthers = NSLocalizedString("Hide Others", comment: "")
    static let showAll = NSLocalizedString("Show All", comment: "")
    static let quit = NSLocalizedString("Quit Explorer", comment: "")
    static let about = NSLocalizedString("About Explorer", comment: "")
    static let services = NSLocalizedString("Services", comment: "")
    static let address = NSLocalizedString("Address", comment: "")
    static let search = NSLocalizedString("Search", comment: "Filters the open folder")
    static let regex = NSLocalizedString("Regex", comment: "Search treats the query as a regular expression")
    static let noMatches = NSLocalizedString("No matching items", comment: "")
    static let invalidRegex = NSLocalizedString("That regular expression isn't valid.", comment: "")
    static let fullDiskAccess = NSLocalizedString("Full Disk Access", comment: "")
    static let fullDiskAccessHelp = NSLocalizedString(
        "Explorer can't open some protected folders, such as Accounts, Mail, and Messages. Turn on Full Disk Access for Explorer in System Settings, then open Explorer again.",
        comment: ""
    )
    static let openSystemSettings = NSLocalizedString("Open System Settings", comment: "")
    static let notNow = NSLocalizedString("Not Now", comment: "")
    static let details = NSLocalizedString("Details", comment: "View mode")
    static let icons = NSLocalizedString("Icons", comment: "View mode")
    static let preview = NSLocalizedString("Preview", comment: "View mode")
    static let noImages = NSLocalizedString("No images in this folder", comment: "")
    static let previewUnavailable = NSLocalizedString("Preview not available", comment: "")
    static let pathMissing = NSLocalizedString("That path doesn't exist.", comment: "")
    static let cancel = NSLocalizedString("Cancel", comment: "")
    static let name = NSLocalizedString("Name", comment: "Column")
    static let size = NSLocalizedString("Size", comment: "Column")
    static let calculatingSize = NSLocalizedString("Calculating size", comment: "Folder size spinner")
    static let updatingSize = NSLocalizedString("Updating size", comment: "Folder size is shown and being checked")
    static let type = NSLocalizedString("Type", comment: "Column")
    static let dateModified = NSLocalizedString("Date Modified", comment: "Column")
    static let loading = NSLocalizedString("Loading…", comment: "")
    static let emptyFolder = NSLocalizedString("This folder is empty", comment: "")
    static let couldntComplete = NSLocalizedString("Couldn't complete the action", comment: "")
    static let shortcuts = NSLocalizedString("Shortcuts", comment: "Sidebar section")
    static let bookmarks = NSLocalizedString("Bookmarks", comment: "Sidebar section")
    static let addBookmark = NSLocalizedString("Add to Bookmarks", comment: "")
    static let removeBookmark = NSLocalizedString("Remove from Bookmarks", comment: "")
    static let locations = NSLocalizedString("Locations", comment: "Sidebar section for disks")

    static func itemsMatching(_ shown: Int, of total: Int) -> String {
        String(format: NSLocalizedString("%d of %d items", comment: "Filtered count in the open folder"), shown, total)
    }

    static func items(_ count: Int) -> String {
        String(format: NSLocalizedString("%d items", comment: "Status bar, nothing selected"), count)
    }

    static func itemsSelected(_ count: Int) -> String {
        String(format: NSLocalizedString("%d items selected", comment: ""), count)
    }

    static func itemsSelected(_ count: Int, size: String) -> String {
        String(format: NSLocalizedString("%d items selected, %@", comment: "Count and total size"), count, size)
    }
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func size(_ count: Int64) -> String {
        if count == 0 { return "0 KB" }
        return bytes.string(fromByteCount: count)
    }

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

enum Icons {
    static func file(_ url: URL, pointSize: CGFloat = 16) -> NSImage {
        let image = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: pointSize, height: pointSize)
        return BookmarkStore.shared.contains(url) ? badged(image) : image
    }

    /// A small star in the corner marks bookmarked folders.
    private static func badged(_ base: NSImage) -> NSImage {
        let size = base.size
        let badge = max(8, size.width * 0.4)
        let star = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemYellow]))
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            guard let star else { return true }
            let frame = NSRect(x: rect.maxX - badge, y: rect.minY, width: badge, height: badge)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: frame.insetBy(dx: -0.5, dy: -0.5)).fill()
            star.draw(in: frame)
            return true
        }
    }

    /// Every toolbar glyph goes through here so they share one size and weight.
    static func symbol(_ name: String, label: String) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? base
        image.isTemplate = true
        return image
    }
}
