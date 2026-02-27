import AppKit

/// Aggregation function applied to a column in the Group By builder.
enum AggregationFunction: String, CaseIterable {
    case count = "COUNT"
    case sum = "SUM"
    case avg = "AVG"
    case min = "MIN"
    case max = "MAX"
    case median = "MEDIAN"

    var label: String { rawValue }
}

/// Represents one aggregation entry: a column with a chosen function.
struct AggregationEntry: Equatable {
    let columnName: String
    var function: AggregationFunction
}

/// The complete Group By configuration passed out when user clicks 'Open as New Tab'.
struct GroupByDefinition {
    let groupByColumns: [String]
    let aggregations: [AggregationEntry]
}

/// Floating NSPanel for building Group By aggregation queries visually.
/// Three areas: Available Columns (left list), Group By zone (top-right), Aggregations zone (bottom-right).
/// Triggered via: toolbar 'Group By' button, Edit menu → 'Group By…', or Opt+Cmd+G.
///
/// US-021: Group By builder dialog with column zones.
final class GroupByPanelController: NSWindowController, NSWindowDelegate {

    private static var shared: GroupByPanelController?

    /// Called when the panel closes (via close button, Escape, or programmatic close).
    static var onClose: (() -> Void)?

    /// Called when user clicks 'Open as New Tab'. Parameters: (definition, fileSession).
    static var onOpenAsNewTab: ((GroupByDefinition, FileSession) -> Void)?

    private weak var fileSession: FileSession?

    // MARK: - Singleton

    static func show(fileSession: FileSession) {
        if let existing = shared {
            if existing.fileSession === fileSession {
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            existing.window?.close()
            shared = nil
        }
        let controller = GroupByPanelController(fileSession: fileSession)
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static func closeIfOpen() {
        shared?.window?.close()
        shared = nil
    }

    static var isVisible: Bool {
        return shared?.window?.isVisible ?? false
    }

    static func closeIfOwned(by session: FileSession) {
        guard let existing = shared, existing.fileSession === session else { return }
        existing.window?.close()
    }

    // MARK: - Session Frame Persistence

    private static var savedFrame: NSRect?

    // MARK: - Data Model

    /// All columns from the file session (excluding _gridka_rowid).
    private var availableColumns: [ColumnDescriptor] = []
    /// Column names currently in the Group By zone.
    private var groupByColumns: [String] = []
    /// Aggregation entries (column + function) in the Aggregations zone.
    private var aggregations: [AggregationEntry] = []
    /// Tracks a column freshly added by single-click, so double-click can undo only that.
    private var pendingSingleClickAdd: (column: String, wasGroupBy: Bool)?

    // MARK: - UI Components

    private var columnsTableView: NSTableView!
    private var groupByStack: NSStackView!
    private var aggregationsStack: NSStackView!
    private var groupByPlaceholder: NSTextField!
    private var aggregationsPlaceholder: NSTextField!
    private var openButton: NSButton!

    // MARK: - Preview Components (US-022)

    private var previewTableView: NSTableView!
    private var previewScrollView: NSScrollView!
    private var previewCountLabel: NSTextField!
    private var previewSpinner: NSProgressIndicator!
    private var previewColumnNames: [String] = []
    private var previewRows: [[String]] = []
    private var previewDebounceWorkItem: DispatchWorkItem?
    private var previewGeneration: Int = 0

    // MARK: - Init

    private init(fileSession: FileSession) {
        self.fileSession = fileSession
        self.availableColumns = fileSession.columns.filter { $0.name != "_gridka_rowid" }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.title = "Group By"
        panel.minSize = NSSize(width: 500, height: 480)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace]

        if let savedFrame = GroupByPanelController.savedFrame {
            panel.setFrame(savedFrame, display: false)
        } else {
            panel.center()
        }

        super.init(window: panel)
        panel.delegate = self

        // Add COUNT(*) by default
        aggregations.append(AggregationEntry(columnName: "*", function: .count))

        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // --- Main horizontal split: Available Columns (left) | Zones (right) ---
        let mainSplit = NSStackView()
        mainSplit.orientation = .horizontal
        mainSplit.spacing = 12
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainSplit)

        // --- Left panel: Available Columns ---
        let leftPanel = makeAvailableColumnsPanel()
        leftPanel.translatesAutoresizingMaskIntoConstraints = false

        // --- Right panel: Group By + Aggregations zones ---
        let rightPanel = makeZonesPanel()
        rightPanel.translatesAutoresizingMaskIntoConstraints = false

        mainSplit.addArrangedSubview(leftPanel)
        mainSplit.addArrangedSubview(rightPanel)

        // Width distribution: left 40%, right 60%
        leftPanel.widthAnchor.constraint(equalTo: mainSplit.widthAnchor, multiplier: 0.38).isActive = true

        // --- Preview section (US-022) ---
        let previewSection = makePreviewSection()
        previewSection.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewSection)

