import AppKit

/// Floating NSPanel that displays the value frequency table for a column.
/// Triggered via: column header context menu → 'Value Frequency…', toolbar Frequency button,
/// or profiler sidebar 'Show full frequency →' link.
///
/// US-010: Container panel. US-011 adds the actual frequency table content.
final class FrequencyPanelController: NSWindowController, NSWindowDelegate {

    private static var shared: FrequencyPanelController?

    /// Called when the panel closes (via close button, Escape, or programmatic close).
    /// Used to sync toolbar button state.
    static var onClose: (() -> Void)?

    private let columnName: String
    private weak var fileSession: FileSession?

    /// Shows the frequency panel for the given column. If a panel is already showing,
    /// updates it for the new column or brings it to front if same column.
    static func show(column: String, fileSession: FileSession) {
        if let existing = shared {
            if existing.columnName == column {
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            // Different column — close old panel and open new one
            existing.window?.close()
            shared = nil
        }
        let controller = FrequencyPanelController(column: column, fileSession: fileSession)
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the frequency panel if open.
    static func closeIfOpen() {
        shared?.window?.close()
        shared = nil
    }

    /// Whether the frequency panel is currently visible.
    static var isVisible: Bool {
        return shared?.window?.isVisible ?? false
    }

    private init(column: String, fileSession: FileSession) {
        self.columnName = column
        self.fileSession = fileSession

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.title = "\(column) — Value Frequency"
        panel.minSize = NSSize(width: 300, height: 200)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace]

        // Position: restore saved or center
        if let savedFrame = FrequencyPanelController.savedFrame {
            panel.setFrame(savedFrame, display: false)
        } else {
            panel.center()
        }

        super.init(window: panel)
        panel.delegate = self
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Session Frame Persistence

    /// Frame is remembered within the app session (not persisted to disk).
    private static var savedFrame: NSRect?

    // MARK: - UI Setup

    private let placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Frequency data will appear here.")
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        contentView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Save frame for position persistence within session
        if let frame = window?.frame {
            FrequencyPanelController.savedFrame = frame
        }
        FrequencyPanelController.shared = nil
        FrequencyPanelController.onClose?()
    }

    func windowDidMove(_ notification: Notification) {
        if let frame = window?.frame {
            FrequencyPanelController.savedFrame = frame
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let frame = window?.frame {
            FrequencyPanelController.savedFrame = frame
        }
    }
}
