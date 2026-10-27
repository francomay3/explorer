import AppKit

enum DraggedFiles {
    static func urls(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

/// Sends a drop that lands on the icon through to the folder cell behind it.
final class DragForwardingImageView: NSImageView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragHost?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragHost?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragHost?.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragHost?.performDragOperation(sender) ?? false
    }

    private var dragHost: NSView? {
        var view = superview
        while let current = view {
            if current is IconDropView || current is DropRowView { return current }
            view = current.superview
        }
        return nil
    }
}

/// A folder row. The whole row accepts a drop, not only the icon at the left.
final class DropRowView: NSTableRowView {
    var canAccept: ((NSDraggingInfo) -> Bool)?
    var accept: ((NSDraggingInfo) -> Bool)?
    private var targeted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        return accept?(sender) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard targeted else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        path.stroke()
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = canAccept?(sender) == true
        setTargeted(ok)
        return ok ? .move : []
    }

    private func setTargeted(_ on: Bool) {
        guard targeted != on else { return }
        targeted = on
        needsDisplay = true
    }
}
