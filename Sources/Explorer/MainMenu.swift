import AppKit

enum MainMenu {
    static func install() {
        let main = NSMenu()
        main.addItem(submenu("Explorer", appMenu()))
        main.addItem(submenu(L10n.file, fileMenu()))
        main.addItem(submenu(L10n.edit, editMenu()))
        main.addItem(submenu(L10n.view, viewMenu()))
        main.addItem(submenu(L10n.window, windowMenu()))
        NSApp.mainMenu = main
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        menu.title = title
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Explorer")
        menu.addItem(item(L10n.about, #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let servicesItem = item(L10n.services, nil)
        let services = NSMenu()
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item(L10n.hide, #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(L10n.hideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(L10n.showAll, #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(L10n.quit, #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.file)
        menu.addItem(item(L10n.newFolder, #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift]))
        menu.addItem(item(L10n.open, #selector(MainWindowController.openSelection(_:)), "o"))
        menu.addItem(item(
            L10n.rename,
            #selector(MainWindowController.renameSelection(_:)),
            String(UnicodeScalar(NSF2FunctionKey)!),
            []
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            L10n.moveToTrash,
            #selector(MainWindowController.trashSelection(_:)),
            String(UnicodeScalar(NSBackspaceCharacter)!),
            [.command]
        ))
        menu.addItem(item(L10n.getInfo, #selector(MainWindowController.getInfo(_:)), "i"))
        menu.addItem(item(L10n.showInFinder, #selector(MainWindowController.showInFinder(_:))))
        menu.addItem(.separator())
        menu.addItem(item(L10n.close, #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.edit)
        menu.addItem(item(L10n.undo, Selector(("undo:")), "z"))
        menu.addItem(item(L10n.redo, Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(L10n.cut, #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(L10n.copy, #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(L10n.paste, #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(L10n.selectAll, #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.view)
        menu.addItem(item(L10n.back, #selector(MainWindowController.goBack(_:)), "["))
        menu.addItem(item(L10n.forward, #selector(MainWindowController.goForward(_:)), "]"))
        menu.addItem(item(
            L10n.up,
            #selector(MainWindowController.goUp(_:)),
            String(UnicodeScalar(NSUpArrowFunctionKey)!),
            [.command]
        ))
        menu.addItem(.separator())
        menu.addItem(modeItem(L10n.details, .details))
        menu.addItem(modeItem(L10n.icons, .icons))
        menu.addItem(modeItem(L10n.preview, .preview))
        menu.addItem(.separator())
        menu.addItem(item(L10n.refresh, #selector(MainWindowController.refresh(_:)), "r"))
        menu.addItem(item(L10n.showHidden, #selector(MainWindowController.toggleHidden(_:)), ".", [.command, .shift]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.window)
        menu.addItem(item(L10n.minimize, #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(L10n.zoom, #selector(NSWindow.performZoom(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    private static func modeItem(_ title: String, _ mode: BrowserViewMode) -> NSMenuItem {
        let menuItem = item(title, #selector(MainWindowController.chooseViewMode(_:)))
        menuItem.representedObject = mode.rawValue
        return menuItem
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return menuItem
    }
}
