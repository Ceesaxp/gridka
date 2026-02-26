import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    // MARK: - Tab/Window Management

    /// Maps each NSWindow to its TabContext. Each "tab" is a separate NSWindow
    /// grouped via NSWindow's native tab bar (tabbingMode = .preferred).
    private var windowTabs: [NSWindow: TabContext] = [:]

    /// Windows that are being closed programmatically after a save prompt.
    /// Used to bypass windowShouldClose when we've already handled the prompt.
    private var windowsClosingAfterPrompt: Set<NSWindow> = []


    /// Total memory budget for all DuckDB engines: 50% of physical RAM.
    private let totalMemoryBudget: UInt64 = ProcessInfo.processInfo.physicalMemory / 2

    /// The currently active window. Updated by NSWindowDelegate callbacks.
    private var activeWindow: NSWindow? {
        return NSApp.keyWindow ?? NSApp.mainWindow ?? windowTabs.keys.first
    }

    /// Safely returns the active tab context for the key window.
    private var activeTab: TabContext? {
        guard let win = activeWindow else { return nil }
        return windowTabs[win]
    }

    /// Convenience: returns the window for a given tab context.
    private func window(for tab: TabContext) -> NSWindow? {
        return windowTabs.first(where: { $0.value === tab })?.key
    }

    /// Finds the tab context that owns a given TableViewController.
    private func tab(for tvc: TableViewController) -> TabContext? {
        return windowTabs.values.first(where: { $0.tableViewController === tvc })
    }

    private func tab(for session: FileSession) -> TabContext? {
        return windowTabs.values.first(where: { $0.fileSession === session })
    }

    // MARK: - Memory Rebalancing

    /// Rebalances DuckDB memory limits across all open tabs.
    /// Total budget (50% of RAM) is divided equally among tabs with active file sessions.
    private func rebalanceMemoryLimits() {
        let sessionsWithEngines = windowTabs.values.compactMap { $0.fileSession }
        guard !sessionsWithEngines.isEmpty else { return }

        let perTabLimit = totalMemoryBudget / UInt64(sessionsWithEngines.count)
        for session in sessionsWithEngines {
            session.updateMemoryLimit(perTabLimit)
        }
    }

    /// Number of open tab windows (including empty tabs).
    private var tabCount: Int {
        return windowTabs.count
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        // Sync toolbar button across all tabs when frequency panel closes
        FrequencyPanelController.onClose = { [weak self] in
            guard let self = self else { return }
            for tab in self.windowTabs.values {
                tab.tableViewController?.analysisBar.setFeatureActive(.frequency, active: false)
            }
        }

        // US-013: Click-to-filter from frequency view
        // Single-click a value → add filter (column = value), panel stays open
        FrequencyPanelController.onValueClicked = { [weak self] columnName, value, session in
            self?.applyFrequencyFilter(columnName: columnName, value: value, session: session)
        }

        // Double-click a value → add filter AND close the frequency panel
        FrequencyPanelController.onValueDoubleClicked = { [weak self] columnName, value, session in
            self?.applyFrequencyFilter(columnName: columnName, value: value, session: session)
            FrequencyPanelController.closeIfOpen()
        }

        // US-017: Sync toolbar button when computed column panel closes
        ComputedColumnPanelController.onClose = { [weak self] in
            guard let self = self else { return }
            for tab in self.windowTabs.values {
                tab.tableViewController?.analysisBar.setFeatureActive(.computedColumn, active: false)
            }
        }

        // US-019: Add computed column to table when user confirms
        ComputedColumnPanelController.onAddColumn = { [weak self] name, expression, session in
            self?.handleComputedColumnAdded(name: name, expression: expression, session: session)
        }

        if windowTabs.isEmpty {
            let win = createWindow()
            let tab = TabContext()
            windowTabs[win] = tab
            showEmptyState(in: win, tab: tab)
            win.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // This can be called before applicationDidFinishLaunching when
        // the app is launched via Finder "Open With". Ensure menu exists.
        if NSApp.mainMenu == nil {
            setupMainMenu()
        }
        let url = URL(fileURLWithPath: filename)

        // If we have a key window with an empty tab, open there
        if let win = activeWindow, let tab = windowTabs[win], tab.isEmptyState {
            openFile(at: url, in: win, tab: tab)
            return true
        }

        // Otherwise open in a new tab
        openFileInNewTab(url)
        return true
    }

    // MARK: - Window Factory

    /// Creates a new NSWindow configured for tabbing.
    private func createWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.title = "Gridka"
        win.center()
        win.minSize = NSSize(width: 600, height: 400)
        win.tabbingMode = .preferred
        win.delegate = self

        let contentView = DragDropView(frame: win.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        contentView.onFileDrop = { [weak self, weak win] url in
            guard let self = self, let win = win else { return }
            self.openFileInNewTab(url, relativeTo: win)
        }
        win.contentView = contentView

        return win
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
        let saveItem = NSMenuItem(title: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)
        let saveAsItem = NSMenuItem(title: "Save As…", action: #selector(saveAsDocument(_:)), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(NSMenuItem.separator())
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTabAction(_:)), keyEquivalent: "t")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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

        let addColumnItem = NSMenuItem(title: "Add Column…", action: #selector(addColumnAction(_:)), keyEquivalent: "n")
        addColumnItem.keyEquivalentModifierMask = [.command, .option]
        addColumnItem.target = self
        editMenu.addItem(addColumnItem)

        let renameColumnItem = NSMenuItem(title: "Rename Column…", action: #selector(renameColumnAction(_:)), keyEquivalent: "")
        renameColumnItem.target = self
        editMenu.addItem(renameColumnItem)

        let deleteColumnItem = NSMenuItem(title: "Delete Column", action: #selector(deleteColumnAction(_:)), keyEquivalent: "")
        deleteColumnItem.target = self
        editMenu.addItem(deleteColumnItem)

        let computedColumnItem = NSMenuItem(title: "Add Computed Column…", action: #selector(addComputedColumnAction(_:)), keyEquivalent: "f")
        computedColumnItem.keyEquivalentModifierMask = [.command, .option]
        computedColumnItem.target = self
        editMenu.addItem(computedColumnItem)

        editMenu.addItem(NSMenuItem.separator())

        let addRowItem = NSMenuItem(title: "Add Row", action: #selector(addRowAction(_:)), keyEquivalent: "r")
        addRowItem.keyEquivalentModifierMask = [.command, .option]
        addRowItem.target = self
        editMenu.addItem(addRowItem)

        let deleteRowItem = NSMenuItem(title: "Delete Row(s)", action: #selector(deleteRowsAction(_:)), keyEquivalent: "\u{08}")
        deleteRowItem.keyEquivalentModifierMask = [.command]
        deleteRowItem.target = self
        editMenu.addItem(deleteRowItem)

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

        let toggleAnalysisItem = NSMenuItem(title: "Show Analysis Toolbar", action: #selector(toggleAnalysisToolbarAction(_:)), keyEquivalent: "t")
        toggleAnalysisItem.keyEquivalentModifierMask = [.command, .option]
        toggleAnalysisItem.target = self
        viewMenu.addItem(toggleAnalysisItem)

        let toggleProfilerItem = NSMenuItem(title: "Toggle Column Profiler", action: #selector(toggleProfilerAction(_:)), keyEquivalent: "p")
        toggleProfilerItem.keyEquivalentModifierMask = [.command, .shift]
        toggleProfilerItem.target = self
        viewMenu.addItem(toggleProfilerItem)

        viewMenu.addItem(NSMenuItem.separator())

        let headerToggleItem = NSMenuItem(title: "First Row as Header", action: #selector(toggleHeaderAction(_:)), keyEquivalent: "")
        headerToggleItem.target = self
        viewMenu.addItem(headerToggleItem)

        let toggleRowNumbersItem = NSMenuItem(title: "Row Numbers", action: #selector(toggleRowNumbersAction(_:)), keyEquivalent: "")
        toggleRowNumbersItem.target = self
        viewMenu.addItem(toggleRowNumbersItem)

        viewMenu.addItem(NSMenuItem.separator())

        let encodingItem = NSMenuItem(title: "Encoding", action: nil, keyEquivalent: "")
        let encodingMenu = NSMenu()
        for (title, encName) in [("UTF-8", "UTF-8"), ("UTF-16 LE", "UTF-16 LE"), ("UTF-16 BE", "UTF-16 BE"),
                                  ("Latin-1 (ISO-8859-1)", "Latin-1 (ISO-8859-1)"), ("Windows-1252", "Windows-1252"),
                                  ("ASCII", "ASCII"), ("Shift-JIS", "Shift-JIS"), ("EUC-KR", "EUC-KR"),
                                  ("GB2312", "GB2312"), ("Big5", "Big5")] {
            let item = NSMenuItem(title: title, action: #selector(changeEncodingAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = encName
            encodingMenu.addItem(item)
        }
        encodingItem.submenu = encodingMenu
        viewMenu.addItem(encodingItem)

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

    // MARK: - New Tab

    @objc private func newTabAction(_ sender: Any?) {
        guard let parentWindow = activeWindow else { return }

        // Show warning when opening a 10th tab
        if tabCount >= 9 {
            let alert = NSAlert()
            alert.messageText = "You have \(tabCount + 1) tabs open."
            alert.informativeText = "This may increase memory usage significantly. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            alert.beginSheetModal(for: parentWindow) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.createEmptyTab(relativeTo: parentWindow)
            }
            return
        }

        createEmptyTab(relativeTo: parentWindow)
    }

    /// Creates a new empty tab window.
    private func createEmptyTab(relativeTo parentWindow: NSWindow) {
        let newWin = createWindow()
        let newTab = TabContext()
        windowTabs[newWin] = newTab
        showEmptyState(in: newWin, tab: newTab)
        newWin.title = "Untitled"

        parentWindow.addTabbedWindow(newWin, ordered: .above)
        newWin.makeKeyAndOrderFront(nil)
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

        guard let win = activeWindow else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, let url = panel.url else { return }
            self.openFileInNewTab(url, relativeTo: win)
        }
    }

    /// Opens a file in a new tab window, grouped with `relativeTo` window.
    /// If `relativeTo` is nil, uses the current active window.
    private func openFileInNewTab(_ url: URL, relativeTo: NSWindow? = nil) {
        let parentWindow = relativeTo ?? activeWindow

        // If the parent window's tab is empty, reuse it
        if let parentWindow = parentWindow, let tab = windowTabs[parentWindow], tab.isEmptyState {
            openFile(at: url, in: parentWindow, tab: tab)
            return
        }

        // Show warning when opening a 10th tab
        if tabCount >= 9 {
            let alert = NSAlert()
            alert.messageText = "You have \(tabCount + 1) tabs open."
            alert.informativeText = "This may increase memory usage significantly. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            if let parentWindow = parentWindow {
                alert.beginSheetModal(for: parentWindow) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    self?.createTabAndOpenFile(url, relativeTo: parentWindow)
                }
                return
            }
        }

        createTabAndOpenFile(url, relativeTo: parentWindow)
    }

    /// Creates a new tab window and opens a file in it.
    private func createTabAndOpenFile(_ url: URL, relativeTo parentWindow: NSWindow?) {
        let newWin = createWindow()
        let newTab = TabContext()
        windowTabs[newWin] = newTab

        if let parentWindow = parentWindow {
            parentWindow.addTabbedWindow(newWin, ordered: .above)
        }
        newWin.makeKeyAndOrderFront(nil)

        openFile(at: url, in: newWin, tab: newTab)
    }

    // MARK: - Save

    @objc private func saveDocument(_ sender: Any?) {
        guard let session = activeTab?.fileSession, session.isModified else { return }

        session.save { [weak self] result in
            switch result {
            case .success:
                break
            case .failure(let error):
                self?.showError(error, context: "saving file")
            }
        }
    }

    // MARK: - Save As

    @objc private func saveAsDocument(_ sender: Any?) {
        guard let session = activeTab?.fileSession, session.isFullyLoaded else { return }
        guard let win = activeWindow else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.filePath.lastPathComponent
        panel.allowedContentTypes = [
            .commaSeparatedText,
            .tabSeparatedText,
            .plainText,
        ]

        let accessory = SavePanelAccessoryView(
            detectedEncoding: session.detectedEncoding,
            currentDelimiter: session.effectiveDelimiter
        )
        panel.accessoryView = accessory

        panel.beginSheetModal(for: win) { [weak self, weak win] response in
            guard response == .OK, let url = panel.url else { return }

            let encoding = accessory.selectedEncoding
            let delimiter = accessory.selectedDelimiter

            session.saveAs(to: url, encoding: encoding, delimiter: delimiter) { [weak self, weak win] result in
                guard self != nil, let win = win else { return }
                switch result {
                case .success:
                    win.title = url.lastPathComponent
                    win.subtitle = url.deletingLastPathComponent().path
                case .failure(let error):
                    self?.showError(error, context: "saving file")
                }
            }
        }
    }

    // MARK: - File Loading

    private func openFile(at url: URL, in win: NSWindow, tab: TabContext) {
        do {
            let session = try FileSession(filePath: url)
            tab.fileSession = session
            win.title = url.lastPathComponent
            win.subtitle = url.deletingLastPathComponent().path

            // Track document-edited state via window dirty dot
            session.onModifiedChanged = { [weak win] modified in
                win?.isDocumentEdited = modified
            }

            // Wire sparkline refresh when column summaries are computed (US-015)
            session.onSummariesComputed = { [weak tab] in
                tab?.tableViewController?.updateSparklines()
            }

            showTableView(in: win, tab: tab)

            let tvc = tab.tableViewController

            // File size for status bar
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let statusBar = tvc?.statusBar
            statusBar?.updateFileSize(fileSize)
            statusBar?.updateProgress(0)

            let loadStartTime = CFAbsoluteTimeGetCurrent()

            // Sniff CSV to detect delimiter, encoding, and header presence
            session.sniffCSV {
                statusBar?.updateDelimiter(session.detectedDelimiter)
                statusBar?.updateEncoding(session.detectedEncoding)
            }

            session.loadPreview { [weak self, weak win] result in
                guard let self = self, let win = win else { return }
                let currentTvc = tab.tableViewController
                switch result {
                case .success(let columns):
                    currentTvc?.fileSession = session
                    currentTvc?.configureColumns(columns)
                    currentTvc?.autoFitAllColumns()

                    // Show preview row count immediately
                    statusBar?.updateRowCount(showing: session.viewState.totalFilteredRows, total: session.viewState.totalFilteredRows)

                    // Start full load in background
                    session.loadFull(progress: { fraction in
                        statusBar?.updateProgress(fraction)
                    }, completion: { [weak self] fullResult in
                        guard let self = self else { return }
                        let currentTvc = tab.tableViewController
                        switch fullResult {
                        case .success(let totalRows):
                            let loadTime = CFAbsoluteTimeGetCurrent() - loadStartTime
                            statusBar?.updateProgress(1.0)
                            statusBar?.updateLoadTime(loadTime)
                            statusBar?.updateRowCount(showing: totalRows, total: totalRows)

                            // Seamless swap: just reassign fileSession (triggers reloadData)
                            // to pick up the new totalFilteredRows. Don't reconfigure columns
                            // since they're the same — this preserves scroll position.
                            currentTvc?.fileSession = session

                            // Rebalance memory across all tabs now that this tab has an active engine
                            self.rebalanceMemoryLimits()

                            // Compute column summaries in background for sparklines (US-014)
                            session.computeColumnSummaries()
                        case .failure(let error):
                            statusBar?.updateProgress(1.0)
                            self.showError(error, context: "loading full file")
                        }
                    })

                case .failure(let error):
                    self.showError(error, context: "loading file preview")
                    self.showEmptyState(in: win, tab: tab)
                }
            }
        } catch {
            showError(error, context: "opening file")
        }
    }

    // MARK: - View Management

    private func showEmptyState(in win: NSWindow, tab: TabContext) {
        tab.containerView?.removeFromSuperview()
        tab.tableViewController?.view.removeFromSuperview()
        tab.tableViewController = nil

        guard let contentView = win.contentView else { return }

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

        tab.emptyStateView = emptyView
        tab.containerView = emptyView
    }

    private func showTableView(in win: NSWindow, tab: TabContext) {
        tab.containerView?.removeFromSuperview()
        tab.emptyStateView?.removeFromSuperview()
        tab.emptyStateView = nil
        tab.tableViewController?.view.removeFromSuperview()
        tab.tableViewController = nil

        guard let contentView = win.contentView else { return }

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

        tvc.onCellEdited = { [weak self, weak tvc] rowid, columnName, newValue, displayRow in
            guard let self = self, let tvc = tvc, let tab = self.tab(for: tvc) else { return }
            self.handleCellEdited(tab: tab, rowid: rowid, columnName: columnName, newValue: newValue, displayRow: displayRow)
        }

        tvc.onColumnRenamed = { [weak self, weak tvc] oldName, newName in
            guard let self = self, let tvc = tvc, let tab = self.tab(for: tvc) else { return }
            self.handleColumnRenamed(tab: tab, oldName: oldName, newName: newName)
        }

        tvc.onColumnTypeChanged = { [weak self, weak tvc] columnName, duckDBType in
            guard let self = self, let tvc = tvc, let tab = self.tab(for: tvc) else { return }
            self.handleColumnTypeChanged(tab: tab, columnName: columnName, duckDBType: duckDBType)
        }

        tvc.onColumnDeleted = { [weak self, weak tvc] columnName in
            guard let self = self, let tvc = tvc, let tab = self.tab(for: tvc) else { return }
            self.handleColumnDeleted(tab: tab, columnName: columnName)
        }

        tvc.onComputedColumnRemoved = { [weak self, weak tvc] columnName in
            guard let self = self, let tvc = tvc, let tab = self.tab(for: tvc) else { return }
            self.handleComputedColumnRemoved(tab: tab, columnName: columnName)
        }

        tvc.onValueFrequency = { [weak tvc] columnName in
            guard let tvc = tvc, let session = tvc.fileSession else { return }
            FrequencyPanelController.show(column: columnName, fileSession: session)
            tvc.analysisBar.setFeatureActive(.frequency, active: FrequencyPanelController.isVisible)
        }

        tvc.onColumnSelected = { [weak self, weak tvc] columnName in
            guard let self = self, let tvc = tvc, let tab = self.tab(for: tvc) else { return }
            self.handleColumnSelected(tab: tab, columnName: columnName)
        }

        tvc.onSparklineClicked = { [weak self, weak tvc] columnName in
            guard let self = self, let tvc = tvc, let tab = self.tab(for: tvc) else { return }
            // Select the column
            self.handleColumnSelected(tab: tab, columnName: columnName)
            // Open the profiler sidebar if not already open
            if !tvc.isProfilerVisible {
                tvc.toggleProfilerSidebar()
            }
        }

        tvc.onAnalysisFeatureToggled = { [weak self, weak tvc] feature, isActive in
            guard let self = self, let tvc = tvc, let tab = self.tab(for: tvc) else { return }
            self.handleAnalysisFeatureToggled(tab: tab, feature: feature, isActive: isActive)
        }

        tab.tableViewController = tvc
        tab.containerView = tvc.view
    }

    // MARK: - Sort Handling

    private func handleSortChanged(_ sortColumns: [SortColumn]) {
        guard let session = activeTab?.fileSession, let tvc = activeTab?.tableViewController else { return }

        var newState = session.viewState
        newState.sortColumns = sortColumns
        session.updateViewState(newState)

        tvc.updateSortIndicators()

        let sortStartTime = CFAbsoluteTimeGetCurrent()

        // Re-fetch the first visible page after sort
        let firstVisibleRow = max(0, tvc.tableView.rows(in: tvc.tableView.visibleRect).location)
        let pageIndex = session.rowCache.pageIndex(forRow: firstVisibleRow)

        session.fetchPage(index: pageIndex) { [weak self] result in
            guard self != nil else { return }
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

    /// Applies an equals filter from the frequency panel to the panel's owning session.
    /// Uses the session passed from the panel (not activeTab) to target the correct tab.
    private func applyFrequencyFilter(columnName: String, value: String, session: FileSession) {
        guard let tab = tab(for: session), let tvc = tab.tableViewController else { return }
        var filters = session.viewState.filters
        filters.removeAll { $0.column == columnName }
        filters.append(ColumnFilter(column: columnName, operator: .equals, value: .string(value)))

        var newState = session.viewState
        newState.filters = filters
        session.updateViewState(newState)

        tvc.updateFilterBar()
        tvc.updateProfilerSidebar()

        let filterStartTime = CFAbsoluteTimeGetCurrent()

        session.fetchPage(index: 0) { result in
            let filterTime = CFAbsoluteTimeGetCurrent() - filterStartTime

            switch result {
            case .success:
                tvc.reloadVisibleRows()
                tvc.statusBar.showQueryTime(filterTime)
            case .failure:
                break
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let filtered = session.viewState.totalFilteredRows
                let total = session.totalRows
                tvc.statusBar.updateRowCount(showing: filtered, total: total)
            }
        }

        tvc.reloadVisibleRows()
    }

    private func handleFiltersChanged(_ filters: [ColumnFilter]) {
        guard let session = activeTab?.fileSession, let tvc = activeTab?.tableViewController else { return }

        var newState = session.viewState
        newState.filters = filters
        session.updateViewState(newState)

        tvc.updateFilterBar()
        tvc.updateProfilerSidebar()

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
        activeTab?.tableViewController?.copyCellValue(sender)
    }

    @objc private func copyRowAction(_ sender: Any?) {
        activeTab?.tableViewController?.copyRowValues(sender)
    }

    @objc private func copyColumnAction(_ sender: Any?) {
        activeTab?.tableViewController?.copyColumnValues(sender)
    }

    // MARK: - Settings

    @objc private func showSettingsAction(_ sender: Any?) {
        SettingsWindowController.showSettings()
    }

    // MARK: - View Actions

    @objc private func toggleDetailPaneAction(_ sender: Any?) {
        activeTab?.tableViewController?.toggleDetailPane()
    }

    @objc private func toggleAnalysisToolbarAction(_ sender: Any?) {
        activeTab?.tableViewController?.toggleAnalysisToolbar()
    }

    @objc private func toggleProfilerAction(_ sender: Any?) {
        activeTab?.tableViewController?.toggleProfilerSidebar()
    }

    // MARK: - Header Toggle

    @objc private func toggleHeaderAction(_ sender: Any?) {
        guard let session = activeTab?.fileSession, let tvc = activeTab?.tableViewController else { return }
        guard session.isFullyLoaded else { return }

        let newValue = !session.hasHeaders

        tvc.statusBar.updateProgress(0)

        session.reload(withHeaders: newValue, progress: { [weak self] fraction in
            self?.activeTab?.tableViewController?.statusBar.updateProgress(fraction)
        }, completion: { [weak self] result in
            guard let self = self, let tvc = self.activeTab?.tableViewController else { return }
            switch result {
            case .success(let totalRows):
                tvc.statusBar.updateProgress(1.0)
                tvc.statusBar.updateRowCount(showing: totalRows, total: totalRows)
                tvc.fileSession = session
                tvc.configureColumns(session.columns)
                tvc.autoFitAllColumns()
                session.computeColumnSummaries()
            case .failure(let error):
                tvc.statusBar.updateProgress(1.0)
                self.showError(error, context: "reloading file")
            }
        })
    }

    // MARK: - Row Numbers Toggle

    @objc private func toggleRowNumbersAction(_ sender: Any?) {
        activeTab?.tableViewController?.toggleRowNumbers()
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

        guard let win = activeWindow else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let text = input.stringValue
            guard !text.isEmpty else { return }
            // Use the first character (or the full string for multi-char delimiters)
            self?.reloadWithDelimiter(text)
        }
    }

    private func reloadWithDelimiter(_ delimiter: String?) {
        guard let session = activeTab?.fileSession, let tvc = activeTab?.tableViewController else { return }
        guard session.isFullyLoaded else { return }

        tvc.statusBar.updateProgress(0)

        session.reload(withDelimiter: delimiter, progress: { [weak self] fraction in
            self?.activeTab?.tableViewController?.statusBar.updateProgress(fraction)
        }, completion: { [weak self] result in
            guard let self = self, let tvc = self.activeTab?.tableViewController else { return }
            switch result {
            case .success(let totalRows):
                tvc.statusBar.updateProgress(1.0)
                tvc.statusBar.updateRowCount(showing: totalRows, total: totalRows)
                tvc.statusBar.updateDelimiter(session.effectiveDelimiter)
                tvc.fileSession = session
                tvc.configureColumns(session.columns)
                tvc.autoFitAllColumns()
                session.computeColumnSummaries()
            case .failure(let error):
                tvc.statusBar.updateProgress(1.0)
                self.showError(error, context: "reloading with delimiter")
            }
        })
    }

    // MARK: - Encoding

    @objc private func changeEncodingAction(_ sender: NSMenuItem) {
        guard let encName = sender.representedObject as? String else { return }
        guard let session = activeTab?.fileSession, session.isFullyLoaded else { return }

        // If already the active encoding, do nothing
        if encName == session.activeEncodingName { return }

        // If there are unsaved changes, warn before reloading
        if session.isModified {
            let alert = NSAlert()
            alert.messageText = "Reloading will discard unsaved changes."
            alert.informativeText = "The file will be reloaded with the \(encName) encoding. Any unsaved edits will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")

            guard let win = self.activeWindow else { return }
            alert.beginSheetModal(for: win) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.reloadWithEncoding(encName)
            }
        } else {
            reloadWithEncoding(encName)
        }
    }

    private func reloadWithEncoding(_ encodingName: String) {
        guard let session = activeTab?.fileSession, let tvc = activeTab?.tableViewController else { return }

        let swiftEncoding = Self.swiftEncoding(forName: encodingName)

        tvc.statusBar.updateProgress(0)

        session.reload(withEncoding: encodingName, swiftEncoding: swiftEncoding, progress: { [weak self] fraction in
            self?.activeTab?.tableViewController?.statusBar.updateProgress(fraction)
        }, completion: { [weak self] result in
            guard let self = self, let tvc = self.activeTab?.tableViewController else { return }
            switch result {
            case .success(let totalRows):
                tvc.statusBar.updateProgress(1.0)
                tvc.statusBar.updateRowCount(showing: totalRows, total: totalRows)
                tvc.statusBar.updateEncoding(session.activeEncodingName)
                tvc.fileSession = session
                tvc.configureColumns(session.columns)
                tvc.autoFitAllColumns()
                session.computeColumnSummaries()
            case .failure(let error):
                tvc.statusBar.updateProgress(1.0)
                self.showError(error, context: "reloading with encoding \(encodingName)")
            }
        })
    }

    /// Maps encoding display names to Swift String.Encoding values.
    /// Returns nil for UTF-8 (no transcoding needed).
    private static func swiftEncoding(forName name: String) -> String.Encoding? {
        switch name {
        case "UTF-8":
            return nil // No transcoding needed — DuckDB reads UTF-8 natively
        case "UTF-16 LE":
            return .utf16LittleEndian
        case "UTF-16 BE":
            return .utf16BigEndian
        case "Latin-1 (ISO-8859-1)":
            return .isoLatin1
        case "Windows-1252":
            return .windowsCP1252
        case "ASCII":
            return .ascii
        case "Shift-JIS":
            return .shiftJIS
        case "EUC-KR":
            return String.Encoding(rawValue: 0x80000940)
        case "GB2312":
            return String.Encoding(rawValue: 0x80000930)
        case "Big5":
            return String.Encoding(rawValue: 0x80000A03)
        default:
            return nil
        }
    }

    // MARK: - Cell Edit Handling

    private func handleCellEdited(tab: TabContext, rowid: Int64, columnName: String, newValue: String, displayRow: Int) {
        guard let session = tab.fileSession, let tvc = tab.tableViewController else { return }

        session.updateCell(rowid: rowid, column: columnName, value: newValue, displayRow: displayRow) { [weak self] result in
            switch result {
            case .success:
                // Re-fetch the page containing the edited row to show the updated value
                let pageIndex = session.rowCache.pageIndex(forRow: displayRow)
                session.fetchPage(index: pageIndex) { _ in
                    // Use targeted reload to preserve scroll position and selection
                    let rowSet = IndexSet(integer: displayRow)
                    let colSet = IndexSet(integersIn: 0..<tvc.tableView.numberOfColumns)
                    tvc.reloadRows(rowSet, columns: colSet)
                    tvc.updateDetailPane()
                }
            case .failure(let error):
                self?.showError(error, context: "editing cell")
            }
        }
    }

    // MARK: - Add Column

    @objc private func addColumnAction(_ sender: Any?) {
        guard let tab = activeTab else { return }
        guard let session = tab.fileSession, session.isFullyLoaded else { return }
        guard let tvc = tab.tableViewController else { return }

        let existingNames = session.columns.map { $0.name }
        let sheetVC = AddColumnSheetController(existingColumns: existingNames)
        sheetVC.onAdd = { [weak self] name, duckDBType in
            self?.handleAddColumn(tab: tab, name: name, duckDBType: duckDBType)
        }

        tvc.presentAsSheet(sheetVC)
    }

    // MARK: - Add Computed Column (US-017)

    @objc private func addComputedColumnAction(_ sender: Any?) {
        guard let tab = activeTab else { return }
        guard let session = tab.fileSession, session.isFullyLoaded else { return }
        guard let tvc = tab.tableViewController else { return }

        ComputedColumnPanelController.show(fileSession: session)
        tvc.analysisBar.setFeatureActive(.computedColumn, active: true)
    }

    // MARK: - Computed Column Add/Remove (US-019)

    private func handleComputedColumnAdded(name: String, expression: String, session: FileSession) {
        guard let tab = tab(for: session), let tvc = tab.tableViewController else { return }

        let cc = ComputedColumn(name: name, expression: expression)
        var newState = session.viewState
        newState.computedColumns.append(cc)
        session.updateViewState(newState)

        // Add the computed column to the table display
        tvc.addComputedColumn(name: name)

        let startTime = CFAbsoluteTimeGetCurrent()

        // Re-fetch page 0 with the new computed column in the SELECT
        session.fetchPage(index: 0) { result in
            let queryTime = CFAbsoluteTimeGetCurrent() - startTime

            switch result {
            case .success:
                tvc.reloadVisibleRows()
                tvc.statusBar.showQueryTime(queryTime)
            case .failure:
                break
            }

            tvc.statusBar.updateRowCount(
                showing: session.viewState.totalFilteredRows,
                total: session.totalRows
            )
        }

        tvc.reloadVisibleRows()
    }

    private func handleComputedColumnRemoved(tab: TabContext, columnName: String) {
        guard let session = tab.fileSession, let tvc = tab.tableViewController else { return }

        var newState = session.viewState
        newState.computedColumns.removeAll { $0.name == columnName }

        // Also remove any sorts/filters referencing this column
        newState.sortColumns.removeAll { $0.column == columnName }
        newState.filters.removeAll { $0.column == columnName }
        if newState.selectedColumn == columnName {
            newState.selectedColumn = nil
        }
        session.updateViewState(newState)

        // Remove the column from the table display
        tvc.removeComputedColumn(name: columnName)
        tvc.updateSortIndicators()
        tvc.updateFilterBar()

        // Re-fetch page 0 without the removed computed column
        session.fetchPage(index: 0) { _ in
            tvc.reloadVisibleRows()
        }

        tvc.statusBar.updateRowCount(
            showing: session.viewState.totalFilteredRows,
            total: session.totalRows
        )
    }

    // MARK: - Rename Column (from Edit menu)

    @objc private func renameColumnAction(_ sender: Any?) {
        guard let tab = activeTab else { return }
        guard let session = tab.fileSession, session.isFullyLoaded else { return }
        guard let tvc = tab.tableViewController else { return }
        let columnName = tvc.selectedColumnName
        guard !columnName.isEmpty, columnName != "_gridka_rowid" else { return }

        let existingNames = session.columns.map { $0.name }
        let renameVC = RenameColumnPopoverController(currentName: columnName, existingNames: existingNames)
        renameVC.onRename = { [weak self] newName in
            self?.handleColumnRenamed(tab: tab, oldName: columnName, newName: newName)
        }

        let popover = NSPopover()
        popover.contentViewController = renameVC
        popover.behavior = .transient
        renameVC.popover = popover

        // Show relative to the column header
        if let headerView = tvc.tableView.headerView,
           let colIndex = tvc.tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == columnName }) {
            let headerRect = headerView.headerRect(ofColumn: colIndex)
            popover.show(relativeTo: headerRect, of: headerView, preferredEdge: .maxY)
        } else {
            // Fallback: show as sheet
            tvc.presentAsSheet(renameVC)
        }
    }

    // MARK: - Delete Column (from Edit menu)

    @objc private func deleteColumnAction(_ sender: Any?) {
        guard let tab = activeTab else { return }
        guard let session = tab.fileSession, session.isFullyLoaded else { return }
        guard let tvc = tab.tableViewController else { return }
        let columnName = tvc.selectedColumnName
        guard !columnName.isEmpty, columnName != "_gridka_rowid" else { return }

        let alert = NSAlert()
        alert.messageText = "Delete column \"\(columnName)\"?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let win = activeWindow else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.handleColumnDeleted(tab: tab, columnName: columnName)
        }
    }

    // MARK: - Add Row

    @objc private func addRowAction(_ sender: Any?) {
        guard let session = activeTab?.fileSession, session.isFullyLoaded else { return }
        handleAddRow()
    }

    private func handleAddRow() {
        guard let session = activeTab?.fileSession, let tvc = activeTab?.tableViewController else { return }

        session.addRow { [weak self] result in
            switch result {
            case .success:
                let newRowIndex = session.viewState.totalFilteredRows - 1
                tvc.reloadVisibleRows()
                tvc.statusBar.updateRowCount(
                    showing: session.viewState.totalFilteredRows,
                    total: session.totalRows
                )

                // Scroll to the new row and auto-enter edit mode on the first editable cell
                tvc.tableView.scrollRowToVisible(newRowIndex)

                // Fetch the page containing the new row, then begin editing
                let pageIndex = session.rowCache.pageIndex(forRow: newRowIndex)
                session.fetchPage(index: pageIndex) { _ in
                    tvc.reloadVisibleRows()

                    // Find the first editable column (skip _gridka_rowid)
                    let editableColIndex = tvc.tableView.tableColumns.firstIndex(where: {
                        $0.identifier.rawValue != "_gridka_rowid"
                    })
                    if let colIndex = editableColIndex {
                        let columnName = tvc.tableView.tableColumns[colIndex].identifier.rawValue
                        DispatchQueue.main.async {
                            tvc.beginEditingCell(row: newRowIndex, column: colIndex, columnName: columnName)
                        }
                    }
                }

            case .failure(let error):
                self?.showError(error, context: "adding row")
            }
        }
    }

    // MARK: - Delete Rows

    @objc private func deleteRowsAction(_ sender: Any?) {
        guard let session = activeTab?.fileSession, session.isFullyLoaded else { return }
        guard let tvc = activeTab?.tableViewController else { return }
        let selectedIndexes = tvc.tableView.selectedRowIndexes
        guard !selectedIndexes.isEmpty else { return }

        handleDeleteRows(selectedIndexes: selectedIndexes)
    }

    private func handleDeleteRows(selectedIndexes: IndexSet) {
        guard let session = activeTab?.fileSession, let tvc = activeTab?.tableViewController else { return }

        let count = selectedIndexes.count
        let alert = NSAlert()
        alert.messageText = "Delete \(count) row\(count == 1 ? "" : "s")?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let win = activeWindow else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self = self else { return }

            // Collect _gridka_rowid values for all selected rows
            var rowids: [Int64] = []
            for row in selectedIndexes {
                if let rowidValue = session.rowCache.value(forRow: row, columnName: "_gridka_rowid"),
                   case .integer(let rowid) = rowidValue {
                    rowids.append(rowid)
                }
            }

            guard !rowids.isEmpty else { return }

            session.deleteRows(rowids: rowids) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    // Requery the filtered count to update totalFilteredRows
                    session.requeryFilteredCount()

                    tvc.tableView.deselectAll(nil)
                    tvc.reloadVisibleRows()

                    // Update status bar row counts after requeryCount completes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        tvc.statusBar.updateRowCount(
                            showing: session.viewState.totalFilteredRows,
                            total: session.totalRows
                        )
                    }
                case .failure(let error):
                    self.showError(error, context: "deleting rows")
                }
            }
        }
    }

    private func handleAddColumn(tab: TabContext, name: String, duckDBType: String) {
        guard let session = tab.fileSession, let tvc = tab.tableViewController else { return }

        session.addColumn(name: name, duckDBType: duckDBType) { [weak self] result in
            switch result {
            case .success(let columns):
                tvc.configureColumns(columns)
                // Scroll to reveal the new column
                let lastCol = tvc.tableView.numberOfColumns - 1
                if lastCol >= 0 {
                    tvc.tableView.scrollColumnToVisible(lastCol)
                }
                tvc.statusBar.updateRowCount(
                    showing: session.viewState.totalFilteredRows,
                    total: session.totalRows
                )
            case .failure(let error):
                self?.showError(error, context: "adding column")
            }
        }
    }

    // MARK: - Rename Column

    private func handleColumnRenamed(tab: TabContext, oldName: String, newName: String) {
        guard let session = tab.fileSession, let tvc = tab.tableViewController else { return }

        session.renameColumn(oldName: oldName, newName: newName) { [weak self] result in
            switch result {
            case .success(let columns):
                tvc.configureColumns(columns)
                tvc.updateSortIndicators()
                tvc.updateFilterBar()

                // Re-fetch page 0 to populate the cache with renamed columns
                session.fetchPage(index: 0) { _ in
                    tvc.reloadVisibleRows()
                }

                tvc.statusBar.updateRowCount(
                    showing: session.viewState.totalFilteredRows,
                    total: session.totalRows
                )
            case .failure(let error):
                self?.showError(error, context: "renaming column")
            }
        }
    }

    // MARK: - Change Column Type

    private func handleColumnTypeChanged(tab: TabContext, columnName: String, duckDBType: String) {
        guard let session = tab.fileSession, let tvc = tab.tableViewController else { return }

        session.changeColumnType(columnName: columnName, newDuckDBType: duckDBType) { [weak self] result in
            switch result {
            case .success(let columns):
                tvc.configureColumns(columns)
                tvc.updateSortIndicators()

                // Re-fetch page 0 to populate the cache with new type values
                session.fetchPage(index: 0) { _ in
                    tvc.reloadVisibleRows()
                    tvc.updateDetailPane()
                }

                tvc.statusBar.updateRowCount(
                    showing: session.viewState.totalFilteredRows,
                    total: session.totalRows
                )
            case .failure(let error):
                self?.showError(error, context: "changing column type")
            }
        }
    }

    // MARK: - Delete Column

    private func handleColumnDeleted(tab: TabContext, columnName: String) {
        guard let session = tab.fileSession, let tvc = tab.tableViewController else { return }

        session.deleteColumn(name: columnName) { [weak self] result in
            switch result {
            case .success(let columns):
                tvc.configureColumns(columns)
                tvc.updateSortIndicators()
                tvc.updateFilterBar()

                // Re-fetch page 0 to populate the cache without the deleted column
                session.fetchPage(index: 0) { _ in
                    tvc.reloadVisibleRows()
                    tvc.updateDetailPane()
                }

                tvc.statusBar.updateRowCount(
                    showing: session.viewState.totalFilteredRows,
                    total: session.totalRows
                )
            case .failure(let error):
                self?.showError(error, context: "deleting column")
            }
        }
    }

    // MARK: - Column Selection Handling

    private func handleColumnSelected(tab: TabContext, columnName: String?) {
        guard let session = tab.fileSession, let tvc = tab.tableViewController else { return }

        var newState = session.viewState
        newState.selectedColumn = columnName
        session.updateViewState(newState)

        tvc.updateSortIndicators()
        tvc.updateProfilerSidebar()
    }

    // MARK: - Analysis Feature Handling

    private func handleAnalysisFeatureToggled(tab: TabContext, feature: AnalysisFeature, isActive: Bool) {
        guard let tvc = tab.tableViewController else { return }
        switch feature {
        case .profiler:
            // Sync profiler sidebar visibility with toolbar button state
            if isActive != tvc.isProfilerVisible {
                tvc.toggleProfilerSidebar()
            }
        case .frequency:
            if isActive {
                if let selectedCol = tab.fileSession?.viewState.selectedColumn,
                   let session = tab.fileSession {
                    FrequencyPanelController.show(column: selectedCol, fileSession: session)
                }
            } else {
                FrequencyPanelController.closeIfOpen()
            }
            tvc.analysisBar.setFeatureActive(.frequency, active: FrequencyPanelController.isVisible)
        case .groupBy:
            // Placeholder: implemented in later stories.
            break
        case .computedColumn:
            if isActive {
                guard let session = tab.fileSession else { return }
                ComputedColumnPanelController.show(fileSession: session)
            } else {
                ComputedColumnPanelController.closeIfOpen()
            }
            tvc.analysisBar.setFeatureActive(.computedColumn, active: ComputedColumnPanelController.isVisible)
        }
    }

    // MARK: - Search Handling

    @objc private func performFind(_ sender: Any?) {
        activeTab?.tableViewController?.toggleSearchBar()
    }

    @objc private func performFindNext(_ sender: Any?) {
        guard let tvc = activeTab?.tableViewController, tvc.searchBar.isVisible else { return }
        tvc.searchBar.onNavigate?(1)
    }

    @objc private func performFindPrevious(_ sender: Any?) {
        guard let tvc = activeTab?.tableViewController, tvc.searchBar.isVisible else { return }
        tvc.searchBar.onNavigate?(-1)
    }

    private func handleSearchChanged(_ term: String) {
        guard let session = activeTab?.fileSession, let tvc = activeTab?.tableViewController else { return }

        // Only allow search when fully loaded
        guard session.isFullyLoaded else { return }

        var newState = session.viewState
        newState.searchTerm = term.isEmpty ? nil : term
        session.updateViewState(newState)

        tvc.updateProfilerSidebar()

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
        let session = activeTab?.fileSession
        let tvc = activeTab?.tableViewController

        if menuItem.action == #selector(saveDocument(_:)) {
            return session?.isModified ?? false
        }
        if menuItem.action == #selector(saveAsDocument(_:)) {
            return session?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(addColumnAction(_:)) {
            return session?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(addComputedColumnAction(_:)) {
            return session?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(renameColumnAction(_:)) {
            guard session?.isFullyLoaded ?? false else {
                menuItem.title = "Rename Column…"
                return false
            }
            let col = tvc?.selectedColumnName ?? ""
            if !col.isEmpty && col != "_gridka_rowid" {
                menuItem.title = "Rename Column \"\(col)\"…"
                return true
            }
            menuItem.title = "Rename Column…"
            return false
        }
        if menuItem.action == #selector(deleteColumnAction(_:)) {
            guard session?.isFullyLoaded ?? false else {
                menuItem.title = "Delete Column"
                return false
            }
            let col = tvc?.selectedColumnName ?? ""
            if !col.isEmpty && col != "_gridka_rowid" {
                menuItem.title = "Delete Column \"\(col)\""
                return true
            }
            menuItem.title = "Delete Column"
            return false
        }
        if menuItem.action == #selector(addRowAction(_:)) {
            return session?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(deleteRowsAction(_:)) {
            guard session?.isFullyLoaded ?? false else { return false }
            return (tvc?.tableView.selectedRowIndexes.isEmpty == false)
        }
        if menuItem.action == #selector(toggleHeaderAction(_:)) {
            menuItem.state = (session?.hasHeaders ?? true) ? .on : .off
            return session?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(toggleRowNumbersAction(_:)) {
            menuItem.state = (tvc?.isRowNumbersVisible ?? false) ? .on : .off
            return tvc != nil
        }
        if menuItem.action == #selector(changeDelimiterAction(_:)) {
            guard let delim = menuItem.representedObject as? String else { return false }
            let effective = session?.customDelimiter
            if delim.isEmpty {
                // "Auto-detect" is checked when no custom delimiter is set
                menuItem.state = (effective == nil) ? .on : .off
            } else {
                menuItem.state = (effective == delim) ? .on : .off
            }
            return session?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(changeEncodingAction(_:)) {
            guard let encName = menuItem.representedObject as? String else { return false }
            menuItem.state = (encName == session?.activeEncodingName) ? .on : .off
            return session?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(customDelimiterAction(_:)) {
            // Check if current delimiter is a custom one not in the standard list
            if let effective = session?.customDelimiter,
               ![",", "\t", ";", "|", "~"].contains(effective) {
                menuItem.state = .on
            } else {
                menuItem.state = .off
            }
            return session?.isFullyLoaded ?? false
        }
        if menuItem.action == #selector(toggleAnalysisToolbarAction(_:)) {
            let visible = tvc?.analysisBar?.isToolbarVisible ?? false
            menuItem.title = visible ? "Hide Analysis Toolbar" : "Show Analysis Toolbar"
            return tvc != nil
        }
        if menuItem.action == #selector(toggleProfilerAction(_:)) {
            let visible = tvc?.isProfilerVisible ?? false
            menuItem.title = visible ? "Hide Column Profiler" : "Toggle Column Profiler"
            return tvc != nil
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
        if let win = activeWindow {
            alert.beginSheetModal(for: win)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {

    func windowDidBecomeKey(_ notification: Notification) {
        // No action needed — activeWindow uses NSApp.keyWindow dynamically.
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // If we're closing after a save prompt, allow it immediately
        if windowsClosingAfterPrompt.remove(sender) != nil {
            return true
        }

        guard let tab = windowTabs[sender] else { return true }
        guard let session = tab.fileSession, session.isModified else {
            // No unsaved changes — allow close immediately
            return true
        }

        // Show save prompt for unsaved changes
        let filename = session.filePath.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(filename)\" before closing?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")        // First button = .alertFirstButtonReturn
        alert.addButton(withTitle: "Don't Save")   // Second button = .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")        // Third button = .alertThirdButtonReturn

        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self = self, let sender = sender else { return }
            switch response {
            case .alertFirstButtonReturn:
                // Save, then close
                session.save { [weak self, weak sender] result in
                    guard let self = self, let sender = sender else { return }
                    switch result {
                    case .success:
                        self.windowsClosingAfterPrompt.insert(sender)
                        sender.close()
                    case .failure(let error):
                        self.showError(error, context: "saving file")
                    }
                }
            case .alertSecondButtonReturn:
                // Don't Save — close without saving
                self.windowsClosingAfterPrompt.insert(sender)
                sender.close()
            default:
                // Cancel — do nothing, keep the window open
                break
            }
        }

        return false // Don't close yet — the alert handler will close if needed
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }

        // Disconnect all delegate/dataSource/target pointers immediately.
        if let tab = windowTabs[win] {
            // Close floating panels if they belong to this tab's session
            if let session = tab.fileSession {
                FrequencyPanelController.closeIfOwned(by: session)
                ComputedColumnPanelController.closeIfOwned(by: session)
            }
            tab.tableViewController?.tearDown()
            tab.fileSession?.onModifiedChanged = nil
        }

        // Release the TabContext (and its FileSession, DuckDBEngine, etc.).
        // The window itself is safe because isReleasedWhenClosed = false,
        // so AppKit won't send an extra release that ARC doesn't expect.
        windowTabs.removeValue(forKey: win)

        // Rebalance memory limits among remaining tabs
        rebalanceMemoryLimits()
    }
}
