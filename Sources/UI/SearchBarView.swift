import AppKit

/// Horizontal search bar with text field, match count, Previous/Next buttons, and close button.
/// Toggled via ⌘F. Debounces search input at 300ms.
final class SearchBarView: NSView {

    /// Called when the search term changes (after debounce). Empty string means search cleared.
    var onSearchChanged: ((String) -> Void)?

    /// Called when the user clicks Next (⌘G) or Previous (⇧⌘G). Parameter is +1 or -1.
    var onNavigate: ((Int) -> Void)?

    /// Called when the user dismisses the search bar (Escape or close button).
    var onDismiss: (() -> Void)?

    /// Current bar height (0 when hidden, 32 when visible). Used by container layout.
    private(set) var currentHeight: CGFloat = 0

    private let searchField: NSTextField = {
        let field = NSTextField()
        field.placeholderString = "Search…"
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        return field
    }()

    private let matchCountLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private let previousButton: NSButton = {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "Previous Match (⇧⌘G)"
        return button
    }()

    private let nextButton: NSButton = {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "Next Match (⌘G)"
        return button
    }()

    private let closeButton: NSButton = {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close search")
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentTintColor = .secondaryLabelColor
        return button
    }()

    private let separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }()

    private var debounceWorkItem: DispatchWorkItem?

    /// Current match index for next/previous navigation (0-based).
    private var currentMatchIndex: Int = 0
    private var matchRowCount: Int = 0

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
        // Frame is managed by the parent container, not Auto Layout.
        // Internal subviews use Auto Layout within this view's bounds.
        setAccessibilityIdentifier("searchBar")
        searchField.setAccessibilityIdentifier("searchField")
        searchField.delegate = self
        previousButton.target = self
        previousButton.action = #selector(previousClicked)
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        addSubview(separator)
        addSubview(searchField)
        addSubview(matchCountLabel)
        addSubview(previousButton)
        addSubview(nextButton)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),

            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            matchCountLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            matchCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            previousButton.leadingAnchor.constraint(equalTo: matchCountLabel.trailingAnchor, constant: 4),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 24),
            previousButton.heightAnchor.constraint(equalToConstant: 24),

            nextButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 24),
            nextButton.heightAnchor.constraint(equalToConstant: 24),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        clipsToBounds = true

        isHidden = true
    }

    // MARK: - Public API

    /// Shows the search bar and focuses the search field.
    func show() {
        guard isHidden else {
            // Already visible — just re-focus
            window?.makeFirstResponder(searchField)
            return
        }
        isHidden = false
        currentHeight = 32
        (superview as? GridkaContainerView)?.layoutChildren()
        window?.makeFirstResponder(searchField)
    }

    /// Hides the search bar and clears the search.
    func dismiss() {
        debounceWorkItem?.cancel()
        searchField.stringValue = ""
        matchCountLabel.stringValue = ""
        currentMatchIndex = 0
        matchRowCount = 0
        currentHeight = 0
        isHidden = true
        (superview as? GridkaContainerView)?.layoutChildren()
        onSearchChanged?("")
    }

    /// Updates the match count display.
    func updateMatchCount(_ count: Int) {
        matchRowCount = count
        currentMatchIndex = 0
        if count > 0 {
            matchCountLabel.stringValue = "\(count) rows match"
        } else if !searchField.stringValue.isEmpty {
            matchCountLabel.stringValue = "No matches"
        } else {
            matchCountLabel.stringValue = ""
        }
    }

    /// Returns the current match row index for navigation, or -1 if none.
    var isVisible: Bool {
        return !isHidden
    }

    // MARK: - Actions

    @objc private func previousClicked() {
        onNavigate?(-1)
    }

    @objc private func nextClicked() {
        onNavigate?(1)
    }

    @objc private func closeClicked() {
        dismiss()
        onDismiss?()
    }

    // MARK: - Debounce

    private func scheduleSearch() {
        debounceWorkItem?.cancel()
        let term = searchField.stringValue
        let workItem = DispatchWorkItem { [weak self] in
            self?.onSearchChanged?(term)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }
}

// MARK: - NSTextFieldDelegate

extension SearchBarView: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape key
            dismiss()
            onDismiss?()
            return true
        }
        return false
    }
}
