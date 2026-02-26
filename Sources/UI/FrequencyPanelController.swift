import AppKit

/// Floating NSPanel that displays the value frequency table for a column.
/// Triggered via: column header context menu → 'Value Frequency…', toolbar Frequency button,
/// or profiler sidebar 'Show full frequency →' link.
///
/// US-010: Container panel. US-011: Sortable frequency table with inline bars and bin toggle.
final class FrequencyPanelController: NSWindowController, NSWindowDelegate {

    private static var shared: FrequencyPanelController?

    /// Called when the panel closes (via close button, Escape, or programmatic close).
    /// Used to sync toolbar button state.
    static var onClose: (() -> Void)?

    /// Called when user clicks a value row (single-click). Parameter: value string.
    static var onValueClicked: ((String, String) -> Void)?

    /// Called when user double-clicks a value row (filter + close). Parameter: (column, value).
    static var onValueDoubleClicked: ((String, String) -> Void)?

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
        controller.loadFrequencyData()
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

    /// Closes the panel if it belongs to the given file session.
    /// Call when a tab/window closes to avoid orphaned panels.
    static func closeIfOwned(by session: FileSession) {
        guard let existing = shared, existing.fileSession === session else { return }
        existing.window?.close()
    }

    private init(column: String, fileSession: FileSession) {
        self.columnName = column
        self.fileSession = fileSession

        // Determine if column is numeric for bin toggle
        if let desc = fileSession.columns.first(where: { $0.name == column }) {
            self.isNumericColumn = desc.displayType == .integer || desc.displayType == .float
        } else {
            self.isNumericColumn = false
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
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

    // MARK: - Data

    /// All frequency rows from the query (unsorted source of truth).
    private var allRows: [FrequencyRow] = []
    /// Currently displayed rows (sorted view of allRows).
    private var displayRows: [FrequencyRow] = []
    /// Current sort: column identifier and ascending flag.
    private var sortColumn: String = "cnt"
    private var sortAscending: Bool = false
    /// Whether the column is numeric (eligible for bin toggle).
    private let isNumericColumn: Bool
    /// Whether bin mode is active.
    private var isBinned: Bool = false
    /// Cached max count across all rows (computed once per data load, not per cell render).
    private var cachedMaxCount: Int = 1

    private struct FrequencyRow {
        let rank: Int
        let value: String
        let count: Int
        let percentage: Double
    }

    // MARK: - UI Components

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var binToggle: NSButton?
    private var spinner: NSProgressIndicator!

    private let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // --- Top toolbar area (status + bin toggle) ---
        let toolbarHeight: CGFloat = 28
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbar)

        statusLabel = NSTextField(labelWithString: "Loading…")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(statusLabel)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(spinner)
        spinner.startAnimation(nil)

        // Bin toggle (only for numeric columns)
        if isNumericColumn {
            let toggle = NSButton(checkboxWithTitle: "Bin values", target: self, action: #selector(binToggleChanged))
            toggle.font = NSFont.systemFont(ofSize: 11)
            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.state = .off
            toggle.isHidden = true  // Shown after data loads if >50 distinct values
            toolbar.addSubview(toggle)
            binToggle = toggle
            NSLayoutConstraint.activate([
                toggle.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
                toggle.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            ])
        }

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
            statusLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 6),
            spinner.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        // --- Table View ---
        tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableRowClicked)
        tableView.doubleAction = #selector(tableRowDoubleClicked)

        // Create columns: #, Value, Count, %
        let rankCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rank"))
        rankCol.title = "#"
        rankCol.width = 40
        rankCol.minWidth = 30
        rankCol.maxWidth = 60
        rankCol.headerCell.alignment = .right
        rankCol.sortDescriptorPrototype = NSSortDescriptor(key: "rank", ascending: true)
        tableView.addTableColumn(rankCol)

        let valueCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueCol.title = "Value"
        valueCol.width = 180
        valueCol.minWidth = 80
        valueCol.sortDescriptorPrototype = NSSortDescriptor(key: "value", ascending: true)
        tableView.addTableColumn(valueCol)

        let countCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cnt"))
        countCol.title = "Count"
        countCol.width = 100
        countCol.minWidth = 60
        countCol.headerCell.alignment = .right
        countCol.sortDescriptorPrototype = NSSortDescriptor(key: "cnt", ascending: false)
        tableView.addTableColumn(countCol)

