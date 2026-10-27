import AppKit
import Darwin

/// Full Disk Access is granted in System Settings. macOS does not show its own prompt for it.
enum FullDiskAccess {
    static func isGranted() -> Bool {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        let fd = Darwin.open(path, O_RDONLY)
        if fd >= 0 {
            Darwin.close(fd)
            return true
        }
        // A missing file is not a denied permission.
        return errno != EPERM && errno != EACCES
    }

    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}
