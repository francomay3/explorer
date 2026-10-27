import Foundation

public struct NavigationHistory {
    private var entries: [URL]
    private var index: Int

    public init(startingAt url: URL) {
        entries = [url.standardized]
        index = 0
    }

    public var current: URL { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    public mutating func go(_ url: URL) {
        let next = url.standardized
        if Paths.same(next, current) { return }
        if canGoForward {
            entries.removeLast(entries.count - index - 1)
        }
        entries.append(next)
        index = entries.count - 1
    }

    @discardableResult
    public mutating func back() -> URL? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    @discardableResult
    public mutating func forward() -> URL? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}
