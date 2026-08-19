import AppKit

/// Accessory view for NSSavePanel providing encoding and delimiter selection.
final class SavePanelAccessoryView: NSView {

    // MARK: - Encoding/Delimiter Definitions

    struct EncodingOption {
        let name: String
        let encoding: String.Encoding
    }

    struct DelimiterOption {
        let name: String
        let value: String
    }

    static let encodingOptions: [EncodingOption] = [
        EncodingOption(name: "UTF-8", encoding: .utf8),
        EncodingOption(name: "UTF-16 LE", encoding: .utf16LittleEndian),
        EncodingOption(name: "UTF-16 BE", encoding: .utf16BigEndian),
        EncodingOption(name: "Latin-1 (ISO-8859-1)", encoding: .isoLatin1),
        EncodingOption(name: "Windows-1252", encoding: .windowsCP1252),
        EncodingOption(name: "ASCII", encoding: .ascii),
        EncodingOption(name: "Shift-JIS", encoding: .shiftJIS),
        EncodingOption(name: "EUC-KR", encoding: String.Encoding(rawValue: 0x80000940)),
        EncodingOption(name: "GB2312", encoding: String.Encoding(rawValue: 0x80000930)),
        EncodingOption(name: "Big5", encoding: String.Encoding(rawValue: 0x80000A03)),
    ]

    static let delimiterOptions: [DelimiterOption] = [
        DelimiterOption(name: "Comma (,)", value: ","),
        DelimiterOption(name: "Tab (⇥)", value: "\t"),
        DelimiterOption(name: "Semicolon (;)", value: ";"),
        DelimiterOption(name: "Pipe (|)", value: "|"),
        DelimiterOption(name: "Tilde (~)", value: "~"),
    ]

    // MARK: - UI Elements

    private let encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let delimiterPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // MARK: - Properties

    var selectedEncoding: String.Encoding {
        let index = encodingPopup.indexOfSelectedItem
        guard index >= 0, index < Self.encodingOptions.count else { return .utf8 }
        return Self.encodingOptions[index].encoding
    }

    var selectedEncodingName: String {
        let index = encodingPopup.indexOfSelectedItem
        guard index >= 0, index < Self.encodingOptions.count else { return "UTF-8" }
        return Self.encodingOptions[index].name
    }

    var selectedDelimiter: String {
        let index = delimiterPopup.indexOfSelectedItem
        guard index >= 0, index < Self.delimiterOptions.count else { return "," }
        return Self.delimiterOptions[index].value
    }

    // MARK: - Init

    init(detectedEncoding: String, currentDelimiter: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 78))
        setupUI()
        selectEncoding(matching: detectedEncoding)
        selectDelimiter(matching: currentDelimiter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false

        let encodingLabel = NSTextField(labelWithString: "Encoding:")
        let delimiterLabel = NSTextField(labelWithString: "Delimiter:")
        for label in [encodingLabel, delimiterLabel] {
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            label.alignment = .right
        }

        for option in Self.encodingOptions {
            encodingPopup.addItem(withTitle: option.name)
        }

        for option in Self.delimiterOptions {
            delimiterPopup.addItem(withTitle: option.name)
        }

        // The save panel is narrow (and got narrower again in macOS 27), so the
        // popups must be able to shrink rather than force the accessory view
        // wider than the panel — a fixed-width row gets clipped.
        for popup in [encodingPopup, delimiterPopup] {
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // Preferred width, not required: wide enough for the longest title
            // but yielding to the panel's width if it is narrower still.
            let preferredWidth = popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 170)
            preferredWidth.priority = .defaultHigh
            preferredWidth.isActive = true
        }

        let grid = NSGridView(views: [
            [encodingLabel, encodingPopup],
            [delimiterLabel, delimiterPopup],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        addSubview(grid)

        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Selection Helpers

    private func selectEncoding(matching name: String) {
        // Match by name prefix to handle "UTF-8 (BOM)" → "UTF-8"
        let normalized = name.replacingOccurrences(of: " (BOM)", with: "")
        for (i, option) in Self.encodingOptions.enumerated() {
            if option.name == normalized {
                encodingPopup.selectItem(at: i)
                return
            }
        }
        // Default to UTF-8
        encodingPopup.selectItem(at: 0)
    }

    private func selectDelimiter(matching value: String) {
        for (i, option) in Self.delimiterOptions.enumerated() {
            if option.value == value {
                delimiterPopup.selectItem(at: i)
                return
            }
        }
        // Default to comma
        delimiterPopup.selectItem(at: 0)
    }
}