        // --- Buttons row ---
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)

        openButton = NSButton(title: "Open as New Tab", target: self, action: #selector(openAsNewTabClicked))
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.keyEquivalent = "\r"
        openButton.isEnabled = false
        contentView.addSubview(openButton)

        // --- Layout ---
        NSLayoutConstraint.activate([
            mainSplit.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            mainSplit.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            mainSplit.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

            previewSection.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            previewSection.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            previewSection.topAnchor.constraint(equalTo: mainSplit.bottomAnchor, constant: 12),
            previewSection.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            openButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            openButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            openButton.topAnchor.constraint(equalTo: previewSection.bottomAnchor, constant: 12),

            cancelButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
        ])

        // Sync button state with the default COUNT(*) aggregation added in init
        updateOpenButtonState()

        // Trigger initial preview for the default COUNT(*) aggregation
        schedulePreviewUpdate()
    }

    // MARK: - Left Panel: Available Columns

    private func makeAvailableColumnsPanel() -> NSView {
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: "AVAILABLE COLUMNS")
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        columnsTableView = NSTableView()
        columnsTableView.style = .plain
        columnsTableView.usesAlternatingRowBackgroundColors = true
        columnsTableView.rowHeight = 24
        columnsTableView.intercellSpacing = NSSize(width: 8, height: 2)
        columnsTableView.headerView = nil
        columnsTableView.dataSource = self
        columnsTableView.delegate = self
        columnsTableView.focusRingType = .none
        columnsTableView.allowsMultipleSelection = false
        columnsTableView.target = self
        columnsTableView.action = #selector(columnClicked(_:))
        columnsTableView.doubleAction = #selector(columnDoubleClicked(_:))

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("columnName"))
        nameCol.title = "Column"
        nameCol.minWidth = 100
        columnsTableView.addTableColumn(nameCol)

        let scrollView = NSScrollView()
        scrollView.documentView = columnsTableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Hint label
        let hintLabel = NSTextField(labelWithString: "Click: default zone · Double-click: other zone")
        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -4),

            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    // MARK: - Right Panel: Group By + Aggregations Zones

    private func makeZonesPanel() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 12
        container.alignment = .leading

        // --- Group By Zone ---
        let groupBySection = makeGroupByZone()
        groupBySection.translatesAutoresizingMaskIntoConstraints = false

        // --- Aggregations Zone ---
        let aggregationsSection = makeAggregationsZone()
        aggregationsSection.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(groupBySection)
        container.addArrangedSubview(aggregationsSection)

        // Equal height distribution
        groupBySection.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        aggregationsSection.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        groupBySection.heightAnchor.constraint(equalTo: aggregationsSection.heightAnchor).isActive = true

        return container
    }

    private func makeGroupByZone() -> NSView {
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: "GROUP BY")
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = true
        container.addSubview(scrollView)

        groupByStack = NSStackView()
        groupByStack.orientation = .vertical
        groupByStack.alignment = .leading
        groupByStack.spacing = 4
        groupByStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = groupByStack
        scrollView.contentView = clipView
        groupByStack.setContentHuggingPriority(.defaultLow, for: .vertical)

        // Use a wrapper view for groupByStack to let it flow top-to-bottom
        let wrapperView = FlippedView()
        wrapperView.translatesAutoresizingMaskIntoConstraints = false
        wrapperView.addSubview(groupByStack)
        scrollView.documentView = wrapperView

        NSLayoutConstraint.activate([
            groupByStack.leadingAnchor.constraint(equalTo: wrapperView.leadingAnchor, constant: 6),
            groupByStack.trailingAnchor.constraint(equalTo: wrapperView.trailingAnchor, constant: -6),
            groupByStack.topAnchor.constraint(equalTo: wrapperView.topAnchor, constant: 6),
        ])

        // Placeholder text
        groupByPlaceholder = NSTextField(labelWithString: "Click a column to add it here")
        groupByPlaceholder.font = NSFont.systemFont(ofSize: 11)
        groupByPlaceholder.textColor = .tertiaryLabelColor
        groupByPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        wrapperView.addSubview(groupByPlaceholder)

        NSLayoutConstraint.activate([
            groupByPlaceholder.centerXAnchor.constraint(equalTo: wrapperView.centerXAnchor),
            groupByPlaceholder.topAnchor.constraint(equalTo: wrapperView.topAnchor, constant: 16),
        ])

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeAggregationsZone() -> NSView {
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: "AGGREGATIONS")
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = true
        container.addSubview(scrollView)

        aggregationsStack = NSStackView()
        aggregationsStack.orientation = .vertical
        aggregationsStack.alignment = .leading
        aggregationsStack.spacing = 4
        aggregationsStack.translatesAutoresizingMaskIntoConstraints = false

        let wrapperView = FlippedView()
        wrapperView.translatesAutoresizingMaskIntoConstraints = false
        wrapperView.addSubview(aggregationsStack)
        scrollView.documentView = wrapperView

        NSLayoutConstraint.activate([
            aggregationsStack.leadingAnchor.constraint(equalTo: wrapperView.leadingAnchor, constant: 6),
            aggregationsStack.trailingAnchor.constraint(equalTo: wrapperView.trailingAnchor, constant: -6),
            aggregationsStack.topAnchor.constraint(equalTo: wrapperView.topAnchor, constant: 6),
        ])

        // Placeholder text
        aggregationsPlaceholder = NSTextField(labelWithString: "Click a numeric column to aggregate")
        aggregationsPlaceholder.font = NSFont.systemFont(ofSize: 11)
        aggregationsPlaceholder.textColor = .tertiaryLabelColor
        aggregationsPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        wrapperView.addSubview(aggregationsPlaceholder)

        NSLayoutConstraint.activate([
            aggregationsPlaceholder.centerXAnchor.constraint(equalTo: wrapperView.centerXAnchor),
            aggregationsPlaceholder.topAnchor.constraint(equalTo: wrapperView.topAnchor, constant: 16),
        ])

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Add the default COUNT(*) pill
        refreshAggregationsPills()

        return container
    }

    // MARK: - Column Color

    private func colorForType(_ displayType: DisplayType) -> NSColor {
        switch displayType {
        case .text:    return .systemBlue
        case .integer: return .systemGreen
        case .float:   return .systemGreen
        case .date:    return .systemOrange
        case .boolean: return .systemPurple
        case .unknown: return .secondaryLabelColor
        }
    }

    /// Returns whether the column's default zone is "Group By" (categorical/date/boolean)
    /// vs "Aggregations" (numeric).
    private func isDefaultGroupByColumn(_ descriptor: ColumnDescriptor) -> Bool {
        switch descriptor.displayType {
        case .text, .date, .boolean: return true
        case .integer, .float:       return false
        case .unknown:               return true
        }
    }

    // MARK: - Actions

    @objc private func columnClicked(_ sender: Any?) {
        // NSTableView fires action before doubleAction — skip single-click
        // when a double-click is in progress to avoid adding to both zones.
        guard let event = NSApp.currentEvent, event.clickCount == 1 else { return }
        let row = columnsTableView.clickedRow
        guard row >= 0, row < availableColumns.count else { return }
        let desc = availableColumns[row]

        pendingSingleClickAdd = nil

        // Default action: categorical → Group By, numeric → Aggregations
        if isDefaultGroupByColumn(desc) {
            let countBefore = groupByColumns.count
            addToGroupBy(desc.name)
            if groupByColumns.count > countBefore {
                pendingSingleClickAdd = (desc.name, true)
            }
        } else {
            let countBefore = aggregations.count
            addToAggregations(desc.name)
            if aggregations.count > countBefore {
                pendingSingleClickAdd = (desc.name, false)
            }
        }
    }

    @objc private func columnDoubleClicked(_ sender: Any?) {
        let row = columnsTableView.clickedRow
        guard row >= 0, row < availableColumns.count else { return }
        let desc = availableColumns[row]

        // Only undo the single-click addition if it actually added something new.
        // Pre-existing entries (added earlier by the user) are preserved.
        if let pending = pendingSingleClickAdd, pending.column == desc.name {
            if pending.wasGroupBy {
                removeFromGroupBy(desc.name)
            } else {
                removeFromAggregations(columnName: desc.name)
            }
            pendingSingleClickAdd = nil
        }

        // Add to alternate zone
        if isDefaultGroupByColumn(desc) {
            addToAggregations(desc.name)
        } else {
            addToGroupBy(desc.name)
        }
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func openAsNewTabClicked() {
        guard let session = fileSession else { return }
        let definition = GroupByDefinition(
            groupByColumns: groupByColumns,
            aggregations: aggregations
        )
        window?.close()
        GroupByPanelController.onOpenAsNewTab?(definition, session)
    }

    // MARK: - Group By Zone Management

    private func addToGroupBy(_ columnName: String) {
        guard !groupByColumns.contains(columnName) else { return }
        groupByColumns.append(columnName)
        refreshGroupByPills()
        updateOpenButtonState()
        schedulePreviewUpdate()
    }

    private func removeFromGroupBy(_ columnName: String) {
        groupByColumns.removeAll { $0 == columnName }
        refreshGroupByPills()
        updateOpenButtonState()
        schedulePreviewUpdate()
    }

    private func refreshGroupByPills() {
        // Remove existing pills
        for view in groupByStack.arrangedSubviews {
            groupByStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for columnName in groupByColumns {
            let pill = makeGroupByPill(columnName: columnName)
            groupByStack.addArrangedSubview(pill)
        }

        groupByPlaceholder.isHidden = !groupByColumns.isEmpty

        // Update document view size for scrolling
        if let wrapperView = groupByStack.superview {
            let contentHeight = max(groupByStack.fittingSize.height + 12, 40)
            wrapperView.frame = NSRect(x: 0, y: 0, width: wrapperView.frame.width, height: contentHeight)
        }
    }

    private func makeGroupByPill(columnName: String) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 4

        // Find the column descriptor for color coding
        let desc = availableColumns.first { $0.name == columnName }
        let typeColor = desc.map { colorForType($0.displayType) } ?? .secondaryLabelColor
        pill.layer?.backgroundColor = typeColor.withAlphaComponent(0.12).cgColor

        // Type dot
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = typeColor.cgColor
        pill.addSubview(dot)

        // Column name label
        let label = NSTextField(labelWithString: columnName)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        // Remove button
        let removeBtn = NSButton(title: "×", target: self, action: #selector(removeGroupByPill(_:)))
        removeBtn.bezelStyle = .inline
        removeBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        removeBtn.isBordered = false
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.identifier = NSUserInterfaceItemIdentifier("groupBy_\(columnName)")
        pill.addSubview(removeBtn)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 24),

            dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: removeBtn.leadingAnchor, constant: -2),

            removeBtn.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -4),
            removeBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            removeBtn.widthAnchor.constraint(equalToConstant: 18),
        ])

        return pill
    }

    @objc private func removeGroupByPill(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("groupBy_") else { return }
        let columnName = String(id.dropFirst("groupBy_".count))
        removeFromGroupBy(columnName)
    }

    // MARK: - Aggregations Zone Management

    private func addToAggregations(_ columnName: String) {
        // Allow same column with multiple aggregations if needed, but not exact duplicates
        let defaultFunc: AggregationFunction = isNumericColumn(columnName) ? .sum : .count
        let entry = AggregationEntry(columnName: columnName, function: defaultFunc)
        guard !aggregations.contains(entry) else { return }
        aggregations.append(entry)
        refreshAggregationsPills()
        updateOpenButtonState()
        schedulePreviewUpdate()
    }

    private func removeFromAggregations(at index: Int) {
        guard index >= 0, index < aggregations.count else { return }
        aggregations.remove(at: index)
        refreshAggregationsPills()
        updateOpenButtonState()
        schedulePreviewUpdate()
    }

    /// Removes the most recently added aggregation for the given column name.
    private func removeFromAggregations(columnName: String) {
        guard let index = aggregations.lastIndex(where: { $0.columnName == columnName }) else { return }
        removeFromAggregations(at: index)
    }

    private func updateAggregationFunction(at index: Int, to function: AggregationFunction) {
        guard index >= 0, index < aggregations.count else { return }
        aggregations[index].function = function
    }

    private func isNumericColumn(_ columnName: String) -> Bool {
        guard let desc = availableColumns.first(where: { $0.name == columnName }) else { return false }
        return desc.displayType == .integer || desc.displayType == .float
    }

    private func refreshAggregationsPills() {
        for view in aggregationsStack.arrangedSubviews {
            aggregationsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, entry) in aggregations.enumerated() {
            let pill = makeAggregationPill(entry: entry, index: index)
            aggregationsStack.addArrangedSubview(pill)
        }

        aggregationsPlaceholder.isHidden = !aggregations.isEmpty

        // Update document view size for scrolling
        if let wrapperView = aggregationsStack.superview {
            let contentHeight = max(aggregationsStack.fittingSize.height + 12, 40)
            wrapperView.frame = NSRect(x: 0, y: 0, width: wrapperView.frame.width, height: contentHeight)
        }
    }

    private func makeAggregationPill(entry: AggregationEntry, index: Int) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 4

        let desc = availableColumns.first { $0.name == entry.columnName }
        let typeColor = desc.map { colorForType($0.displayType) } ?? .secondaryLabelColor
        pill.layer?.backgroundColor = typeColor.withAlphaComponent(0.12).cgColor

        // Function dropdown
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        popup.controlSize = .small
        for fn in AggregationFunction.allCases {
            popup.addItem(withTitle: fn.label)
        }
        popup.selectItem(withTitle: entry.function.label)
        popup.tag = index
        popup.target = self
        popup.action = #selector(aggregationFunctionChanged(_:))
        pill.addSubview(popup)

        // Column name label (show "*" as "all rows" for COUNT(*))
        let displayName = entry.columnName == "*" ? "(*)" : "(\(entry.columnName))"
        let label = NSTextField(labelWithString: displayName)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        // Remove button
        let removeBtn = NSButton(title: "×", target: self, action: #selector(removeAggregationPill(_:)))
        removeBtn.bezelStyle = .inline
        removeBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        removeBtn.isBordered = false
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.tag = index
        pill.addSubview(removeBtn)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 24),

            popup.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 4),
            popup.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: removeBtn.leadingAnchor, constant: -2),

            removeBtn.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -4),
            removeBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            removeBtn.widthAnchor.constraint(equalToConstant: 18),
        ])

        return pill
    }

    @objc private func aggregationFunctionChanged(_ sender: NSPopUpButton) {
        let index = sender.tag
        guard let title = sender.titleOfSelectedItem,
              let fn = AggregationFunction(rawValue: title) else { return }
        updateAggregationFunction(at: index, to: fn)
        schedulePreviewUpdate()
    }

    @objc private func removeAggregationPill(_ sender: NSButton) {
        removeFromAggregations(at: sender.tag)
    }

    // MARK: - Button State

    private func updateOpenButtonState() {
        // Need at least one aggregation (groupByColumns can be empty for overall aggregation)
        openButton.isEnabled = !aggregations.isEmpty
    }

    // MARK: - Preview Section (US-022)

    private func makePreviewSection() -> NSView {
        let container = NSView()

        // Title row: "PREVIEW" label + spinner + count label
        let titleLabel = NSTextField(labelWithString: "PREVIEW")
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        previewSpinner = NSProgressIndicator()
        previewSpinner.style = .spinning
        previewSpinner.controlSize = .small
        previewSpinner.isDisplayedWhenStopped = false
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewSpinner)

        previewCountLabel = NSTextField(labelWithString: "")
        previewCountLabel.font = NSFont.systemFont(ofSize: 10)
        previewCountLabel.textColor = .secondaryLabelColor
        previewCountLabel.alignment = .right
        previewCountLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewCountLabel)

        // Preview table
        previewTableView = NSTableView()
        previewTableView.style = .plain
        previewTableView.usesAlternatingRowBackgroundColors = true
        previewTableView.rowHeight = 20
        previewTableView.intercellSpacing = NSSize(width: 8, height: 2)
        previewTableView.focusRingType = .none
        previewTableView.allowsColumnSelection = false
        previewTableView.allowsMultipleSelection = false

        previewScrollView = NSScrollView()
        previewScrollView.documentView = previewTableView
        previewScrollView.hasVerticalScroller = true
        previewScrollView.hasHorizontalScroller = true
        previewScrollView.autohidesScrollers = true
        previewScrollView.borderType = .bezelBorder
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewScrollView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),

            previewSpinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            previewSpinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            previewCountLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewCountLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            previewScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewScrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            previewScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func schedulePreviewUpdate() {
        previewDebounceWorkItem?.cancel()
        previewGeneration += 1

        guard !aggregations.isEmpty else {
            previewColumnNames = []
            previewRows = []
            rebuildPreviewTableColumns()
            previewTableView.reloadData()
            previewCountLabel.stringValue = ""
            previewSpinner.stopAnimation(nil)
            return
        }

        previewSpinner.startAnimation(nil)

        let workItem = DispatchWorkItem { [weak self] in
            self?.executePreviewQuery()
        }
        previewDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func executePreviewQuery() {
        guard let session = fileSession else { return }
        let generation = previewGeneration

        session.fetchGroupByPreview(
            groupByColumns: groupByColumns,
            aggregations: aggregations
        ) { [weak self] result in
            guard let self = self else { return }
            guard self.previewGeneration == generation else { return }

            self.previewSpinner.stopAnimation(nil)

            switch result {
            case .success(let preview):
                self.previewColumnNames = preview.columnNames
                self.previewRows = preview.rows
                self.rebuildPreviewTableColumns()
                self.previewTableView.reloadData()
                let groupWord = preview.totalGroups == 1 ? "group" : "groups"
                self.previewCountLabel.stringValue = "\(preview.totalGroups) \(groupWord) total"

            case .failure(let error):
                self.previewColumnNames = []
                self.previewRows = []
                self.rebuildPreviewTableColumns()
                self.previewTableView.reloadData()
                self.previewCountLabel.stringValue = "Error: \(error.localizedDescription)"
            }
        }
    }

    /// Rebuilds the preview table's columns to match the current preview result.
    private func rebuildPreviewTableColumns() {
        // Remove existing columns
        while let col = previewTableView.tableColumns.last {
            previewTableView.removeTableColumn(col)
        }

        for (index, name) in previewColumnNames.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview_\(index)"))
            col.title = name
            col.minWidth = 60
            col.width = 100
            previewTableView.addTableColumn(col)
        }

        // Set data source/delegate after columns are configured
        previewTableView.dataSource = self
        previewTableView.delegate = self
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame {
            GroupByPanelController.savedFrame = frame
        }
        GroupByPanelController.shared = nil
        GroupByPanelController.onClose?()
    }

    func windowDidMove(_ notification: Notification) {
        if let frame = window?.frame {
            GroupByPanelController.savedFrame = frame
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let frame = window?.frame {
            GroupByPanelController.savedFrame = frame
        }
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate (Available Columns + Preview)

extension GroupByPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === previewTableView {
            return previewRows.count
        }
        return availableColumns.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Preview table
        if tableView === previewTableView {
            return makePreviewCell(tableView: tableView, tableColumn: tableColumn, row: row)
        }

        // Available columns table
        guard row < availableColumns.count else { return nil }
        let desc = availableColumns[row]

        let cellID = NSUserInterfaceItemIdentifier("AvailableColumnCell")
        let dotID = NSUserInterfaceItemIdentifier("dot")
        let labelID = NSUserInterfaceItemIdentifier("label")

        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) {
            // Update existing subviews
            if let dot = reused.subviews.first(where: { $0.identifier == dotID }),
               let label = reused.subviews.first(where: { $0.identifier == labelID }) as? NSTextField {
                dot.layer?.backgroundColor = colorForType(desc.displayType).cgColor
                label.stringValue = desc.name
            }
            return reused
        }

        let container = NSView()
        container.identifier = cellID

        let dot = NSView()
        dot.identifier = dotID
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = colorForType(desc.displayType).cgColor
        container.addSubview(dot)

        let label = NSTextField(labelWithString: desc.name)
        label.identifier = labelID
        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    // MARK: - Preview Cell

    private func makePreviewCell(tableView: NSTableView, tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue,
              colID.hasPrefix("preview_"),
              let colIndex = Int(colID.dropFirst("preview_".count)),
              row < previewRows.count,
              colIndex < previewRows[row].count else { return nil }

        let value = previewRows[row][colIndex]
        let cellID = NSUserInterfaceItemIdentifier("PreviewCell")

        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            reused.textField?.stringValue = value
            return reused
        }

        let cell = NSTableCellView()
        cell.identifier = cellID
        let tf = NSTextField(labelWithString: value)
        tf.font = NSFont.systemFont(ofSize: 11)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf

        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

// MARK: - FlippedView (for top-to-bottom scroll content)

/// A simple NSView with flipped coordinate system for scroll view document views.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
