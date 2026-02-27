import AppKit

/// Horizontal toolbar row with toggle buttons for analysis features:
/// Profiler, Frequency, Group By, Computed Column.
/// Frame is managed by the parent container (GridkaContainerView), not Auto Layout.
/// Internal subviews use Auto Layout within this view's bounds.
final class AnalysisToolbarView: NSView {

    /// Called when an analysis button is toggled. Parameter is the feature identifier.
    var onFeatureToggled: ((AnalysisFeature, Bool) -> Void)?

    /// Current bar height (0 when hidden, 36 when visible). Used by container layout.
    private(set) var currentHeight: CGFloat = 0

    /// The active (pressed) state of each feature button.
    private var featureStates: [AnalysisFeature: Bool] = [
        .profiler: false,
        .frequency: false,
        .groupBy: false,
        .computedColumn: false,
    ]

    private var buttons: [AnalysisFeature: NSButton] = [:]

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
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
        addSubview(separator)
        addSubview(stackView)

        let separatorBottom = separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        separatorBottom.priority = .defaultHigh
        let stackCenterY = stackView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1)
        stackCenterY.priority = .defaultHigh

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorBottom,

            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackCenterY,
        ])

        // Create toggle buttons for each feature
        for feature in AnalysisFeature.allCases {
            let button = makeToggleButton(for: feature)
            buttons[feature] = button
            stackView.addArrangedSubview(button)
        }

        clipsToBounds = true
        isHidden = true
    }

    private func makeToggleButton(for feature: AnalysisFeature) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .toolbar
        button.setButtonType(.toggle)
        button.isBordered = true
        button.title = feature.label
        button.image = NSImage(systemSymbolName: feature.iconName, accessibilityDescription: feature.label)
        button.imagePosition = .imageLeading
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        button.tag = feature.rawValue
        button.target = self
        button.action = #selector(buttonToggled(_:))
        button.state = .off

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 24),
        ])

        return button
    }

    @objc private func buttonToggled(_ sender: NSButton) {
        guard let feature = AnalysisFeature(rawValue: sender.tag) else { return }
        let isOn = sender.state == .on
        featureStates[feature] = isOn
        onFeatureToggled?(feature, isOn)
    }

    /// Shows or hides the toolbar, triggering a parent relayout.
    func setVisible(_ visible: Bool) {
        currentHeight = visible ? 36 : 0
        isHidden = !visible
        (superview as? GridkaContainerView)?.layoutChildren()
    }

    /// Returns whether the toolbar is currently visible.
    var isToolbarVisible: Bool {
        return !isHidden
    }

    /// Returns the active state of a feature button.
    func isFeatureActive(_ feature: AnalysisFeature) -> Bool {
        return featureStates[feature] ?? false
    }

    /// Programmatically sets a feature button's state without triggering the callback.
    func setFeatureActive(_ feature: AnalysisFeature, active: Bool) {
        featureStates[feature] = active
        buttons[feature]?.state = active ? .on : .off
    }
}

// MARK: - AnalysisFeature

enum AnalysisFeature: Int, CaseIterable {
    case profiler = 0
    case frequency = 1
    case groupBy = 2
    case computedColumn = 3

    var label: String {
        switch self {
        case .profiler:       return "Profiler"
        case .frequency:      return "Frequency"
        case .groupBy:        return "Group By"
        case .computedColumn: return "Computed Column"
        }
    }

    var iconName: String {
        switch self {
        case .profiler:       return "chart.bar"
        case .frequency:      return "list.number"
        case .groupBy:        return "rectangle.3.group"
        case .computedColumn: return "function"
        }
    }
}
