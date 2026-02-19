import AppKit

/// Popover for renaming a column. Shows a text field pre-filled with the current
/// column name and an inline error message when the name is invalid.
final class RenameColumnPopoverController: NSViewController, NSTextFieldDelegate {

    /// Callback invoked with the new column name when the user confirms.
    var onRename: ((String) -> Void)?

    /// Weak reference to the popover so we can dismiss it on confirm.
    weak var popover: NSPopover?

    private let currentName: String
    private let existingNames: [String]

    private var nameField: NSTextField!
    private var errorLabel: NSTextField!
    private var renameButton: NSButton!

    init(currentName: String, existingNames: [String]) {
        self.currentName = currentName
        self.existingNames = existingNames
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 90))

        let label = NSTextField(labelWithString: "New name:")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false

        nameField = NSTextField()
        nameField.stringValue = currentName
        nameField.placeholderString = "Column name"
        nameField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.delegate = self

        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        renameButton = NSButton(title: "Rename", target: self, action: #selector(renameClicked(_:)))
        renameButton.bezelStyle = .rounded
        renameButton.keyEquivalent = "\r"
        renameButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(nameField)
        container.addSubview(errorLabel)
        container.addSubview(renameButton)
        container.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            nameField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),

            errorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            errorLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),

            renameButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            renameButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            cancelButton.trailingAnchor.constraint(equalTo: renameButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        self.view = container
        self.preferredContentSize = NSSize(width: 260, height: 90)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Select all text for easy replacement
        nameField.selectText(nil)
        view.window?.makeFirstResponder(nameField)
    }

    // MARK: - Validation

    private func validate() -> Bool {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)

        if name.isEmpty {
            showError("Column name cannot be empty")
            return false
        }

        // Check for duplicates (case-sensitive, excluding the current name)
        if name != currentName && existingNames.contains(where: { $0 == name }) {
            showError("A column named \"\(name)\" already exists")
            return false
        }

        hideError()
        return true
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        renameButton.isEnabled = false
        preferredContentSize = NSSize(width: 260, height: 108)
    }

    private func hideError() {
        errorLabel.isHidden = true
        renameButton.isEnabled = true
        preferredContentSize = NSSize(width: 260, height: 90)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        _ = validate()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            popover?.performClose(nil)
            return true
        }
        return false
    }

    // MARK: - Actions

    @objc private func renameClicked(_ sender: Any?) {
        guard validate() else { return }
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)

        // No-op if the name hasn't changed
        guard newName != currentName else {
            popover?.performClose(nil)
            return
        }

        popover?.performClose(nil)
        onRename?(newName)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        popover?.performClose(nil)
    }
}
