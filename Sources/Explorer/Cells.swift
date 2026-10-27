import AppKit
import ExplorerCore

final class NameCell: NSTableCellView {
    let nameField = NSTextField(labelWithString: "")
    private let iconView = DragForwardingImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = .systemFont(ofSize: 13)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(iconView)
        addSubview(nameField)
        imageView = iconView
        textField = nameField
        iconView.unregisterDraggedTypes()
        nameField.unregisterDraggedTypes()
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(name: String, icon: NSImage) {
        nameField.stringValue = name
        iconView.image = icon
        iconView.unregisterDraggedTypes()
        nameField.unregisterDraggedTypes()
    }

    func beginEditing(text: String, delegate: NSTextFieldDelegate, selectsAll: Bool) {
        NameEditing.begin(nameField, text: text, delegate: delegate, selectsAll: selectsAll, bezeled: false)
    }

    func finishEditing() {
        NameEditing.finish(nameField, bezeled: false)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        finishEditing()
    }
}

/// The editor shown while renaming: a wrapping, multi-line field in a popover, so long names are fully visible.
final class RenameField: NSTextField {
    weak var popover: NSPopover?
    private(set) var cancelled = false
    private var escapeMonitor: Any?

    /// Esc abandons the edit. The popover would otherwise close like a click outside and keep the typed name.
    func watchForEscape() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.currentEditor() != nil else { return event }
            self.cancelled = true
            self.close()
            return nil
        }
    }

    func close() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        popover?.close()
        popover = nil
    }
}

enum NameEditing {
    static func begin(
        _ field: NSTextField,
        text: String,
        delegate: NSTextFieldDelegate,
        selectsAll: Bool,
        bezeled: Bool
    ) {
        guard field.window != nil else { return }
        let editor = RenameField(frame: NSRect(x: 10, y: 10, width: 300, height: 72))
        editor.stringValue = text
        editor.font = .systemFont(ofSize: 13)
        editor.isEditable = true
        editor.isSelectable = true
        editor.isBezeled = true
        editor.bezelStyle = .squareBezel
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.usesSingleLineMode = false
        editor.maximumNumberOfLines = 0
        editor.lineBreakMode = .byCharWrapping
        editor.cell?.wraps = true
        editor.cell?.isScrollable = false
        editor.delegate = delegate

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 92))
        content.addSubview(editor)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        editor.popover = popover
        editor.watchForEscape()
        let anchor = NSRect(x: 0, y: 0, width: min(160, field.bounds.width), height: field.bounds.height)
        popover.show(relativeTo: anchor, of: field, preferredEdge: .maxY)

        DispatchQueue.main.async { [weak editor] in
            guard let editor, let window = editor.window else { return }
            if editor.currentEditor() == nil { window.makeFirstResponder(editor) }
            guard let current = editor.currentEditor() else { return }
            let ns = text as NSString
            let dot = ns.range(of: ".", options: .backwards)
            if selectsAll || ns.length == 0 || dot.location == NSNotFound || dot.location == 0 {
                current.selectedRange = NSRange(location: 0, length: ns.length)
            } else {
                current.selectedRange = NSRange(location: 0, length: dot.location)
            }
        }
    }

    static func finish(_ field: NSTextField, bezeled: Bool) {
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        guard bezeled else { return }
        field.isBezeled = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 2
    }

    static func movement(in note: Notification) -> Int? {
        if let value = note.userInfo?["NSTextMovement"] as? Int { return value }
        if let value = note.userInfo?["NSTextMovement"] as? NSNumber { return value.intValue }
        return nil
    }
}

/// A second click on an already selected item, after the double-click window, starts a rename.
final class RenameClick {
    var onRename: (() -> Void)?
    private var work: DispatchWorkItem?

    func cancel() {
        work?.cancel()
        work = nil
    }

    func arm(alreadySelected: Bool, clickCount: Int, modifiers: NSEvent.ModifierFlags, dragged: Bool) {
        cancel()
        guard clickCount == 1, alreadySelected, !dragged else { return }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .shift, .option, .control]) else { return }
        let work = DispatchWorkItem { [weak self] in self?.onRename?() }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}

final class SizeCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        addSubview(label)
        addSubview(spinner)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showFile(bytes: Int64?) {
        guard let bytes else {
            showIdle("")
            return
        }
        showBytes(bytes, marked: false)
    }

    func showDirectory(_ reading: FolderSizeReading) {
        switch reading {
        case .loading:
            label.isHidden = true
            label.stringValue = ""
            spinner.isHidden = false
            spinner.startAnimation(nil)
            toolTip = L10n.calculatingSize
        case .unavailable:
            showIdle("")
        case let .fresh(bytes):
            showBytes(bytes, marked: false)
        case let .revalidating(bytes):
            showBytes(bytes, marked: true)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.isHidden = false
        toolTip = nil
    }

    private func showBytes(_ bytes: Int64, marked: Bool) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.isHidden = false
        let font = NSFont.systemFont(ofSize: 13)
        let text = NSMutableAttributedString(
            string: Format.size(bytes),
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        if marked {
            text.append(NSAttributedString(
                string: " *",
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
            toolTip = L10n.updatingSize
        } else {
            toolTip = nil
        }
        label.attributedStringValue = text
    }

    private func showIdle(_ text: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.isHidden = false
        label.stringValue = text
        toolTip = nil
    }
}

final class TextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: String, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
    }
}

/// Sits over an empty folder without eating clicks meant for the list.
final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
