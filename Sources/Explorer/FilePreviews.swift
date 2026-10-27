import AppKit
import AVFoundation
import ExplorerCore
import UniformTypeIdentifiers

/// What the preview pane can show for one file.
enum FilePreview {
    case image(NSImage)
    case text(String)
    case unavailable
}

/// One format the preview pane understands.
/// To support another, add a type below and put it in `FilePreviews.providers`.
/// Earlier providers win when more than one matches.
protocol FilePreviewProvider: AnyObject {
    func canPreview(_ item: FileItem) -> Bool
    func loadPreview(_ item: FileItem, completion: @escaping (FilePreview) -> Void)
    func loadThumbnail(_ item: FileItem, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void)
}

extension FilePreviewProvider {
    func loadThumbnail(_ item: FileItem, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        completion(nil)
    }
}

enum FilePreviews {
    static let providers: [FilePreviewProvider] = [
        ImagePreviewProvider(),
        VideoPreviewProvider(),
        TextPreviewProvider(),
    ]

    static func provider(for item: FileItem) -> FilePreviewProvider? {
        guard !item.opensAsFolder else { return nil }
        return providers.first { $0.canPreview(item) }
    }
}

private enum PreviewTypes {
    static func item(_ item: FileItem, conformsTo type: UTType) -> Bool {
        let ext = item.url.pathExtension
        guard !ext.isEmpty, let ut = UTType(filenameExtension: ext) else { return false }
        return ut.conforms(to: type)
    }
}

private final class ImagePreviewProvider: FilePreviewProvider {
    func canPreview(_ item: FileItem) -> Bool {
        PreviewTypes.item(item, conformsTo: .image)
    }

    func loadPreview(_ item: FileItem, completion: @escaping (FilePreview) -> Void) {
        Thumbnails.image(for: item.url, maxPixel: 1600) { image in
            completion(image.map(FilePreview.image) ?? .unavailable)
        }
    }

    func loadThumbnail(_ item: FileItem, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        Thumbnails.image(for: item.url, maxPixel: maxPixel, completion: completion)
    }
}

private final class VideoPreviewProvider: FilePreviewProvider {
    private var live: [AVAssetImageGenerator] = []
    private let extraExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "m4v", "mov", "mp4"]

    func canPreview(_ item: FileItem) -> Bool {
        if PreviewTypes.item(item, conformsTo: .movie) || PreviewTypes.item(item, conformsTo: .video) {
            return true
        }
        return extraExtensions.contains(item.url.pathExtension.lowercased())
    }

    func loadPreview(_ item: FileItem, completion: @escaping (FilePreview) -> Void) {
        frame(for: item.url, maxPixel: 1600) { image in
            completion(image.map(FilePreview.image) ?? .unavailable)
        }
    }

    func loadThumbnail(_ item: FileItem, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        frame(for: item.url, maxPixel: maxPixel, completion: completion)
    }

    private func frame(for url: URL, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let slack = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        live.append(generator)
        let time = NSValue(time: CMTime(seconds: 1, preferredTimescale: 600))
        generator.generateCGImagesAsynchronously(forTimes: [time]) { [weak self] _, cgImage, _, _, _ in
            let width = cgImage?.width ?? 0
            let height = cgImage?.height ?? 0
            let retained = cgImage
            DispatchQueue.main.async {
                self?.live.removeAll { $0 === generator }
                let image = retained.map {
                    NSImage(cgImage: $0, size: NSSize(width: CGFloat(width), height: CGFloat(height)))
                }
                completion(image)
            }
        }
    }
}

private final class TextPreviewProvider: FilePreviewProvider {
    private let extraExtensions: Set<String> = [
        "md", "markdown", "yaml", "yml", "toml", "log", "csv", "json", "sh", "zsh", "txt",
    ]

    func canPreview(_ item: FileItem) -> Bool {
        if PreviewTypes.item(item, conformsTo: .rtf) { return false }
        if PreviewTypes.item(item, conformsTo: .text) { return true }
        return extraExtensions.contains(item.url.pathExtension.lowercased())
    }

    func loadPreview(_ item: FileItem, completion: @escaping (FilePreview) -> Void) {
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = Self.read(url)
            DispatchQueue.main.async { completion(preview) }
        }
    }

    private static func read(_ url: URL) -> FilePreview {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unavailable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return .unavailable }
        if data.isEmpty { return .text("") }
        if let text = String(data: data, encoding: .utf8) { return .text(text) }
        if let text = String(data: data, encoding: .utf16) { return .text(text) }
        return .unavailable
    }
}
