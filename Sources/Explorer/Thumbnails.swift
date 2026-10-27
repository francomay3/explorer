import AppKit
import ExplorerCore
import ImageIO

enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for url: URL, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)|\(Int(maxPixel.rounded()))" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = render(url: url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                let image = rendered.map { cgImage in
                    NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
                }
                if let image {
                    cache.setObject(image, forKey: key)
                }
                completion(image)
            }
        }
    }

    private static func render(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
