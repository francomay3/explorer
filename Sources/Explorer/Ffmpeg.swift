import AppKit
import CryptoKit

/// Optional help from an installed ffmpeg for video that macOS can't decode, such as VP9 or mkv.
/// Nothing here is required: without ffmpeg every call reports "no result" and the pane shows a message.
enum Ffmpeg {
    static let url: URL? = [
        "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
    ]
    .map { URL(fileURLWithPath: $0) }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    /// A still frame from the video, on the main queue, or nil when ffmpeg is missing or fails.
    /// Thumbnails for a whole folder share two slots, so `urgent` lets the selected file go first.
    static func frame(of video: URL, maxPixel: CGFloat, urgent: Bool = false, completion: @escaping (NSImage?) -> Void) {
        guard let ffmpeg = url else {
            completion(nil)
            return
        }
        let operation = BlockOperation {
            let size = Int(maxPixel)
            // A clip shorter than the first seek point gives no frame, so retry from the start.
            let image = ["1", "0"].lazy.compactMap { start -> NSImage? in
                let data = output(ffmpeg, [
                    "-v", "error", "-ss", start, "-i", video.path, "-frames:v", "1",
                    "-vf", "scale=\(size):\(size):force_original_aspect_ratio=decrease",
                    "-f", "image2pipe", "-vcodec", "png", "-",
                ])
                return data.isEmpty ? nil : NSImage(data: data)
            }.first
            DispatchQueue.main.async { completion(image) }
        }
        operation.queuePriority = urgent ? .veryHigh : .normal
        frameQueue.addOperation(operation)
    }

    private static let frameQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Runs ffmpeg and returns what it wrote to stdout. Reading comes first, because a full pipe would block it.
    private static func output(_ ffmpeg: URL, _ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : Data()
    }
}

/// Makes an H.264 copy of a video that macOS can't play, so the pane can play that instead.
/// Copies live in the user's caches folder and are reused until the source changes or a week passes.
final class PlaybackConverter {
    static let shared = PlaybackConverter()

    private let queue = DispatchQueue(label: "explorer.convert", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var running: Process?
    private var purged = false

    private var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.framay.explorer/playback", isDirectory: true)
    }

    /// The finished copy, when an earlier conversion already made it.
    func cached(for source: URL) -> URL? {
        let url = destination(for: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Calls `completion` on the main queue with the copy, or nil when it could not be made.
    /// A cancelled conversion never calls back.
    func convert(_ source: URL, completion: @escaping (URL?) -> Void) {
        guard let ffmpeg = Ffmpeg.url else {
            completion(nil)
            return
        }
        lock.lock()
        let mine = generation
        lock.unlock()
        queue.async {
            guard self.isCurrent(mine) else { return }
            let destination = self.destination(for: source)
            if FileManager.default.fileExists(atPath: destination.path) {
                DispatchQueue.main.async { completion(destination) }
                return
            }
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            self.purgeOldCopies()
            let partial = destination.deletingPathExtension().appendingPathExtension("partial.mp4")
            let made = self.encode(ffmpeg, source, to: partial, hardware: true, generation: mine)
                || self.encode(ffmpeg, source, to: partial, hardware: false, generation: mine)
            guard self.isCurrent(mine) else {
                try? FileManager.default.removeItem(at: partial)
                return
            }
            var result: URL?
            if made, (try? FileManager.default.moveItem(at: partial, to: destination)) != nil {
                result = destination
            }
            try? FileManager.default.removeItem(at: partial)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stops the running conversion, for when the selection moves on.
    func cancel() {
        lock.lock()
        generation += 1
        let process = running
        lock.unlock()
        process?.terminate()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation
    }

    private func encode(_ ffmpeg: URL, _ source: URL, to output: URL, hardware: Bool, generation: Int) -> Bool {
        try? FileManager.default.removeItem(at: output)
        let video = hardware
            ? ["-c:v", "h264_videotoolbox", "-b:v", "8M"]
            : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-y", "-i", source.path, "-map", "0:v:0", "-map", "0:a:0?",
                             "-vf", "scale='min(1920,iw)':-2,format=yuv420p"]
            + video + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        guard generation == self.generation, (try? process.run()) != nil else {
            lock.unlock()
            return false
        }
        running = process
        lock.unlock()
        process.waitUntilExit()
        lock.lock()
        running = nil
        lock.unlock()
        return process.terminationStatus == 0 && generation == self.generation
    }

    /// The name changes with the file's path, size and date, so an edited file gets a new copy.
    private func destination(for source: URL) -> URL {
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(source.standardized.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(stamp.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash).appendingPathExtension("mp4")
    }

    private func purgeOldCopies() {
        guard !purged else { return }
        purged = true
        let week: TimeInterval = 7 * 24 * 3600
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, Date().timeIntervalSince(date) > week { try? FileManager.default.removeItem(at: file) }
        }
    }
}
