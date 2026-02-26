import AppKit

final class TableViewController: NSViewController {

    // MARK: - Properties

    private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private(set) var statusBar: StatusBarView!
    private(set) var filterBar: FilterBarView!
    private(set) var searchBar: SearchBarView!
    private(set) var detailPane: DetailPaneView!
    private var splitView: NSSplitView!

    /// Called when the user changes sort via column header clicks.
    var onSortChanged: (([SortColumn]) -> Void)?

    /// Called when the user adds or removes a filter via the filter bar UI.
    var onFiltersChanged: (([ColumnFilter]) -> Void)?

    /// Called when the search term changes (debounced). Empty string means cleared.
    var onSearchChanged: ((String) -> Void)?

    var fileSession: FileSession? {
        didSet {
            tableView?.reloadData()
            if let session = fileSession {
                filterBar?.updateFilters(session.viewState.filters)
            }
        }
    }

    /// Tracks page indices currently being fetched to avoid duplicate requests.
    private var fetchingPages: Set<Int> = []

    /// Last known first visible row — used to detect scroll direction.
    private var lastVisibleRow: Int = 0

    /// Holds a strong reference to the filter popover so it isn't deallocated while visible.
    private var activePopover: NSPopover?

    /// Set of column identifiers (names) that are currently hidden.
    private var hiddenColumns: Set<String> = []

    /// Flag to position the split view divider on first layout.
    private var needsInitialDividerPosition = true

    /// All column descriptors from the last configureColumns call (including hidden ones).
    private var allColumnDescriptors: [ColumnDescriptor] = []

    /// Currently selected cell coordinates for copy and detail pane.
    private(set) var selectedRow: Int = -1
    private(set) var selectedColumnName: String = ""

    /// Whether the detail pane is visible.
    private var isDetailPaneVisible = true

    /// Currently highlighted cell view for visual feedback.
    private weak var highlightedCellView: NSView?

    /// The active inline edit text field, if any.
    private var editField: NSTextField?
    /// The row being edited.
    private var editingRow: Int = -1
    /// The column name being edited.
    private var editingColumnName: String = ""

    /// Called when a cell edit is committed. Parameters: (rowid, columnName, newValue, displayRow).
    var onCellEdited: ((Int64, String, String, Int) -> Void)?

    /// Called when a column is renamed via the header context menu. Parameters: (oldName, newName).
    var onColumnRenamed: ((String, String) -> Void)?

    /// Called when a column type is changed via the header context menu. Parameters: (columnName, newDuckDBType).
    var onColumnTypeChanged: ((String, String) -> Void)?

    /// Called when a column is deleted via the header context menu. Parameter: columnName.
    var onColumnDeleted: ((String) -> Void)?

    /// Called when a column is selected via header click. Parameter: columnName (nil to deselect).
    var onColumnSelected: ((String?) -> Void)?

    /// Row number gutter view.
    private var rowNumberView: RowNumberView?
    /// Whether row numbers are visible.
    private(set) var isRowNumbersVisible = false
    private static let rowNumberGutterWidth: CGFloat = 50

    // MARK: - Number Formatters

