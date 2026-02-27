import AppKit

final class SettingsWindowController: NSWindowController {

    private static var shared: SettingsWindowController?

    static func showSettings() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController()
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let dateFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thousandsSeparatorCheckbox = NSButton(checkboxWithTitle: "Use thousands separator (1,234,567)", target: nil, action: nil)
    private let decimalCommaCheckbox = NSButton(checkboxWithTitle: "Use comma as decimal delimiter (1.234,56)", target: nil, action: nil)
    private let sparklineCheckbox = NSButton(checkboxWithTitle: "Show sparklines in column headers", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setupUI()
        loadSettings()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        ])

        // Date format row
        let dateRow = NSStackView()
        dateRow.orientation = .horizontal
        dateRow.spacing = 8
        let dateLabel = NSTextField(labelWithString: "Date format:")
        dateLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for style in DateFormatStyle.allCases {
            dateFormatPopup.addItem(withTitle: style.displayName)
        }
        dateFormatPopup.target = self
        dateFormatPopup.action = #selector(dateFormatChanged(_:))
        dateRow.addArrangedSubview(dateLabel)
        dateRow.addArrangedSubview(dateFormatPopup)
        stack.addArrangedSubview(dateRow)

        // Thousands separator
        thousandsSeparatorCheckbox.target = self
        thousandsSeparatorCheckbox.action = #selector(thousandsSeparatorChanged(_:))
        stack.addArrangedSubview(thousandsSeparatorCheckbox)

        // Decimal comma
        decimalCommaCheckbox.target = self
        decimalCommaCheckbox.action = #selector(decimalCommaChanged(_:))
        stack.addArrangedSubview(decimalCommaCheckbox)

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Sparklines
        sparklineCheckbox.target = self
        sparklineCheckbox.action = #selector(sparklineChanged(_:))
        stack.addArrangedSubview(sparklineCheckbox)
    }

    private func loadSettings() {
        let settings = SettingsManager.shared

        let dateIndex = DateFormatStyle.allCases.firstIndex(of: settings.dateFormat) ?? 0
        dateFormatPopup.selectItem(at: dateIndex)

        thousandsSeparatorCheckbox.state = settings.useThousandsSeparator ? .on : .off
        decimalCommaCheckbox.state = settings.useDecimalComma ? .on : .off
        sparklineCheckbox.state = settings.showSparklines ? .on : .off
    }

    @objc private func dateFormatChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < DateFormatStyle.allCases.count else { return }
        SettingsManager.shared.dateFormat = DateFormatStyle.allCases[index]
    }

    @objc private func thousandsSeparatorChanged(_ sender: NSButton) {
        SettingsManager.shared.useThousandsSeparator = (sender.state == .on)
        // Refresh the other checkbox (mutual exclusivity)
        decimalCommaCheckbox.state = SettingsManager.shared.useDecimalComma ? .on : .off
    }

    @objc private func decimalCommaChanged(_ sender: NSButton) {
        SettingsManager.shared.useDecimalComma = (sender.state == .on)
        // Refresh the other checkbox (mutual exclusivity)
        thousandsSeparatorCheckbox.state = SettingsManager.shared.useThousandsSeparator ? .on : .off
    }

    @objc private func sparklineChanged(_ sender: NSButton) {
        SettingsManager.shared.showSparklines = (sender.state == .on)
    }
}
