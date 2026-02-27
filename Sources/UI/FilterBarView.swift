import AppKit

/// Displays active filters as removable chip views in a horizontal bar.
/// Hidden when no filters are active.
final class FilterBarView: NSView {

    /// Called when the user clicks the X button on a filter chip.
    var onFilterRemoved: ((ColumnFilter) -> Void)?

    /// Current bar height (0 when hidden, 30 when visible). Used by container layout.
    private(set) var currentHeight: CGFloat = 0

    private var filters: [ColumnFilter] = []
    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }()

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
        setAccessibilityIdentifier("filterBar")
        addSubview(separator)
        addSubview(stackView)

        // Vertical constraints use lower priority so they yield to the
        // autoresizing-mask height==0 constraint when the bar is hidden.
        let separatorBottom = separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        separatorBottom.priority = .defaultHigh
        let stackTop = stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        stackTop.priority = .defaultHigh
        let stackBottom = stackView.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -4)
        stackBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorBottom,

            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackTop,
            stackBottom,
        ])

        clipsToBounds = true
        isHidden = true
    }

    func updateFilters(_ newFilters: [ColumnFilter]) {
        filters = newFilters
        rebuildChips()

        let shouldShow = !filters.isEmpty
        currentHeight = shouldShow ? 30 : 0
        isHidden = !shouldShow
        (superview as? GridkaContainerView)?.layoutChildren()
    }

    private func rebuildChips() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for filter in filters {
            let chip = FilterChipView(filter: filter)
            chip.onRemove = { [weak self] removedFilter in
                self?.onFilterRemoved?(removedFilter)
            }
            stackView.addArrangedSubview(chip)
        }
    }
}

// MARK: - FilterChipView

private final class FilterChipView: NSView {

    var onRemove: ((ColumnFilter) -> Void)?
    private let filter: ColumnFilter

    init(filter: ColumnFilter) {
        self.filter = filter
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1

        let label = NSTextField(labelWithString: chipText())
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove filter")
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.contentTintColor = .secondaryLabelColor

        addSubview(label)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @objc private func closeClicked() {
        onRemove?(filter)
    }

    private func chipText() -> String {
        let col = filter.column
        let op = operatorLabel(filter.operator)
        let val = valueLabel(filter.value)
        let not = filter.negate ? "NOT " : ""

        switch filter.operator {
        case .isEmpty, .isNotEmpty, .isNull, .isNotNull, .isTrue, .isFalse:
            return "\(col) \(not)\(op)"
        default:
            return "\(col) \(not)\(op) \(val)"
        }
    }

    private func operatorLabel(_ op: FilterOperator) -> String {
        switch op {
        case .contains:     return "contains"
        case .equals:       return "="
        case .startsWith:   return "starts with"
        case .endsWith:     return "ends with"
        case .regex:        return "~"
        case .isEmpty:      return "is empty"
        case .isNotEmpty:   return "is not empty"
        case .greaterThan:  return ">"
        case .lessThan:     return "<"
        case .greaterOrEqual: return ">="
        case .lessOrEqual:  return "<="
        case .between:      return "between"
        case .isNull:       return "is null"
        case .isNotNull:    return "is not null"
        case .isTrue:       return "is true"
        case .isFalse:      return "is false"
        }
    }

    private func valueLabel(_ value: FilterValue) -> String {
        switch value {
        case .string(let s):        return s
        case .number(let n):
            if n == n.rounded() && !n.isInfinite {
                return String(Int64(n))
            }
            return String(n)
        case .dateRange(let a, let b): return "\(a) – \(b)"
        case .boolean(let b):       return b ? "true" : "false"
        case .none:                 return ""
        }
    }
}
