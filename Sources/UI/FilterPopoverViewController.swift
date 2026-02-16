import AppKit

/// A popover view controller for creating a column filter.
/// Shows a type-appropriate operator dropdown, value field, and Apply/Cancel buttons.
final class FilterPopoverViewController: NSViewController {

    /// Called when the user clicks Apply with a valid filter.
    var onApply: ((ColumnFilter) -> Void)?

    private let column: ColumnDescriptor

    private let operatorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let valueField = NSTextField()
    private let secondValueField = NSTextField() // For "between" operator
    private let secondValueLabel = NSTextField(labelWithString: "and")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// Maps popup menu item index to FilterOperator.
    private var operatorMapping: [Int: FilterOperator] = [:]

    init(column: ColumnDescriptor) {
        self.column = column
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 160))

        let titleLabel = NSTextField(labelWithString: "Filter: \(column.name)")
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        configureOperatorPopup()
        operatorPopup.translatesAutoresizingMaskIntoConstraints = false
        operatorPopup.target = self
        operatorPopup.action = #selector(operatorChanged)

        valueField.placeholderString = "Value"
        valueField.translatesAutoresizingMaskIntoConstraints = false

        secondValueField.placeholderString = "End value"
        secondValueField.translatesAutoresizingMaskIntoConstraints = false
        secondValueField.isHidden = true

        secondValueLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        secondValueLabel.translatesAutoresizingMaskIntoConstraints = false
        secondValueLabel.isHidden = true

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        applyButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [cancelButton, applyButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(operatorPopup)
        container.addSubview(valueField)
        container.addSubview(secondValueLabel)
        container.addSubview(secondValueField)
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            operatorPopup.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            operatorPopup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            operatorPopup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            valueField.topAnchor.constraint(equalTo: operatorPopup.bottomAnchor, constant: 8),
            valueField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            valueField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            secondValueLabel.topAnchor.constraint(equalTo: valueField.bottomAnchor, constant: 4),
            secondValueLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            secondValueField.topAnchor.constraint(equalTo: valueField.bottomAnchor, constant: 4),
            secondValueField.leadingAnchor.constraint(equalTo: secondValueLabel.trailingAnchor, constant: 4),
            secondValueField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        self.view = container
        updateFieldVisibility()
    }

    // MARK: - Operator Configuration

    private func configureOperatorPopup() {
        operatorPopup.removeAllItems()
        operatorMapping.removeAll()

        let operators = operatorsForDisplayType(column.displayType)
        for (index, op) in operators.enumerated() {
            operatorPopup.addItem(withTitle: operatorMenuLabel(op))
            operatorMapping[index] = op
        }
    }

    private func operatorsForDisplayType(_ type: DisplayType) -> [FilterOperator] {
        switch type {
        case .text, .unknown:
            return [.contains, .equals, .startsWith, .endsWith, .regex, .isEmpty, .isNotEmpty, .isNull, .isNotNull]
        case .integer, .float:
            return [.equals, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual, .between, .isNull, .isNotNull]
        case .date:
            return [.equals, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual, .between, .isNull, .isNotNull]
        case .boolean:
            return [.isTrue, .isFalse, .isNull, .isNotNull]
        }
    }

    private func operatorMenuLabel(_ op: FilterOperator) -> String {
        switch op {
        case .contains:       return "Contains"
        case .equals:         return "Equals"
        case .startsWith:     return "Starts with"
        case .endsWith:       return "Ends with"
        case .regex:          return "Regex"
        case .isEmpty:        return "Is empty"
        case .isNotEmpty:     return "Is not empty"
        case .greaterThan:    return "Greater than"
        case .lessThan:       return "Less than"
        case .greaterOrEqual: return "Greater or equal"
        case .lessOrEqual:    return "Less or equal"
        case .between:        return "Between"
        case .isNull:         return "Is null"
        case .isNotNull:      return "Is not null"
        case .isTrue:         return "Is true"
        case .isFalse:        return "Is false"
        }
    }

    private var selectedOperator: FilterOperator {
        return operatorMapping[operatorPopup.indexOfSelectedItem] ?? .contains
    }

    // MARK: - Actions

    @objc private func operatorChanged() {
        updateFieldVisibility()
    }

    @objc private func applyClicked() {
        guard let filter = buildFilter() else { return }
        onApply?(filter)
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        dismiss(nil)
    }

    // MARK: - Helpers

    private func updateFieldVisibility() {
        let op = selectedOperator
        let needsValue: Bool
        let needsSecondValue: Bool

        switch op {
        case .isEmpty, .isNotEmpty, .isNull, .isNotNull, .isTrue, .isFalse:
            needsValue = false
            needsSecondValue = false
        case .between:
            needsValue = true
            needsSecondValue = true
        default:
            needsValue = true
            needsSecondValue = false
        }

        valueField.isHidden = !needsValue
        secondValueField.isHidden = !needsSecondValue
        secondValueLabel.isHidden = !needsSecondValue

        // Adjust view height based on visible fields
        var height: CGFloat = 130
        if needsSecondValue { height += 30 }
        if !needsValue { height -= 30 }

        view.setFrameSize(NSSize(width: 280, height: height))
        preferredContentSize = NSSize(width: 280, height: height)
    }

    private func buildFilter() -> ColumnFilter? {
        let op = selectedOperator

        let value: FilterValue
        switch op {
        case .isEmpty, .isNotEmpty, .isNull, .isNotNull, .isTrue, .isFalse:
            value = .none

        case .between:
            let startText = valueField.stringValue.trimmingCharacters(in: .whitespaces)
            let endText = secondValueField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !startText.isEmpty, !endText.isEmpty else { return nil }
            value = .dateRange(startText, endText)

        default:
            let text = valueField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }

            switch column.displayType {
            case .integer, .float:
                if let num = Double(text) {
                    value = .number(num)
                } else {
                    value = .string(text)
                }
            case .date:
                value = .string(text)
            default:
                value = .string(text)
            }
        }

        return ColumnFilter(column: column.name, operator: op, value: value)
    }
}