    private var integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.usesGroupingSeparator = true
        return f
    }()

    private var floatFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        return f
    }()

    private var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Input formatter to parse dates from DuckDB's ISO format.
    private static let isoDateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Lifecycle

    override func loadView() {
        // Use a frame-based container that manually lays out children.
        // This prevents Auto Layout constraints from propagating to the
        // window and causing it to resize based on content fitting size.
        let container = GridkaContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.dataSource = self
        tableView.delegate = self

        // Custom header view for double-click auto-fit
        let customHeader = AutoFitTableHeaderView(tableViewController: self)
        tableView.headerView = customHeader

        // Right-click menu for column headers
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        customHeader.menu = headerMenu

        // Right-click context menu on table cells
        let cellMenu = NSMenu()
        cellMenu.delegate = self
        cellMenu.identifier = NSUserInterfaceItemIdentifier("cellContextMenu")
        tableView.menu = cellMenu

        // Single-click selects a row, then we track column via click
        tableView.target = self
        tableView.action = #selector(tableViewClicked(_:))
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        filterBar = FilterBarView()
        filterBar.onFilterRemoved = { [weak self] removedFilter in
            self?.removeFilter(removedFilter)
        }

        searchBar = SearchBarView()
        searchBar.onSearchChanged = { [weak self] term in
            self?.onSearchChanged?(term)
        }
        searchBar.onNavigate = { [weak self] direction in
            self?.navigateMatch(direction: direction)
        }
        searchBar.onDismiss = { [weak self] in
            self?.view.window?.makeFirstResponder(self?.tableView)
        }

        statusBar = StatusBarView()
        detailPane = DetailPaneView()

        // Split view: top = scroll view with table, bottom = detail pane
        splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin

        splitView.addSubview(scrollView)
        splitView.addSubview(detailPane)
        splitView.adjustSubviews()
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        splitView.delegate = self

        // Add children to container — GridkaContainerView handles layout.
        // Order matters for z-ordering: bars are added last so they draw
        // on top of the split view when they become visible.
        container.filterBar = filterBar
        container.searchBar = searchBar
        container.splitView = splitView
        container.statusBar = statusBar
        container.addSubview(splitView)
        container.addSubview(statusBar)
        container.addSubview(filterBar)
        container.addSubview(searchBar)

        self.view = container

        // Observe scroll position changes for pre-fetching
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Observe settings changes to update formatters
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: SettingsManager.settingsChangedNotification,
            object: nil
        )
        updateFormattersFromSettings()
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        updateFormattersFromSettings()
        reloadVisibleRows()
    }

    private func updateFormattersFromSettings() {
        let settings = SettingsManager.shared

        integerFormatter.usesGroupingSeparator = settings.useThousandsSeparator
        floatFormatter.usesGroupingSeparator = settings.useThousandsSeparator

        if settings.useDecimalComma {
            let locale = Locale(identifier: "de_DE")
            integerFormatter.locale = locale
            floatFormatter.locale = locale
        } else {
            let locale = Locale(identifier: "en_US")
            integerFormatter.locale = locale
            floatFormatter.locale = locale
        }

        dateFormatter.dateFormat = settings.dateFormat.rawValue
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if needsInitialDividerPosition {
            let h = splitView.bounds.height
            if h > 120 {
                needsInitialDividerPosition = false
                // Dispatch async so that the position is set after all pending
                // layout passes complete — avoids being undone by a subsequent
                // resizeSubviews triggered by the container frame assignment.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.splitView.setPosition(h - 120, ofDividerAt: 0)
                }
            }
        }
    }

    /// Disconnects all delegate/dataSource/target pointers so the view hierarchy
    /// can be torn down safely after the TVC is released.
    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        cancelEdit()
        tableView.dataSource = nil
        tableView.delegate = nil
        tableView.target = nil
        tableView.doubleAction = nil
        tableView.action = nil
        tableView.menu?.delegate = nil
        tableView.headerView?.menu?.delegate = nil
        splitView.delegate = nil
        fileSession = nil
        view.removeFromSuperview()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Column Configuration

    func configureColumns(_ columns: [ColumnDescriptor]) {
        // Remember all descriptors (excluding _gridka_rowid) for hide/show management
        allColumnDescriptors = columns.filter { $0.name != "_gridka_rowid" }

        // Remove existing columns
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }

        for descriptor in allColumnDescriptors {
            // Skip hidden columns
            if hiddenColumns.contains(descriptor.name) { continue }
            tableView.addTableColumn(makeTableColumn(for: descriptor))
        }

        tableView.reloadData()
    }

    // MARK: - Reload Helpers

    func reloadVisibleRows() {
        tableView.reloadData()
    }

    func reloadRows(_ rows: IndexSet, columns: IndexSet) {
        tableView.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }

    // MARK: - Sort Indicator Updates

    /// Updates column header titles to reflect current sort and selection state.
    func updateSortIndicators() {
        guard let session = fileSession else { return }
        let sortColumns = session.viewState.sortColumns
        let isMultiSort = sortColumns.count > 1
        let selectedColumn = session.viewState.selectedColumn

        for tableColumn in tableView.tableColumns {
            let columnName = tableColumn.identifier.rawValue
            guard let descriptor = session.columns.first(where: { $0.name == columnName }) else { continue }

            var sortSuffix = ""
            if let sortIndex = sortColumns.firstIndex(where: { $0.column == columnName }) {
                let sort = sortColumns[sortIndex]
                let arrow = sort.direction == .ascending ? "\u{25B2}" : "\u{25BC}"
                if isMultiSort {
                    sortSuffix = "\(sortIndex + 1)\(arrow)"
                } else {
                    sortSuffix = arrow
                }
            }

            let isSelected = (columnName == selectedColumn)
            styleHeaderCell(tableColumn.headerCell, descriptor: descriptor, sortSuffix: sortSuffix, isSelected: isSelected)
        }
    }

    /// Called by AutoFitTableHeaderView when the user clicks on the sort indicator area
    /// of a sorted column header. Triggers sort cycling without requiring the Option key.
    func handleSortIndicatorClick(columnIndex: Int, event: NSEvent) {
        guard let session = fileSession, session.isFullyLoaded else { return }
        guard columnIndex >= 0, columnIndex < tableView.tableColumns.count else { return }

        let columnName = tableView.tableColumns[columnIndex].identifier.rawValue
        var sortColumns = session.viewState.sortColumns
        let isShiftHeld = event.modifierFlags.contains(.shift)

        if let existingIndex = sortColumns.firstIndex(where: { $0.column == columnName }) {
            let current = sortColumns[existingIndex]
            switch current.direction {
            case .ascending:
                sortColumns[existingIndex] = SortColumn(column: columnName, direction: .descending)
            case .descending:
                sortColumns.remove(at: existingIndex)
            }
        } else {
            if isShiftHeld {
                sortColumns.append(SortColumn(column: columnName, direction: .ascending))
            } else {
                sortColumns = [SortColumn(column: columnName, direction: .ascending)]
            }
        }

        onSortChanged?(sortColumns)
    }

    // MARK: - Filter Management

    func updateFilterBar() {
        guard let session = fileSession else { return }
        filterBar.updateFilters(session.viewState.filters)
    }

    private func removeFilter(_ filter: ColumnFilter) {
        guard let session = fileSession else { return }
        var filters = session.viewState.filters
        filters.removeAll { $0 == filter }
        onFiltersChanged?(filters)
    }

    private func showFilterPopover(for column: ColumnDescriptor, relativeTo positioningRect: NSRect, of positioningView: NSView) {
        let popoverVC = FilterPopoverViewController(column: column)
        popoverVC.onApply = { [weak self] newFilter in
            self?.addFilter(newFilter)
        }

        let popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popoverVC.popover = popover
        popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: .maxY)
        activePopover = popover
    }

    private func addFilter(_ filter: ColumnFilter) {
        guard let session = fileSession else { return }
        var filters = session.viewState.filters
        filters.append(filter)
        onFiltersChanged?(filters)
    }

    // MARK: - Search

    /// Toggles search bar visibility. Called by ⌘F.
    func toggleSearchBar() {
        if searchBar.isVisible {
            searchBar.dismiss()
        } else {
            searchBar.show()
        }
    }

    /// Navigates to the next or previous match row. Direction is +1 or -1.
    private func navigateMatch(direction: Int) {
        guard let session = fileSession else { return }
        let totalRows = session.viewState.totalFilteredRows
        guard totalRows > 0 else { return }

        let visibleRange = tableView.rows(in: tableView.visibleRect)
        let currentRow = max(0, visibleRange.location)

        var targetRow: Int
        if direction > 0 {
            // Next: move one page down from current visible row
            targetRow = currentRow + visibleRange.length
            if targetRow >= totalRows { targetRow = 0 }
        } else {
            // Previous: move one page up
            targetRow = currentRow - visibleRange.length
            if targetRow < 0 { targetRow = max(0, totalRows - visibleRange.length) }
        }

        tableView.scrollRowToVisible(targetRow)
    }

    // MARK: - Row Numbers

    func toggleRowNumbers() {
        isRowNumbersVisible.toggle()
        if isRowNumbersVisible {
            showRowNumbers()
        } else {
            hideRowNumbers()
        }
    }

    private func showRowNumbers() {
        let gutterWidth = TableViewController.rowNumberGutterWidth
        scrollView.contentInsets.left = gutterWidth

        // Position below the header, aligned with the clip view
        let clipFrame = scrollView.contentView.frame
        let rnView = RowNumberView(frame: NSRect(
            x: 0,
            y: clipFrame.origin.y,
            width: gutterWidth,
            height: clipFrame.height
        ))
        rnView.autoresizingMask = [.height]
        rnView.tableView = tableView
        rnView.onRowClicked = { [weak self] row in
            self?.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        scrollView.addSubview(rnView)
        rowNumberView = rnView
        rnView.updateVisibleRows()
    }

    private func hideRowNumbers() {
        scrollView.contentInsets.left = 0
        rowNumberView?.removeFromSuperview()
        rowNumberView = nil
    }

    // MARK: - Scroll Pre-fetching

    @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
        // Dismiss any active inline edit when scrolling
        if editField != nil {
            cancelEdit()
        }
        clearHighlightIfNeeded()
        if isRowNumbersVisible {
            rowNumberView?.updateVisibleRows()
        }
        guard let session = fileSession, session.isFullyLoaded else { return }

        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }
        let firstVisibleRow = max(0, visibleRange.location)

        // Detect scroll direction
        let scrollingDown = firstVisibleRow >= lastVisibleRow
        lastVisibleRow = firstVisibleRow

        // Determine the page index of the last visible row
        let lastVisibleRow = firstVisibleRow + visibleRange.length - 1
        let currentPageStart = session.rowCache.pageIndex(forRow: firstVisibleRow)
        let currentPageEnd = session.rowCache.pageIndex(forRow: lastVisibleRow)

        // Pre-fetch 2 pages ahead in the scroll direction
        if scrollingDown {
            for offset in 1...2 {
                let pageIndex = currentPageEnd + offset
                let pageStart = pageIndex * RowCache.pageSize
                guard pageStart < session.viewState.totalFilteredRows else { break }
                prefetchPage(pageIndex)
            }
        } else {
            for offset in 1...2 {
                let pageIndex = currentPageStart - offset
                guard pageIndex >= 0 else { break }
                prefetchPage(pageIndex)
            }
        }
    }

    private func prefetchPage(_ pageIndex: Int) {
        guard let session = fileSession else { return }
        guard !fetchingPages.contains(pageIndex) else { return }
        guard !session.rowCache.hasPage(pageIndex) else { return }

        let startRow = pageIndex * RowCache.pageSize
        guard startRow < session.viewState.totalFilteredRows else { return }
        requestPageFetch(forRow: startRow)
    }

    // MARK: - Detail Pane

    /// Toggles detail pane visibility.
    func toggleDetailPane() {
        isDetailPaneVisible.toggle()
        if isDetailPaneVisible {
            splitView.arrangedSubviews[1].isHidden = false
            splitView.setPosition(splitView.bounds.height - 120, ofDividerAt: 0)
        } else {
            splitView.arrangedSubviews[1].isHidden = true
        }
    }

    func updateDetailPane() {
        guard let session = fileSession,
              selectedRow >= 0,
              !selectedColumnName.isEmpty else {
            detailPane.showEmpty()
            return
        }

        let descriptor = session.columns.first(where: { $0.name == selectedColumnName })
        let typeStr = typeLabel(for: descriptor?.displayType ?? .unknown)

        if let value = session.rowCache.value(forRow: selectedRow, columnName: selectedColumnName) {
            detailPane.update(columnName: selectedColumnName, dataType: typeStr, value: value)
        } else {
            detailPane.update(columnName: selectedColumnName, dataType: typeStr, value: .null)
            requestPageFetch(forRow: selectedRow)
        }
    }

    // MARK: - Cell Selection

    @objc private func tableViewClicked(_ sender: Any?) {
        let clickedRow = tableView.clickedRow
        let clickedCol = tableView.clickedColumn

        guard clickedRow >= 0, clickedCol >= 0, clickedCol < tableView.numberOfColumns else { return }

        // Dismiss any active edit if the click is outside the editing cell
        if editField != nil {
            cancelEdit()
        }

        selectedRow = clickedRow
        selectedColumnName = tableView.tableColumns[clickedCol].identifier.rawValue
        updateCellHighlight(row: clickedRow, column: clickedCol)
        updateDetailPane()
        statusBar.updateCellLocation(row: clickedRow, columnName: selectedColumnName)
    }

    @objc private func tableViewDoubleClicked(_ sender: Any?) {
        let clickedRow = tableView.clickedRow
        let clickedCol = tableView.clickedColumn

        guard clickedRow >= 0, clickedCol >= 0, clickedCol < tableView.numberOfColumns else { return }
        guard let session = fileSession, session.isFullyLoaded else { return }

        let columnName = tableView.tableColumns[clickedCol].identifier.rawValue

        // Don't allow editing the _gridka_rowid column
        guard columnName != "_gridka_rowid" else { return }

        beginEditing(row: clickedRow, column: clickedCol, columnName: columnName)
    }

    // MARK: - Inline Cell Editing

    /// Public entry point for starting inline editing on a specific cell.
    /// Called by AppDelegate after adding a new row to auto-enter edit mode.
    func beginEditingCell(row: Int, column: Int, columnName: String) {
        beginEditing(row: row, column: column, columnName: columnName)
    }

    private func beginEditing(row: Int, column: Int, columnName: String) {
        // Cancel any existing edit
        cancelEdit()

        guard let session = fileSession else { return }

        // Get the raw value for pre-populating the edit field
        let rawValue: String
        if let value = session.rowCache.value(forRow: row, columnName: columnName) {
            switch value {
            case .null:
                rawValue = ""
            default:
                rawValue = value.description
            }
        } else {
            // Cache miss — can't edit without data
            return
        }

        editingRow = row
        editingColumnName = columnName

        // Get the cell frame in table view coordinates
        let cellFrame = tableView.frameOfCell(atColumn: column, row: row)

        // Create edit field
        let field = NSTextField()
        field.stringValue = rawValue
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .controlBackgroundColor
        field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .exterior
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.frame = cellFrame

        // Match alignment with the cell
        let descriptor = session.columns.first(where: { $0.name == columnName })
        let isNumeric = descriptor?.displayType == .integer || descriptor?.displayType == .float
        field.alignment = isNumeric ? .right : .left

        tableView.addSubview(field)
        field.selectText(nil)
        view.window?.makeFirstResponder(field)

        editField = field
    }

    private func commitEdit() {
        guard let field = editField, let session = fileSession else { return }
        let newValue = field.stringValue
        let columnName = editingColumnName
        let displayRow = editingRow

        // Get the _gridka_rowid for this row
        guard let rowidValue = session.rowCache.value(forRow: displayRow, columnName: "_gridka_rowid"),
              case .integer(let rowid) = rowidValue else {
            cancelEdit()
            return
        }

        // Remove the edit field
        field.removeFromSuperview()
        editField = nil
        editingRow = -1
        editingColumnName = ""

        // Fire the callback to perform the UPDATE
        onCellEdited?(rowid, columnName, newValue, displayRow)
    }

    func cancelEdit() {
        guard let field = editField else { return }
        field.removeFromSuperview()
        editField = nil
        editingRow = -1
        editingColumnName = ""
    }

    /// Direction for Tab/Shift+Tab cell navigation.
    private enum EditMoveDirection {
        case forward
        case backward
    }

    /// Commits the current edit and moves to the next/previous editable cell.
    private func commitEditAndMove(direction: EditMoveDirection) {
        guard editField != nil, let session = fileSession else { return }

        let currentRow = editingRow
        let currentColumnName = editingColumnName

        // Commit the current edit
        commitEdit()

        // Find the current column index in the table view
        guard let colIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == currentColumnName }) else { return }

        let columnCount = tableView.numberOfColumns
        let rowCount = session.viewState.totalFilteredRows
        guard columnCount > 0, rowCount > 0 else { return }

        // Build list of editable column indices (skip _gridka_rowid)
        let editableColumns: [Int] = (0..<columnCount).filter { i in
            tableView.tableColumns[i].identifier.rawValue != "_gridka_rowid"
        }
        guard !editableColumns.isEmpty else { return }

        // Find position in editable columns list
        guard let editableIndex = editableColumns.firstIndex(of: colIndex) else { return }

        var nextRow = currentRow
        var nextEditableIndex = editableIndex

        switch direction {
        case .forward:
            nextEditableIndex += 1
            if nextEditableIndex >= editableColumns.count {
                // Wrap to first editable column of next row
                nextEditableIndex = 0
                nextRow += 1
                if nextRow >= rowCount { return } // At the very end, stop
            }
        case .backward:
            nextEditableIndex -= 1
            if nextEditableIndex < 0 {
                // Wrap to last editable column of previous row
                nextEditableIndex = editableColumns.count - 1
                nextRow -= 1
                if nextRow < 0 { return } // At the very beginning, stop
            }
        }

        let nextCol = editableColumns[nextEditableIndex]
        let nextColumnName = tableView.tableColumns[nextCol].identifier.rawValue

        // Scroll to make the target cell visible
        tableView.scrollRowToVisible(nextRow)
        tableView.scrollColumnToVisible(nextCol)

        // Begin editing the next cell (dispatch to let the scroll settle)
        DispatchQueue.main.async { [weak self] in
            self?.beginEditing(row: nextRow, column: nextCol, columnName: nextColumnName)
        }
    }

    private func updateCellHighlight(row: Int, column: Int) {
        // Clear previous highlight
        if let prev = highlightedCellView {
            prev.layer?.borderWidth = 0
            prev.layer?.borderColor = nil
        }

        // Apply new highlight — use a border so it's visible over row selection
        guard let cellView = tableView.view(atColumn: column, row: row, makeIfNecessary: false) else { return }
        cellView.wantsLayer = true
        cellView.layer?.borderWidth = 2
        cellView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlightedCellView = cellView
    }

    /// Clears highlight when the highlighted cell is scrolled out of view.
    func clearHighlightIfNeeded() {
        if let prev = highlightedCellView {
            prev.layer?.borderWidth = 0
            prev.layer?.borderColor = nil
            highlightedCellView = nil
        }
    }

    // MARK: - Copy Operations

    /// Returns the plain text value of the selected cell, or nil if nothing is selected.
    func selectedCellText() -> String? {
        guard let session = fileSession, selectedRow >= 0, !selectedColumnName.isEmpty else { return nil }
        guard let value = session.rowCache.value(forRow: selectedRow, columnName: selectedColumnName) else { return nil }
        return value.description
    }

    /// Returns all values in the selected row as tab-separated text.
    func selectedRowText(withHeaders: Bool) -> String? {
        guard let session = fileSession, selectedRow >= 0 else { return nil }
        let visibleColumns = tableView.tableColumns.map { $0.identifier.rawValue }

        var lines: [String] = []
        if withHeaders {
            lines.append(visibleColumns.joined(separator: "\t"))
        }

        let values = visibleColumns.map { colName -> String in
            if let value = session.rowCache.value(forRow: selectedRow, columnName: colName) {
                return value.description
            }
            return ""
        }
        lines.append(values.joined(separator: "\t"))
        return lines.joined(separator: "\n")
    }

    /// Returns all visible values in the selected column as newline-separated text.
    func selectedColumnText() -> String? {
        guard let session = fileSession, !selectedColumnName.isEmpty else { return nil }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return nil }

        var values: [String] = []
        for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
            guard row >= 0, row < session.viewState.totalFilteredRows else { continue }
            if let value = session.rowCache.value(forRow: row, columnName: selectedColumnName) {
                values.append(value.description)
            } else {
                values.append("")
            }
        }
        return values.joined(separator: "\n")
    }

    @objc func copyCellValue(_ sender: Any?) {
        guard let text = selectedCellText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyRowValues(_ sender: Any?) {
        guard let text = selectedRowText(withHeaders: false) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyColumnValues(_ sender: Any?) {
        guard let text = selectedColumnText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyWithHeaders(_ sender: Any?) {
        guard let text = selectedRowText(withHeaders: true) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func filterForValue(_ sender: NSMenuItem) {
        guard let duckValue = sender.representedObject as? DuckDBValue else { return }
        addQuickFilter(for: duckValue, negate: false)
    }

    @objc private func excludeValue(_ sender: NSMenuItem) {
        guard let duckValue = sender.representedObject as? DuckDBValue else { return }
        addQuickFilter(for: duckValue, negate: true)
    }

    private func addQuickFilter(for value: DuckDBValue, negate: Bool) {
        let columnName = selectedColumnName
        guard !columnName.isEmpty else { return }

        let filterValue: FilterValue
        let filterOp: FilterOperator

        switch value {
        case .null:
            filterOp = .isNull
            filterValue = .none
        case .boolean(let b):
            filterOp = b ? .isTrue : .isFalse
            filterValue = .none
        case .integer(let n):
            filterOp = .equals
            filterValue = .number(Double(n))
        case .double(let n):
            filterOp = .equals
            filterValue = .number(n)
        case .string(let s):
            filterOp = .equals
            filterValue = .string(s)
        case .date(let s):
            filterOp = .equals
            filterValue = .string(s)
        }

        let filter = ColumnFilter(column: columnName, operator: filterOp, value: filterValue, negate: negate)
        addFilter(filter)
    }

    // MARK: - Column Management (Hide/Show/Auto-fit)

    func hideColumn(_ columnName: String) {
        hiddenColumns.insert(columnName)
        let identifier = NSUserInterfaceItemIdentifier(columnName)
        if let index = tableView.tableColumns.firstIndex(where: { $0.identifier == identifier }) {
            tableView.removeTableColumn(tableView.tableColumns[index])
        }
    }

    func showColumn(_ columnName: String) {
        hiddenColumns.remove(columnName)

        guard let descriptor = allColumnDescriptors.first(where: { $0.name == columnName }) else { return }

        let column = makeTableColumn(for: descriptor)

        // Insert at the original position (or at end if other columns are hidden)
        let originalIndex = allColumnDescriptors.firstIndex(of: descriptor) ?? allColumnDescriptors.count - 1
        var insertAt = tableView.numberOfColumns
        for (i, tableCol) in tableView.tableColumns.enumerated() {
            if let desc = allColumnDescriptors.first(where: { $0.name == tableCol.identifier.rawValue }),
               let descIndex = allColumnDescriptors.firstIndex(of: desc),
               descIndex > originalIndex {
                insertAt = i
                break
            }
        }

        tableView.addTableColumn(column)
        if insertAt < tableView.numberOfColumns - 1 {
            tableView.moveColumn(tableView.numberOfColumns - 1, toColumn: insertAt)
        }

        // Restore sort indicator if applicable
        updateSortIndicators()
        tableView.reloadData()
    }

    /// Auto-fits the column width to the content of visible rows.
    func autoFitColumn(at columnIndex: Int) {
        guard columnIndex >= 0, columnIndex < tableView.numberOfColumns else { return }
        guard let session = fileSession else { return }

        let tableColumn = tableView.tableColumns[columnIndex]
        let columnName = tableColumn.identifier.rawValue
        let descriptor = session.columns.first(where: { $0.name == columnName })
        let displayType = descriptor?.displayType ?? .text

        // Measure header width
        var maxWidth = (tableColumn.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width + 16

        // Scan visible rows for max content width
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
            guard row >= 0, row < session.viewState.totalFilteredRows else { continue }
            if let value = session.rowCache.value(forRow: row, columnName: columnName) {
                let formatted = formatValue(value, displayType: displayType)
                let width = formatted.size().width
                maxWidth = max(maxWidth, width)
            }
        }

        // Add padding
        tableColumn.width = min(max(maxWidth + 16, tableColumn.minWidth), tableColumn.maxWidth)
    }

    /// Auto-fits all columns based on header text and sampled data, then
    /// distributes remaining space if columns are narrower than the view.
    func autoFitAllColumns() {
        guard let session = fileSession else { return }

        let cellFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let sampleCount = min(100, session.viewState.totalFilteredRows)

        for tableColumn in tableView.tableColumns {
            let columnName = tableColumn.identifier.rawValue
            let descriptor = session.columns.first(where: { $0.name == columnName })
            let displayType = descriptor?.displayType ?? .text

            // Measure header title
            var maxWidth = (tableColumn.title as NSString).size(
                withAttributes: [.font: headerFont]
            ).width + 16

            // Sample first N cached rows
            for row in 0..<sampleCount {
                if let value = session.rowCache.value(forRow: row, columnName: columnName) {
                    let formatted = formatValue(value, displayType: displayType)
                    let width = formatted.size().width
                    maxWidth = max(maxWidth, width)
                }
            }

            // Clamp: at least minWidth, at most 400 on initial auto-fit
            tableColumn.width = min(max(maxWidth + 16, tableColumn.minWidth), 400)
        }

        // If total column width < visible width, distribute extra space proportionally
        let intercell = tableView.intercellSpacing.width
        let totalColumnWidth = tableView.tableColumns.reduce(CGFloat(0)) { $0 + $1.width + intercell }
        let visibleWidth = scrollView.contentSize.width

        if totalColumnWidth < visibleWidth, !tableView.tableColumns.isEmpty {
            let extra = visibleWidth - totalColumnWidth
            let perColumn = extra / CGFloat(tableView.tableColumns.count)
            for tableColumn in tableView.tableColumns {
                tableColumn.width += perColumn
            }
        }
    }

    // MARK: - Private Helpers

    private func typeLabel(for displayType: DisplayType) -> String {
        switch displayType {
        case .text:     return "text"
        case .integer:  return "int"
        case .float:    return "float"
        case .date:     return "date"
        case .boolean:  return "bool"
        case .unknown:  return "?"
        }
    }

    /// Returns the SF Symbol name for a given display type.
    private func typeIconName(for displayType: DisplayType) -> String {
        switch displayType {
        case .text:     return "textformat"
        case .integer:  return "number"
        case .float:    return "textformat.123"
        case .date:     return "calendar"
        case .boolean:  return "checkmark.circle"
        case .unknown:  return "questionmark.circle"
        }
    }

    /// Returns the full DuckDB type name for tooltip display.
    private func duckDBTypeName(for descriptor: ColumnDescriptor) -> String {
        switch descriptor.duckDBType {
        case .varchar:    return "VARCHAR"
        case .integer:    return "INTEGER"
        case .bigint:     return "BIGINT"
        case .double:     return "DOUBLE"
        case .float:      return "FLOAT"
        case .boolean:    return "BOOLEAN"
        case .date:       return "DATE"
        case .timestamp:  return "TIMESTAMP"
        case .blob:       return "BLOB"
        case .unknown:    return "UNKNOWN"
        }
    }

    /// Builds an attributed string with a type icon followed by the column name.
    private func buildHeaderAttributedString(columnName: String, descriptor: ColumnDescriptor, sortSuffix: String = "") -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Add SF Symbol icon
        let iconName = typeIconName(for: descriptor.displayType)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: typeLabel(for: descriptor.displayType)) {
            let configuredImage = image.withSymbolConfiguration(symbolConfig) ?? image
            let tintedImage = configuredImage.tinted(with: .secondaryLabelColor)
            let attachment = NSTextAttachment()
            attachment.image = tintedImage
            // Adjust vertical alignment: shift the icon down slightly to align with text baseline
            let iconSize = tintedImage.size
            attachment.bounds = CGRect(x: 0, y: -1, width: iconSize.width, height: iconSize.height)
            result.append(NSAttributedString(attachment: attachment))
        }

        // 4pt spacing between icon and column name
        result.append(NSAttributedString(string: "\u{2009} ")) // thin space + regular space ≈ 4pt

        // Column name (uppercased)
        result.append(NSAttributedString(string: columnName.uppercased()))

        // Sort suffix (e.g., " ▲" or " 1▲")
        if !sortSuffix.isEmpty {
            result.append(NSAttributedString(string: " \(sortSuffix)"))
        }

        return result
    }

    private func makeTableColumn(for descriptor: ColumnDescriptor) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(descriptor.name))
        column.title = descriptor.name.uppercased() // plain title for internal use
        column.width = widthForColumn(descriptor)
        column.minWidth = 50
        column.maxWidth = 2000

        // Set tooltip to full DuckDB type name
        column.headerToolTip = duckDBTypeName(for: descriptor)

        styleHeaderCell(column.headerCell, descriptor: descriptor)

        return column
    }

    /// Applies bold font, type icon, and numeric right-alignment to a header cell via attributed string.
    /// When `isSelected` is true, the header cell gets a tinted background color.
    private func styleHeaderCell(_ headerCell: NSTableHeaderCell, descriptor: ColumnDescriptor, sortSuffix: String = "", isSelected: Bool = false) {
        let isNumeric = descriptor.displayType == .integer || descriptor.displayType == .float
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = isNumeric ? .right : .left
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attrStr = buildHeaderAttributedString(
            columnName: descriptor.name,
            descriptor: descriptor,
            sortSuffix: sortSuffix
        )

        // Apply bold font and paragraph style to the full string
        let styled = NSMutableAttributedString(attributedString: attrStr)
        styled.addAttributes([
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraphStyle,
        ], range: NSRange(location: 0, length: styled.length))

        // Apply selection tint via background color on the attributed string
        if isSelected {
            styled.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.15),
                range: NSRange(location: 0, length: styled.length)
            )
        }

        headerCell.attributedStringValue = styled
    }

    private func widthForColumn(_ descriptor: ColumnDescriptor) -> CGFloat {
        let headerWidth = (descriptor.name as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ).width + 40 // padding for type label and header chrome
        return max(headerWidth, 100)
    }

    private static let rightParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()

    private func formatValue(_ value: DuckDBValue, displayType: DisplayType, rightAlign: Bool = false) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [:]
        if rightAlign {
            attrs[.paragraphStyle] = TableViewController.rightParagraphStyle
        }

        switch value {
        case .null:
            attrs[.font] = NSFont.systemFont(ofSize: NSFont.systemFontSize).italic
            attrs[.foregroundColor] = NSColor.tertiaryLabelColor
            return NSAttributedString(string: "NULL", attributes: attrs)
        case .integer(let v):
            let text = integerFormatter.string(from: NSNumber(value: v)) ?? String(v)
            return NSAttributedString(string: text, attributes: attrs)
        case .double(let v):
            let text = floatFormatter.string(from: NSNumber(value: v)) ?? String(v)
            return NSAttributedString(string: text, attributes: attrs)
        case .boolean(let v):
            return NSAttributedString(string: v ? "true" : "false", attributes: attrs)
        case .date(let v):
            // Re-format date according to user settings
            if let parsed = TableViewController.isoDateParser.date(from: v) {
                return NSAttributedString(string: dateFormatter.string(from: parsed), attributes: attrs)
            }
            return NSAttributedString(string: v, attributes: attrs)
        case .string(let v):
            return NSAttributedString(string: v, attributes: attrs)
        }
    }

    /// Identifier for the edited-cell dot layer.
    private static let editedDotLayerName = "editedCellDot"

    /// Adds or removes a small colored dot in the top-right corner of a cell
    /// to indicate that the cell has been edited since the last save.
    private func updateEditedDot(on cell: NSTextField, row: Int, columnName: String, session: FileSession) {
        let existingDot = cell.layer?.sublayers?.first(where: { $0.name == TableViewController.editedDotLayerName })

        // Check if this cell is edited by looking up the rowid
        var isEdited = false
        if !session.editedCells.isEmpty,
           let rowidValue = session.rowCache.value(forRow: row, columnName: "_gridka_rowid"),
           case .integer(let rowid) = rowidValue {
            isEdited = session.editedCells.contains(EditedCell(rowid: rowid, column: columnName))
        }

        if isEdited {
            let dotSize: CGFloat = 3
            if let dot = existingDot {
                // Reposition the existing dot (in case cell was resized)
                dot.frame = CGRect(
                    x: cell.bounds.width - dotSize - 2,
                    y: 2,
                    width: dotSize,
                    height: dotSize
                )
            } else {
                let dot = CALayer()
                dot.name = TableViewController.editedDotLayerName
                dot.backgroundColor = NSColor.controlAccentColor.cgColor
                dot.cornerRadius = 1.5
                // Position in top-right corner. In a flipped coordinate system
                // (NSTableView cells), y=0 is top, so use y=2 for top-right.
                dot.frame = CGRect(
                    x: cell.bounds.width - dotSize - 2,
                    y: 2,
                    width: dotSize,
                    height: dotSize
                )
                // Auto-resize to stay in top-right when cell width changes
                dot.autoresizingMask = [.layerMinXMargin]
                cell.layer?.addSublayer(dot)
            }
        } else {
            existingDot?.removeFromSuperlayer()
        }
    }

    private func requestPageFetch(forRow row: Int) {
        guard let session = fileSession else { return }
        let pageIndex = session.rowCache.pageIndex(forRow: row)

        guard !fetchingPages.contains(pageIndex) else { return }
        fetchingPages.insert(pageIndex)

        session.fetchPage(index: pageIndex) { [weak self] result in
            guard let self = self else { return }
            self.fetchingPages.remove(pageIndex)

            switch result {
            case .success(let page):
                let startRow = page.startRow
                let endRow = startRow + page.data.count
                let rowRange = IndexSet(integersIn: startRow..<endRow)
                let colRange = IndexSet(integersIn: 0..<self.tableView.numberOfColumns)
                self.tableView.reloadData(forRowIndexes: rowRange, columnIndexes: colRange)
            case .failure:
                break
            }
        }
    }
}

