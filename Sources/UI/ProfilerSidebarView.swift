import AppKit

/// Right sidebar showing column profiler information.
/// Displays column type, stats, distribution, and top values for the selected column.
/// Content sections are stacked vertically in a scrollable view.
final class ProfilerSidebarView: NSView {

    // MARK: - Properties

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        return sv
    }()

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }()

    /// Placeholder label shown when no column is selected.
    private let placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Click a column header to inspect")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// Column name header label.
    private let columnNameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }()

    /// Column type badge.
    private let typeBadge: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        return label
    }()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        addSubview(separator)
        addSubview(scrollView)
        addSubview(placeholderLabel)

        scrollView.documentView = stackView

        // Use flipped document view so content starts at the top
        let flipper = FlippedClipView()
        flipper.documentView = stackView
        flipper.drawsBackground = false
        scrollView.contentView = flipper

        // Separator on the left edge
        separator.frame = .zero
        separator.autoresizingMask = [.height]

        // Build the header row: column name + type badge
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .firstBaseline
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(columnNameLabel)
        headerRow.addArrangedSubview(typeBadge)

        stackView.addArrangedSubview(headerRow)

        showPlaceholder()
    }

    override func layout() {
        super.layout()
        let b = bounds
        separator.frame = NSRect(x: 0, y: 0, width: 1, height: b.height)
        scrollView.frame = NSRect(x: 1, y: 0, width: max(0, b.width - 1), height: b.height)

        // Pin stackView width to scrollView content width so sections expand horizontally
        if let docWidth = scrollView.contentView.documentVisibleRect.width as CGFloat? {
            stackView.frame.size.width = max(docWidth, 0)
        }

        placeholderLabel.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height)
    }

    // MARK: - Public API

    /// Updates the sidebar to show profiler info for the given column.
    func showColumn(name: String, typeName: String) {
        placeholderLabel.isHidden = true
        scrollView.isHidden = false

        columnNameLabel.stringValue = name
        typeBadge.stringValue = "  \(typeName)  "
        typeBadge.textColor = .white
        typeBadge.layer?.backgroundColor = badgeColor(for: typeName).cgColor
    }

    /// Shows the placeholder text when no column is selected.
    func showPlaceholder() {
        placeholderLabel.isHidden = false
        scrollView.isHidden = true
    }

    // MARK: - Helpers

    private func badgeColor(for typeName: String) -> NSColor {
        let upper = typeName.uppercased()
        if upper.contains("INT") { return .systemGreen }
        if upper.contains("VARCHAR") || upper.contains("TEXT") || upper.contains("CHAR") { return .systemBlue }
        if upper.contains("FLOAT") || upper.contains("DOUBLE") || upper.contains("DECIMAL") || upper.contains("NUMERIC") { return .systemOrange }
        if upper.contains("BOOL") { return .systemPurple }
        if upper.contains("DATE") || upper.contains("TIME") { return .systemRed }
        return .systemGray
    }
}

// MARK: - FlippedClipView

/// NSClipView subclass with flipped coordinate system so scroll content starts at the top.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
