import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var tableViewController: TableViewController?
    private var emptyStateView: NSView?
    private var fileSession: FileSession?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if window == nil {
            setupWindow()
            setupMainMenu()
        }
        if tableViewController == nil && fileSession == nil {
            showEmptyState()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // This can be called before applicationDidFinishLaunching when
        // the app is launched via Finder "Open With". Ensure window exists.
        if window == nil {
            setupWindow()
            setupMainMenu()
        }
        let url = URL(fileURLWithPath: filename)
        openFile(at: url)
        return true
    }

    // MARK: - Window Setup

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Gridka"
        window.center()
        window.minSize = NSSize(width: 600, height: 400)

        let contentView = DragDropView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        contentView.onFileDrop = { [weak self] url in
            self?.openFile(at: url)
        }
        window.contentView = contentView

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Gridka", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsAction(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Gridka", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        let copyCellItem = NSMenuItem(title: "Copy Cell", action: #selector(copyCellAction(_:)), keyEquivalent: "c")
        copyCellItem.target = self
        editMenu.addItem(copyCellItem)

        let copyRowItem = NSMenuItem(title: "Copy Row", action: #selector(copyRowAction(_:)), keyEquivalent: "c")
        copyRowItem.keyEquivalentModifierMask = [.command, .shift]
        copyRowItem.target = self
        editMenu.addItem(copyRowItem)

        let copyColumnItem = NSMenuItem(title: "Copy Column", action: #selector(copyColumnAction(_:)), keyEquivalent: "c")
        copyColumnItem.keyEquivalentModifierMask = [.command, .option]
        copyColumnItem.target = self
        editMenu.addItem(copyColumnItem)

        editMenu.addItem(NSMenuItem.separator())

        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())

        let findItem = NSMenuItem(title: "Find…", action: #selector(performFind(_:)), keyEquivalent: "f")
        findItem.target = self
        editMenu.addItem(findItem)

        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(performFindNext(_:)), keyEquivalent: "g")
        findNextItem.target = self
        editMenu.addItem(findNextItem)

        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(performFindPrevious(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.target = self
        editMenu.addItem(findPrevItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let toggleDetailItem = NSMenuItem(title: "Toggle Detail Pane", action: #selector(toggleDetailPaneAction(_:)), keyEquivalent: "d")
        toggleDetailItem.keyEquivalentModifierMask = [.command, .shift]
        toggleDetailItem.target = self
        viewMenu.addItem(toggleDetailItem)

        viewMenu.addItem(NSMenuItem.separator())

        let headerToggleItem = NSMenuItem(title: "First Row as Header", action: #selector(toggleHeaderAction(_:)), keyEquivalent: "")
        headerToggleItem.target = self
        viewMenu.addItem(headerToggleItem)

        let toggleRowNumbersItem = NSMenuItem(title: "Row Numbers", action: #selector(toggleRowNumbersAction(_:)), keyEquivalent: "")
        toggleRowNumbersItem.target = self
        viewMenu.addItem(toggleRowNumbersItem)

        viewMenu.addItem(NSMenuItem.separator())

        let delimiterItem = NSMenuItem(title: "Delimiter", action: nil, keyEquivalent: "")
        let delimiterMenu = NSMenu()
        for (title, delim) in [("Auto-detect", ""), ("Comma (,)", ","), ("Tab (⇥)", "\t"),
                                ("Semicolon (;)", ";"), ("Pipe (|)", "|"), ("Tilde (~)", "~")] {
            let item = NSMenuItem(title: title, action: #selector(changeDelimiterAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = delim
            delimiterMenu.addItem(item)
        }
        delimiterMenu.addItem(NSMenuItem.separator())
        let customItem = NSMenuItem(title: "Custom…", action: #selector(customDelimiterAction(_:)), keyEquivalent: "")
        customItem.target = self
        delimiterMenu.addItem(customItem)
        delimiterItem.submenu = delimiterMenu
        viewMenu.addItem(delimiterItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(showHelpAction(_:)), keyEquivalent: "")
        shortcutsItem.target = self
        helpMenu.addItem(shortcutsItem)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - File Open

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .commaSeparatedText,
            .tabSeparatedText,
            .plainText,
        ]

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFile(at: url)
        }
    }

    // MARK: - File Loading

    private func openFile(at url: URL) {
        do {
            let session = try FileSession(filePath: url)
            self.fileSession = session
            window.title = "Gridka — \(url.lastPathComponent)"

            showTableView()

            // File size for status bar
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let statusBar = tableViewController?.statusBar
            statusBar?.updateFileSize(fileSize)
            statusBar?.updateProgress(0)

            let loadStartTime = CFAbsoluteTimeGetCurrent()

            // Sniff CSV to detect delimiter, encoding, and header presence
            session.sniffCSV { [weak self] in
                guard let self = self else { return }
                statusBar?.updateDelimiter(session.detectedDelimiter)
                statusBar?.updateEncoding(session.detectedEncoding)
            }

            session.loadPreview { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let columns):
                    self.tableViewController?.fileSession = session
                    self.tableViewController?.configureColumns(columns)
                    self.tableViewController?.autoFitAllColumns()

                    // Show preview row count immediately
                    statusBar?.updateRowCount(showing: session.viewState.totalFilteredRows, total: session.viewState.totalFilteredRows)

                    // Start full load in background
                    session.loadFull(progress: { fraction in
                        statusBar?.updateProgress(fraction)
                    }, completion: { [weak self] fullResult in
                        guard let self = self else { return }
                        switch fullResult {
                        case .success(let totalRows):
                            let loadTime = CFAbsoluteTimeGetCurrent() - loadStartTime
                            statusBar?.updateProgress(1.0)
                            statusBar?.updateLoadTime(loadTime)
                            statusBar?.updateRowCount(showing: totalRows, total: totalRows)

                            // Seamless swap: just reassign fileSession (triggers reloadData)
                            // to pick up the new totalFilteredRows. Don't reconfigure columns
                            // since they're the same — this preserves scroll position.
                            self.tableViewController?.fileSession = session
                        case .failure(let error):
                            statusBar?.updateProgress(1.0)
                            self.showError(error, context: "loading full file")
                        }
                    })

                case .failure(let error):
                    self.showError(error, context: "loading file preview")
                    self.showEmptyState()
                }
            }
        } catch {
            showError(error, context: "opening file")
        }
    }

    // MARK: - View Management

    private func showEmptyState() {
        tableViewController?.view.removeFromSuperview()
        tableViewController = nil

        guard let contentView = window.contentView else { return }

        // Use autoresizing mask at the window boundary to prevent
        // Auto Layout from influencing the window size.
        let emptyView = NSView(frame: contentView.bounds)
        emptyView.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "Drop a CSV file or ⌘O to open")
        label.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        emptyView.addSubview(label)
        contentView.addSubview(emptyView)

        // Only use Auto Layout for the label within emptyView.
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor),
        ])

        self.emptyStateView = emptyView
    }

    private func showTableView() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        tableViewController?.view.removeFromSuperview()
        tableViewController = nil

        guard let contentView = window.contentView else { return }

        let tvc = TableViewController()
        // Use autoresizing mask (not Auto Layout) at the window boundary.
        // Auto Layout constraints in the content view hierarchy cause NSWindow
        // to derive its size from the constraints, which collapses the window
        // when internal views have small intrinsic sizes.
        tvc.view.frame = contentView.bounds
        tvc.view.autoresizingMask = [.width, .height]
        contentView.addSubview(tvc.view)

        tvc.onSortChanged = { [weak self] sortColumns in
            self?.handleSortChanged(sortColumns)
        }

        tvc.onFiltersChanged = { [weak self] filters in
            self?.handleFiltersChanged(filters)
        }

        tvc.onSearchChanged = { [weak self] term in
            self?.handleSearchChanged(term)
        }

        self.tableViewController = tvc
    }

    // MARK: - Sort Handling

    private func handleSortChanged(_ sortColumns: [SortColumn]) {
        guard let session = fileSession, let tvc = tableViewController else { return }

        var newState = session.viewState
        newState.sortColumns = sortColumns
        session.updateViewState(newState)

        tvc.updateSortIndicators()

        let sortStartTime = CFAbsoluteTimeGetCurrent()

        // Re-fetch the first visible page after sort
        let firstVisibleRow = max(0, tvc.tableView.rows(in: tvc.tableView.visibleRect).location)
        let pageIndex = session.rowCache.pageIndex(forRow: firstVisibleRow)

        session.fetchPage(index: pageIndex) { [weak self] result in
            guard let self = self else { return }
            let sortTime = CFAbsoluteTimeGetCurrent() - sortStartTime

            switch result {
            case .success:
                tvc.reloadVisibleRows()
                tvc.statusBar.updateRowCount(
                    showing: session.viewState.totalFilteredRows,
                    total: session.viewState.totalFilteredRows
                )
                tvc.statusBar.showQueryTime(sortTime)
            case .failure:
                break
            }
        }

        // Immediately reload to show placeholders for uncached rows
        tvc.reloadVisibleRows()
    }

    // MARK: - Filter Handling

    private func handleFiltersChanged(_ filters: [ColumnFilter]) {
        guard let session = fileSession, let tvc = tableViewController else { return }

        var newState = session.viewState
        newState.filters = filters
        session.updateViewState(newState)

        tvc.updateFilterBar()

        let filterStartTime = CFAbsoluteTimeGetCurrent()

        // Re-fetch page 0 since filters reset the result set
        session.fetchPage(index: 0) { result in
            let filterTime = CFAbsoluteTimeGetCurrent() - filterStartTime

            switch result {
            case .success:
                tvc.reloadVisibleRows()
                tvc.statusBar.showQueryTime(filterTime)
            case .failure:
                break
            }

            // Update row counts — requeryCount runs async, use small delay to let it complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let filtered = session.viewState.totalFilteredRows
                let total = session.totalRows
                tvc.statusBar.updateRowCount(showing: filtered, total: total)
            }
        }

        // Immediately reload to show placeholders for uncached rows
        tvc.reloadVisibleRows()
    }

    // MARK: - Copy Actions

    @objc private func copyCellAction(_ sender: Any?) {
        tableViewController?.copyCellValue(sender)
    }

    @objc private func copyRowAction(_ sender: Any?) {
        tableViewController?.copyRowValues(sender)
    }

    @objc private func copyColumnAction(_ sender: Any?) {
        tableViewController?.copyColumnValues(sender)
    }

    // MARK: - Settings

    @objc private func showSettingsAction(_ sender: Any?) {
        SettingsWindowController.showSettings()
    }

    // MARK: - View Actions

    @objc private func toggleDetailPaneAction(_ sender: Any?) {
        tableViewController?.toggleDetailPane()
    }

    // MARK: - Header Toggle

    @objc private func toggleHeaderAction(_ sender: Any?) {
        guard let session = fileSession, let tvc = tableViewController else { return }
        guard session.isFullyLoaded else { return }

        let newValue = !session.hasHeaders

        tvc.statusBar.updateProgress(0)

        session.reload(withHeaders: newValue, progress: { [weak self] fraction in
            self?.tableViewController?.statusBar.updateProgress(fraction)
        }, completion: { [weak self] result in
            guard let self = self, let tvc = self.tableViewController else { return }
            switch result {
            case .success(let totalRows):
                tvc.statusBar.updateProgress(1.0)
                tvc.statusBar.updateRowCount(showing: totalRows, total: totalRows)
                tvc.fileSession = session
                tvc.configureColumns(session.columns)
                tvc.autoFitAllColumns()
            case .failure(let error):
                tvc.statusBar.updateProgress(1.0)
                self.showError(error, context: "reloading file")
            }
        })
    }

    // MARK: - Row Numbers Toggle

    @objc private func toggleRowNumbersAction(_ sender: Any?) {
        tableViewController?.toggleRowNumbers()
    }

    // MARK: - Delimiter

    @objc private func changeDelimiterAction(_ sender: NSMenuItem) {
        guard let delim = sender.representedObject as? String else { return }
        let newDelimiter: String? = delim.isEmpty ? nil : delim
        reloadWithDelimiter(newDelimiter)
    }

    @objc private func customDelimiterAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Custom Delimiter"
        alert.informativeText = "Enter a single character to use as the column delimiter:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "e.g. ~ or | or ;"
        alert.accessoryView = input

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let text = input.stringValue
            guard !text.isEmpty else { return }
            // Use the first character (or the full string for multi-char delimiters)
            self?.reloadWithDelimiter(text)
        }
    }

    private func reloadWithDelimiter(_ delimiter: String?) {
        guard let session = fileSession, let tvc = tableViewController else { return }
        guard session.isFullyLoaded else { return }

        tvc.statusBar.updateProgress(0)

        session.reload(withDelimiter: delimiter, progress: { [weak self] fraction in
            self?.tableViewController?.statusBar.updateProgress(fraction)
        }, completion: { [weak self] result in
            guard let self = self, let tvc = self.tableViewController else { return }
            switch result {
            case .success(let totalRows):
                tvc.statusBar.updateProgress(1.0)
                tvc.statusBar.updateRowCount(showing: totalRows, total: totalRows)
                tvc.statusBar.updateDelimiter(session.effectiveDelimiter)
                tvc.fileSession = session
                tvc.configureColumns(session.columns)
                tvc.autoFitAllColumns()
            case .failure(let error):
                tvc.statusBar.updateProgress(1.0)
                self.showError(error, context: "reloading with delimiter")
            }
        })
    }

    // MARK: - Search Handling

    @objc private func performFind(_ sender: Any?) {
        tableViewController?.toggleSearchBar()
    }

    @objc private func performFindNext(_ sender: Any?) {
        guard let tvc = tableViewController, tvc.searchBar.isVisible else { return }
        tvc.searchBar.onNavigate?(1)
    }

    @objc private func performFindPrevious(_ sender: Any?) {
        guard let tvc = tableViewController, tvc.searchBar.isVisible else { return }
        tvc.searchBar.onNavigate?(-1)
    }

    private func handleSearchChanged(_ term: String) {
        guard let session = fileSession, let tvc = tableViewController else { return }

        // Only allow search when fully loaded
        guard session.isFullyLoaded else { return }

        var newState = session.viewState
        newState.searchTerm = term.isEmpty ? nil : term
        session.updateViewState(newState)

        let searchStartTime = CFAbsoluteTimeGetCurrent()

        // Re-fetch page 0 since search resets the result set
        session.fetchPage(index: 0) { result in
            let searchTime = CFAbsoluteTimeGetCurrent() - searchStartTime

            switch result {
            case .success:
                tvc.reloadVisibleRows()
                tvc.statusBar.showQueryTime(searchTime)
            case .failure:
                break
            }

            // Update row counts after requeryCount completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let filtered = session.viewState.totalFilteredRows
                let total = session.totalRows
                tvc.statusBar.updateRowCount(showing: filtered, total: total)
                tvc.searchBar.updateMatchCount(filtered)
            }
        }

        // Immediately reload to show placeholders
        tvc.reloadVisibleRows()
    }

    // MARK: - Help

    @objc private func showHelpAction(_ sender: Any?) {
        HelpWindowController.showHelp()
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleHeaderAction(_:)) {
            menuItem.state = (fileSession?.hasHeaders ?? true) ? .on : .off
            return fileSession?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(toggleRowNumbersAction(_:)) {
            menuItem.state = (tableViewController?.isRowNumbersVisible ?? false) ? .on : .off
            return tableViewController != nil
        }
        if menuItem.action == #selector(changeDelimiterAction(_:)) {
            guard let delim = menuItem.representedObject as? String else { return false }
            let effective = fileSession?.customDelimiter
            if delim.isEmpty {
                // "Auto-detect" is checked when no custom delimiter is set
                menuItem.state = (effective == nil) ? .on : .off
            } else {
                menuItem.state = (effective == delim) ? .on : .off
            }
            return fileSession?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(customDelimiterAction(_:)) {
            // Check if current delimiter is a custom one not in the standard list
            if let effective = fileSession?.customDelimiter,
               ![",", "\t", ";", "|", "~"].contains(effective) {
                menuItem.state = .on
            } else {
                menuItem.state = .off
            }
            return fileSession?.isFullyLoaded ?? false
        }
        return true
    }

    // MARK: - Error Handling

    private func showError(_ error: Error, context: String) {
        let alert = NSAlert()
        alert.messageText = "Error \(context)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
