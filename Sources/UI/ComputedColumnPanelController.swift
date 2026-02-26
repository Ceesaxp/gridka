import AppKit

/// Floating NSPanel for defining computed columns with DuckDB SQL expressions.
/// Triggered via: toolbar 'Computed Column' button, Edit menu → 'Add Computed Column…',
/// or keyboard shortcut Opt+Cmd+F.
///
/// US-017: Dialog with expression editor and function hint chips.
final class ComputedColumnPanelController: NSWindowController, NSWindowDelegate {

    private static var shared: ComputedColumnPanelController?

    /// Called when the panel closes (via close button, Escape, or programmatic close).
    /// Used to sync toolbar button state.
    static var onClose: (() -> Void)?

    /// Called when user clicks 'Add Column'. Parameters: (columnName, expression).
    static var onAddColumn: ((String, String) -> Void)?

    private weak var fileSession: FileSession?
    private let existingColumnNames: Set<String>

    /// Shows the computed column panel. If already open, brings it to front.
    static func show(fileSession: FileSession) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ComputedColumnPanelController(fileSession: fileSession)
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel if open.
    static func closeIfOpen() {
        shared?.window?.close()
        shared = nil
    }

    /// Whether the panel is currently visible.
    static var isVisible: Bool {
        return shared?.window?.isVisible ?? false
    }

    /// Closes the panel if it belongs to the given file session.
    static func closeIfOwned(by session: FileSession) {
        guard let existing = shared, existing.fileSession === session else { return }
        existing.window?.close()
    }

    private init(fileSession: FileSession) {
        self.fileSession = fileSession
        self.existingColumnNames = Set(fileSession.columns.map(\.name))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.title = "Add Computed Column"
        panel.minSize = NSSize(width: 400, height: 340)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace]

        if let savedFrame = ComputedColumnPanelController.savedFrame {
            panel.setFrame(savedFrame, display: false)
        } else {
            panel.center()
        }

        super.init(window: panel)
        panel.delegate = self
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Session Frame Persistence

    private static var savedFrame: NSRect?

    // MARK: - UI Components

    private var columnNameField: NSTextField!
    private var expressionTextView: NSTextView!
    private var expressionScrollView: NSScrollView!
    private var errorLabel: NSTextField!
    private var addButton: NSButton!

    // MARK: - Function Hint Chips

    private static let functionHints: [(label: String, template: String)] = [
        ("ROUND", "ROUND(, 2)"),
        ("UPPER", "UPPER()"),
        ("LOWER", "LOWER()"),
        ("LENGTH", "LENGTH()"),
        ("YEAR", "YEAR()"),
        ("MONTH", "MONTH()"),
        ("CASE...END", "CASE WHEN  THEN  ELSE  END"),
        ("CONCAT", "CONCAT(, )"),
        ("COALESCE", "COALESCE(, )"),
        ("CAST", "CAST( AS )"),
        ("REGEXP_EXTRACT", "REGEXP_EXTRACT(, '')"),
        ("TRIM", "TRIM()"),
        ("REPLACE", "REPLACE(, '', '')"),
        ("SUBSTR", "SUBSTR(, 1, )"),
    ]

    // MARK: - Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // --- Column Name ---
        let nameLabel = NSTextField(labelWithString: "Column Name:")
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        columnNameField = NSTextField()
        columnNameField.translatesAutoresizingMaskIntoConstraints = false
        columnNameField.placeholderString = "computed_column"
        columnNameField.font = NSFont.systemFont(ofSize: 13)
        columnNameField.delegate = self
        contentView.addSubview(columnNameField)

        // --- Expression Label ---
        let exprLabel = NSTextField(labelWithString: "Expression (DuckDB SQL):")
        exprLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        exprLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(exprLabel)

        // --- Expression Text View (multi-line, monospace) ---
        expressionTextView = NSTextView()
        expressionTextView.isRichText = false
        expressionTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        expressionTextView.isAutomaticQuoteSubstitutionEnabled = false
        expressionTextView.isAutomaticDashSubstitutionEnabled = false
        expressionTextView.isAutomaticTextReplacementEnabled = false
        expressionTextView.isAutomaticSpellingCorrectionEnabled = false
        expressionTextView.delegate = self
        expressionTextView.textContainerInset = NSSize(width: 4, height: 4)

        expressionScrollView = NSScrollView()
        expressionScrollView.translatesAutoresizingMaskIntoConstraints = false
        expressionScrollView.documentView = expressionTextView
        expressionScrollView.hasVerticalScroller = true
        expressionScrollView.hasHorizontalScroller = false
        expressionScrollView.autohidesScrollers = true
        expressionScrollView.borderType = .bezelBorder
        contentView.addSubview(expressionScrollView)

        // NSTextView needs explicit width binding to wrap text
        expressionTextView.autoresizingMask = [.width]
        expressionTextView.isVerticallyResizable = true
        expressionTextView.isHorizontallyResizable = false
        expressionTextView.textContainer?.widthTracksTextView = true

