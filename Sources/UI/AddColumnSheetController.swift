import AppKit

/// A sheet controller for adding a new column to the data table.
/// Shows a name field and a type popup, with inline validation.
final class AddColumnSheetController: NSViewController {

    private var nameField: NSTextField!
    private var typePopup: NSPopUpButton!
    private var errorLabel: NSTextField!
    private var addButton: NSButton!

    /// Existing column names used for duplicate validation.
    private let existingColumns: Set<String>

    /// Called when the user confirms. Parameters: (columnName, duckDBType).
    var onAdd: ((String, String) -> Void)?

    /// Display type → DuckDB SQL type mapping.
    private static let typeOptions: [(display: String, duckDB: String)] = [
        ("Text", "VARCHAR"),
        ("Integer", "BIGINT"),
        ("Float", "DOUBLE"),
        ("Date", "DATE"),
        ("Boolean", "BOOLEAN"),
    ]

    init(existingColumns: [String]) {
        self.existingColumns = Set(existingColumns)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))

        // Column name
        let nameLabel = NSTextField(labelWithString: "Column Name:")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)

        nameField = NSTextField()
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "new_column"
        nameField.delegate = self
        container.addSubview(nameField)

        // Column type
        let typeLabel = NSTextField(labelWithString: "Type:")
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(typeLabel)

        typePopup = NSPopUpButton()
        typePopup.translatesAutoresizingMaskIntoConstraints = false
        for option in Self.typeOptions {
            typePopup.addItem(withTitle: option.display)
        }
        container.addSubview(typePopup)

        // Error label
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .systemRed
        errorLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true
        container.addSubview(errorLabel)

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        container.addSubview(cancelButton)

        addButton = NSButton(title: "Add Column", target: self, action: #selector(addClicked(_:)))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.keyEquivalent = "\r" // Enter
        addButton.isEnabled = false
        container.addSubview(addButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),

            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            typeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            typeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),

            typePopup.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            typePopup.centerYAnchor.constraint(equalTo: typeLabel.centerYAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            errorLabel.topAnchor.constraint(equalTo: typePopup.bottomAnchor, constant: 8),

            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            cancelButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])

        self.view = container
    }

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(nil)
    }

    @objc private func addClicked(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard validateName(name) else { return }

        let typeIndex = typePopup.indexOfSelectedItem
        let duckDBType = Self.typeOptions[typeIndex].duckDB

        dismiss(nil)
        onAdd?(name, duckDBType)
    }

    private func validateName(_ name: String) -> Bool {
        if name.isEmpty {
            showError("Column name cannot be empty")
            return false
        }
        if existingColumns.contains(name) {
            showError("A column named \"\(name)\" already exists")
            return false
        }
        hideError()
        return true
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        addButton.isEnabled = false
    }

    private func hideError() {
        errorLabel.isHidden = true
        addButton.isEnabled = true
    }
}

// MARK: - NSTextFieldDelegate

extension AddColumnSheetController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            addButton.isEnabled = false
            hideError()
        } else if existingColumns.contains(name) {
            showError("A column named \"\(name)\" already exists")
        } else {
            hideError()
            addButton.isEnabled = true
        }
    }
}