        let pctCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pct"))
        pctCol.title = "%"
        pctCol.width = 120
        pctCol.minWidth = 70
        pctCol.headerCell.alignment = .right
        pctCol.sortDescriptorPrototype = NSSortDescriptor(key: "pct", ascending: false)
        tableView.addTableColumn(pctCol)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Set initial sort indicator
        updateSortIndicators()
    }

    // MARK: - Data Loading

    private func loadFrequencyData() {
        guard let session = fileSession else { return }

        statusLabel.stringValue = "Loading…"
        spinner.startAnimation(nil)

        if isBinned {
            session.fetchBinnedFrequency(columnName: columnName) { [weak self] result in
                self?.handleFrequencyResult(result)
            }
        } else {
            session.fetchFullFrequency(columnName: columnName) { [weak self] result in
                self?.handleFrequencyResult(result)
            }
        }
    }

    private func handleFrequencyResult(_ result: Result<FileSession.FrequencyData, Error>) {
        spinner.stopAnimation(nil)

        switch result {
        case .success(let data):
            allRows = data.rows.enumerated().map { (i, row) in
                FrequencyRow(rank: i + 1, value: row.value, count: row.count, percentage: row.percentage)
            }
            cachedMaxCount = allRows.map(\.count).max() ?? 1
            sortAndReload()
            let groupLabel = isBinned ? "bins" : "distinct values"
            statusLabel.stringValue = "\(allRows.count) \(groupLabel)"
            // Show bin toggle only for numeric columns with >50 distinct values
            if isNumericColumn && !isBinned {
                binToggle?.isHidden = allRows.count <= 50
            }
        case .failure(let error):
            allRows = []
            displayRows = []
            tableView.reloadData()
            statusLabel.stringValue = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Sorting

    private func sortAndReload() {
        let asc = sortAscending
        let col = sortColumn
        displayRows = allRows.sorted { a, b in
            switch col {
            case "rank":
                return asc ? a.rank < b.rank : a.rank > b.rank
            case "value":
                let cmp = a.value.localizedCaseInsensitiveCompare(b.value)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            case "cnt":
                return asc ? a.count < b.count : a.count > b.count
            case "pct":
                return asc ? a.percentage < b.percentage : a.percentage > b.percentage
            default:
                return asc ? a.count < b.count : a.count > b.count
            }
        }
        tableView.reloadData()
    }

    private func updateSortIndicators() {
        for col in tableView.tableColumns {
            let id = col.identifier.rawValue
            if id == sortColumn {
                let indicator = sortAscending ? NSImage(named: "NSAscendingSortIndicator") : NSImage(named: "NSDescendingSortIndicator")
                tableView.setIndicatorImage(indicator, in: col)
                tableView.highlightedTableColumn = col
            } else {
                tableView.setIndicatorImage(nil, in: col)
            }
        }
    }

    // MARK: - Actions

    @objc private func binToggleChanged() {
        isBinned = binToggle?.state == .on
        loadFrequencyData()
    }

    @objc private func tableRowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < displayRows.count, !isBinned else { return }
        let value = displayRows[row].value
        FrequencyPanelController.onValueClicked?(columnName, value)
    }

    @objc private func tableRowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < displayRows.count, !isBinned else { return }
        let value = displayRows[row].value
        FrequencyPanelController.onValueDoubleClicked?(columnName, value)
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

// MARK: - NSTableViewDataSource

extension FrequencyPanelController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        if key == sortColumn {
            sortAscending = descriptor.ascending
        } else {
            sortColumn = key
            sortAscending = descriptor.ascending
        }
        updateSortIndicators()
        sortAndReload()
    }
}

// MARK: - NSTableViewDelegate

extension FrequencyPanelController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn, row < displayRows.count else { return nil }
        let id = tableColumn.identifier
        let freqRow = displayRows[row]

        switch id.rawValue {
        case "rank":
            let cell = reuseOrCreateTextField(tableView: tableView, id: id)
            cell.stringValue = "\(freqRow.rank)"
            cell.alignment = .right
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textColor = .secondaryLabelColor
            return cell

        case "value":
            let cell = reuseOrCreateTextField(tableView: tableView, id: id)
            cell.stringValue = freqRow.value
            cell.alignment = .left
            cell.font = NSFont.systemFont(ofSize: 11)
            cell.textColor = .labelColor
            cell.lineBreakMode = .byTruncatingTail
            cell.toolTip = freqRow.value
            return cell

        case "cnt":
            let cell = reuseOrCreateBarCell(tableView: tableView, id: id)
            cell.configure(
                count: freqRow.count,
                maxCount: cachedMaxCount,
                formattedCount: countFormatter.string(from: NSNumber(value: freqRow.count)) ?? "\(freqRow.count)"
            )
            return cell

        case "pct":
            let cell = reuseOrCreateTextField(tableView: tableView, id: id)
            cell.stringValue = String(format: "%.1f%%", freqRow.percentage)
            cell.alignment = .right
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textColor = .labelColor
            return cell

        default:
            return nil
        }
    }

    private func reuseOrCreateTextField(tableView: NSTableView, id: NSUserInterfaceItemIdentifier) -> NSTextField {
        if let existing = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            return existing
        }
        let tf = NSTextField()
        tf.identifier = id
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = false
        tf.isSelectable = false
        tf.cell?.truncatesLastVisibleLine = true
        tf.cell?.lineBreakMode = .byTruncatingTail
        return tf
    }

    private func reuseOrCreateBarCell(tableView: NSTableView, id: NSUserInterfaceItemIdentifier) -> FrequencyBarCellView {
        let barId = NSUserInterfaceItemIdentifier(id.rawValue + "_bar")
        if let existing = tableView.makeView(withIdentifier: barId, owner: self) as? FrequencyBarCellView {
            return existing
        }
        let cell = FrequencyBarCellView()
        cell.identifier = barId
        return cell
    }
}

// MARK: - FrequencyBarCellView

/// Custom cell view that shows a colored inline percentage bar with a count label overlay.
private final class FrequencyBarCellView: NSView {

    override var isFlipped: Bool { true }

    private let barLayer = CALayer()
    private let countLabel: NSTextField = {
        let tf = NSTextField()
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = false
        tf.isSelectable = false
        tf.alignment = .right
        tf.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        tf.textColor = .labelColor
        tf.cell?.truncatesLastVisibleLine = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(barLayer)
        barLayer.cornerRadius = 2
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(count: Int, maxCount: Int, formattedCount: String) {
        countLabel.stringValue = formattedCount
        let proportion = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
        barProportion = proportion
        needsLayout = true
    }

    private var barProportion: CGFloat = 0

    override func layout() {
        super.layout()
        let h = bounds.height
        let barH: CGFloat = max(h - 6, 8)
        let barY: CGFloat = (h - barH) / 2
        let barW = max(bounds.width * barProportion, 0)
        barLayer.frame = CGRect(x: 0, y: barY, width: barW, height: barH)
        barLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
    }
}
