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

    // MARK: - Number Formatters

    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.usesGroupingSeparator = true
        return f
    }()

    private static let floatFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
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
        tableView.allowsMultipleSelection = false
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

        splitView.addArrangedSubview(scrollView)
        splitView.addArrangedSubview(detailPane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.delegate = self

        // Add children to container — GridkaContainerView handles layout
        container.filterBar = filterBar
        container.searchBar = searchBar
        container.splitView = splitView
        container.statusBar = statusBar
        container.addSubview(filterBar)
        container.addSubview(searchBar)
        container.addSubview(splitView)
        container.addSubview(statusBar)

        self.view = container

        // Observe scroll position changes for pre-fetching
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if needsInitialDividerPosition {
            let h = splitView.bounds.height
            if h > 120 {
                needsInitialDividerPosition = false
                splitView.setPosition(h - 120, ofDividerAt: 0)
            }
        }
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

    /// Updates column header titles to reflect current sort state.
    func updateSortIndicators() {
        guard let session = fileSession else { return }
        let sortColumns = session.viewState.sortColumns
        let isMultiSort = sortColumns.count > 1

        for tableColumn in tableView.tableColumns {
            let columnName = tableColumn.identifier.rawValue
            guard let descriptor = session.columns.first(where: { $0.name == columnName }) else { continue }
            let typeStr = typeLabel(for: descriptor.displayType)

            if let sortIndex = sortColumns.firstIndex(where: { $0.column == columnName }) {
                let sort = sortColumns[sortIndex]
                let arrow = sort.direction == .ascending ? "\u{25B2}" : "\u{25BC}"
                if isMultiSort {
                    tableColumn.title = "\(descriptor.name) (\(typeStr)) \(sortIndex + 1)\(arrow)"
                } else {
                    tableColumn.title = "\(descriptor.name) (\(typeStr)) \(arrow)"
                }
            } else {
                tableColumn.title = "\(descriptor.name) (\(typeStr))"
            }
            styleHeaderCell(tableColumn.headerCell, descriptor: descriptor)
        }
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

    private func showFilterPopover(for column: ColumnDescriptor, relativeTo view: NSView) {
        let popoverVC = FilterPopoverViewController(column: column)
        popoverVC.onApply = { [weak self] newFilter in
            self?.addFilter(newFilter)
        }

        let popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
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

    // MARK: - Scroll Pre-fetching

    @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
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

    private func updateDetailPane() {
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

        selectedRow = clickedRow
        selectedColumnName = tableView.tableColumns[clickedCol].identifier.rawValue
        updateDetailPane()
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

    private func makeTableColumn(for descriptor: ColumnDescriptor) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(descriptor.name))
        column.title = "\(descriptor.name) (\(typeLabel(for: descriptor.displayType)))"
        column.width = widthForColumn(descriptor)
        column.minWidth = 50
        column.maxWidth = 2000

        styleHeaderCell(column.headerCell, descriptor: descriptor)

        return column
    }

    /// Applies bold font and numeric right-alignment to a header cell via attributed string.
    private func styleHeaderCell(_ headerCell: NSTableHeaderCell, descriptor: ColumnDescriptor) {
        let isNumeric = descriptor.displayType == .integer || descriptor.displayType == .float
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = isNumeric ? .right : .left
        paragraphStyle.lineBreakMode = .byTruncatingTail

        headerCell.attributedStringValue = NSAttributedString(
            string: headerCell.stringValue,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraphStyle,
            ]
        )
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
            let text = TableViewController.integerFormatter.string(from: NSNumber(value: v)) ?? String(v)
            return NSAttributedString(string: text, attributes: attrs)
        case .double(let v):
            let text = TableViewController.floatFormatter.string(from: NSNumber(value: v)) ?? String(v)
            return NSAttributedString(string: text, attributes: attrs)
        case .boolean(let v):
            return NSAttributedString(string: v ? "true" : "false", attributes: attrs)
        case .date(let v):
            return NSAttributedString(string: v, attributes: attrs)
        case .string(let v):
            return NSAttributedString(string: v, attributes: attrs)
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

        var sortColumns = session.viewState.sortColumns
        let isShiftHeld = NSEvent.modifierFlags.contains(.shift)

        if let existingIndex = sortColumns.firstIndex(where: { $0.column == columnName }) {
            let current = sortColumns[existingIndex]
            switch current.direction {
            case .ascending:
                // Second click: switch to descending
                sortColumns[existingIndex] = SortColumn(column: columnName, direction: .descending)
            case .descending:
                // Third click: remove sort
                sortColumns.remove(at: existingIndex)
            }
        } else {
            if isShiftHeld {
                // Shift+click: add as secondary/tertiary sort key
                sortColumns.append(SortColumn(column: columnName, direction: .ascending))
            } else {
                // Regular click: replace all sorts with this column ascending
                sortColumns = [SortColumn(column: columnName, direction: .ascending)]
            }
        }

        onSortChanged?(sortColumns)
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
        updateDetailPane()

        let copyCell = NSMenuItem(title: "Copy Cell", action: #selector(copyCellValue(_:)), keyEquivalent: "")
        copyCell.target = self
        menu.addItem(copyCell)

        let copyRow = NSMenuItem(title: "Copy Row", action: #selector(copyRowValues(_:)), keyEquivalent: "")
        copyRow.target = self
        menu.addItem(copyRow)

        let copyHeaders = NSMenuItem(title: "Copy with Headers", action: #selector(copyWithHeaders(_:)), keyEquivalent: "")
        copyHeaders.target = self
        menu.addItem(copyHeaders)
    }

    @objc private func filterColumnClicked(_ sender: NSMenuItem) {
        guard let columnName = sender.representedObject as? String,
              let session = fileSession,
              let descriptor = session.columns.first(where: { $0.name == columnName }) else { return }

        guard let headerView = tableView.headerView else { return }
        let columnIndex = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(columnName))
        guard columnIndex >= 0 else { return }

        showFilterPopover(for: descriptor, relativeTo: headerView)
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
}

// MARK: - AutoFitTableHeaderView

/// Custom NSTableHeaderView subclass that detects double-clicks on column border
/// dividers to trigger auto-fit column width.
private final class AutoFitTableHeaderView: NSTableHeaderView {

    weak var tableViewController: TableViewController?

    init(tableViewController: TableViewController) {
        self.tableViewController = tableViewController
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 23))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let localPoint = convert(event.locationInWindow, from: nil)
            if let columnIndex = columnBorderIndex(at: localPoint) {
                tableViewController?.autoFitColumn(at: columnIndex)
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

    override func layout() {
        super.layout()
        layoutChildren()
    }

    private func layoutChildren() {
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
        splitView.frame = NSRect(x: 0, y: y, width: w, height: max(0, h - y - statusH))
    }
}

// MARK: - NSFont Italic Helper

private extension NSFont {
    var italic: NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}


// MARK: - Previewer

#Preview {
    TableViewController()
}
