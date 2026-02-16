import AppKit

final class HelpWindowController: NSWindowController {

    private static var shared: HelpWindowController?

    static func showHelp() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = HelpWindowController()
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let inset: CGFloat = 16
        let scrollFrame = contentView.bounds.insetBy(dx: inset, dy: 12)

        let scrollView = NSScrollView(frame: scrollFrame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        contentView.addSubview(scrollView)

        let contentWidth = scrollView.contentSize.width
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 0))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        textView.textStorage?.setAttributedString(buildHelpContent())
    }

    private func buildHelpContent() -> NSAttributedString {
        let result = NSMutableAttributedString()

        let sectionFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let shortcutFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let descFont = NSFont.systemFont(ofSize: 12)
        let sectionColor = NSColor.labelColor
        let descColor = NSColor.secondaryLabelColor
        let accentColor = NSColor.controlAccentColor

        func addSection(_ title: String) {
            let attrs: [NSAttributedString.Key: Any] = [.font: sectionFont, .foregroundColor: sectionColor]
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            result.append(NSAttributedString(string: title, attributes: attrs))
            result.append(NSAttributedString(string: "\n"))
        }

        func addShortcut(_ key: String, _ description: String) {
            let keyAttrs: [NSAttributedString.Key: Any] = [.font: shortcutFont, .foregroundColor: accentColor]
            let descAttrs: [NSAttributedString.Key: Any] = [.font: descFont, .foregroundColor: descColor]
            result.append(NSAttributedString(string: "  \(key)", attributes: keyAttrs))
            result.append(NSAttributedString(string: "  —  ", attributes: descAttrs))
            result.append(NSAttributedString(string: description, attributes: descAttrs))
            result.append(NSAttributedString(string: "\n"))
        }

        addSection("General")
        addShortcut("❖", "Gridka is a simple, yet powerful CSV viewer.")
        addShortcut("❖", "Its powers are sourced from DuckDB—a fast, feature-rich SQLite alternative.")
        
        addSection("File")
        addShortcut("⌘O", "Open file")
        addShortcut("⌘W", "Close window")
        addShortcut("⌘Q", "Quit")

        addSection("Edit")
        addShortcut("⌘C", "Copy cell value")
        addShortcut("⇧⌘C", "Copy entire row")
        addShortcut("⌥⌘C", "Copy column (visible rows)")

        addSection("Search")
        addShortcut("⌘F", "Toggle search bar")
        addShortcut("⌘G", "Find next")
        addShortcut("⇧⌘G", "Find previous")

        addSection("View")
        addShortcut("⇧⌘D", "Toggle detail pane")
        addShortcut("⌘,", "Settings")

        addSection("Table")
        addShortcut("Click header", "Sort ascending (click again: descending, again: clear)")
        addShortcut("⇧+Click header", "Add secondary sort column")
        addShortcut("Double-click divider", "Auto-fit column width")
        addShortcut("Right-click header", "Filter / hide column")
        addShortcut("Right-click cell", "Copy / filter by value")

        addSection("Navigation")
        addShortcut("Drag & drop", "Open CSV file by dragging onto window")

        return result
    }
}
