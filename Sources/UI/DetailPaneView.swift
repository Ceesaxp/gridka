import AppKit

/// Shows the full content of a selected cell with column metadata.
/// Appears as a pane below the table view within an NSSplitView.
final class DetailPaneView: NSView {

    // MARK: - Properties

    private let columnNameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    private let dataTypeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    private let charCountLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let valueTextView: NSTextView = {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        return textView
    }()

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.drawsBackground = false
        return sv
    }()

    private let separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }()

    private let emptyLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Click a cell to inspect")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
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
        // Frame is managed by NSSplitView.
        scrollView.documentView = valueTextView

        addSubview(separator)
        addSubview(columnNameLabel)
        addSubview(dataTypeLabel)
        addSubview(charCountLabel)
        addSubview(scrollView)
        addSubview(emptyLabel)

        let inset: CGFloat = 8

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),

            columnNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            columnNameLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),

            dataTypeLabel.leadingAnchor.constraint(equalTo: columnNameLabel.trailingAnchor, constant: 8),
            dataTypeLabel.centerYAnchor.constraint(equalTo: columnNameLabel.centerYAnchor),

            charCountLabel.leadingAnchor.constraint(equalTo: dataTypeLabel.trailingAnchor, constant: 8),
            charCountLabel.centerYAnchor.constraint(equalTo: columnNameLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            scrollView.topAnchor.constraint(equalTo: columnNameLabel.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        showEmpty()
    }

    // MARK: - Public API

    func update(columnName: String, dataType: String, value: DuckDBValue) {
        emptyLabel.isHidden = true
        columnNameLabel.isHidden = false
        dataTypeLabel.isHidden = false
        charCountLabel.isHidden = false
        scrollView.isHidden = false

        columnNameLabel.stringValue = columnName
        dataTypeLabel.stringValue = dataType

        let valueString = value.description
        charCountLabel.stringValue = "\(valueString.count) chars"

        // Use monospace font for long text, URLs, and JSON-like content
        let useMonospace = valueString.count > 100
            || valueString.hasPrefix("{")
            || valueString.hasPrefix("[")
            || valueString.hasPrefix("http://")
            || valueString.hasPrefix("https://")

        if case .null = value {
            valueTextView.textColor = .tertiaryLabelColor
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            valueTextView.font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            charCountLabel.stringValue = ""
        } else {
            valueTextView.textColor = .labelColor
            if useMonospace {
                valueTextView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            } else {
                valueTextView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            }
        }

        valueTextView.string = valueString
        valueTextView.scrollToBeginningOfDocument(nil)
    }

    func showEmpty() {
        emptyLabel.isHidden = false
        columnNameLabel.isHidden = true
        dataTypeLabel.isHidden = true
        charCountLabel.isHidden = true
        scrollView.isHidden = true
    }
}