// MARK: - NSTextFieldDelegate (Inline Cell Editing)

extension TableViewController: NSTextFieldDelegate {

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Enter — commit the edit
            commitEdit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape — cancel the edit
            cancelEdit()
            view.window?.makeFirstResponder(tableView)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            // Tab — commit and move to next cell
            commitEditAndMove(direction: .forward)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            // Shift+Tab — commit and move to previous cell
            commitEditAndMove(direction: .backward)
            return true
        }
        return false
    }
}

// MARK: - NSTableViewDataSource

extension TableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return fileSession?.viewState.totalFilteredRows ?? 0
    }
}

// MARK: - NSTableViewDelegate

extension TableViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let session = fileSession else { return }
        let columnName = tableColumn.identifier.rawValue

        // Skip if file isn't fully loaded yet
        guard session.isFullyLoaded else { return }

        let modifiers = NSEvent.modifierFlags
        let isOptionHeld = modifiers.contains(.option)
        let isShiftHeld = modifiers.contains(.shift)

        if isOptionHeld {
            // Option+click (or Shift+Option+click): sort by this column
            var sortColumns = session.viewState.sortColumns

            if let existingIndex = sortColumns.firstIndex(where: { $0.column == columnName }) {
                let current = sortColumns[existingIndex]
                switch current.direction {
                case .ascending:
                    sortColumns[existingIndex] = SortColumn(column: columnName, direction: .descending)
                case .descending:
                    sortColumns.remove(at: existingIndex)
                }
            } else {
                if isShiftHeld {
                    sortColumns.append(SortColumn(column: columnName, direction: .ascending))
                } else {
                    sortColumns = [SortColumn(column: columnName, direction: .ascending)]
                }
            }

            onSortChanged?(sortColumns)
        } else {
            // Plain click: select this column (toggle off if already selected)
            let newSelection = (session.viewState.selectedColumn == columnName) ? nil : columnName
            onColumnSelected?(newSelection)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn, let session = fileSession else { return nil }

        let identifier = tableColumn.identifier
        let columnName = identifier.rawValue

        var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
        if cellView == nil {
            let textField = NSTextField()
            textField.identifier = identifier
            textField.isBordered = false
            textField.drawsBackground = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.lineBreakMode = .byTruncatingTail
            textField.cell?.truncatesLastVisibleLine = true
            textField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textField.wantsLayer = true
            cellView = textField
        }

        guard let cell = cellView else { return nil }

        let value = session.rowCache.value(forRow: row, columnName: columnName)

        let descriptor = session.columns.first(where: { $0.name == columnName })
        let displayType = descriptor?.displayType ?? .text
        let isNumeric = displayType == .integer || displayType == .float

        if let value = value {
            cell.attributedStringValue = formatValue(value, displayType: displayType, rightAlign: isNumeric)
        } else {
            // Cache miss — show placeholder and request fetch
            cell.attributedStringValue = NSAttributedString(
                string: "...",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor]
            )
            requestPageFetch(forRow: row)
        }

        // Show/hide the edited cell dot indicator
        updateEditedDot(on: cell, row: row, columnName: columnName, session: session)

        return cell
    }
}

