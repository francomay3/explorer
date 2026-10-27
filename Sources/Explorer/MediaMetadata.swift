import CoreServices
import ExplorerCore
import Foundation

/// Size, capture date and length of photos and videos, read from Spotlight.
final class MediaMetadataCache {
    private var cache: [String: MediaInfo] = [:]
    private var waiters: [String: [() -> Void]] = [:]
    private let queue = DispatchQueue(label: "dev.framay.explorer.media-metadata", qos: .utility, attributes: .concurrent)

    func cached(_ url: URL) -> MediaInfo? {
        cache[url.path]
    }

    func reset() {
        cache.removeAll()
    }

    /// Reads one file off the main thread, then calls `completion` there. Always called later, never inline.
    func load(_ url: URL, completion: @escaping () -> Void) {
        let path = url.path
        if cache[path] != nil {
            DispatchQueue.main.async(execute: completion)
            return
        }
        if waiters[path] != nil {
            waiters[path]?.append(completion)
            return
        }
        waiters[path] = [completion]
        queue.async { [weak self] in
            let info = Self.read(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[path] = info
                let done = self.waiters.removeValue(forKey: path) ?? []
                done.forEach { $0() }
            }
        }
    }

    /// Calls `completion` once every file is read.
    func loadAll(_ urls: [URL], completion: @escaping () -> Void) {
        guard !urls.isEmpty else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        var remaining = urls.count
        for url in urls {
            load(url) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    private static func read(_ url: URL) -> MediaInfo {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return MediaInfo() }
        let keys = [kMDItemPixelWidth, kMDItemPixelHeight, kMDItemContentCreationDate, kMDItemDurationSeconds] as CFArray
        guard let values = MDItemCopyAttributes(item, keys) as? [String: Any] else { return MediaInfo() }
        return MediaInfo(
            width: (values[kMDItemPixelWidth as String] as? NSNumber)?.intValue,
            height: (values[kMDItemPixelHeight as String] as? NSNumber)?.intValue,
            taken: values[kMDItemContentCreationDate as String] as? Date,
            duration: (values[kMDItemDurationSeconds as String] as? NSNumber)?.doubleValue
        )
    }
}
