import AppKit
import AVFoundation
import ExplorerCore
import Highlightr
import PDFKit
import UniformTypeIdentifiers

/// What the preview pane can show for one file.
enum FilePreview {
    case image(NSImage)
    case text(NSAttributedString)
    /// Audio or video that the pane plays itself.
    case video(URL)
    /// A PDF the pane scrolls with PDFKit.
    case pdf(PDFDocument)
    /// A video macOS can't play is being converted. Shows its still frame, if there is one, meanwhile.
    case converting(NSImage?)
    /// Why the file can't be previewed.
    case message(String)
    case unavailable
}

/// One format the preview pane understands.
/// To support another, add a type below and put it in `FilePreviews.providers`.
/// Earlier providers win when more than one matches.
/// `loadPreview` may call back more than once, and a later result replaces the earlier one.
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
        PDFPreviewProvider(),
        VideoPreviewProvider(),
        AudioPreviewProvider(),
        TextPreviewProvider(),
    ]

    /// Last resort for the preview pane: files no provider claims, such as `.tsx` or `Makefile`,
    /// are shown as text when their content looks like text. Reads the file, so the file lists
    /// must not call it per row.
    private static let sniffing: FilePreviewProvider = TextPreviewProvider(sniffs: true)

    static func stageProvider(for item: FileItem) -> FilePreviewProvider? {
        guard !item.opensAsFolder else { return nil }
        return provider(for: item) ?? sniffing
    }

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

private final class PDFPreviewProvider: FilePreviewProvider {
    func canPreview(_ item: FileItem) -> Bool {
        PreviewTypes.item(item, conformsTo: .pdf)
    }

    func loadPreview(_ item: FileItem, completion: @escaping (FilePreview) -> Void) {
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            let document = PDFDocument(url: url)
            let preview: FilePreview
            if let document, !document.isLocked, document.pageCount > 0 {
                preview = .pdf(document)
            } else {
                preview = .unavailable
            }
            DispatchQueue.main.async { completion(preview) }
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
        let url = item.url
        Task {
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            if playable {
                await MainActor.run { completion(.video(url)) }
                return
            }
            let codec = await Self.codecName(of: asset)
            await MainActor.run { self.playConverted(url, codec: codec, completion: completion) }
        }
    }

    /// Video macOS can't decode, such as VP9 or mkv: play an H.264 copy made by ffmpeg when there is one.
    private func playConverted(_ url: URL, codec: String?, completion: @escaping (FilePreview) -> Void) {
        let cantPlay = FilePreview.message(L10n.cantPlay(codec: codec))
        if let copy = PlaybackConverter.shared.cached(for: url) {
            completion(.video(copy))
            return
        }
        var finished = false
        var still: NSImage?
        guard Ffmpeg.url != nil else {
            frame(for: url, maxPixel: 1600) { image in
                completion(image.map(FilePreview.image) ?? cantPlay)
            }
            return
        }
        completion(.converting(nil))
        frame(for: url, maxPixel: 1600, urgent: true) { image in
            still = image
            if !finished, image != nil { completion(.converting(image)) }
        }
        PlaybackConverter.shared.convert(url) { copy in
            finished = true
            if let copy {
                completion(.video(copy))
            } else {
                completion(still.map(FilePreview.image) ?? cantPlay)
            }
        }
    }

    private static func codecName(of asset: AVURLAsset) async -> String? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first
        else { return nil }
        let code = description.mediaSubType.rawValue
        let name = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? ""
        let known = ["vp09": "VP9", "vp08": "VP8", "av01": "AV1", "hev1": "HEVC", "hvc1": "HEVC"]
        return known[name] ?? (name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name.uppercased())
    }

    func loadThumbnail(_ item: FileItem, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        frame(for: item.url, maxPixel: maxPixel, completion: completion)
    }

    private func frame(for url: URL, maxPixel: CGFloat, urgent: Bool = false, completion: @escaping (NSImage?) -> Void) {
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
                if image == nil {
                    // macOS couldn't read a frame, so ask ffmpeg, which knows more formats.
                    Ffmpeg.frame(of: url, maxPixel: maxPixel, urgent: urgent, completion: completion)
                } else {
                    completion(image)
                }
            }
        }
    }
}

/// Sound files get the same player as video, which shows only its controls.
private final class AudioPreviewProvider: FilePreviewProvider {
    func canPreview(_ item: FileItem) -> Bool {
        PreviewTypes.item(item, conformsTo: .audio)
    }

