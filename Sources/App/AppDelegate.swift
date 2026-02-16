import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var tableViewController: TableViewController?
    private var emptyStateView: NSView?
    private var fileSession: FileSession?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupMainMenu()
        showEmptyState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
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

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

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

    // MARK: - View Actions

    @objc private func toggleDetailPaneAction(_ sender: Any?) {
        tableViewController?.toggleDetailPane()
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
