import Foundation

/// Captured before a trash, while the files still exist and their sizes can be read.
public struct FolderRemovalPlan {
    fileprivate let items: [(path: String, weight: Int64?)]
}

/// Captured before a move. Applied afterwards, including when only some of the items arrived.
public struct FolderMovePlan {
    fileprivate let destination: URL
    fileprivate let items: [(from: String, name: String, weight: Int64?)]
}

/// Stored sizes for directories, plus a one-at-a-time walk of the folders on screen.
///
/// A delete subtracts the known weight from each stored ancestor, so the top folder
/// does not get walked again. A later look reuses child totals: within 7 days it
/// only re-lists the folder, and after that it rewalks branches nobody has refreshed.
public final class FolderSizeIndex {
    public var performsWorkInline = false
    public var now: () -> Date = { Date() }
    public var onUpdate: ((Set<String>) -> Void)?

    private struct Stored {
        var bytes: Int64
        var computedAt: Date
    }

    private enum Work {
        /// Re-list this folder and reuse every cached child, however old.
        case shallow
        /// Reuse a child only when it is younger than `staleAfter`.
        case deep
    }

    private final class Walk {
        var cancelled = false
    }

    private struct Cancelled: Error {}

    private let database: FolderSizeDatabase?
    private let lock = NSLock()
    private var records: [String: Stored] = [:]
    private var wanted: Set<String> = []
    private var visibleOrder: [String] = []
    private var blocked: Set<String> = []
    private var runningPath: String?
    private var runningToken: Walk?
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .volumeURLKey,
    ]

    /// One path for `/var` and `/private/var`. Symlink folders are not measured, so resolving the path does not follow a link we meant to skip.
    public static func cacheKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path
    }

    public init(databaseURL: URL) {
        let folder = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = FolderSizeDatabase(url: databaseURL)
        self.database = database
        if let database {
            records = database.loadAll().mapValues { Stored(bytes: $0.bytes, computedAt: $0.computedAt) }
        }
    }

    public static func defaultDatabaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("dev.framay.explorer", isDirectory: true)
            .appendingPathComponent("folder-sizes.sqlite")
    }

    public func reading(for url: URL) -> FolderSizeReading {
        let path = Self.cacheKey(for: url)
        lock.lock()
        let stored = records[path]
        let isBlocked = blocked.contains(path)
        lock.unlock()
        guard let stored else { return isBlocked ? .unavailable : .loading }
        switch FolderSizePolicy.phase(age: now().timeIntervalSince(stored.computedAt)) {
        case .fresh:
            return .fresh(stored.bytes)
        case .revalidating, .stale:
            return .revalidating(stored.bytes)
        }
    }

    public func cachedBytes(for url: URL) -> Int64? {
        let path = Self.cacheKey(for: url)
        lock.lock()
        let bytes = records[path]?.bytes
        lock.unlock()
        return bytes
    }

    public func record(for url: URL) -> FolderSizeRecord? {
        let path = Self.cacheKey(for: url)
        lock.lock()
        let stored = records[path]
        lock.unlock()
        guard let stored else { return nil }
        return FolderSizeRecord(bytes: stored.bytes, computedAt: stored.computedAt)
    }

    /// Records a size without walking. An empty folder just created is `0`.
    public func remember(url: URL, bytes: Int64, computedAt: Date? = nil) {
        let stamp = computedAt ?? now()
        write(path: Self.cacheKey(for: url), bytes: bytes, computedAt: stamp, bubble: false, announce: true)
    }

    public func noteCreatedFolder(_ url: URL) {
        remember(url: url, bytes: 0)
    }

    /// `urls` is every directory in the open folder. `prioritizing` is the ones on screen, and they go first.
    public func noteVisible(_ urls: [URL], prioritizing preferred: [URL] = []) {
        var seen = Set<String>()
        var order: [String] = []
        func append(_ url: URL) {
            let path = Self.cacheKey(for: url)
            if seen.insert(path).inserted {
                order.append(path)
            }
        }
        for url in preferred {
            append(url)
        }
        for url in urls {
            append(url)
        }
        lock.lock()
        let unchanged = visibleOrder == order
        if !unchanged {
            let previous = wanted
            wanted = seen
            visibleOrder = order
            blocked.subtract(previous.subtracting(seen))
            if let runningPath, !seen.contains(runningPath) {
                runningToken?.cancelled = true
            }
        }
        lock.unlock()
        schedule()
    }

    public func noteRenamed(from: URL, to: URL) {
        let source = Self.cacheKey(for: from)
        let destination = Self.cacheKey(for: to)
        guard source != destination else { return }
        lock.lock()
        let moved = retargetLocked(from: source, to: destination)
        lock.unlock()
        database?.delete(paths: moved.removed)
        database?.save(moved.saved)
        if !moved.saved.isEmpty || !moved.removed.isEmpty {
            publish(Set(moved.removed).union(moved.saved.map(\.path)))
        }
    }

    public func planRemoval(of urls: [URL]) -> FolderRemovalPlan {
        FolderRemovalPlan(items: urls.map { url in
            let path = Self.cacheKey(for: url)
            return (path, knownWeight(of: url))
        })
    }

    public func finishRemoval(_ plan: FolderRemovalPlan, succeeded: [URL]) {
        let ok = Set(succeeded.map { Self.cacheKey(for: $0) })
        var changed = Set<String>()
        var saving: [(path: String, record: FolderSizeRecord)] = []
        var removing: [String] = []
        let stamp = now()
        lock.lock()
        for item in plan.items where ok.contains(item.path) {
            let dropped = dropLocked(path: item.path)
            removing.append(contentsOf: dropped)
            changed.formUnion(dropped)
            if let weight = item.weight {
                applyDeltaLocked(-weight, ancestorsOf: item.path, markFresh: true, now: stamp, changed: &changed, saving: &saving)
            } else {
                ageAncestorsLocked(of: item.path, now: stamp, changed: &changed, saving: &saving)
            }
        }
        lock.unlock()
        database?.delete(paths: removing)
        database?.save(saving)
        publish(changed)
        schedule()
    }

    public func planMove(of urls: [URL], to folder: URL) -> FolderMovePlan {
        FolderMovePlan(
            destination: URL(fileURLWithPath: Self.cacheKey(for: folder), isDirectory: true),
            items: urls.map { url in
                (Self.cacheKey(for: url), url.lastPathComponent, knownWeight(of: url))
            }
        )
    }

    /// Call after the move returns, whether or not every item made it.
    public func finishMove(_ plan: FolderMovePlan) {
        var changed = Set<String>()
        var saving: [(path: String, record: FolderSizeRecord)] = []
        var removing: [String] = []
        let stamp = now()
        lock.lock()
        for item in plan.items {
            let destination = Self.cacheKey(for: plan.destination.appendingPathComponent(item.name))
            let atDestination = FileManager.default.fileExists(atPath: destination)
            let atSource = FileManager.default.fileExists(atPath: item.from)
            guard atDestination, !atSource else { continue }
            let moved = retargetLocked(from: item.from, to: destination)
            removing.append(contentsOf: moved.removed)
            saving.append(contentsOf: moved.saved)
            changed.formUnion(moved.removed)
            changed.formUnion(moved.saved.map(\.path))
            if let weight = item.weight {
                applyDeltaLocked(-weight, ancestorsOf: item.from, markFresh: true, now: stamp, changed: &changed, saving: &saving)
                applyDeltaLocked(weight, ancestorsOf: destination, markFresh: true, now: stamp, changed: &changed, saving: &saving)
            } else {
                ageAncestorsLocked(of: item.from, now: stamp, changed: &changed, saving: &saving)
                ageAncestorsLocked(of: destination, now: stamp, changed: &changed, saving: &saving)
            }
        }
        lock.unlock()
        database?.delete(paths: removing)
        database?.save(saving)
        publish(changed)
        schedule()
    }

    public func noteCopied(from sources: [URL], to created: [URL]) {
        let pairs = zip(sources, created)
        var changed = Set<String>()
        var saving: [(path: String, record: FolderSizeRecord)] = []
        let stamp = now()
        lock.lock()
        for (source, copy) in pairs {
            let from = Self.cacheKey(for: source)
            let to = Self.cacheKey(for: copy)
            let weight = knownWeightLocked(path: from, url: source)
            if records[from] != nil {
                let copied = duplicateLocked(from: from, to: to)
                saving.append(contentsOf: copied)
                changed.formUnion(copied.map(\.path))
            }
            if let weight {
                applyDeltaLocked(weight, ancestorsOf: to, markFresh: true, now: stamp, changed: &changed, saving: &saving)
            } else {
                ageAncestorsLocked(of: to, now: stamp, changed: &changed, saving: &saving)
                ageLocked(to, now: stamp, changed: &changed, saving: &saving)
            }
        }
        lock.unlock()
        database?.save(saving)
        publish(changed)
        schedule()
    }

    /// The stored number stays, and the next look at a visible folder checks it again.
    public func markRevalidating(_ urls: [URL]) {
        var changed = Set<String>()
        var saving: [(path: String, record: FolderSizeRecord)] = []
        let stamp = now()
        lock.lock()
        for url in urls {
            let path = Self.cacheKey(for: url)
            ageLocked(path, now: stamp, changed: &changed, saving: &saving)
            ageAncestorsLocked(of: path, now: stamp, changed: &changed, saving: &saving)
        }
        lock.unlock()
        database?.save(saving)
        publish(changed)
        schedule()
    }

    private func schedule() {
        lock.lock()
        let idle = runningPath == nil
        let order = visibleOrder
        let next = idle ? nextPathLocked(in: order) : nil
        let token = Walk()
        if let next {
            runningPath = next
            runningToken = token
        }
        let trustAnyAge = next.map { workKindLocked($0) == .shallow } ?? false
        lock.unlock()
        guard let next else { return }

        let run = { [weak self] in
            guard let self else { return }
            do {
                let bytes = try self.measure(url: URL(fileURLWithPath: next), trustAnyAge: trustAnyAge, walk: token)
                self.finish(path: next, bytes: bytes, token: token)
            } catch {
                self.finish(path: next, bytes: nil, token: token)
            }
        }
        if performsWorkInline {
            run()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: run)
        }
    }

    /// Folders with no number go first, so spinners clear before stale ones are checked.
    private func nextPathLocked(in order: [String]) -> String? {
        let pending = order.filter { needsWorkLocked($0) }
        if let missing = pending.first(where: { records[$0] == nil }) {
            return missing
        }
        return pending.first
    }

    private func needsWorkLocked(_ path: String) -> Bool {
        if blocked.contains(path) { return false }
        return workKindLocked(path) != nil
    }

    private func workKindLocked(_ path: String) -> Work? {
        guard let stored = records[path] else { return .deep }
        switch FolderSizePolicy.phase(age: now().timeIntervalSince(stored.computedAt)) {
        case .fresh:
            return nil
        case .revalidating:
            return .shallow
        case .stale:
            return .deep
        }
    }

    private func finish(path: String, bytes: Int64?, token: Walk) {
        let apply = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.runningToken === token
            if current {
                self.runningPath = nil
                self.runningToken = nil
            }
            self.lock.unlock()
            guard current else { return }
            if let bytes {
                self.lock.lock()
                self.blocked.remove(path)
                self.lock.unlock()
                // A walk that finished is worth keeping, even if the folder has since scrolled away.
                self.write(path: path, bytes: bytes, computedAt: self.now(), bubble: true, announce: true)
            } else if !token.cancelled {
                self.lock.lock()
                self.blocked.insert(path)
                self.lock.unlock()
                self.publish([path])
            }
            self.schedule()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func measure(url: URL, trustAnyAge: Bool, walk: Walk) throws -> Int64 {
        if walk.cancelled { throw Cancelled() }
        let standard = url.standardized
        let values = try? standard.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true {
            return Int64(values?.fileSize ?? 0)
        }
        let parentVolume = values?.volume?.standardized.path
        let children = try FileManager.default.contentsOfDirectory(
            at: standard,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var total: Int64 = 0
        for child in children {
            if walk.cancelled { throw Cancelled() }
            let childValues = try? child.resourceValues(forKeys: keys)
            if childValues?.isSymbolicLink == true {
                total += Int64(childValues?.fileSize ?? 0)
                continue
            }
            let isDirectory = childValues?.isDirectory ?? false
            if isDirectory {
                if let parentVolume, let childVolume = childValues?.volume?.standardized.path, childVolume != parentVolume {
                    continue
                }
                let path = Self.cacheKey(for: child)
                if let cached = cachedChildBytes(path: path, trustAnyAge: trustAnyAge) {
                    total += cached
                } else {
                    let bytes = try measure(url: child, trustAnyAge: trustAnyAge, walk: walk)
                    write(path: path, bytes: bytes, computedAt: now(), bubble: false, announce: false)
                    total += bytes
                }
            } else {
                total += Int64(childValues?.fileSize ?? 0)
            }
        }
        return total
    }

    private func cachedChildBytes(path: String, trustAnyAge: Bool) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = records[path] else { return nil }
        if trustAnyAge { return stored.bytes }
        if now().timeIntervalSince(stored.computedAt) < FolderSizePolicy.staleAfter {
            return stored.bytes
        }
        return nil
    }

    private func write(path: String, bytes: Int64, computedAt: Date, bubble: Bool, announce: Bool) {
        var changed: Set<String> = [path]
        var saving: [(path: String, record: FolderSizeRecord)] = []
        lock.lock()
        let previous = records[path]?.bytes
        records[path] = Stored(bytes: bytes, computedAt: computedAt)
        saving.append((path, FolderSizeRecord(bytes: bytes, computedAt: computedAt)))
        if bubble, let previous, previous != bytes {
            applyDeltaLocked(bytes - previous, ancestorsOf: path, markFresh: false, now: computedAt, changed: &changed, saving: &saving)
        }
        let visible = wanted
        lock.unlock()
        database?.save(saving)
        let announced = announce ? changed : changed.intersection(visible)
        if !announced.isEmpty {
            publish(announced)
        }
    }

    private func knownWeight(of url: URL) -> Int64? {
        lock.lock()
        let weight = knownWeightLocked(path: Self.cacheKey(for: url), url: url)
        lock.unlock()
        return weight
    }

    private func knownWeightLocked(path: String, url: URL) -> Int64? {
        if let stored = records[path] { return stored.bytes }
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true {
            return Int64(values?.fileSize ?? 0)
        }
        if values?.isDirectory == true {
            return nil
        }
        return values?.fileSize.map { Int64($0) }
    }

    private func applyDeltaLocked(
        _ delta: Int64,
        ancestorsOf path: String,
        markFresh: Bool,
        now: Date,
        changed: inout Set<String>,
        saving: inout [(path: String, record: FolderSizeRecord)]
    ) {
        guard delta != 0 else { return }
        var parent = Paths.parent(of: URL(fileURLWithPath: path))
        while let current = parent {
            let key = current.standardized.path
            if var stored = records[key] {
                stored.bytes += delta
                if markFresh { stored.computedAt = now }
                records[key] = stored
                changed.insert(key)
                saving.append((key, FolderSizeRecord(bytes: stored.bytes, computedAt: stored.computedAt)))
            }
            parent = Paths.parent(of: current)
        }
    }

    private func ageAncestorsLocked(
        of path: String,
        now: Date,
        changed: inout Set<String>,
        saving: inout [(path: String, record: FolderSizeRecord)]
    ) {
        var parent = Paths.parent(of: URL(fileURLWithPath: path))
        while let current = parent {
            ageLocked(current.standardized.path, now: now, changed: &changed, saving: &saving)
            parent = Paths.parent(of: current)
        }
    }

    private func ageLocked(
        _ path: String,
        now: Date,
        changed: inout Set<String>,
        saving: inout [(path: String, record: FolderSizeRecord)]
    ) {
        guard var stored = records[path] else { return }
        stored.computedAt = now.addingTimeInterval(-(FolderSizePolicy.fresh + 1))
        records[path] = stored
        changed.insert(path)
        saving.append((path, FolderSizeRecord(bytes: stored.bytes, computedAt: stored.computedAt)))
    }

    private func dropLocked(path: String) -> [String] {
        let doomed = records.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        for key in doomed {
            records.removeValue(forKey: key)
        }
        return doomed
    }

    private func retargetLocked(
        from source: String,
        to destination: String
    ) -> (removed: [String], saved: [(path: String, record: FolderSizeRecord)]) {
        let keys = records.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
        var removed: [String] = []
        var saved: [(path: String, record: FolderSizeRecord)] = []
        for key in keys {
            guard let stored = records.removeValue(forKey: key) else { continue }
            let suffix = key.dropFirst(source.count)
            let path = destination + suffix
            records[path] = stored
            removed.append(key)
            saved.append((path, FolderSizeRecord(bytes: stored.bytes, computedAt: stored.computedAt)))
        }
        return (removed, saved)
    }

    private func duplicateLocked(
        from source: String,
        to destination: String
    ) -> [(path: String, record: FolderSizeRecord)] {
        let keys = records.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
        var saved: [(path: String, record: FolderSizeRecord)] = []
        for key in keys {
            guard let stored = records[key] else { continue }
            let suffix = key.dropFirst(source.count)
            let path = destination + suffix
            records[path] = stored
            saved.append((path, FolderSizeRecord(bytes: stored.bytes, computedAt: stored.computedAt)))
        }
        return saved
    }

    private func publish(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let callback = onUpdate
        if Thread.isMainThread {
            callback?(paths)
        } else {
            DispatchQueue.main.async {
                callback?(paths)
            }
        }
    }
}