        // --- Function Hint Chips ---
        let hintsLabel = NSTextField(labelWithString: "Insert function:")
        hintsLabel.font = NSFont.systemFont(ofSize: 11)
        hintsLabel.textColor = .secondaryLabelColor
        hintsLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hintsLabel)

        let chipsContainer = makeChipsView()
        chipsContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(chipsContainer)

        // --- Error Label ---
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .systemRed
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        errorLabel.preferredMaxLayoutWidth = 460
        contentView.addSubview(errorLabel)

        // --- Buttons ---
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        contentView.addSubview(cancelButton)

        addButton = NSButton(title: "Add Column", target: self, action: #selector(addColumnClicked))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.keyEquivalent = "\r" // Enter
        addButton.isEnabled = false
        contentView.addSubview(addButton)

        // --- Layout ---
        NSLayoutConstraint.activate([
            // Column Name
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

            columnNameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            columnNameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            columnNameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            columnNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            // Expression label
            exprLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            exprLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),

            // Expression text view
            expressionScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            expressionScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            expressionScrollView.topAnchor.constraint(equalTo: exprLabel.bottomAnchor, constant: 6),
            expressionScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            // Hints label
            hintsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hintsLabel.topAnchor.constraint(equalTo: expressionScrollView.bottomAnchor, constant: 12),

            // Chips
            chipsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            chipsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chipsContainer.topAnchor.constraint(equalTo: hintsLabel.bottomAnchor, constant: 4),

            // Error label
            errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            errorLabel.topAnchor.constraint(equalTo: chipsContainer.bottomAnchor, constant: 8),

            // Buttons
            addButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            addButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            cancelButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            // Expression scroll view stretches to fill available space
            expressionScrollView.bottomAnchor.constraint(lessThanOrEqualTo: hintsLabel.topAnchor, constant: -12),
        ])

        // Make the expression area expand when window resizes
        let exprExpandConstraint = expressionScrollView.heightAnchor.constraint(equalToConstant: 120)
        exprExpandConstraint.priority = .defaultLow
        exprExpandConstraint.isActive = true
    }

    /// Creates a flow-layout container with function hint chip buttons.
    private func makeChipsView() -> NSView {
        // Use multiple NSStackViews (rows) to simulate flow layout
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        var currentRow = NSStackView()
        currentRow.orientation = .horizontal
        currentRow.spacing = 4

        // Approximate flow layout: start a new row after ~480px worth of buttons
        var rowWidth: CGFloat = 0
        let maxRowWidth: CGFloat = 480

        for (index, hint) in Self.functionHints.enumerated() {
            let btn = NSButton(title: hint.label, target: self, action: #selector(chipClicked(_:)))
            btn.bezelStyle = .inline
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            btn.tag = index
            btn.controlSize = .small

            let estimatedWidth = CGFloat(hint.label.count) * 7 + 16
            if rowWidth + estimatedWidth > maxRowWidth && rowWidth > 0 {
                container.addArrangedSubview(currentRow)
                currentRow = NSStackView()
                currentRow.orientation = .horizontal
                currentRow.spacing = 4
                rowWidth = 0
            }

            currentRow.addArrangedSubview(btn)
            rowWidth += estimatedWidth + 4
        }

        if currentRow.arrangedSubviews.count > 0 {
            container.addArrangedSubview(currentRow)
        }

        return container
    }

    // MARK: - Actions

    @objc private func chipClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < Self.functionHints.count else { return }
        let template = Self.functionHints[index].template

        // Insert template at the current cursor position in the expression text view
        let selectedRange = expressionTextView.selectedRange()
        expressionTextView.insertText(template, replacementRange: selectedRange)

        // Try to position cursor inside the first pair of parentheses
        if let openParen = template.firstIndex(of: "(") {
            let offset = template.distance(from: template.startIndex, to: openParen) + 1
            let insertionPoint = selectedRange.location + offset
            let textLength = (expressionTextView.string as NSString).length
            if insertionPoint <= textLength {
                expressionTextView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
            }
        }

        window?.makeFirstResponder(expressionTextView)
        updateAddButtonState()
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func addColumnClicked() {
        let name = columnNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let expression = expressionTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard validateInput(name: name, expression: expression) else { return }

        window?.close()
        ComputedColumnPanelController.onAddColumn?(name, expression)
    }

    // MARK: - Validation

    private func validateInput(name: String, expression: String) -> Bool {
        if name.isEmpty {
            showError("Column name cannot be empty")
            return false
        }
        if existingColumnNames.contains(name) {
            showError("A column named \"\(name)\" already exists")
            return false
        }
        if expression.isEmpty {
            showError("Expression cannot be empty")
            return false
        }
        hideError()
        return true
    }

    private func updateAddButtonState() {
        let name = columnNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let expression = expressionTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        addButton.isEnabled = !name.isEmpty && !expression.isEmpty
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func hideError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame {
            ComputedColumnPanelController.savedFrame = frame
        }
        ComputedColumnPanelController.shared = nil
        ComputedColumnPanelController.onClose?()
    }

    func windowDidMove(_ notification: Notification) {
        if let frame = window?.frame {
            ComputedColumnPanelController.savedFrame = frame
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let frame = window?.frame {
            ComputedColumnPanelController.savedFrame = frame
        }
    }
}

// MARK: - NSTextFieldDelegate (Column Name)

extension ComputedColumnPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let name = columnNameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && existingColumnNames.contains(name) {
            showError("A column named \"\(name)\" already exists")
        } else {
            hideError()
        }
        updateAddButtonState()
    }
}

// MARK: - NSTextViewDelegate (Expression)

extension ComputedColumnPanelController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        hideError()
        updateAddButtonState()
    }
}
