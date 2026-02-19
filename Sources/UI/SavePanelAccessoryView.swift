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
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
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
        encodingLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        encodingLabel.translatesAutoresizingMaskIntoConstraints = false

        let delimiterLabel = NSTextField(labelWithString: "Delimiter:")
        delimiterLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        delimiterLabel.translatesAutoresizingMaskIntoConstraints = false

        encodingPopup.translatesAutoresizingMaskIntoConstraints = false
        delimiterPopup.translatesAutoresizingMaskIntoConstraints = false

        for option in Self.encodingOptions {
            encodingPopup.addItem(withTitle: option.name)
        }

        for option in Self.delimiterOptions {
            delimiterPopup.addItem(withTitle: option.name)
        }

        addSubview(encodingLabel)
        addSubview(encodingPopup)
        addSubview(delimiterLabel)
        addSubview(delimiterPopup)

        NSLayoutConstraint.activate([
            // Height
            heightAnchor.constraint(equalToConstant: 60),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 400),

            // Encoding row
            encodingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            encodingLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 15),
            encodingLabel.widthAnchor.constraint(equalToConstant: 68),

            encodingPopup.leadingAnchor.constraint(equalTo: encodingLabel.trailingAnchor, constant: 4),
            encodingPopup.centerYAnchor.constraint(equalTo: encodingLabel.centerYAnchor),
            encodingPopup.widthAnchor.constraint(equalToConstant: 180),

            // Delimiter row (same line, right side)
            delimiterLabel.leadingAnchor.constraint(equalTo: encodingPopup.trailingAnchor, constant: 20),
            delimiterLabel.centerYAnchor.constraint(equalTo: encodingLabel.centerYAnchor),
            delimiterLabel.widthAnchor.constraint(equalToConstant: 68),

            delimiterPopup.leadingAnchor.constraint(equalTo: delimiterLabel.trailingAnchor, constant: 4),
            delimiterPopup.centerYAnchor.constraint(equalTo: encodingLabel.centerYAnchor),
            delimiterPopup.widthAnchor.constraint(equalToConstant: 120),
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
