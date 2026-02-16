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
        addSubview(separator)
        addSubview(rowCountLabel)
        addSubview(fileSizeLabel)
        addSubview(loadTimeLabel)
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

            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
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

    func clear() {
        rowCountLabel.stringValue = ""
        fileSizeLabel.stringValue = ""
        loadTimeLabel.stringValue = ""
        progressLabel.stringValue = ""
    }
}