    func loadPreview(_ item: FileItem, completion: @escaping (FilePreview) -> Void) {
        let url = item.url
        Task {
            let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            await MainActor.run { completion(playable ? .video(url) : .unavailable) }
        }
    }
}

private final class TextPreviewProvider: FilePreviewProvider {
    private let extraExtensions: Set<String> = [
        "md", "markdown", "yaml", "yml", "toml", "log", "csv", "json", "sh", "zsh", "txt",
    ]
    /// When set, the provider accepts every file and reports binary content as unavailable.
    private let sniffs: Bool

    init(sniffs: Bool = false) {
        self.sniffs = sniffs
    }

    func canPreview(_ item: FileItem) -> Bool {
        if sniffs { return true }
        if PreviewTypes.item(item, conformsTo: .rtf) { return false }
        if PreviewTypes.item(item, conformsTo: .text) { return true }
        return extraExtensions.contains(item.url.pathExtension.lowercased())
    }

    func loadPreview(_ item: FileItem, completion: @escaping (FilePreview) -> Void) {
        let url = item.url
        let sniffs = sniffs
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        DispatchQueue.global(qos: .userInitiated).async {
            guard let text = Self.read(url, sniffs: sniffs) else {
                DispatchQueue.main.async { completion(.unavailable) }
                return
            }
            CodeHighlighter.shared.render(text, url: url, dark: dark) { rendered in
                DispatchQueue.main.async { completion(.text(rendered)) }
            }
        }
    }

    private static let maxBytes = 64 * 1024

    private static func read(_ url: URL, sniffs: Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return decode(data, strict: sniffs)
    }

    /// `strict` is for files we only guess are text: a NUL byte or invalid UTF-8 means binary.
    private static func decode(_ data: Data, strict: Bool) -> String? {
        if data.isEmpty { return "" }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if strict, data.contains(0) { return nil }
        // The read can stop in the middle of a multi-byte character.
        for cut in 0...min(3, data.count - 1) {
            if let text = String(data: data.dropLast(cut), encoding: .utf8) { return text }
        }
        if strict { return nil }
        return String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// Colors source text with highlight.js through Highlightr.
/// Highlightr is not thread safe, so all of its work runs on one serial queue.
private final class CodeHighlighter {
    static let shared = CodeHighlighter()

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Extensions whose highlight.js language has a different name.
    private static let languages: [String: String] = [
        "html": "xml", "htm": "xml", "xhtml": "xml", "svg": "xml", "plist": "xml", "vue": "xml",
        "xsd": "xml", "xsl": "xml", "rss": "xml", "jsx": "javascript", "js": "javascript",
        "mjs": "javascript", "cjs": "javascript", "ts": "typescript", "tsx": "typescript",
        "mts": "typescript", "cts": "typescript", "h": "c", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "hh": "cpp", "hxx": "cpp", "m": "objectivec", "mm": "objectivec", "py": "python",
        "rb": "ruby", "rs": "rust", "kt": "kotlin", "kts": "kotlin", "sh": "bash", "zsh": "bash",
        "yml": "yaml", "md": "markdown", "toml": "ini", "conf": "ini", "env": "ini",
        "gradle": "groovy", "mk": "makefile", "pl": "perl", "ps1": "powershell", "cs": "csharp",
    ]
    /// Files named instead of given an extension.
    private static let names: [String: String] = [
        "makefile": "makefile", "dockerfile": "dockerfile", "gemfile": "ruby", "rakefile": "ruby",
        "podfile": "ruby", "cmakelists.txt": "cmake",
    ]

    private let queue = DispatchQueue(label: "explorer.highlight", qos: .userInitiated)
    private let highlightr = Highlightr()
    private lazy var supported = Set(highlightr?.supportedLanguages() ?? [])
    private var theme: String?

    func render(_ text: String, url: URL, dark: Bool, completion: @escaping (NSAttributedString) -> Void) {
        queue.async {
            completion(self.highlight(text, url: url, dark: dark) ?? Self.plain(text))
        }
    }

    private func highlight(_ text: String, url: URL, dark: Bool) -> NSAttributedString? {
        guard let highlightr, let language = language(for: url) else { return nil }
        let name = dark ? "atom-one-dark" : "atom-one-light"
        if theme != name {
            guard highlightr.setTheme(to: name) else { return nil }
            highlightr.theme.setCodeFont(Self.font)
            theme = name
        }
        return highlightr.highlight(text, as: language, fastRender: true)
    }

    private func language(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let candidates = [Self.names[url.lastPathComponent.lowercased()], Self.languages[ext], ext]
        return candidates.compactMap { $0 }.first { supported.contains($0) }
    }

    private static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}
