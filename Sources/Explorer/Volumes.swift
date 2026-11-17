import AppKit

enum Volumes {
    /// True for the mount point of a volume that can be ejected: a disk image, a USB drive or a network share.
    /// Folders inside a volume, and the startup disk, are not.
    static func isEjectable(_ url: URL) -> Bool {
        let path = url.standardized.path
        guard path != "/" else { return false }
        let keys: Set<URLResourceKey> = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        guard let volume = mounted.first(where: { $0.standardized.path == path }),
              let values = try? volume.resourceValues(forKeys: keys)
        else { return false }
        return values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
    }

    /// Unmounts off the main thread, because a busy volume can take a while to answer.
    static func eject(_ url: URL, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let error: Error?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                error = nil
            } catch let failure {
                error = failure
            }
            DispatchQueue.main.async { completion(error) }
        }
    }
}
