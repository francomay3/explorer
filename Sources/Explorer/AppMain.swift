import AppKit
import ExplorerCore

private let appDelegate = AppDelegate()

@main
enum ExplorerMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController(startingAt: Self.launchFolder())
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// `Explorer /some/folder` opens there. Anything else starts at home.
    private static func launchFolder() -> URL? {
        guard let raw = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        guard let url = PathInput.resolve(raw, relativeTo: FileManager.default.homeDirectoryForCurrentUser) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let values = try? url.resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage == true ? nil : url
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
