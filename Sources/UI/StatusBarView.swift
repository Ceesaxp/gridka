import AppKit

final class StatusBarView: NSView {

    // MARK: - Labels

    private let rowCountLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let fileSizeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let loadTimeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let cellLocationLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let delimiterLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let encodingLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let progressLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let separator: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }()

    // MARK: - Number Formatters

    private static let rowFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.usesGroupingSeparator = true
        return f
    }()

    private static let fileSizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
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
        // Frame is managed by the parent container, not Auto Layout.
        // Internal labels use Auto Layout within this view's bounds.
        setAccessibilityIdentifier("statusBar")
        rowCountLabel.setAccessibilityIdentifier("statusBarRowCount")
        addSubview(separator)
        addSubview(rowCountLabel)
        addSubview(fileSizeLabel)
        addSubview(loadTimeLabel)
        addSubview(cellLocationLabel)
        addSubview(delimiterLabel)
        addSubview(encodingLabel)
        addSubview(progressLabel)

        let inset: CGFloat = 10

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),

            rowCountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            rowCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            fileSizeLabel.leadingAnchor.constraint(equalTo: rowCountLabel.trailingAnchor, constant: 16),
            fileSizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            loadTimeLabel.leadingAnchor.constraint(equalTo: fileSizeLabel.trailingAnchor, constant: 16),
            loadTimeLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            cellLocationLabel.leadingAnchor.constraint(equalTo: loadTimeLabel.trailingAnchor, constant: 16),
            cellLocationLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            // Right side: progress | delimiter | encoding
            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            encodingLabel.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -16),
            encodingLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            delimiterLabel.trailingAnchor.constraint(equalTo: encodingLabel.leadingAnchor, constant: -16),
            delimiterLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    // MARK: - Public API

    func updateRowCount(showing: Int, total: Int) {
        let showingText = StatusBarView.rowFormatter.string(from: NSNumber(value: showing)) ?? "\(showing)"
        let totalText = StatusBarView.rowFormatter.string(from: NSNumber(value: total)) ?? "\(total)"

        if showing == total {
            rowCountLabel.stringValue = "\(totalText) rows"
        } else {
            rowCountLabel.stringValue = "showing \(showingText) of \(totalText) rows"
        }
    }

    func updateFileSize(_ bytes: Int64) {
        fileSizeLabel.stringValue = StatusBarView.fileSizeFormatter.string(fromByteCount: bytes)
    }

    func updateLoadTime(_ seconds: TimeInterval) {
        let text: String
        if seconds < 1 {
            text = String(format: "%.0f ms", seconds * 1000)
        } else {
            text = String(format: "%.1f s", seconds)
        }
        loadTimeLabel.stringValue = text
    }

    func updateProgress(_ fraction: Double) {
        if fraction >= 1.0 {
            progressLabel.stringValue = ""
        } else {
            let percent = Int(fraction * 100)
            progressLabel.stringValue = "Loading… \(percent)%"
        }
    }

    func showQueryTime(_ seconds: TimeInterval) {
        let text: String
        if seconds < 1 {
            text = String(format: "query: %.0f ms", seconds * 1000)
        } else {
            text = String(format: "query: %.1f s", seconds)
        }
        progressLabel.stringValue = text

        // Clear after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if self.progressLabel.stringValue == text {
                self.progressLabel.stringValue = ""
            }
        }
    }

    func updateCellLocation(row: Int, columnName: String) {
        let rowText = StatusBarView.rowFormatter.string(from: NSNumber(value: row + 1)) ?? "\(row + 1)"
        cellLocationLabel.stringValue = "Row \(rowText) | Col: \(columnName)"
    }

    func updateDelimiter(_ delimiter: String) {
        let readable: String
        switch delimiter {
        case ",":  readable = "Comma"
        case "\t": readable = "Tab"
        case ";":  readable = "Semicolon"
        case "|":  readable = "Pipe"
        case " ":  readable = "Space"
        default:   readable = "\"\(delimiter)\""
        }
        delimiterLabel.stringValue = readable
    }

    func updateEncoding(_ encoding: String) {
        encodingLabel.stringValue = encoding
    }

    func clear() {
        rowCountLabel.stringValue = ""
        fileSizeLabel.stringValue = ""
        loadTimeLabel.stringValue = ""
        progressLabel.stringValue = ""
        cellLocationLabel.stringValue = ""
        delimiterLabel.stringValue = ""
        encodingLabel.stringValue = ""
    }
}