// MARK: - NSMenuDelegate (Column Header + Cell Context Menu)

extension TableViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Cell context menu
        if menu.identifier == NSUserInterfaceItemIdentifier("cellContextMenu") {
            buildCellContextMenu(menu)
            return
        }

        // Column header context menu
        guard let session = fileSession, session.isFullyLoaded else { return }
        guard let headerView = tableView.headerView,
              let window = headerView.window else { return }

        // Convert mouse screen coordinates to header view local coordinates
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = headerView.convert(windowPoint, from: nil)
        let clickedColumnIndex = headerView.column(at: localPoint)
        guard clickedColumnIndex >= 0, clickedColumnIndex < tableView.tableColumns.count else { return }

        let tableColumn = tableView.tableColumns[clickedColumnIndex]
        let columnName = tableColumn.identifier.rawValue
        guard session.columns.contains(where: { $0.name == columnName }) else { return }

        // Filter option
        let filterItem = NSMenuItem(title: "Filter \"\(columnName)\"…", action: #selector(filterColumnClicked(_:)), keyEquivalent: "")
        filterItem.target = self
        filterItem.representedObject = columnName as NSString
        menu.addItem(filterItem)

        // Rename Column option (hidden for _gridka_rowid)
        if columnName != "_gridka_rowid" {
            let renameItem = NSMenuItem(title: "Rename Column…", action: #selector(renameColumnClicked(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = columnName as NSString
            menu.addItem(renameItem)
        }

        // Change Type submenu (hidden for _gridka_rowid)
        if columnName != "_gridka_rowid",
           let descriptor = session.columns.first(where: { $0.name == columnName }) {
            let changeTypeItem = NSMenuItem(title: "Change Type", action: nil, keyEquivalent: "")
            let typeSubmenu = NSMenu()

            let typeOptions: [(String, String, DisplayType)] = [
                ("Text", "VARCHAR", .text),
                ("Integer", "BIGINT", .integer),
                ("Float", "DOUBLE", .float),
                ("Date", "DATE", .date),
                ("Boolean", "BOOLEAN", .boolean),
            ]

            for (title, duckDBType, displayType) in typeOptions {
                let item = NSMenuItem(title: title, action: #selector(changeColumnTypeClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [columnName, duckDBType] as [String]
                // Show checkmark for the current type
                if descriptor.displayType == displayType {
                    item.state = .on
                }
                typeSubmenu.addItem(item)
            }

            changeTypeItem.submenu = typeSubmenu
            menu.addItem(changeTypeItem)
        }

        // Delete Column option (hidden for _gridka_rowid)
        if columnName != "_gridka_rowid" {
            let deleteItem = NSMenuItem(title: "Delete Column", action: #selector(deleteColumnClicked(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = columnName as NSString
            menu.addItem(deleteItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Hide Column option (only if more than 1 column visible)
        if tableView.tableColumns.count > 1 {
            let hideItem = NSMenuItem(title: "Hide Column", action: #selector(hideColumnClicked(_:)), keyEquivalent: "")
            hideItem.target = self
            hideItem.representedObject = columnName as NSString
            menu.addItem(hideItem)
        }

        // Show Columns submenu (only if there are hidden columns)
        if !hiddenColumns.isEmpty {
            let showItem = NSMenuItem(title: "Show Columns", action: nil, keyEquivalent: "")
            let showSubmenu = NSMenu()

            for descriptor in allColumnDescriptors where hiddenColumns.contains(descriptor.name) {
                let item = NSMenuItem(
                    title: "\(descriptor.name) (\(typeLabel(for: descriptor.displayType)))",
                    action: #selector(showColumnClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = descriptor.name as NSString
                showSubmenu.addItem(item)
            }

            showItem.submenu = showSubmenu
            menu.addItem(showItem)
        }
    }

    private func buildCellContextMenu(_ menu: NSMenu) {
        let clickedRow = tableView.clickedRow
        let clickedCol = tableView.clickedColumn
        guard clickedRow >= 0, clickedCol >= 0, clickedCol < tableView.numberOfColumns else { return }

        // Update selection to the right-clicked cell
        selectedRow = clickedRow
        selectedColumnName = tableView.tableColumns[clickedCol].identifier.rawValue
        tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        updateCellHighlight(row: clickedRow, column: clickedCol)
        updateDetailPane()
        statusBar.updateCellLocation(row: clickedRow, columnName: selectedColumnName)

        let copyCell = NSMenuItem(title: "Copy Cell", action: #selector(copyCellValue(_:)), keyEquivalent: "")
        copyCell.target = self
        menu.addItem(copyCell)

        let copyRow = NSMenuItem(title: "Copy Row", action: #selector(copyRowValues(_:)), keyEquivalent: "")
        copyRow.target = self
        menu.addItem(copyRow)

        let copyHeaders = NSMenuItem(title: "Copy with Headers", action: #selector(copyWithHeaders(_:)), keyEquivalent: "")
        copyHeaders.target = self
        menu.addItem(copyHeaders)

        // Filter by value actions (only if we can read the cell value)
        if let session = fileSession,
           let value = session.rowCache.value(forRow: clickedRow, columnName: selectedColumnName) {

            menu.addItem(NSMenuItem.separator())

            let filterFor = NSMenuItem(title: "Filter for This Value", action: #selector(filterForValue(_:)), keyEquivalent: "")
            filterFor.target = self
            filterFor.representedObject = value
            menu.addItem(filterFor)

            let filterExclude = NSMenuItem(title: "Exclude This Value", action: #selector(excludeValue(_:)), keyEquivalent: "")
            filterExclude.target = self
            filterExclude.representedObject = value
            menu.addItem(filterExclude)
        }
    }

    @objc private func filterColumnClicked(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String,
              let session = fileSession,
              let descriptor = session.columns.first(where: { $0.name == columnName }) else { return }

        guard let headerView = tableView.headerView else { return }
        let columnIndex = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(columnName))
        guard columnIndex >= 0 else { return }

        let headerRect = headerView.headerRect(ofColumn: columnIndex)
        showFilterPopover(for: descriptor, relativeTo: headerRect, of: headerView)
    }

    @objc private func renameColumnClicked(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String,
              let session = fileSession else { return }

        guard let headerView = tableView.headerView else { return }
        let columnIndex = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(columnName))
        guard columnIndex >= 0 else { return }

        let existingNames = session.columns.map { $0.name }
        let headerRect = headerView.headerRect(ofColumn: columnIndex)

        let renameVC = RenameColumnPopoverController(
            currentName: columnName,
            existingNames: existingNames
        )
        renameVC.onRename = { [weak self] newName in
            self?.onColumnRenamed?(columnName, newName)
        }

        let popover = NSPopover()
        popover.contentViewController = renameVC
        popover.behavior = .transient
        renameVC.popover = popover
        popover.show(relativeTo: headerRect, of: headerView, preferredEdge: .maxY)
        activePopover = popover
    }

    @objc private func changeColumnTypeClicked(_ sender: NSMenuItem) {
        guard let params = sender.representedObject as? [String],
              params.count == 2 else { return }
        let columnName = params[0]
        let duckDBType = params[1]

        // If the current type already matches, do nothing
        guard let session = fileSession,
              let descriptor = session.columns.first(where: { $0.name == columnName }) else { return }

        let currentDuckDBType: String
        switch descriptor.displayType {
        case .text:     currentDuckDBType = "VARCHAR"
        case .integer:  currentDuckDBType = "BIGINT"
        case .float:    currentDuckDBType = "DOUBLE"
        case .date:     currentDuckDBType = "DATE"
        case .boolean:  currentDuckDBType = "BOOLEAN"
        case .unknown:  currentDuckDBType = ""
        }
        guard duckDBType != currentDuckDBType else { return }

        onColumnTypeChanged?(columnName, duckDBType)
    }

    @objc private func deleteColumnClicked(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = "Delete column \"\(columnName)\"?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onColumnDeleted?(columnName)
        }
    }

    @objc private func hideColumnClicked(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        hideColumn(columnName)
    }

    @objc private func showColumnClicked(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String else { return }
        showColumn(columnName)
    }
}

// MARK: - NSSplitViewDelegate

extension TableViewController: NSSplitViewDelegate {

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofDividerAt dividerIndex: Int) -> CGFloat {
        // Table (first pane) needs at least 100pt
        return 100
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofDividerAt dividerIndex: Int) -> CGFloat {
        // Detail pane (second pane) needs at least 60pt
        return splitView.bounds.height - 60
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // Only the table (scrollView) should absorb size changes.
        // The detail pane keeps its current height when the split view resizes.
        return view !== detailPane
    }
}

// MARK: - AutoFitTableHeaderView

/// Custom NSTableHeaderView subclass that detects double-clicks on column border
/// dividers to trigger auto-fit column width, and routes clicks on the sort indicator
/// area to sort instead of column select.
private final class AutoFitTableHeaderView: NSTableHeaderView {

    weak var tableViewController: TableViewController?

    /// Width of the clickable sort indicator area on the right side of each header cell.
    private static let sortIndicatorClickWidth: CGFloat = 24

    init(tableViewController: TableViewController) {
        self.tableViewController = tableViewController
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 23))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2 {
            if let columnIndex = columnBorderIndex(at: localPoint) {
                tableViewController?.autoFitColumn(at: columnIndex)
                return
            }
        }

        // Check if click is in the sort indicator area of a sorted column
        if event.clickCount == 1, !event.modifierFlags.contains(.option) {
            if let columnIndex = sortIndicatorColumnIndex(at: localPoint) {
                tableViewController?.handleSortIndicatorClick(columnIndex: columnIndex, event: event)
                return
            }
        }

        super.mouseDown(with: event)
    }

    /// Returns the index of the column whose right-edge border is near the given point,
    /// or nil if the point is not near a column border.
    private func columnBorderIndex(at point: NSPoint) -> Int? {
        guard let tableView = tableView else { return nil }
        let borderThreshold: CGFloat = 4.0

        var xOffset: CGFloat = 0
        for (index, column) in tableView.tableColumns.enumerated() {
            xOffset += column.width + tableView.intercellSpacing.width
            if abs(point.x - xOffset) <= borderThreshold {
                return index
            }
        }
        return nil
    }

    /// Returns the column index if the click point is within the sort indicator area
    /// (rightmost ~24pt) of a currently-sorted column. Returns nil otherwise.
    private func sortIndicatorColumnIndex(at point: NSPoint) -> Int? {
        guard let tableView = tableView,
              let session = tableViewController?.fileSession else { return nil }
        let sortColumns = session.viewState.sortColumns
        guard !sortColumns.isEmpty else { return nil }

        var xOffset: CGFloat = 0
        for (index, column) in tableView.tableColumns.enumerated() {
            let columnRight = xOffset + column.width
            let indicatorLeft = columnRight - Self.sortIndicatorClickWidth

            if point.x >= indicatorLeft && point.x <= columnRight {
                let columnName = column.identifier.rawValue
                if sortColumns.contains(where: { $0.column == columnName }) {
                    return index
                }
            }
            xOffset = columnRight + tableView.intercellSpacing.width
        }
        return nil
    }
}

// MARK: - GridkaContainerView (frame-based layout)

/// A plain NSView that lays out filterBar, searchBar, splitView, and statusBar
/// using frame math — no Auto Layout constraints. This prevents the window from
/// deriving its size from the content's Auto Layout fitting size.
final class GridkaContainerView: NSView {
    var filterBar: NSView!
    var searchBar: NSView!
    var splitView: NSView!
    var statusBar: NSView!

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutChildren()
    }

    func layoutChildren() {
        guard let filterBar, let searchBar, let splitView, let statusBar else { return }
        let w = bounds.width
        let h = bounds.height
        let statusH: CGFloat = 22
        let filterH: CGFloat = filterBar.isHidden ? 0 : (filterBar as? FilterBarView)?.currentHeight ?? 0
        let searchH: CGFloat = searchBar.isHidden ? 0 : (searchBar as? SearchBarView)?.currentHeight ?? 0

        var y: CGFloat = 0
        filterBar.frame = NSRect(x: 0, y: y, width: w, height: filterH)
        y += filterH
        searchBar.frame = NSRect(x: 0, y: y, width: w, height: searchH)
        y += searchH
        statusBar.frame = NSRect(x: 0, y: h - statusH, width: w, height: statusH)

        // Only update splitView.frame when it actually changed.
        // Setting the frame triggers NSSplitView.resizeSubviews() internally,
        // which can redistribute subviews and undo divider positioning.
        let newSplitFrame = NSRect(x: 0, y: y, width: w, height: max(0, h - y - statusH))
        if splitView.frame != newSplitFrame {
            splitView.frame = newSplitFrame
        }
    }
}

// MARK: - NSFont Italic Helper

private extension NSFont {
    var italic: NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - NSImage Tinting Helper

private extension NSImage {
    /// Returns a copy of the image tinted with the specified color.
    func tinted(with color: NSColor) -> NSImage {
        let tinted = self.copy() as! NSImage
        tinted.lockFocus()
        color.set()
        let imageRect = NSRect(origin: .zero, size: tinted.size)
        imageRect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}


// MARK: - RowNumberView

/// Custom view that draws row numbers in the frozen left gutter.
/// Added as a direct subview of NSScrollView, positioned over the left content inset.
/// Uses coordinate conversion from the tableView to position row numbers correctly.
final class RowNumberView: NSView {

    weak var tableView: NSTableView?
    var onRowClicked: ((Int) -> Void)?

    private var visibleRowRange: Range<Int> = 0..<0
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private let textColor = NSColor.secondaryLabelColor
    private let bgColor = NSColor.windowBackgroundColor
    private let borderColor = NSColor.separatorColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func updateVisibleRows() {
        guard let tableView = tableView else { return }
        let visibleRect = tableView.visibleRect
        let range = tableView.rows(in: visibleRect)
        guard range.length > 0 else { return }
        let start = max(0, range.location)
        let end = start + range.length
        visibleRowRange = start..<end
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tableView = tableView else { return }

        // Background
        bgColor.setFill()
        bounds.fill()

        // Right border
        borderColor.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        borderPath.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        borderPath.lineWidth = 1
        borderPath.stroke()

        // Draw row numbers using coordinate conversion
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]

        for row in visibleRowRange {
            let rowRect = tableView.rect(ofRow: row)
            let convertedRect = convert(rowRect, from: tableView)
            let drawRect = NSRect(
                x: 4,
                y: convertedRect.origin.y + 1,
                width: bounds.width - 10,
                height: convertedRect.height
            )
            guard drawRect.intersects(dirtyRect) else { continue }

            let text = "\(row + 1)"
            text.draw(in: drawRect, withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard let tableView = tableView else { return }

        for row in visibleRowRange {
            let rowRect = tableView.rect(ofRow: row)
            let convertedRect = convert(rowRect, from: tableView)
            if localPoint.y >= convertedRect.origin.y && localPoint.y < convertedRect.maxY {
                onRowClicked?(row)
                return
            }
        }
    }
}

// MARK: - Previewer

#Preview {
    TableViewController()
}
